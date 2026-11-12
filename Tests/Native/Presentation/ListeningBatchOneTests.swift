import AppKit
import Compression
import XCTest
@testable import SpotifyLyrics

/// Round 15 batch one: Canvas from the Spotify cache, cover colour routes,
/// tempo-timed line follow, censored words, lyric-end evidence, seek snap
/// and seek hold.
final class ListeningBatchOneTests: XCTestCase {
    // MARK: Spotify cache

    func testSnappyLiteralAndOverlappingCopy() {
        // Length 9; literal "ab"; a 1-byte-offset copy of 7 from 2 back:
        // tag (7 - 4) << 2 | 1 = 13. The copy overlaps what it writes.
        let fixed: [UInt8] = [9, 0x04, 0x61, 0x62, 13, 2]
        XCTAssertEqual(Snappy.decompress(fixed).map { String(decoding: $0, as: UTF8.self) }, "ababababa")
        XCTAssertNil(Snappy.decompress([5, 0x04, 0x61, 0x62]), "a short result is rejected")
    }

    func testBlockEntriesSharePrefixes() {
        // Two entries: "key1"→"a", "key2"→"b" (shares 3 bytes), one restart.
        var block: [UInt8] = [0, 4, 1] + Array("key1".utf8) + Array("a".utf8)
        block += [3, 1, 1] + Array("2".utf8) + Array("b".utf8)
        block += [0, 0, 0, 0, 1, 0, 0, 0]
        let entries = LevelDBFileReader.blockEntries(block)
        XCTAssertEqual(entries.map { String(decoding: $0.key, as: UTF8.self) }, ["key1", "key2"])
        XCTAssertEqual(entries.map { String(decoding: $0.value, as: UTF8.self) }, ["a", "b"])
    }

    private func canvasValue(url: String, kind: UInt64, uri: String) -> [UInt8] {
        func bytes(_ field: UInt8, _ text: String) -> [UInt8] { [field << 3 | 2, UInt8(text.utf8.count)] + Array(text.utf8) }
        let message = bytes(2, url) + [4 << 3, UInt8(kind)] + bytes(5, uri)
        let typeURL = "type.googleapis.com/spotify.canvaz.cache.EntityCanvazResponse.Canvaz"
        return [0x0A, UInt8(typeURL.utf8.count)] + Array(typeURL.utf8) + [0x12, UInt8(message.count)] + message
    }

    func testCanvasValueNeedsVideoKindAndTheSameTrack() {
        let uri = "spotify:track:4ygNS3AtvJmdKCa1SU2FEa"
        let clip = "https://canvaz.scdn.co/upload/artist/x/video/abc.cnvs.mp4"
        XCTAssertEqual(SpotifyCanvasLocator.canvasURL(fromValue: canvasValue(url: clip, kind: 2, uri: uri), trackURI: uri)?.absoluteString, clip)
        XCTAssertNil(SpotifyCanvasLocator.canvasURL(fromValue: canvasValue(url: clip, kind: 0, uri: uri), trackURI: uri), "images are not used")
        XCTAssertNil(SpotifyCanvasLocator.canvasURL(fromValue: canvasValue(url: clip, kind: 2, uri: "spotify:track:other"), trackURI: uri))
        XCTAssertNil(SpotifyCanvasLocator.canvasURL(fromValue: canvasValue(url: "https://evil.example/a.mp4", kind: 2, uri: uri), trackURI: uri))
    }

    func testCanvasCacheKeyShape() {
        let key = SpotifyCanvasLocator.cacheKey(trackURI: "spotify:track:abc")!
        XCTAssertEqual(Array(key.prefix(13)), Array("!xmeta#cache#".utf8))
        XCTAssertEqual(Array(key[13...16]), [0x01, 0x30, UInt8(ascii: "#"), 17])
        XCTAssertEqual(key.last, UInt8(ascii: "#"))
    }

    func testArtistPhotoUsesTheLargerSize() {
        let small = URL(string: "https://image-cdn-fa.spotifycdn.com/image/ab67616100005174ddfeef94d35f21d1af62a9d9")!
        XCTAssertEqual(V3ArtistImageStore.larger(small).absoluteString,
                       "https://image-cdn-fa.spotifycdn.com/image/ab6761610000e5ebddfeef94d35f21d1af62a9d9")
    }

