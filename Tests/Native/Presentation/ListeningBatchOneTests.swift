import AppKit
import Compression
import SwiftUI
import XCTest
@testable import SpotifyLyrics

/// Round 15 batch one: Canvas from the Spotify cache, cover colour routes,
/// tempo-timed line follow, censored words, lyric-end evidence, seek snap
/// and seek hold.
final class ListeningBatchOneTests: XCTestCase {
    @MainActor
    func testAppleMusicArtworkKeepsRecentCoversWithinItsBudget() async throws {
        let directory = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = AppleMusicArtworkCache(directory: directory, diskBudget: 60)
        let legacy = directory.appendingPathComponent("applemusic_artwork_AAAAAAAAAAAAAAAA.jpg")
        let unrelated = directory.appendingPathComponent("other.jpg")
        let link = directory.appendingPathComponent("applemusic_artwork_CCCCCCCCCCCCCCCC.jpg")
        try Data(repeating: 1, count: 40).write(to: legacy)
        try Data(repeating: 2, count: 96).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        XCTAssertEqual(try cache.diskBytes(), 40)
        let hit = await cache.localFile(for: "AAAAAAAAAAAAAAAA") { _ in
            XCTFail("An existing cover should not need AppleScript")
            return false
        }
        XCTAssertEqual(hit, legacy)
        let update = await cache.localFile(for: "BBBBBBBBBBBBBBBB") { staging in
            (try? Data(repeating: 3, count: 40).write(to: staging)) != nil
        }
        let newest = try XCTUnwrap(update)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try cache.diskBytes(), 40)
        XCTAssertEqual(try Data(contentsOf: newest).count, 40)
        try cache.clearCache()
        XCTAssertEqual(try cache.diskBytes(), 0)
        XCTAssertEqual(try Data(contentsOf: unrelated).count, 96)
        XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: link.path).hasSuffix("other.jpg"))
    }

    @MainActor
    func testSettingsIncludesAndClearsLocalAppleMusicArtwork() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        let provider = AppleMusicDesktopProvider(scriptRunner: { script, _ in
            let prefix = "set targetPath to POSIX file \""
            guard let line = script.components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let staging = URL(fileURLWithPath: String(line.dropFirst(prefix.count).dropLast()))
            try Data(repeating: 4, count: 8192).write(to: staging)
            return "ok"
        }, applicationIsInstalled: { true }, applicationIsRunning: { true })
        let local = await provider.artworkURL(for: .init(id: "applemusic:DDDDDDDDDDDDDDDD", title: "Cover", artist: "Fixture", album: "", duration: 120),
                                              source: .appleMusic)
        let cover = try XCTUnwrap(local)
        let data = SettingsDataController(repository: SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("local.sqlite3")))
        data.refreshStatistics()
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while data.isBusy && ContinuousClock.now < startDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(data.statistics)
        XCTAssertEqual(data.localArtworkBytes, 8192)
        XCTAssertEqual(data.artworkBytes, data.networkArtworkBytes + 8192)
        data.clearLyricsCache()
        let clearDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while data.isBusy && ContinuousClock.now < clearDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(data.localArtworkBytes, 0)
        XCTAssertEqual(data.artworkBytes, data.networkArtworkBytes)
        XCTAssertTrue(data.statusMessage.contains("已清理"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path))
    }

    func testCleaningCanvasRemovesOnlyDownloadedClips() async throws {
        let dir = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clip = dir.appendingPathComponent(String(repeating: "b", count: 32) + ".mp4")
        let kept = dir.appendingPathComponent("my-video.mp4")
        try Data(repeating: 1, count: 64).write(to: clip)
        try Data(repeating: 2, count: 32).write(to: kept)
        let store = V3CanvasStore(directory: dir)
        let before = try await store.diskBytes()
        XCTAssertEqual(before, 64)
        try await store.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertEqual(try Data(contentsOf: kept).count, 32)
    }

    // MARK: Spotify cache

    func testSnappyLiteralAndOverlappingCopy() {
        // Length 9; literal "ab"; a 1-byte-offset copy of 7 from 2 back:
        // tag (7 - 4) << 2 | 1 = 13. The copy overlaps what it writes.
        let fixed: [UInt8] = [9, 0x04, 0x61, 0x62, 13, 2]
        XCTAssertEqual(Snappy.decompress(fixed).map { String(decoding: $0, as: UTF8.self) }, "ababababa")
        XCTAssertEqual(Snappy.decompress([6, 0, 0x61, 18, 1, 0]), Array("aaaaaa".utf8))
        XCTAssertEqual(Snappy.decompress([4, 4, 0x61, 0x62, 7, 2, 0, 0, 0]), Array("abab".utf8))
        XCTAssertNil(Snappy.decompress([5, 0x04, 0x61, 0x62]), "a short result is rejected")
        XCTAssertNil(Snappy.decompress([2, 0, 0x61, 18, 1, 0]), "a copy cannot exceed the declared output")
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

    func testWordTimedCacheKeepsParenthesesAndDistinguishesEnsemble() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lyrics = root.appendingPathComponent("lyrics", isDirectory: true)
        try FileManager.default.createDirectory(at: lyrics, withIntermediateDirectories: true)
        let track = Track(title: "Fixture", artist: "Singers", album: "Studio", duration: 10,
                          spotifyId: "0123456789ABCDEFGHIJKL")
        let index = ["Singers|Fixture|Studio": ["spotify_track_id": track.spotifyId!, "duration_secs": 10,
            "lyrics_speakers": ["yrc": ["合", "v1", "v2"]]]]
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("lyrimuse-enrich-index.json"))
        try """
        [1000,600](1000,300,0)A(test)(1300,300,0) B
        [3000,600](3000,600,0)C
        [5000,600](5000,600,0)D
        """.write(to: lyrics.appendingPathComponent("Singers - Fixture - Studio.yrc"), atomically: true, encoding: .utf8)
        let match = await LyrimuseLyricsCache.lookup(for: track, root: root)
        let edition = try XCTUnwrap(match)
        XCTAssertEqual(edition.lines.first?.originalText, "A(test) B")
        XCTAssertEqual(edition.timingTitle, "逐字")
        let voices = LyricsTimeline.VoicePresentation(in: edition.lines)
        XCTAssertEqual([voices.label(at: 0), voices.label(at: 1), voices.label(at: 2)], ["合唱", "声部 1", "声部 2"])
        let other = Track(title: track.title, artist: track.artist, album: track.album, duration: 13,
                          spotifyId: track.spotifyId)
        let differentRecording = await LyrimuseLyricsCache.lookup(for: other, root: root)
        XCTAssertNil(differentRecording)
    }

    func testQQDisplayAliasKeepsWordTimedStudioCandidate() {
        let track = Track(title: "革命道中 - On The Way", artist: "AiNA THE END", album: "", duration: 197.668)
        let identity = TrackIdentity(track: track)
        let metadata = TrackMetadata(identity: identity, track: track)
        func decision(title: String, artist: String) -> LyricsMatchDecision {
            let lines = QRCParser.parseLines("[1000,600]A(1000,300) B(1300,300)\n[180000,300]C(180000,300)")
            let edition = LyricsCandidate(id: "fixture", identity: identity, title: title, artist: artist, album: "",
                duration: 197, lines: lines, isSynchronized: true, source: .qqExperimental, confidence: 1)
            return LyricsSafeMatcher.decide(candidate: edition, metadata: metadata)
        }
        let title = "革命道中 - On The Way (革命途中 - On The Way)"
        let correct = decision(title: title, artist: "AiNA THE END (アイナ・ジ・エンド)")
        XCTAssertTrue(correct.tier == .autoHigh || correct.tier == .autoMedium, "\(correct.explanation)")
        XCTAssertTrue(decision(title: title, artist: "Different Singer (別人)").hardReject)
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

    func testProgressDraftCannotSeekTheNextRecording() {
        var draft = PlaybackSeekDraft()
        draft.begin(for: 1)
        draft.update(30, for: 1)
        XCTAssertEqual(draft.position(for: 1), 30)
        draft.update(55, for: 2)
        XCTAssertNil(draft.position(for: 2))
        XCTAssertNil(draft.finish(for: 2))

        draft.update(22, for: 1)
        draft.invalidate()
        draft.update(70, for: 1)
        XCTAssertNil(draft.finish(for: 1), "Invalidation discards the held gesture even if playback remains on the same recording")

        draft.update(33, for: 2)
        draft.begin(for: 2)
        XCTAssertEqual(draft.finish(for: 2), 33, "A native slider can write its value before starting an edit")
        XCTAssertNil(draft.finish(for: 2), "A completed drag commits only once")
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

    func testFullScreenCoverBelongsToTheDisplayHoldingDesktopLyrics() {
        let first = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let second = CGRect(x: -1440, y: -300, width: 1440, height: 900)
        XCTAssertTrue(FloatingLyricsWindowController.window(second, covers: second))
        XCTAssertFalse(FloatingLyricsWindowController.window(first, covers: second))
        XCTAssertFalse(FloatingLyricsWindowController.window(second.offsetBy(dx: 250, dy: 0), covers: second))
        XCTAssertFalse(FloatingLyricsWindowController.window(second.insetBy(dx: 0, dy: 15), covers: second))
    }

    @MainActor
    func testClosingWindowRestoreIgnoresTheOldDesktopDisplay() throws {
        let home = try XCTUnwrap(NSScreen.main)
        guard let other = NSScreen.screens.first(where: { $0 != home }) else { throw XCTSkip("Two connected displays") }
        let name = "lyrics-displays-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettingsStore(defaults: defaults)
        let persistence = FloatingLyricsWindowPersistence.shared
        settings.saveFloatingWindowFrame(NSStringFromRect(other.visibleFrame.insetBy(dx: 80, dy: 80)),
                                         screenID: other.lyricsFrameScreenID)
        settings.restoreWindowState = false
        XCTAssertEqual(persistence.restoreFrame(settings: settings), persistence.defaultFrame())
    }

    @MainActor
    func testIslandDisplayChoiceAndMovingDesktopLyricsAcrossConnectedScreens() throws {
        let home = try XCTUnwrap(NSScreen.main)
        guard let other = NSScreen.screens.first(where: { $0 != home }) else { throw XCTSkip("Two connected displays") }
        let name = "island-displays-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettingsStore(defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: home.visibleFrame.midX, y: home.visibleFrame.midY, width: 160, height: 90),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let island = CapsuleLyricsWindowPersistence.shared
        XCTAssertEqual(island.targetScreen(mainWindow: window, settings: settings), home)
        settings.capsulePreferredDisplayID = other.lyricsDisplayID
        XCTAssertEqual(island.targetScreen(mainWindow: window, settings: settings), other)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).capsulePreferredDisplayID, other.lyricsDisplayID)
        settings.capsulePreferredDisplayID = "disconnected-fixture"
        XCTAssertEqual(island.targetScreen(mainWindow: window, settings: settings), home)
        XCTAssertEqual(settings.capsulePreferredDisplayID, "disconnected-fixture")
        settings.capsulePreferredDisplayID = ""
        window.setFrameOrigin(CGPoint(x: other.visibleFrame.midX, y: other.visibleFrame.midY))
        XCTAssertEqual(island.targetScreen(mainWindow: window, settings: settings), other)
        XCTAssertFalse(window.isVisible)

        let source = CGRect(x: -1400, y: 80, width: 1400, height: 900)
        let destination = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let frame = CGRect(x: source.midX - 300, y: source.minY, width: 600, height: 120)
        let moved = FloatingLyricsWindowPersistence.shared.placing(frame, from: source, on: destination)
        XCTAssertEqual(moved, CGRect(x: 200, y: 0, width: 600, height: 120))
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

    // MARK: Batch seven — kept lines, whole-line timing

    @MainActor func testFavoriteLinesToggleAndPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = V3FavoriteLines(fileURL: url)
        XCTAssertTrue(store.toggle(text: " 今天的风很轻 ", translation: "", title: "歌", artist: "人", trackKey: "k1", artworkURL: nil))
        XCTAssertTrue(store.toggle(text: "第二句", translation: "second", title: "歌", artist: "人", trackKey: "k1", artworkURL: nil))
        XCTAssertFalse(store.toggle(text: "   ", translation: nil, title: "歌", artist: "人", trackKey: "k1", artworkURL: nil), "empty lines are not kept")
        XCTAssertEqual(store.entries.map(\.text), ["第二句", "今天的风很轻"], "newest first, trimmed")
        XCTAssertNil(store.entries[1].translation, "an empty translation is not stored")
        XCTAssertTrue(store.contains(text: "今天的风很轻", trackKey: "k1"))
        XCTAssertFalse(store.contains(text: "今天的风很轻", trackKey: "k2"), "the same words in another song are another line")

        let reopened = V3FavoriteLines(fileURL: url)
        XCTAssertEqual(reopened.entries.map(\.text), ["第二句", "今天的风很轻"])
        XCTAssertFalse(reopened.toggle(text: "第二句", translation: nil, title: "歌", artist: "人", trackKey: "k1", artworkURL: nil),
                       "a second toggle removes it")
        XCTAssertEqual(V3FavoriteLines(fileURL: url).entries.count, 1)
        let incomplete = Data("[{".utf8)
        try incomplete.write(to: url)
        let unreadable = V3FavoriteLines(fileURL: url)
        XCTAssertFalse(unreadable.toggle(text: "不能覆盖旧收藏", translation: nil, title: "歌", artist: "人", trackKey: "k1", artworkURL: nil))
        XCTAssertEqual(try Data(contentsOf: url), incomplete)
    }

    @MainActor func testFavoriteKeepsSeparateOccurrencesOfAChorus() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chorus-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let version = UUID()
        let favorites = V3FavoriteLines(fileURL: url)
        for index in [1, 4] {
            XCTAssertTrue(favorites.toggle(text: "又唱到这里", translation: "Here again", title: "歌", artist: "人",
                                           trackKey: "song", artworkURL: nil, lyricsVersionID: version, lineIndex: index))
        }
        XCTAssertEqual(V3FavoriteLines(fileURL: url).entries.map(\.lineIndex), [4, 1])
    }

    func testWholeLineTimingDropsOnlyTheWordTiming() {
        var line = LyricLine(timestamp: 12, originalText: "hello world")
        XCTAssertEqual(line.withoutWordTiming, line, "a line without word timing is left alone")
        line.timedSpans = [TimedTextSpan(id: 0, text: "hello", startTime: 12, endTime: 12.5, utf16Start: 0, utf16Length: 5)]
        let plain = line.withoutWordTiming
        XCTAssertNil(plain.timedSpans)
        XCTAssertEqual(plain.id, line.id)
        XCTAssertEqual(plain.timestamp, 12)
        XCTAssertEqual(plain.originalText, "hello world")
    }

    // MARK: Batch eight — breath in, vocal onsets, the other display

    func testBreathInRisesOverTheLastTwoSeconds() {
        XCTAssertEqual(V3BreathIn.level(time: 10, end: 20), 0, "nothing until two seconds before the voice")
        XCTAssertEqual(V3BreathIn.level(time: 19, end: 20), 0.5, accuracy: 0.001)
        XCTAssertEqual(V3BreathIn.level(time: 20, end: 20), 1, accuracy: 0.001)
        XCTAssertEqual(V3BreathIn.level(time: 20.1, end: 20), 0, "gone once the line is sung")
    }

    func testVocalOnsetsHitOncePerWord() {
        var line = LyricLine(timestamp: 10, originalText: "ab cd")
        XCTAssertTrue(V3VocalOnsets.onsets(of: line).isEmpty)
        XCTAssertTrue(V3VocalOnsets.onsets(of: nil).isEmpty)
        line.timedSpans = [TimedTextSpan(id: 1, text: "cd", startTime: 11, endTime: 11.5, utf16Start: 3, utf16Length: 2),
                           TimedTextSpan(id: 0, text: "ab", startTime: 10, endTime: 10.5, utf16Start: 0, utf16Length: 2)]
        let onsets = V3VocalOnsets.onsets(of: line)
        XCTAssertEqual(onsets, [10, 11])
        XCTAssertEqual(V3VocalOnsets.index(at: 10.05, in: onsets), 0)
        XCTAssertNil(V3VocalOnsets.index(at: 10.5, in: onsets), "between words there is no hit")
        XCTAssertEqual(V3VocalOnsets.index(at: 11.1, in: onsets), 1)
        XCTAssertNil(V3VocalOnsets.index(at: 9, in: onsets))
    }

    func testFullScreenPicksTheNextDisplayOnlyWhenAsked() {
        XCTAssertEqual(FullScreenLyricsWindowController.targetIndex(home: 0, count: 1, prefersOther: true), 0)
        XCTAssertEqual(FullScreenLyricsWindowController.targetIndex(home: 0, count: 2, prefersOther: false), 0)
        XCTAssertEqual(FullScreenLyricsWindowController.targetIndex(home: 0, count: 2, prefersOther: true), 1)
        XCTAssertEqual(FullScreenLyricsWindowController.targetIndex(home: 1, count: 2, prefersOther: true), 0)
        XCTAssertEqual(FullScreenLyricsWindowController.targetIndex(home: nil, count: 3, prefersOther: true), 1)
        XCTAssertNil(FullScreenLyricsWindowController.targetIndex(home: 0, count: 0, prefersOther: true))
    }

    func testDuetUnisonCoalescesOnlyTheSamePhraseAtTheSameMoment() {
        let lines = [
            LyricLine(timestamp: 59.558, originalText: "別の言葉", endTime: 61.251, performerID: "v2"),
            LyricLine(timestamp: 59.674, originalText: "違う言葉", endTime: 61.314, performerID: "v1"),
            LyricLine(timestamp: 61.385, originalText: "二人で歌う", endTime: 62.998, performerID: "v2"),
            LyricLine(timestamp: 61.431, originalText: "二人で歌う", endTime: 62.931, performerID: "v1"),
            LyricLine(timestamp: 64, originalText: "二人で歌う", endTime: 65.9, performerID: "v2")
        ]
        XCTAssertEqual(LyricsTimeline.duetUnisonDuplicates(in: lines), [3: 2])
        XCTAssertEqual(lines[3].performerID, "v1")
        let projection = LyricsTimeline.presentedLyrics(in: lines, currentIndex: 3, before: 2)
        XCTAssertEqual(projection.current, 2)
        XCTAssertEqual(projection.visible, [0, 1, 2, 4])
        XCTAssertEqual(projection.voices.label(at: 3), "合唱")
        XCTAssertEqual([0, 1, 2, 4].map(projection.voices.labelAtChange), ["声部 1", "声部 2", "合唱", "声部 1"])
        let unsynchronized = LyricsTimeline.VoicePresentation(in: lines, isSynchronized: false)
        XCTAssertTrue(unsynchronized.duplicates.isEmpty)
        XCTAssertEqual(unsynchronized.label(at: 3), "声部 2")
        XCTAssertNil(LyricsTimeline.VoicePresentation(in: [lines[1]]).label(at: 0))
        let desktop = FloatingLyricsPresentationHelper.selection(lines: lines, currentIndex: 3,
                                                                 isSynchronized: true, isPlaying: true)
        XCTAssertEqual(desktop.currentIndex, 2)
        XCTAssertEqual(desktop.visibleIndices, [2, 4])
        XCTAssertEqual(desktop.voiceLabels, [2: "合唱", 4: "声部 1"])
        let track = Track(title: "Fixture", artist: "Duet", album: "", duration: 100)
        let document = LyricsDocument(identity: TrackIdentity(track: track), title: track.title, artist: track.artist,
                                      album: track.album, duration: track.duration, lines: lines,
                                      isSynchronized: true, source: .amll, confidence: 1)
        let capsule = CapsuleLyricsPresentation.selection(lines: lines, currentIndex: 3,
                                                          isSynchronized: true, state: .loaded(document))
        XCTAssertEqual(capsule.currentIndex, 2)
        XCTAssertEqual(capsule.currentVoiceLabel, "合唱")
        XCTAssertEqual(capsule.followingVoiceLabel, "声部 1")
    }

    // MARK: 和声

    func testTTMLReadsMainVoiceTranslationsAndRomanizationFromTheFile() throws {
        let ttml = """
        <tt xmlns:ttm="urn:ttm" xmlns:amll="urn:amll" xmlns:itunes="urn:itunes" xml:lang="ja">
          <head><metadata>
            <amll:meta key="musicName" value="窗边"/><amll:meta key="artists" value="本机样例"/>
            <amll:meta key="album" value="声音来信"/>
            <iTunesMetadata><translations><translation type="subtitle" xml:lang="zh-Hans">
              <text for="B"><span>再</span><span>见</span><span ttm:role="x-bg">幕后</span></text>
            </translation></translations></iTunesMetadata>
          </metadata></head>
          <body><div>
            <p begin="1s" end="3s" itunes:key="A"><span begin="1s" end="2s">窓</span><span ttm:role="x-bg">あ<span ttm:role="x-translation">不是主唱</span></span><span ttm:role="x-translation" xml:lang="en">window</span><span ttm:role="x-translation" xml:lang="zh-Hans">窗</span><span ttm:role="x-roman" xml:lang="ja-Latn">mado</span></p>
            <p begin="3s" end="5s" itunes:key="B">またね</p>
          </div></body></tt>
        """
        let track = Track(title: "fixture", artist: "fixture", album: "", duration: 6)
        let document = try XCTUnwrap(TTMLParser.parse(ttml, identity: TrackIdentity(track: track)))
        XCTAssertEqual(document.title, "窗边")
        XCTAssertEqual(document.artist, "本机样例")
        XCTAssertEqual(document.album, "声音来信")
        XCTAssertEqual(document.language, "ja")
        XCTAssertEqual(document.lines.map(\.originalText), ["窓", "またね"])
        XCTAssertEqual(document.lines.map(\.translationText), ["窗", "再见"])
        XCTAssertEqual(document.lines.first?.romajiText, "mado")
        XCTAssertEqual(document.lines.first?.backgroundText, "あ")
        XCTAssertEqual(document.lines.first?.timedSpans?.map(\.text), ["窓"])
        let english = TTMLParser.parse(ttml, identity: TrackIdentity(track: track), preferredTranslationLanguage: "en-GB")
        XCTAssertEqual(english?.lines.first?.translationText, "window")
    }

    func testUntimedTTMLPreservesTextOrderWithoutInventingPlaybackTiming() throws {
        let xml = #"<tt xmlns:itunes="urn:itunes" itunes:timing="None"><body><div><p>先读</p><p>再读</p></div></body></tt>"#
        let track = Track(title: "fixture", artist: "fixture", album: "", duration: 0)
        let document = try XCTUnwrap(TTMLParser.parse(xml, identity: TrackIdentity(track: track)))
        XCTAssertFalse(document.isSynchronized)
        XCTAssertEqual(document.lines.map(\.originalText), ["先读", "再读"])
        let partial = #"<tt><body><div><p>序</p><p><span begin="0s" end="1s">唱</span></p><p>尾</p></div></body></tt>"#
        let partiallyTimed = try XCTUnwrap(TTMLParser.parse(partial, identity: TrackIdentity(track: track)))
        XCTAssertFalse(partiallyTimed.isSynchronized)
        XCTAssertEqual(partiallyTimed.explicitlyTimedLineIndices, [1])
        XCTAssertEqual(partiallyTimed.lines.map(\.originalText), ["序", "唱", "尾"])
    }

    func testBackingVocalsBecomeTheirOwnLine() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
        <p begin="1.000" end="4.000"><span begin="1.000" end="2.000">Hello</span> <span begin="2.000" end="3.000">there</span><span ttm:role="x-bg" begin="3.000" end="4.000"><span begin="3.000" end="4.000">(ooh</span> <span begin="3.500" end="4.000">yeah)</span></span></p>
        <p begin="5.000" end="6.000"><span begin="5.000" end="6.000">Plain</span></p>
        </div></body></tt>
        """
        let track = Track(id: "bg-test", title: "T", artist: "A", album: "", duration: 10)
        let document = try XCTUnwrap(TTMLParser.parse(ttml, identity: TrackIdentity(track: track)))
        XCTAssertEqual(document.lines[0].originalText, "Hello there", "the sung line keeps its own text and offsets")
        XCTAssertEqual(document.lines[0].backgroundText, "ooh yeah")
        XCTAssertEqual(document.lines[0].timedSpans?.count, 2)
        XCTAssertNil(document.lines[1].backgroundText)

        // AMLL nests the backing line's translation and romanization inside x-bg.
        let nested = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
        <p begin="1.000" end="4.000"><span begin="1.000" end="2.000">Oh</span><span ttm:role="x-bg"><span begin="2.000" end="3.000">(忘れられない人)</span><span ttm:role="x-translation" xml:lang="zh-CN">你永远是我无法忘记的人</span><span ttm:role="x-roman">wa su re ra re na i hi to</span></span></p>
        </div></body></tt>
        """
        let nestedDocument = try XCTUnwrap(TTMLParser.parse(nested, identity: TrackIdentity(track: track)))
        XCTAssertEqual(nestedDocument.lines[0].backgroundText, "忘れられない人", "only what the backing voices sing")

        let payload = try XCTUnwrap(DocumentTimingPayload.encode(document.lines))
        XCTAssertEqual(DocumentTimingPayload.decodeBackground(payload), [0: "ooh yeah"])
        XCTAssertEqual(DocumentTimingPayload.decode(payload)?[0]?.spans.count, 2, "the timing map reads as before")
        let plain = try XCTUnwrap(DocumentTimingPayload.encode([document.lines[1]]))
        XCTAssertFalse(plain.contains("backgroundText"), "lines without backing vocals store exactly what they stored before")
        XCTAssertTrue(DocumentTimingPayload.decodeBackground(plain).isEmpty)
    }

    func testBackingVocalBracketsAreTidied() {
        XCTAssertEqual(TTMLParser.tidiedBackground("  (la  la) "), "la la")
        XCTAssertEqual(TTMLParser.tidiedBackground("（啦啦）"), "啦啦")
        XCTAssertEqual(TTMLParser.tidiedBackground("(a) b (c)"), "(a) b (c)", "inner brackets are left alone")
        XCTAssertNil(TTMLParser.tidiedBackground(" \n "))
    }

    // MARK: Artist written another way (2026-11-15 source re-read)

    private func decide(track title: String, _ artist: String, _ duration: Double,
                        candidate cTitle: String, _ cArtist: String, _ cDuration: Double,
                        aliases: [String] = [], loose: Bool = false) -> LyricsMatchDecision {
        let track = Track(title: title, artist: artist, album: "", duration: duration)
        let identity = TrackIdentity(track: track)
        let lines = [LyricLine(timestamp: 10, originalText: "line one"), LyricLine(timestamp: max(20, cDuration - 30), originalText: "line two")]
        let candidate = LyricsCandidate(id: "c", identity: identity, title: cTitle, artist: cArtist, album: "",
                                        duration: cDuration, lines: lines, source: .neteaseExperimental, confidence: 0.8,
                                        declaredTitleAliases: aliases)
        let variant = loose ? LyricsQueryVariant(rank: 6, strategy: .titleOnlyLoose, queryKind: .titleOnlyLoose,
                                                 titleQuery: title, artistQuery: nil) : nil
        return LyricsSafeMatcher.decide(candidate: candidate, metadata: TrackMetadata.bootstrap(from: track), queryVariant: variant)
    }

    func testArtistListedSecondIsTheSameRecording() {
        let second = decide(track: "坠落", "徐梓淳", 205, candidate: "坠落", "方言, 徐梓淳", 205)
        XCTAssertEqual(second.tier, .autoMedium, second.reasons.joined(separator: ","))
        XCTAssertTrue(second.reasons.contains("primaryArtistInCredits"))
        let bracketed = decide(track: "星星的眼泪", "傲七爷", 251, candidate: "星星的眼泪", "超星, 傲七爷(江偌绮)", 251)
        XCTAssertEqual(bracketed.tier, .autoMedium, bracketed.reasons.joined(separator: ","))
        XCTAssertNotEqual(decide(track: "坠落", "徐梓淳", 205, candidate: "坠落", "方言, 徐梓淳", 230).tier, .autoMedium,
                          "another length is not the same recording")
        XCTAssertEqual(decide(track: "坠落", "徐梓淳", 205, candidate: "坠落", "方言", 205).tier, .reject,
                       "an artist not in the credits stays a conflict")
        XCTAssertNotEqual(decide(track: "坠落", "徐梓淳", 205, candidate: "坠落之后", "方言, 徐梓淳", 205).tier, .autoMedium)
    }

    func testProducerCreditInTheTitleIsTheSameSong() {
        XCTAssertEqual(TrackTextNormalizer.strippingProducerCredit("活着（Prod.By Red killer）"), "活着")
        XCTAssertEqual(TrackTextNormalizer.strippingProducerCredit("Song (prod. X)"), "Song")
        XCTAssertEqual(TrackTextNormalizer.strippingProducerCredit("Song - Prod. by X"), "Song")
        XCTAssertEqual(TrackTextNormalizer.strippingProducerCredit("Product"), "Product")
        let credit = decide(track: "活着", "Sop天", 165, candidate: "活着（Prod.By Red killer）", "Sop天", 165)
        XCTAssertTrue(credit.reasons.contains("titleProducerCreditExact"), credit.reasons.joined(separator: ","))
        XCTAssertTrue(credit.tier == .autoMedium || credit.tier == .autoHigh, credit.reasons.joined(separator: ","))
    }

    /// Timeless (feat. mahiru) by TakaseToya on Spotify is タイムレス (feat. 茉ひる)
    /// by 高瀬統也, 茉ひる on NetEase, same length to the millisecond. Only the
    /// timed NetEase copy has timestamps (2026-11-15, user report).
    func testKatakanaLoanwordTitleAndKanjiNameAreTheSameRecording() {
        func decideTimeless(_ cTitle: String, _ cArtist: String, _ cDuration: Double) -> LyricsMatchDecision {
            let track = Track(title: "Timeless (feat. mahiru)", artist: "TakaseToya, 茉ひる", album: "LOVE-C", duration: 174.892)
            var metadata = TrackMetadata.bootstrap(from: track)
            metadata.verifiedSpotifyArtists = ["TakaseToya", "茉ひる"]
            let lines = (0..<20).map { LyricLine(timestamp: Double(10 + $0 * 7), originalText: "歌詞 \($0)") }
            let candidate = LyricsCandidate(id: "c", identity: TrackIdentity(track: track), title: cTitle, artist: cArtist,
                album: "タイムレス", duration: cDuration, lines: lines, isSynchronized: true,
                source: .neteaseExperimental, confidence: 0.8)
            return LyricsSafeMatcher.decide(candidate: candidate, metadata: metadata)
        }
        let same = decideTimeless("タイムレス (feat. 茉ひる)", "高瀬統也, 茉ひる", 174.892)
        XCTAssertEqual(same.tier, .autoMedium, same.reasons.joined(separator: ","))
        XCTAssertTrue(same.reasons.contains("titleLoanwordReading"), same.reasons.joined(separator: ","))
        // A longer version, another word or another singer stays out.
        XCTAssertNotEqual(decideTimeless("タイムレス (feat. 茉ひる)", "高瀬統也, 茉ひる", 192).tier, .autoMedium)
        XCTAssertEqual(decideTimeless("トゥモロー (feat. 茉ひる)", "高瀬統也, 茉ひる", 174.892).tier, .reject)
        XCTAssertEqual(decideTimeless("タイムレス", "Another Singer", 174.892).tier, .reject)
        XCTAssertNotEqual(decideTimeless("タイムレス", "別の歌手", 175.0).tier, .autoMedium, "a whole-second length is not a master length")
        XCTAssertNotEqual(decideTimeless("タイムレス (feat. 茉ひる)", "高瀬統也, 茉ひる", 174.5).tier, .autoMedium, "a guest alone needs the exact length")
        XCTAssertEqual(decideTimeless("Timeless (feat. mahiru)", "別の人, 茉ひる", 174.892).tier, .autoMedium, "same title, credited guest, exact length")
        XCTAssertNotEqual(decideTimeless("タイムレス (feat. 茉ひる) [LIVE TOUR 2024 Ver.]", "高瀬統也, 茉ひる", 174.892).tier, .autoMedium)

        XCTAssertEqual(LyricsSafeMatcher.loanwordKey("Timeless"), LyricsSafeMatcher.loanwordKey("タイムレス"))
        XCTAssertEqual(LyricsSafeMatcher.loanwordKey("Jump"), LyricsSafeMatcher.loanwordKey("ジャンプ"))
        XCTAssertEqual(LyricsSafeMatcher.loanwordKey("Seventeen"), LyricsSafeMatcher.loanwordKey("セブンティーン"))
        XCTAssertNotEqual(LyricsSafeMatcher.loanwordKey("Timeless"), LyricsSafeMatcher.loanwordKey("トゥモロー"))
        XCTAssertNil(LyricsSafeMatcher.loanwordKey("夜に駆ける"), "only katakana or Latin words have a loanword key")
    }

    /// Stay with me / TakaseToya is Stay with me / 高瀬統也 on NetEase, 0.048 s apart.
    func testSingerInAnotherScriptAtTheSameLength() {
        let same = decide(track: "Stay with me", "TakaseToya", 222.624, candidate: "Stay with me", "高瀬統也", 222.672)
        XCTAssertEqual(same.tier, .autoMedium, same.reasons.joined(separator: ","))
        XCTAssertTrue(same.reasons.contains("primaryArtistOtherScriptExactLength"))
        XCTAssertEqual(decide(track: "Stay with me", "TakaseToya", 222.624, candidate: "Stay with me", "松たか子", 258).tier, .reject)
        XCTAssertEqual(decide(track: "Stay with me", "TakaseToya", 222.624, candidate: "Stay with me", "高瀬統也", 223.4).tier, .reject,
                       "without the exact length a name in another script is not enough")
        XCTAssertEqual(decide(track: "Stay with me", "TakaseToya", 222.624, candidate: "Stay with me", "Other Singer", 222.624).tier, .reject,
                       "two Latin names that differ are two singers")
        XCTAssertNotEqual(decide(track: "Stay with me", "TakaseToya", 222.624, candidate: "Stay with me (Live)", "高瀬統也", 222.624).tier, .autoMedium)
    }

    /// Library re-check, 2026-11-15.
    func testRomanizedTitleWithoutLongVowelAndPunctuatedName() {
        let rescue = decide(track: "resukyumi-! (feat. syo24)", "429, syo24", 134.71, candidate: "れすきゅみー！ (feat. syo24)", "429、syo24", 134.0)
        XCTAssertEqual(rescue.tier, .autoMedium, rescue.reasons.joined(separator: ","))
        let riria = decide(track: "最後のバイバイ。", "Riria.", 231.5, candidate: "最後のバイバイ。", "りりあ。", 231.0)
        XCTAssertEqual(riria.tier, .autoMedium, riria.reasons.joined(separator: ","))
        // Whole-second lengths cannot prove the same master.
        let wholeSecond = decide(track: "ルミネセンス", "Lovely Summer Chan", 305.02, candidate: "ルミネセンス", "ラブリーサマーちゃん", 305.0)
        XCTAssertNotEqual(wholeSecond.tier, .autoMedium, wholeSecond.reasons.joined(separator: ","))
        XCTAssertNotEqual(decide(track: "Stay with me", "TakaseToya", 222.62, candidate: "Stay with Me", "裘德", 223.0).tier, .autoMedium)
    }

    func testReleaseCreditsGuestNamesAndExplicitTagDoNotBlockAdoption() {
        // Provider lists the whole release credit; Spotify shows the singer.
        let distance = decide(track: "Distance", "茉ひる", 175.125, candidate: "ディスタンス", "茉ひる、RINZO、VILLSHANA", 175.0)
        XCTAssertEqual(distance.tier, .autoMedium, distance.reasons.joined(separator: ","))
        let night = decide(track: "kimitoauyoru", "茉ひる", 162.4, candidate: "君と会う夜", "茉ひる、RINZO", 162.0)
        XCTAssertEqual(night.tier, .autoMedium, night.reasons.joined(separator: ","))
        // A guest written under two names is still the guest in the title.
        let oracle = decide(track: "oracle (feat. nayuta) - Mwk Remix", "Room97", 203.4,
                            candidate: "oracle (feat. nayuta) (Mwk Remix)", "Room97, nayuta (葉月なの)", 203.0)
        XCTAssertEqual(oracle.tier, .autoMedium, oracle.reasons.joined(separator: ","))
        let curse = decide(track: "you are my curse", "nyamura", 140.086, candidate: "you are my curse (Explicit)", "nyamura", 140.0)
        XCTAssertTrue(curse.tier == .autoMedium || curse.tier == .autoHigh, curse.reasons.joined(separator: ","))

        // Still kept for review: a different singer, a clean edit, a
        // guest version far from the length, an instrumental.
        XCTAssertNotEqual(decide(track: "Distance", "茉ひる", 175.125, candidate: "ディスタンス", "RINZO、茉ひる", 175.0).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "you are my curse", "nyamura", 140.086, candidate: "you are my curse (Clean)", "nyamura", 140.0).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "kimitoauyoru", "茉ひる", 162.4, candidate: "君と会う夜", "茉ひる、RINZO", 171.0).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "忘れてやらない", "結束バンド", 223.4, candidate: "忘れてやらない (纯音乐)", "結束バンド", 223.0).tier, .autoMedium)
    }

    func testTranslatedTitleAtTheSameMasterLength() {
        let again = decide(track: "Again - Sped Up Ver.", "stb", 185.504, candidate: "もう一度 (Sped Up Ver.)", "stb, NEA", 185.504)
        XCTAssertEqual(again.tier, .autoMedium, again.reasons.joined(separator: ","))
        let noise = decide(track: "the NOISE (Contains a Samples of 夜に駆ける)", "LE SSERAFIM", 224.28,
                           candidate: "the NOISE (Contains a Samples of Into The Night)", "LE SSERAFIM, YOASOBI", 224.28)
        XCTAssertEqual(noise.tier, .autoMedium, noise.reasons.joined(separator: ","))
        // Stores differ by a few hundredths for one master.
        let mayday = decide(track: "Mayday", "Tsukuyomi", 202.933, candidate: "メデ", "月詠み", 202.988, aliases: ["Mayday"])
        XCTAssertEqual(mayday.tier, .autoMedium, mayday.reasons.joined(separator: ","))

        // Whole seconds, a backing track, a sped-up cut against the original,
        // another singer: still not adopted.
        XCTAssertNotEqual(decide(track: "不够", "橙汁", 200.071, candidate: "千度雪寻", "橙汁", 200.0).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "听悲伤的情歌 - 女版", "一口甜", 198.02, candidate: "听悲伤的情歌 (伴奏)", "一口甜", 198.02).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "Again", "stb", 185.504, candidate: "もう一度 (Sped Up Ver.)", "stb", 185.504).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "Again", "stb", 185.504, candidate: "もう一度", "Another Singer", 185.504).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "Again", "stb", 185.504, candidate: "もう一度", "stb", 185.904).tier, .autoMedium)
    }

    func testWrittenAndSymbolicPercentageTitlesMatchWithRecordingEvidence() {
        let matched = decide(track: "百分之零", "橙汁, 迟亦骁, 97Virus", 176.367,
                             candidate: "0%", "橙汁", 176)
        XCTAssertEqual(matched.tier, .autoMedium, matched.reasons.joined(separator: ","))
        for (title, artist, duration) in [
            ("1%", "橙汁", 176.0), ("0%", "七羽", 176.0), ("0%", "橙汁", 180.0),
            ("0% (Live)", "橙汁", 176.0), ("0%", "橙汁, 七羽", 176.0)
        ] {
            let result = decide(track: "百分之零", "橙汁, 迟亦骁, 97Virus", 176.367,
                                candidate: title, artist, duration)
            XCTAssertFalse([.autoMedium, .autoHigh].contains(result.tier), result.reasons.joined(separator: ","))
        }
    }

    func testTitleOnlyQueryAndBilingualTitlesStillAdoptTheSameRecording() {
        // Found by title alone, but title, singer and length all agree.
        let shikiura = decide(track: "叶わぬ恋じゃ終われない！", "ハコニワリリィ", 190.96,
                              candidate: "叶わぬ恋じゃ終われない!", "ハコニワリリィ", 190.96, loose: true)
        XCTAssertEqual(shikiura.tier, .autoMedium, shikiura.reasons.joined(separator: ","))
        let kiddy = decide(track: "Kiddy", "Rokudenashi", 199.4, candidate: "Kiddy", "ロクデナシ", 199.0, loose: true)
        XCTAssertEqual(kiddy.tier, .autoMedium, kiddy.reasons.joined(separator: ","))
        // Original and English names written together.
        let love = decide(track: "Love°C", "TakaseToya", 230.729, candidate: "愛℃ - Love°C", "TakaseToya", 231.0)
        XCTAssertEqual(love.tier, .autoMedium, love.reasons.joined(separator: ","))
        let station = decide(track: "星街の駅で - At Hoshimachi Station", "tuki.", 239.4, candidate: "星街の駅で", "tuki.", 239.0)
        XCTAssertEqual(station.tier, .autoMedium, station.reasons.joined(separator: ","))

        // Loose results with another singer, another length or a version
        // label stay out; a dash followed by a version is not a second name.
        XCTAssertNotEqual(decide(track: "Kiddy", "Rokudenashi", 199.4, candidate: "Kiddy", "Someone Else", 199.0, loose: true).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "Kiddy", "Rokudenashi", 199.4, candidate: "Kiddy", "ロクデナシ", 230.0, loose: true).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "Kiddy", "Rokudenashi", 199.4, candidate: "Kiddy (Live)", "ロクデナシ", 199.0, loose: true).tier, .autoMedium)
        XCTAssertFalse(LyricsSafeMatcher.titlesAreBilingualPair("夜に駆ける - Live", "夜に駆ける"))
        XCTAssertFalse(LyricsSafeMatcher.titlesAreBilingualPair("Song - Another Song", "Song"))
        XCTAssertNotEqual(decide(track: "Love°C", "TakaseToya", 230.729, candidate: "愛℃ - Love°C", "Other", 231.0).tier, .autoMedium)
        XCTAssertNotEqual(decide(track: "Love°C", "TakaseToya", 230.729, candidate: "愛℃ - Love°C", "TakaseToya", 250.0).tier, .autoMedium)
    }

    func testSameMasterWithEarlyLastLineAndThePublishersOwnPage() {
        let twin = decide(track: "822", "橙汁", 182.405, candidate: "0822", "橙汁", 182.405)
        XCTAssertNotEqual(twin.tier, .reject, twin.reasons.joined(separator: ","))
        let track = Track(title: "Kuzuyan", artist: "Haruki Hamano", album: "NET BaBY", duration: 188.5)
        let identity = TrackIdentity(track: track)
        let page = LyricsCandidate(id: "lc", identity: identity, title: "Kuzuyan", artist: "Haruki Hamano", album: "",
                                   duration: 0, lines: [LyricLine(timestamp: 0, originalText: "words")], isSynchronized: false,
                                   source: .linkcore, confidence: 0.7)
        let metadata = TrackMetadata.bootstrap(from: track)
        XCTAssertEqual(LyricsSafeMatcher.decide(candidate: page, metadata: metadata).tier, .autoMedium)
        let other = LyricsCandidate(id: "lc2", identity: identity, title: "Kuzuyan", artist: "Someone", album: "",
                                    duration: 0, lines: [LyricLine(timestamp: 0, originalText: "words")], isSynchronized: false,
                                    source: .linkcore, confidence: 0.7)
        XCTAssertNotEqual(LyricsSafeMatcher.decide(candidate: other, metadata: metadata).tier, .autoMedium)
        let live = LyricsCandidate(id: "lc3", identity: identity, title: "Kuzuyan (Live)", artist: "Haruki Hamano", album: "",
                                   duration: 0, lines: [LyricLine(timestamp: 0, originalText: "words")], isSynchronized: false,
                                   source: .linkcore, confidence: 0.7)
        XCTAssertNotEqual(LyricsSafeMatcher.decide(candidate: live, metadata: metadata).tier, .autoMedium)
    }

    func testOpenAIAPINeedsOnlyAKeyAndTheListenerPicksModelAndEffort() async throws {
        XCTAssertTrue(OpenAIAPIDefaults.isChatModel("gpt-5.1-mini"))
        XCTAssertFalse(OpenAIAPIDefaults.isChatModel("gpt-4o-realtime-preview"))
        XCTAssertFalse(OpenAIAPIDefaults.isChatModel("text-embedding-3-small"))

        final class Recorder: AIHTTPClient, @unchecked Sendable {
            var requests: [URLRequest] = []
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                requests.append(request)
                let body = #"{"choices":[{"message":{"content":"[{\"index\":0,\"translation\":\"ok\"}]"}}]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let http = Recorder()
        let service = OpenAICompatibleTranslationService.openAI(client: OpenAICompatibleClient(httpClient: http),
                                                               keyStore: InMemoryAITranslationAPIKeyStore(key: "sk-test"))
        // No model chosen yet: nothing is sent and nothing is picked for the listener.
        var configuration = AITranslationConfiguration(engineID: TranslationEngineID.openAIAPI.rawValue)
        XCTAssertFalse(configuration.isConfigured)
        do { try await service.testConnection(configuration: configuration); XCTFail("needs a chosen model") } catch {}
        XCTAssertTrue(http.requests.isEmpty)

        // Model and effort chosen; the endpoint is never typed.
        configuration.model = "gpt-5.1"
        configuration = TranslationReasoningPolicy.setting("high", in: configuration)
        try await service.testConnection(configuration: configuration)
        let chat = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(chat.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: chat.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.1")
        XCTAssertEqual(json["reasoning_effort"] as? String, "high")
        XCTAssertNil(json["temperature"], "OpenAI reasoning models reject a non-default temperature")
        XCTAssertEqual(configuration.providerReasoningSetting, "reasoning_effort=high")
        XCTAssertEqual(TranslationEngineCatalog.topLevelID(for: TranslationEngineID.openAIAPI.rawValue),
                       TranslationEngineID.openAICompatible.rawValue)
        XCTAssertTrue(TranslationEngineRegistry.make(stableID: TranslationEngineID.deepSeekAPI.rawValue) is DeepSeekTranslationService,
                      "DeepSeek is wired, not the unavailable placeholder")
    }

    @MainActor
    func testAIOnlyTranslationHidesTheSourcesOwnTranslation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = SQLiteLyricsRepository(databaseURL: dir.appendingPathComponent("t.sqlite3"),
                                          alignmentProvenanceDirectory: dir.appendingPathComponent("p"))
        try await repo.prepare()
        let track = Track(title: "Luv it", artist: "Singer", album: "A", duration: 120)
        let identity = TrackIdentity(track: track)
        let document = LyricsDocument(identity: identity, title: track.title, artist: track.artist, album: track.album,
            duration: 120, lines: [LyricLine(timestamp: 1, originalText: "きみとなら", translationText: "和你的话"),
                                   LyricLine(timestamp: 5, originalText: "恋したいの", translationText: "想恋爱")],
            isSynchronized: true, source: .neteaseExperimental, confidence: 0.9)
        let saved = try await repo.save(track: track, identity: identity, document: document)
        let suite = "ai-only-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = TranslationSessionController(repository: repo, engine: nil, selectionDefaults: defaults, acceptanceBudget: nil)
        var config = AITranslationConfiguration(engineID: TranslationEngineID.openAIAPI.rawValue)
        config.autoTranslateNewLyrics = false
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        session.synchronize(document: document, lyricsVersionID: saved.versionID,
                            sourceContentHash: saved.sourceContentHash, configuration: config)
        try await waitFor { session.selectedVersion != nil }
        XCTAssertEqual(session.selectedVersion?.isEmbeddedTranslation, true, "automatic shows the source's translation")

        session.preferAITranslation()
        try await waitFor { session.selectedVersion == nil }
        XCTAssertNil(session.selectedVersion)
        XCTAssertTrue(session.project(onto: document.lines).allSatisfy { $0.translationText == nil },
                      "no AI translation yet: nothing is shown")
        XCTAssertTrue(defaults.bool(forKey: TranslationSessionController.prefersAITranslationKey), "kept for every song")

        session.restoreRecommended()
        try await waitFor { session.selectedVersion != nil }
        XCTAssertEqual(session.selectedVersion?.isEmbeddedTranslation, true)
        XCTAssertFalse(session.prefersAITranslation)
    }

    @MainActor
    func testOpenAIEffortUsesTheModelsOwnLevelsAndSurvivesARelaunch() async throws {
        let suite = "openai-effort-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // The Codex directory knows gpt-6-astra's levels; OpenAI's list does not.
        let codex = AITranslationConfiguration(engineID: TranslationEngineID.codexChatGPT.rawValue)
        let store = TranslationModelSettingsStore(defaults: defaults, configuration: codex) { _ in
            [TranslationModelDescriptor(id: "gpt-6-astra", reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"])]
        }
        store.refresh(codex)
        let deadline = Date().addingTimeInterval(2)
        while store.knownReasoningEfforts(model: "gpt-6-astra") == nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.knownReasoningEfforts(model: "gpt-6-astra"), ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertNil(store.knownReasoningEfforts(model: "gpt-unknown"))
        let firstRead = try XCTUnwrap(store.cachedAt)
        var configured = codex
        configured.model = "gpt-6-astra"
        configured.codexReasoningEffort = "ultra"
        store.refresh(configured)
        XCTAssertEqual(store.status, .loading)
        let refreshDeadline = Date().addingTimeInterval(2)
        while store.status == .loading && Date() < refreshDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(try XCTUnwrap(store.cachedAt), firstRead, "identical results still record a fresh read")
        XCTAssertEqual(store.restored(codex).codexReasoningEffort, "ultra")
        XCTAssertEqual(TranslationReasoningPolicy.recordedCodexEffortLabel("effort=ultra"), "超高（Ultra）")

        let settings = AppSettingsStore(defaults: defaults)
        _ = settings.translationModelSettings
        settings.selectTranslationProvider(TranslationEngineID.openAIAPI.rawValue)
        let controls = TranslationProviderControls(settings: settings)
        controls.modelBinding.wrappedValue = "gpt-6-astra"
        controls.reasoningBinding.wrappedValue = "max"
        XCTAssertEqual(settings.aiTranslationConfiguration.providerReasoningSetting, "reasoning_effort=max")
        // A relaunch reads it before anything opens the translation panel.
        XCTAssertEqual(AppSettingsStore(defaults: defaults).aiTranslationConfiguration.openAIReasoningEffort, "max")
    }

    func testSingerFromBandIsTheSinger() {
        XCTAssertEqual(TrackTextNormalizer.fromArtistNames("suis from Yorushika"), ["suis"])
        XCTAssertTrue(TrackTextNormalizer.fromArtistNames("Yorushika").isEmpty)
        let from = decide(track: "星めぐる詩", "suis from Yorushika", 202, candidate: "星めぐる詩", "suis", 202)
        XCTAssertTrue(from.tier == .autoMedium || from.tier == .autoHigh, from.reasons.joined(separator: ","))
    }
}
