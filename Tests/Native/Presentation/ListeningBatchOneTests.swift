import AppKit
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

    func testTempoFromARegularBeat() {
        let fps = PulseAnalyzer.framesPerSecond
        let period = 60.0 / 120 * fps   // 120 BPM
        let flux = (0..<Int(fps * 8)).map { index -> Double in
            fmod(Double(index), period) < 1 ? 1 : 0
        }
        let bpm = try? XCTUnwrap(PulseAnalyzer.tempo(flux, fps: fps))
        XCTAssertEqual(bpm ?? 0, 120, accuracy: 3)
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