    func testCoverFallbackUsesTheLargerSize() {
        let small = URL(string: "https://image-cdn-ak.spotifycdn.com/image/ab67616d00001e02f1abf2765238ce9f309e0b7d")!
        XCTAssertEqual(SpotifyPublicArtwork.larger(small).absoluteString,
                       "https://image-cdn-ak.spotifycdn.com/image/ab67616d0000b273f1abf2765238ce9f309e0b7d")
        XCTAssertEqual(SpotifyPublicArtwork.trackID(from: "spotify:track:5Q8K5lNtJlRMIsMB1Ha8P6"), "5Q8K5lNtJlRMIsMB1Ha8P6")
        XCTAssertNil(SpotifyPublicArtwork.trackID(from: "spotify:local:abc"))
    }

    func testBackdropSourceIsOneChoice() {
        XCTAssertEqual(V3BackdropSource.migrated(source: nil, usesVideo: nil), .video)
        XCTAssertEqual(V3BackdropSource.migrated(source: "", usesVideo: false), .cover)
        XCTAssertEqual(V3BackdropSource.migrated(source: "artist", usesVideo: true), .artist,
                       "a chosen photo is no longer hidden by the video")
    }

    // MARK: Cover colour routes

    private func pixels(_ parts: [((Double, Double, Double), Int)]) -> [(Double, Double, Double)] {
        parts.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    func testDarkCoverWithOneColourIsDarkIdentity() {
        let cover = pixels([((0.04, 0.04, 0.05), 70), ((0.85, 0.15, 0.10), 30)])
        let result = CoverColorRoute.analyze(cover)
        XCTAssertEqual(result.route, .darkIdentity)
        XCTAssertNotNil(result.identity)
    }

    func testTwoStrongColoursAreDuet() {
        let cover = pixels([((0.05, 0.12, 0.45), 50), ((0.95, 0.75, 0.15), 40), ((0.1, 0.1, 0.1), 10)])
        XCTAssertEqual(CoverColorRoute.analyze(cover).route, .duet)
        XCTAssertEqual(V3SceneFamily.automaticAmbient(luminance: 0.3, route: .duet).title, "双色")
    }

    func testPaleGreyCoverIsPaleNeutral() {
        let cover = pixels([((0.88, 0.88, 0.86), 80), ((0.6, 0.6, 0.62), 20)])
        XCTAssertEqual(CoverColorRoute.analyze(cover).route, .paleNeutral)
    }

    func testDeepNavyCountsAsColour() {
        // Absolute chroma would call this grey; relative chroma does not.
        let cover = pixels([((0.03, 0.05, 0.16), 60), ((0.02, 0.02, 0.02), 40)])
        XCTAssertNotNil(CoverColorRoute.analyze(cover).identity)
    }

    // MARK: Tempo and lines

    func testLineFollowKeepsTimeOnlyWithATempo() {
        XCTAssertEqual(V3LyricMotionPolicy.followDuration(bpm: nil), V3LyricMotionPolicy.followDuration)
        XCTAssertEqual(V3LyricMotionPolicy.followDuration(bpm: 60), 0.56, accuracy: 0.001)
        XCTAssertEqual(V3LyricMotionPolicy.followDuration(bpm: 150), 0.32, accuracy: 0.001)
        XCTAssertEqual(V3LyricMotionPolicy.followDuration(bpm: 200), 0.32, accuracy: 0.001)
    }

    /// A drum-like onset curve: strong beats, weaker off-beat eighth notes.
    private func onsets(bpm: Double, seconds: Double = 8, eighths: Double = 0.45) -> [Double] {
        let fps = PulseAnalyzer.framesPerSecond
        let period = 60.0 / bpm * fps
        return (0..<Int(fps * seconds)).map { index -> Double in
            let phase = fmod(Double(index), period)
            if phase < 1 { return 1 }
            if abs(phase - period / 2) < 0.5 { return eighths }
            return 0.02 * Double((index * 7) % 5)
        }
    }

    func testTempoFromARegularBeat() {
        let fps = PulseAnalyzer.framesPerSecond
        // 80–160 BPM. Outside it a steady pulse is as much half or double
        // (174 reads as 87, 70 as 140); Spotify's own tempo covers those songs.
        for bpm in [150.0, 128.0, 92.0, 110.0, 84.0] {
            let estimate = PulseAnalyzer.tempo(onsets(bpm: bpm), fps: fps) ?? 0
            XCTAssertEqual(estimate, bpm, accuracy: bpm * 0.03, "\(bpm) BPM")
        }
        XCTAssertEqual(PulseAnalyzer.tempo(onsets(bpm: 150, seconds: 4), fps: fps) ?? 0, 150, accuracy: 4.5,
                       "four seconds are enough")
    }

    func testSpotifyAnalysisFields() {
        // AudioAttributes: 1 tempo (double), 2 { 1 "B", 2 mode, 3 { 1 "1B" } }.
        var tempo = Data(count: 8); tempo.withUnsafeMutableBytes { $0.storeBytes(of: (150.0).bitPattern.littleEndian, as: UInt64.self) }
        let camelot: [UInt8] = [0x0A, 2] + Array("1B".utf8)
        let keyPart: [UInt8] = [0x0A, 1] + Array("B".utf8) + [0x10, 2] + [0x1A, UInt8(camelot.count)] + camelot
        let attributes: [UInt8] = [0x09] + [UInt8](tempo) + [0x12, UInt8(keyPart.count)] + keyPart
        var analysis = SpotifyTrackAnalysis()
        analysis.apply(attributes: attributes)
        XCTAssertEqual(analysis.bpm, 150)
        XCTAssertEqual(analysis.key, "B")
        XCTAssertEqual(analysis.camelot, "1B")
        // Beats: 2 { 1 time (float), 3 beat in bar }.
        func beat(_ time: Float, _ position: UInt8) -> [UInt8] {
            var raw = Data(count: 4); raw.withUnsafeMutableBytes { $0.storeBytes(of: time.bitPattern.littleEndian, as: UInt32.self) }
            let body: [UInt8] = [0x0D] + [UInt8](raw) + [0x18, position]
            return [0x12, UInt8(body.count)] + body
        }
        let beats = SpotifyTrackAnalysis.beats([0x08, 4] + beat(0.81, 4) + beat(0.41, 3) + beat(1.21, 1))
        XCTAssertEqual(beats.map(\.positionInBar), [3, 4, 1])
        XCTAssertEqual(beats.first?.time ?? 0, 0.41, accuracy: 0.001)
    }

    // MARK: Censored words

    func testCensoredWordsAreRestoredAtTheSameLength() {
        XCTAssertEqual(LyricCensorRestorer.restore("What the f**k is this sh*t"), "What the fuck is this shit")
        XCTAssertEqual(LyricCensorRestorer.restore("F**K it, motherf**ker"), "FUCK it, motherfucker")
        XCTAssertEqual(LyricCensorRestorer.restore("kiss my a**"), "kiss my ass")
        XCTAssertEqual(LyricCensorRestorer.restore("5 * 3 = 15"), "5 * 3 = 15")
        XCTAssertEqual(LyricCensorRestorer.restore("no stars here"), "no stars here")
    }

    func testRestoredLineKeepsWordTiming() {
        let text = "oh f**k"
        let spans = [TimedTextSpan(id: 0, text: "oh", trailingWhitespace: " ", startTime: 1, endTime: 1.5, utf16Start: 0, utf16Length: 2),
                     TimedTextSpan(id: 1, text: "f**k", startTime: 1.5, endTime: 2, utf16Start: 3, utf16Length: 4)]
        let line = LyricLine(timestamp: 1, originalText: text, timedSpans: spans)
        let projected = ReadingProjection.empty.applying(to: [line], restoresCensoredWords: true)[0]
        XCTAssertEqual(projected.readingSurfaceText, "oh fuck")
        XCTAssertEqual(projected.timedSpans?.map(\.text), ["oh", "fuck"])
        XCTAssertEqual(projected.originalText, text, "the stored text is not changed")
        XCTAssertNil(ReadingProjection.empty.applying(to: [line]).first?.readingSurfaceText)
    }

    // MARK: Matching

    func testLyricsEndAgainstSongLength() {
        let lines = [LyricLine(timestamp: 10, originalText: "a"), LyricLine(timestamp: 200, originalText: "b")]
        XCTAssertEqual(LyricsSafeMatcher.lyricsEndFit(lines: lines, synchronized: true, songDuration: 210), .fits(1 - (10.0 / 210) / 0.25))
        XCTAssertEqual(LyricsSafeMatcher.lyricsEndFit(lines: lines, synchronized: true, songDuration: 180), .overshoots)
        XCTAssertEqual(LyricsSafeMatcher.lyricsEndFit(lines: lines, synchronized: true, songDuration: 400), .early)
        XCTAssertNil(LyricsSafeMatcher.lyricsEndFit(lines: lines, synchronized: false, songDuration: 210))
    }

    func testTraditionalAndSimplifiedTitlesMatch() {
        XCTAssertEqual(TrackTextNormalizer.normalize("曾經你說（說唱版）"), TrackTextNormalizer.normalize("曾经你说 (说唱版)"))
        XCTAssertEqual(TrackTextNormalizer.normalizeArtistToken("趙乃吉"), TrackTextNormalizer.normalizeArtistToken("赵乃吉"))
        XCTAssertNotEqual(TrackTextNormalizer.normalize("曾經", foldsChineseScript: false),
                          TrackTextNormalizer.normalize("曾经", foldsChineseScript: false))
    }

    // MARK: Kugou KRC

    private let krcSample = """
    [ti:]
    [0,272]<0,17,0>曾<17,17,0>经<34,17,0>你<51,17,0>说
    [5580,3390]<0,330,0>不<330,420,0>如<750,660,0>看
    [14010,1740]<0,990,0>刘<990,630,0>兆<1620,60,0>宇<1680,60,0>：
    [17910,1050]<0,180,0>一<180,120,0>个<300,90,0>人
    [20000,1000]<0,500,0>赵<500,300,0>乃<800,200,0>吉<1000,0,0>：
    [21000,1000]<0,500,0>(时<500,500,0>光)
    """

    func testKRCWordTimingAndSingers() throws {
        let identity = TrackIdentity(title: "曾经你说", artist: "赵乃吉", album: "", duration: 201)
        let document = try XCTUnwrap(KRCParser.parse(krcSample, identity: identity, source: .kugouExperimental))
        XCTAssertEqual(document.lines.map(\.originalText), ["曾经你说", "不如看", "一个人", "(时光)"],
                       "singer lines are not shown")
        let second = document.lines[1]
        XCTAssertEqual(second.timedSpans?.map(\.text), ["不", "如", "看"])
        XCTAssertEqual(second.timedSpans?[1].startTime ?? 0, 5.91, accuracy: 0.001, "offsets are relative to the line")
        XCTAssertEqual(document.lines.map(\.performerID), [nil, nil, "刘兆宇", "赵乃吉"])
        XCTAssertEqual(LyricAgentPresentationMap(lines: document.lines).voiceIndex(for: "赵乃吉"), 1)
        XCTAssertNil(LyricAgentPresentationMap.displayName("v2"))
    }

    func testKRCDecryptRoundTrip() throws {
        let text = "[0,100]<0,100,0>好"
        let source = Array(text.utf8)
        var deflated = [UInt8](repeating: 0, count: 256)
        let size = compression_encode_buffer(&deflated, deflated.count, source, source.count, nil, COMPRESSION_ZLIB)
        var payload: [UInt8] = [0x78, 0x9C] + deflated[0..<size] + [0, 0, 0, 0]
        for index in payload.indices { payload[index] ^= KRCParser.key[index % KRCParser.key.count] }
        let encoded = (Data("krc1".utf8) + Data(payload)).base64EncodedString()
        XCTAssertEqual(KRCParser.decrypt(base64: encoded), text)
    }

    // MARK: QQ QRC

    func testQQDESDecryptsARealBlock() {
        // First block of a real QRC download; it opens a zlib stream (78 9C).
        let cipher: [UInt8] = [0x28, 0xBE, 0xE4, 0xBD, 0xFC, 0x7B, 0xEB, 0x3B]
        let key = QRCParser.key
        var block = QQDES.crypt(cipher, QQDES.subkeys(Array(key[16..<24]), decrypt: true))
        block = QQDES.crypt(block, QQDES.subkeys(Array(key[8..<16]), decrypt: false))
        block = QQDES.crypt(block, QQDES.subkeys(Array(key[0..<8]), decrypt: true))
        XCTAssertEqual(block, [0x78, 0x9C, 0x4D, 0x5B, 0x5B, 0x8F, 0x55, 0x47])
    }

    func testQRCLinesWordsAndSingers() {
        let content = """
        [0,272]曾(0,17)经(17,17)
        [5580,1000]((5580,100)时(5680,400)光(6080,500))(6580,0)
        [9000,500]刘(9000,100)兆(9100,100)宇(9200,100)：(9300,100)
        [10000,800]一(10000,400)个(10400,400)
        [11000,500]赵(11000,100)乃(11100,100)吉(11200,100)：(11300,100)
        [12000,800]人(12000,800)
        """
        let lines = QRCParser.parseLines(content)
        XCTAssertEqual(lines.map(\.originalText), ["曾经", "(时光)", "一个", "人"])
        XCTAssertEqual(lines[1].timedSpans?.map(\.text), ["(", "时", "光", ")"], "brackets are words, not timing")
        XCTAssertEqual(lines[1].timedSpans?[1].startTime ?? 0, 5.68, accuracy: 0.001, "QRC times are absolute")
        XCTAssertEqual(lines.map(\.performerID), [nil, nil, "刘兆宇", "赵乃吉"])
        XCTAssertEqual(QRCParser.lyricContent(fromXML: "<Lyric_1 LyricType=\"1\" LyricContent=\"[0,1]a(0,1)&amp;\"/>"), "[0,1]a(0,1)&")
    }

    func testTitlesDifferingOnlyInPunctuationOrVersionName() {
        XCTAssertTrue(LyricsSafeMatcher.titleOnlyAddsVersionName(track: "听悲伤的情歌 - 女版", candidate: "听悲伤的情歌"))
        XCTAssertFalse(LyricsSafeMatcher.titleOnlyAddsVersionName(track: "听悲伤的情歌 (伴奏)", candidate: "听悲伤的情歌"))
        XCTAssertFalse(LyricsSafeMatcher.titleOnlyAddsVersionName(track: "听悲伤的情歌 (DJ版)", candidate: "听悲伤的情歌"))
        XCTAssertFalse(LyricsSafeMatcher.titleOnlyAddsVersionName(track: "听悲伤的情歌", candidate: "听悲伤的情歌"))
    }

    // MARK: Seeking

    func testDragLandsOnTheNearestLineStart() {
        let lines = [LyricLine(timestamp: 10, originalText: "a"), LyricLine(timestamp: 20, originalText: "b"),
                     LyricLine(timestamp: 21, originalText: " ")]
        XCTAssertEqual(PlaybackState.lyricSnappedTarget(19.2, lines: lines, synchronized: true), 20)
        XCTAssertEqual(PlaybackState.lyricSnappedTarget(15, lines: lines, synchronized: true), 15, "no line within 1.5 s")
        XCTAssertEqual(PlaybackState.lyricSnappedTarget(20.8, lines: lines, synchronized: true), 20, "empty lines are not targets")
        XCTAssertEqual(PlaybackState.lyricSnappedTarget(19.2, lines: lines, synchronized: false), 19.2)
    }

    func testSeekHoldIgnoresTheOldPositionForAMoment() {
        let pending = PlaybackState.PendingSeek(target: 100, issuedAt: 50, trackKey: "k")
        XCTAssertEqual(PlaybackState.heldPosition(reported: 30, isPlaying: true, pending: pending, now: 50.5), 100.5)
        XCTAssertNil(PlaybackState.heldPosition(reported: 100.4, isPlaying: true, pending: pending, now: 50.5), "Spotify caught up")
        XCTAssertNil(PlaybackState.heldPosition(reported: 30, isPlaying: true, pending: pending, now: 53), "held at most 2.2 s")
    }
}
