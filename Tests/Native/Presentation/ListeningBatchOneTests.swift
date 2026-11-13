import AppKit
import Compression
import SwiftUI
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

    // MARK: Chorus

    func testChorusIsTheRepeatedRun() {
        let texts = ["开头一句话", "第二句不一样", "我们一起唱副歌", "副歌第二句很长", "主歌第二段", "又换了词",
                     "我们一起唱副歌", "副歌第二句很长", "结尾"]
        let lines = texts.enumerated().map { LyricLine(timestamp: Double($0.offset * 5 + 1), originalText: $0.element) }
        let spans = LyricsChorus.compute(lines: lines, duration: 60)
        XCTAssertEqual(spans.map(\.lines), [2...3, 6...7])
        XCTAssertEqual(spans.first?.start, 11)
        XCTAssertEqual(spans.first?.end, 21, "ends where the next line starts")
        let single = ["一", "啊啊", "啊啊", "噢噢"].enumerated().map { LyricLine(timestamp: Double($0.offset), originalText: $0.element) }
        XCTAssertTrue(LyricsChorus.compute(lines: single, duration: 10).isEmpty, "one short repeated line is not a chorus")
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

    func testLyricImageryFindsPlainKeywordsOnly() {
        XCTAssertEqual(V3LyricImagery.detect(["窗外下着雨"]), .rain)
        XCTAssertEqual(V3LyricImagery.detect(["粉雪舞う季節"]), .snow)
        XCTAssertEqual(V3LyricImagery.detect(["Under the stars tonight"]), .stars)
        XCTAssertEqual(V3LyricImagery.detect(["桜の下で", nil]), .petals)
        XCTAssertEqual(V3LyricImagery.detect(["我想你", "Dancing in the rain"]), .rain, "translation counts too")
        XCTAssertNil(V3LyricImagery.detect(["Take the train to Spain"]), "rain inside a word is not rain")
        XCTAssertNil(V3LyricImagery.detect(["Brainstorm"]))
        XCTAssertNil(V3LyricImagery.detect([nil, ""]))
    }

    func testVUNeedleSettlesInAboutAThirdOfASecondWithASmallOvershoot() {
        let needles = V3VUNeedles()
        var t = 0.0, peak = 0.0, settled: Double?
        _ = needles.step(targets: [0, 0], now: t)
        while t < 1.5 {
            t += 1.0 / 30.0
            needles.step(targets: [1, 1], now: t)
            peak = max(peak, needles.position[0])
            if settled == nil, abs(needles.position[0] - 1) < 0.02, abs(needles.velocity[0]) < 0.2 { settled = t }
        }
        XCTAssertGreaterThan(peak, 1.0, "a real movement overshoots a little")
        XCTAssertLessThan(peak, 1.03)
        XCTAssertLessThan(settled ?? 9, 0.45)
        XCTAssertGreaterThan(settled ?? 0, 0.15)
        XCTAssertEqual(V3VUMeterFace.reading(1), 0.6, accuracy: 0.001, "the song's own average reads below 0 VU")
    }

    @MainActor
    func testShareCardRendersAtPosterSizeAndNamesFilesSafely() throws {
        let cover = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemPink.setFill(); rect.fill()
            NSColor.systemIndigo.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 8, dy: 8)).fill()
            return true
        }
        let renderer = ImageRenderer(content: V3LyricShareCardView(
            line: "この夜を越えて、まだ見ぬ朝へ", translation: "越过今夜，走向未见的清晨",
            title: "夜を越えて", artist: "Visual Fixture", cover: cover, ground: cover))
        renderer.proposedSize = ProposedViewSize(V3LyricShareCard.size)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1350)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aster-share-card-test.png")
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        print("SHARE_CARD_TEST \(url.path)")
        XCTAssertEqual(V3LyricShareCard.fileSafe("A/B: C?"), "A B  C")
        XCTAssertEqual(V3LyricShareCard.fileSafe("   "), "歌词")
    }

    private func historyEntry(_ key: String, _ title: String, _ artist: String) -> ListeningHistoryEntry {
        ListeningHistoryEntry(sessionID: UUID(), stableKey: key, title: title, artist: artist, album: "",
                              startedAt: Date(), lastObservedAt: Date(), observedPlaybackDuration: 60,
                              trackDuration: 200, completionRatio: 0.3)
    }

    @MainActor
    func testCoverWallShowsEachSongOnceAndLinksTheSameSinger() throws {
        let entries = [historyEntry("a", "如果你還愛著他", "張若凡"), historyEntry("b", "夜に駆ける", "YOASOBI"),
                       historyEntry("a", "如果你還愛著他", "張若凡"), historyEntry("c", "群青", "YOASOBI, 别人")]
        let tiles = ListeningCoverWall.tiles(entries)
        XCTAssertEqual(tiles.map(\.id), ["a", "b", "c"], "each song once, most recent first")
        XCTAssertEqual(tiles.first?.plays, 2)
        XCTAssertEqual(tiles[1].artistKey, tiles[2].artistKey, "a feature does not split the singer")
        XCTAssertEqual(ListeningCoverWall.primaryArtist("Aimer feat. someone"), "aimer feat. someone".replacingOccurrences(of: " feat.", with: ""))

    }

    @MainActor
    func testRecapCardRendersAtPosterSize() throws {
        let songs = (1...5).map { ListeningStatisticsSong(stableKey: "s\($0)", title: "歌 \($0)",
                                                          artist: "歌手", observedListeningTime: 600, sessionCount: 6 - $0) }
        let statistics = ListeningStatistics(timeRange: .last30Days, totalListeningTime: 45_000, sessionCount: 120,
                                             uniqueSongCount: 48, topSongs: songs,
                                             topArtists: [ListeningStatisticsArtist(artist: "YOASOBI", observedListeningTime: 9000, sessionCount: 30)],
                                             dailyPlayCounts: [])
        let renderer = ImageRenderer(content: V3RecapCardView(statistics: statistics, songs: songs, covers: [:], ground: nil))
        renderer.proposedSize = ProposedViewSize(V3LyricShareCard.size)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1350)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aster-recap-card-test.png")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("RECAP_CARD_TEST \(url.path)")
        XCTAssertEqual(V3RecapCard.durationText(45_000), "12 小时 30 分")
        XCTAssertEqual(V3RecapCard.durationText(1_800), "30 分钟")
    }

    @MainActor
    func testSoundprintKeepsOneRingPerSongAndBlendsEachBin() {
        let store = V3SoundprintStore.shared
        let key = "test-soundprint-\(UUID().uuidString)"
        XCTAssertTrue(store.print(for: key).allSatisfy { $0 < 0 }, "nothing heard yet")
        store.record(1.0, at: 0.5, for: key)
        store.record(0.0, at: 0.5, for: key)
        let bin = V3SoundprintStore.bins / 2
        XCTAssertEqual(Double(store.print(for: key)[bin]), 0.7, accuracy: 0.001, "a running blend, not the last value")
        store.record(0.4, at: 1.0, for: key)
        XCTAssertEqual(store.print(for: key).filter { $0 >= 0 }.count, 1, "the end of the song is outside the ring")
        XCTAssertTrue(store.print(for: "other-\(key)").allSatisfy { $0 < 0 }, "each song its own ring")
    }

    func testSoundprintLoopStartsAtTopCentreAndGoesClockwise() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(V3SoundprintRing.loopPoint(0, around: rect).point, CGPoint(x: 50, y: 0))
        XCTAssertEqual(V3SoundprintRing.loopPoint(0.125, around: rect).point, CGPoint(x: 100, y: 0), "top right corner")
        XCTAssertEqual(V3SoundprintRing.loopPoint(0.25, around: rect).normal, CGVector(dx: 1, dy: 0), "down the right side")
        XCTAssertEqual(V3SoundprintRing.loopPoint(0.5, around: rect).point, CGPoint(x: 50, y: 100), "bottom centre")
    }

    func testSpectrumBandsCoverFiftyHertzToTwelveKilohertzInOrder() {
        let bands = PulseAnalyzer.spectrumBands
        XCTAssertEqual(bands.count, 24)
        XCTAssertGreaterThanOrEqual(bands.first?.0 ?? 0, 1, "no DC bin")
        for (index, band) in bands.enumerated() {
            XCTAssertGreaterThan(band.1, band.0, "every band at least one bin")
            if index > 0 { XCTAssertEqual(band.0, bands[index - 1].1, "bands touch, no gaps or overlaps") }
        }
        XCTAssertLessThanOrEqual(bands.last?.1 ?? 0, PulseAnalyzer.frameSize / 2)
        XCTAssertEqual(Double(bands.last?.1 ?? 0) * 48_000 / 1024, 12_000, accuracy: 50)
    }

    func testSpectrumBarsRiseAtOnceAndFallSlowly() {
        let smoother = V3SpectrumSmoother()
        XCTAssertEqual(smoother.step([1, 0], now: 0), [1, 0])
        let after = smoother.step([0, 0], now: 0.1)
        XCTAssertEqual(Double(after[0]), 0.86, accuracy: 0.001, "falls 1.4 per second")
        XCTAssertEqual(smoother.step([0.9, 0], now: 0.2)[0], 0.9, "rises at once")
    }

    // MARK: Batch four — line stepping, hour wash, parallax

    func testStepLineGoesToTheNeighbouringSungLine() {
        let lines = [LyricLine(timestamp: 10, originalText: "a"), LyricLine(timestamp: 20, originalText: "b"),
                     LyricLine(timestamp: 25, originalText: " "), LyricLine(timestamp: 30, originalText: "c")]
        XCTAssertEqual(PlaybackState.lyricStepTarget(from: 21, lines: lines, synchronized: true, forward: true), 30,
                       "empty lines are skipped")
        XCTAssertEqual(PlaybackState.lyricStepTarget(from: 20.6, lines: lines, synchronized: true, forward: false), 10,
                       "just into a line, back means the line before")
        XCTAssertEqual(PlaybackState.lyricStepTarget(from: 23, lines: lines, synchronized: true, forward: false), 20,
                       "well into a line, back restarts it")
        XCTAssertEqual(PlaybackState.lyricStepTarget(from: 10.2, lines: lines, synchronized: true, forward: false), 10)
        XCTAssertNil(PlaybackState.lyricStepTarget(from: 31, lines: lines, synchronized: true, forward: true))
        XCTAssertNil(PlaybackState.lyricStepTarget(from: 5, lines: lines, synchronized: true, forward: false))
        XCTAssertNil(PlaybackState.lyricStepTarget(from: 21, lines: lines, synchronized: false, forward: true))
    }

    func testLineKeysAreQAndE() {
        XCTAssertEqual(V3ListeningKey.resolve("q", modifiers: [], repeating: false, focused: true, editing: false), .previousLine)
        XCTAssertEqual(V3ListeningKey.resolve("E", modifiers: [], repeating: true, focused: true, editing: false), .nextLine)
        XCTAssertNil(V3ListeningKey.resolve("q", modifiers: [.command], repeating: false, focused: true, editing: false))
        XCTAssertNil(V3ListeningKey.resolve("e", modifiers: [], repeating: false, focused: true, editing: true))
    }

    func testHourWashOnlyAtDawnDuskAndLateNight() {
        XCTAssertNil(V3DayTint.wash(hour: 12))
        XCTAssertNil(V3DayTint.wash(hour: 21))
        XCTAssertEqual(V3DayTint.wash(hour: 6.5)?.opacity ?? 0, 0.12, accuracy: 0.001)
        XCTAssertEqual(V3DayTint.wash(hour: 18)?.opacity ?? 0, 0.14, accuracy: 0.001)
        XCTAssertEqual(V3DayTint.wash(hour: 1)?.opacity ?? 0, 0.16, accuracy: 0.001)
        XCTAssertEqual(V3DayTint.wash(hour: 23.25)?.opacity ?? 0, 0.08, accuracy: 0.001, "fades in over half an hour")
        XCTAssertEqual(V3DayTint.wash(hour: 4.25)?.opacity ?? 0, 0.08, accuracy: 0.001, "and out")
        XCTAssertGreaterThan(V3DayTint.wash(hour: 18)?.red ?? 0, V3DayTint.wash(hour: 18)?.blue ?? 1, "dusk is warm")
    }

    func testParallaxLeansAwayFromThePointerWithoutShowingAnEdge() {
        let size = CGSize(width: 1000, height: 600)
        XCTAssertEqual(V3BackdropParallax.offset(pointer: nil, in: size), .zero)
        XCTAssertEqual(V3BackdropParallax.offset(pointer: CGPoint(x: 500, y: 300), in: size), .zero)
        let corner = V3BackdropParallax.offset(pointer: CGPoint(x: 1000, y: 0), in: size)
        XCTAssertEqual(corner.width, -12, accuracy: 0.001)
        XCTAssertEqual(corner.height, 12, accuracy: 0.001)
        // The enlargement covers the furthest lean on both axes.
        let grow = V3BackdropParallax.scale(for: size) - 1
        XCTAssertGreaterThanOrEqual(grow * size.height / 2, 12 - 0.001)
        XCTAssertGreaterThanOrEqual(grow * size.width / 2, 12 - 0.001)
    }

    // MARK: Batch five — bass followers, docking, credit-only lyrics

    func testBassFollowerJumpsUpAndFallsBack() {
        var follower = V3BassFollower()
        XCTAssertEqual(follower.step(bass: 1.0, now: 0), 0, "the song's usual level lifts nothing")
        XCTAssertEqual(follower.step(bass: 1.55, now: 0.03), 1, accuracy: 0.001, "a hit arrives at once")
        let later = follower.step(bass: 1.0, now: 0.13)
        XCTAssertEqual(later, exp(-0.1 / 0.22), accuracy: 0.001)
        XCTAssertEqual(follower.step(bass: nil, now: 5), exp(-0.1 / 0.22) * exp(-0.1 / 0.22), accuracy: 0.001,
                       "a long gap counts as one step, and stale levels lift nothing")
    }

    func testDesktopLyricsDockCentresTopAndBottom() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 795)
        let size = CGSize(width: 600, height: 120)
        XCTAssertEqual(FloatingLyricsDock.origin(size: size, visibleFrame: visible, place: .top), CGPoint(x: 420, y: 747))
        XCTAssertEqual(FloatingLyricsDock.origin(size: size, visibleFrame: visible, place: .bottom), CGPoint(x: 420, y: 88))
    }

    func testCreditOnlyLyricsAreNotLyrics() {
        XCTAssertTrue(LyricsCreditOnly.matches(["作词 : 某人", "作曲 : 某人", "编曲：某人"]))
        XCTAssertTrue(LyricsCreditOnly.matches(lrc: "[ti:歌]\n[00:00.00] 作词 : A\n[00:01.00] 作曲 : B\n"))
        XCTAssertTrue(LyricsCreditOnly.matches(["サヨナラ - stb", "词：stb", "曲：stb"]), "a heading before the credits")
        XCTAssertFalse(LyricsCreditOnly.matches(["作词 : 某人", "作曲 : 某人", "今天的风很轻"]))
        XCTAssertFalse(LyricsCreditOnly.matches(["今天的风很轻", "曲终人散"]), "no colon, no credit")
        XCTAssertFalse(LyricsCreditOnly.matches([String]()))
        XCTAssertFalse(LyricsCreditOnly.matches(["Written by the river: a song"]), "a sung line that happens to hold a colon later")
    }

    func testCoverCaptionTypeStaysReadableOnAnyCover() {
        XCTAssertEqual(V3CoverCaption.fontSize(coverWidth: 120), 11, "never below 11 pt")
        XCTAssertEqual(V3CoverCaption.fontSize(coverWidth: 330), 15.84, accuracy: 0.01)
        XCTAssertEqual(V3CoverCaption.fontSize(coverWidth: 900), 22, "never above 22 pt")
    }
}
