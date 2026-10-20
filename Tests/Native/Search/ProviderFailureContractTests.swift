import Foundation
import XCTest
@testable import SpotifyLyrics

private final class ProviderFailureLRCLIBSession: LRCLIBSession, @unchecked Sendable {
    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
        let error: Error?
        let delay: UInt64
    }

    private let responses: [Response]
    private(set) var requests: [URLRequest] = []
    private var index = 0

    init(responses: [Response]) { self.responses = responses }

    convenience init(data: Data, statusCode: Int = 200, headers: [String: String] = [:], delay: UInt64 = 0) {
        self.init(responses: [Response(data: data, statusCode: statusCode, headers: headers, error: nil, delay: delay)])
    }

    convenience init(error: Error, delay: UInt64 = 0) {
        self.init(responses: [Response(data: Data(), statusCode: 0, headers: [:], error: error, delay: delay)])
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response: Response
        if index < responses.count {
            response = responses[index]
            index += 1
        } else if let lastResponse = responses.last {
            response = lastResponse
        } else {
            throw NSError(domain: "ProviderFailureContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "No HTTP fixture response configured"])
        }
        if response.delay > 0 { try await Task.sleep(nanoseconds: response.delay) }
        try Task.checkCancellation()
        if let error = response.error { throw error }
        guard let responseURL = request.url ?? URL(string: "https://lrclib.net/api/get"),
              let http = HTTPURLResponse(
                url: responseURL,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
              ) else {
            throw NSError(domain: "ProviderFailureContractTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create HTTP fixture response"])
        }
        return (response.data, http)
    }
}

private struct ProviderFailureFixedLyricsProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { result }
}

private struct ProviderFailureDelayedLyricsProvider: LyricsProvider {
    let name: String
    let delay: UInt64
    let result: LyricsLookupResult
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        try? await Task.sleep(nanoseconds: delay)
        if Task.isCancelled { return .failed(.cancelled) }
        return result
    }
}

private struct ProviderFailureCountingLyricsProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    let counter: ProviderFailureCounter
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        counter.increment()
        return result
    }
}

private final class ProviderFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

private final class ProviderFailureNetEaseFixtureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var searchBody = Data()
    private var lyricBodies: [String: Data] = [:]

    func reset(searchBody: Data, lyricBodies: [String: Data]) {
        lock.lock()
        self.searchBody = searchBody
        self.lyricBodies = lyricBodies
        lock.unlock()
    }

    func body(for request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return Data() }
        if url.path.hasSuffix("/api/search/get/web") { return searchBody }
        if url.path.hasSuffix("/api/song/lyric"),
           let id = components.queryItems?.first(where: { $0.name == "id" })?.value {
            return lyricBodies[id] ?? Data("{}".utf8)
        }
        return Data("{}".utf8)
    }
}

private final class ProviderFailureNetEaseFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = ProviderFailureNetEaseFixtureStore()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "music.163.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "ProviderFailureContractTests", code: 3))
            return
        }
        let body = Self.store.body(for: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ProviderFailureContractTests: XCTestCase {
    func testNetEaseAliasesAndMetadataOnlyFailureRemainDistinct() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFailureNetEaseFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let fireworkTrack = Track(title: "Fireworks", artist: "Fixture Artist", album: "Fixture Album", duration: 120)
        let fireworkIdentity = TrackIdentity(track: fireworkTrack)
        let fireworkSearch = try JSONSerialization.data(withJSONObject: ["result": ["songs": [[
            "id": 9001, "name": "花火", "alias": [], "transNames": ["Fireworks"],
            "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture Album"], "duration": 120_000
        ]]]])
        let lyricBody = try JSONSerialization.data(withJSONObject: [
            "lrc": ["lyric": "[00:01.00]fixture line"], "tlyric": ["lyric": ""], "yrc": ["lyric": ""]
        ])
        ProviderFailureNetEaseFixtureURLProtocol.store.reset(searchBody: fireworkSearch, lyricBodies: ["9001": lyricBody])
        let fireworkResult = await NetEaseExperimentalLyricsProvider(session: session)
            .lookup(track: fireworkTrack, identity: fireworkIdentity)
        guard case .candidates(let fireworkCandidates) = fireworkResult else {
            XCTFail("NetEase provider should return a translated-title candidate, got \(fireworkResult)")
            return
        }
        let fireworkCandidate = try XCTUnwrap(fireworkCandidates.first)
        XCTAssertEqual(fireworkCandidate.declaredTitleAliases, ["Fireworks"], "NetEase transNames should be retained as independent title metadata")
        let fireworkDecision = LyricsSafeMatcher.decide(
            candidate: fireworkCandidate,
            metadata: TrackMetadata.bootstrap(from: fireworkTrack)
        )
        XCTAssertEqual(fireworkDecision.tier, .autoMedium)
        XCTAssertTrue(fireworkDecision.reasons.contains("titleProviderAliasConfirmed"))

        let echoSearch = try JSONSerialization.data(withJSONObject: ["result": ["songs": [[
            "id": 9002, "name": "花火", "alias": [], "transNames": [],
            "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture Album"], "duration": 120_000
        ]]]])
        ProviderFailureNetEaseFixtureURLProtocol.store.reset(searchBody: echoSearch, lyricBodies: ["9002": lyricBody])
        let echoResult = await NetEaseExperimentalLyricsProvider(session: session)
            .lookup(track: fireworkTrack, identity: fireworkIdentity)
        guard case .candidates(let echoCandidates) = echoResult else {
            XCTFail("Unaliased NetEase title should remain a candidate for matcher rejection, got \(echoResult)")
            return
        }
        let echoCandidate = try XCTUnwrap(echoCandidates.first)
        XCTAssertTrue(echoCandidate.declaredTitleAliases.isEmpty, "The query title must not be copied into provider-declared aliases")
        let echoDecision = LyricsSafeMatcher.decide(candidate: echoCandidate, metadata: TrackMetadata.bootstrap(from: fireworkTrack))
        XCTAssertEqual(echoDecision.tier, .reject)
        XCTAssertTrue(echoDecision.reasons.contains("titleMismatch"))

        let hanabiTrack = Track(title: "HANABI", artist: "SACBEN", album: "はなび", duration: 120.086)
        let hanabiIdentity = TrackIdentity(track: hanabiTrack)
        let exactHanabiSearch = try JSONSerialization.data(withJSONObject: ["result": ["songs": [[
            "id": 2086887456, "name": "はなび", "alias": [], "transNames": ["花火"],
            "artists": [["name": "SACBEN"]], "album": ["name": "はなび"], "duration": 120_085
        ]]]])
        let noLyricsBody = try JSONSerialization.data(withJSONObject: [
            "lrc": ["lyric": ""], "tlyric": ["lyric": ""], "yrc": ["lyric": ""]
        ])
        ProviderFailureNetEaseFixtureURLProtocol.store.reset(searchBody: exactHanabiSearch, lyricBodies: ["2086887456": noLyricsBody])
        let metadataOnlyResult = await NetEaseExperimentalLyricsProvider(session: session)
            .lookup(track: hanabiTrack, identity: hanabiIdentity)
        guard case .failed(.lyricsBodyUnavailable(let metadataOnlyMessage)) = metadataOnlyResult else {
            XCTFail("Exact NetEase metadata without lyric text must be reported distinctly, got \(metadataOnlyResult)")
            return
        }
        XCTAssertTrue(metadataOnlyMessage.contains("目录命中"))
        XCTAssertTrue(metadataOnlyMessage.contains("没有歌词正文"))

        let wrongHanabi = LyricsCandidate(
            id: "wrong-hanabi", identity: hanabiIdentity, title: "Hanabi", artist: "黒川沙良", album: "Other Album", duration: 321.506,
            lines: [LyricLine(timestamp: 0, originalText: "fixture")], source: .neteaseExperimental, confidence: 1
        )
        let splitDiagnosis = await LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "wrong same-title source", result: .candidates([wrongHanabi])),
            ProviderFailureFixedLyricsProvider(name: "NetEase Experimental", result: metadataOnlyResult)
        ]).search(track: hanabiTrack, identity: hanabiIdentity)
        guard case .failed(let splitFailure) = splitDiagnosis.result,
              case .lyricsBodyUnavailable = splitFailure else {
            XCTFail("Exact catalog without text must remain distinct from unrelated same-title candidates")
            return
        }
        XCTAssertTrue(splitFailure.recoveryMessage.contains("目录命中"))
        XCTAssertTrue(splitFailure.recoveryMessage.contains("没有歌词正文"))
        XCTAssertEqual(splitFailure.userFacingTitle, "已找到歌曲，暂无歌词正文")
        XCTAssertFalse(splitFailure.recoveryMessage.contains("黒川沙良"))
        XCTAssertFalse(splitFailure.recoveryMessage.contains("322 秒"))
    }

    func testLRCLIBResultMappingRetriesAndNoFileMutation() async throws {
        let track = Track(title: "LRCLIB Song", artist: "LRCLIB Artist", album: "LRCLIB Album", duration: 210)
        let identity = TrackIdentity(track: track)
        let okPayload = Data("""
        {
          "id": 1,
          "trackName": "LRCLIB Song",
          "artistName": "LRCLIB Artist",
          "albumName": "LRCLIB Album",
          "duration": 210,
          "syncedLyrics": "[00:01.00]hello\\n[00:02.00]world"
        }
        """.utf8)
        let okSession = ProviderFailureLRCLIBSession(data: okPayload, statusCode: 200)
        let okResult = await LRCLIBLyricsProvider(session: okSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .match(let document) = okResult else {
            XCTFail("Expected LRCLIB match, got \(okResult)")
            return
        }
        XCTAssertEqual(document.identity, identity)
        XCTAssertTrue(document.isSynchronized)
        XCTAssertEqual(document.source, .lrclib)
        XCTAssertTrue(okSession.requests.first?.url?.absoluteString.contains("track_name=LRCLIB%20Song") == true)

        for (label, title, artist, duration, instrumental) in [
            ("unrelated instrumental", "Other Song", "Other Artist", 210.0, true),
            ("different version", "LRCLIB Song (Instrumental)", "LRCLIB Artist", 210.0, true),
            ("different duration", "LRCLIB Song", "LRCLIB Artist", 300.0, true),
            ("empty vocal record", "LRCLIB Song", "LRCLIB Artist", 210.0, false)
        ] {
            let body = try JSONSerialization.data(withJSONObject: [
                "id": 8, "trackName": title, "artistName": artist, "duration": duration, "instrumental": instrumental
            ])
            let outcome = await LRCLIBLyricsProvider(session: ProviderFailureLRCLIBSession(data: body), maxAutomaticRetries: 0)
                .lookup(track: track, identity: identity)
            guard case .noMatch = outcome else {
                XCTFail("\(label) must not declare the requested song lyric-free: \(outcome)")
                return
            }
        }
        let instrumentalBody = try JSONSerialization.data(withJSONObject: [
            "id": 9, "trackName": track.title, "artistName": track.artist, "duration": track.duration, "instrumental": true
        ])
        let explicitNoLyrics = await LRCLIBLyricsProvider(session: ProviderFailureLRCLIBSession(data: instrumentalBody), maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .noLyrics = explicitNoLyrics else {
            XCTFail("Exact instrumental metadata should retain noLyrics result, got \(explicitNoLyrics)")
            return
        }

        let notFoundSession = ProviderFailureLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 404, headers: [:], error: nil, delay: 0),
            .init(data: Data("[]".utf8), statusCode: 200, headers: [:], error: nil, delay: 0)
        ])
        let notFound = await LRCLIBLyricsProvider(session: notFoundSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .noMatch = notFound else {
            XCTFail("Expected 404/noMatch, got \(notFound)")
            return
        }

        let badRequest = await LRCLIBLyricsProvider(
            session: ProviderFailureLRCLIBSession(data: Data(), statusCode: 400), maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.serverError(400)) = badRequest else {
            XCTFail("Expected 400 failure, got \(badRequest)")
            return
        }

        let timeout = await LRCLIBLyricsProvider(
            session: ProviderFailureLRCLIBSession(error: URLError(.timedOut)), maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.timedOut) = timeout else {
            XCTFail("Expected timeout, got \(timeout)")
            return
        }

        let network = await LRCLIBLyricsProvider(
            session: ProviderFailureLRCLIBSession(error: URLError(.notConnectedToInternet)), maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.networkUnavailable) = network else {
            XCTFail("Expected network failure, got \(network)")
            return
        }

        let rateSession = ProviderFailureLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 429, headers: ["Retry-After": "0"], error: nil, delay: 0),
            .init(data: Data(), statusCode: 429, headers: ["Retry-After": "0"], error: nil, delay: 0)
        ])
        let rateLimited = await LRCLIBLyricsProvider(session: rateSession, maxAutomaticRetries: 1)
            .lookup(track: track, identity: identity)
        guard case .failed(.rateLimited) = rateLimited else {
            XCTFail("Expected rateLimited, got \(rateLimited)")
            return
        }
        XCTAssertEqual(rateSession.requests.count, 2)

        let parse = await LRCLIBLyricsProvider(
            session: ProviderFailureLRCLIBSession(data: Data("not-json".utf8), statusCode: 200), maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.parseFailure) = parse else {
            XCTFail("Expected parse failure, got \(parse)")
            return
        }

        let recoverSession = ProviderFailureLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 0, headers: [:], error: URLError(.timedOut), delay: 0),
            .init(data: okPayload, statusCode: 200, headers: [:], error: nil, delay: 0)
        ])
        let recovered = await LRCLIBLyricsProvider(session: recoverSession, maxAutomaticRetries: 1)
            .lookup(track: track, identity: identity)
        guard case .match = recovered else {
            XCTFail("Expected retry recovery, got \(recovered)")
            return
        }
        XCTAssertEqual(recoverSession.requests.count, 2)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("marker.txt")
        try "keep".write(to: marker, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: marker)
        _ = await LRCLIBLyricsProvider(session: okSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        XCTAssertEqual(try Data(contentsOf: marker), before, "LRCLIB must not persist or mutate local files")
    }

    func testSearchManagerKeepsFailuresAndIdentityDecisionsSeparate() async throws {
        let track = Track(title: "LRCLIB Song", artist: "LRCLIB Artist", album: "LRCLIB Album", duration: 210)
        let identity = TrackIdentity(track: track)
        let slowDoc = LyricsDocument(
            identity: identity, title: track.title, artist: track.artist, album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 1, originalText: "stale")], source: .lrclib
        )
        let trackB = Track(title: "Track B", artist: "Artist B", album: "Album", duration: 180)
        let identityB = TrackIdentity(track: trackB)
        let freshDoc = LyricsDocument(
            identity: identityB, title: trackB.title, artist: trackB.artist, album: trackB.album, duration: trackB.duration,
            lines: [LyricLine(timestamp: 1, originalText: "fresh")], source: .local
        )
        let slowController = LyricsSessionController(
            provider: ProviderFailureDelayedLyricsProvider(name: "slow", delay: 120_000_000, result: .match(slowDoc))
        )
        slowController.begin(track: track, identity: identity)
        let fastController = LyricsSessionController(
            provider: ProviderFailureFixedLyricsProvider(name: "fast", result: .match(freshDoc))
        )
        fastController.begin(track: track, identity: identity)
        fastController.begin(track: trackB, identity: identityB)
        try await Task.sleep(nanoseconds: 20_000_000)
        guard let loaded = fastController.state.document else {
            XCTFail("Expected fresh loaded state")
            return
        }
        XCTAssertEqual(loaded.identity, identityB)
        XCTAssertEqual(loaded.lines.first?.originalText, "fresh")
        XCTAssertEqual(fastController.lyrics.first?.originalText, "fresh")

        let localMatch = LyricsDocument(
            identity: identity, title: track.title, artist: track.artist, album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "local")], source: .local, confidence: 0.95
        )
        let localCounter = ProviderFailureCounter()
        let remoteCounter = ProviderFailureCounter()
        let manager = LyricsSearchManager(providers: [
            ProviderFailureCountingLyricsProvider(name: "local", result: .match(localMatch), counter: localCounter),
            ProviderFailureCountingLyricsProvider(name: "lrclib-fail", result: .failed(.networkUnavailable), counter: remoteCounter)
        ])
        let outcome = await manager.search(track: track, identity: identity)
        guard case .match(let matched) = outcome.result else {
            XCTFail("Local success must win despite remote failure")
            return
        }
        XCTAssertEqual(matched.source, .local)
        XCTAssertEqual(localCounter.value, 1)

        let remoteOnly = LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "local-miss", result: .noMatch),
            ProviderFailureFixedLyricsProvider(name: "lrclib-fail", result: .failed(.timedOut)),
            ProviderFailureFixedLyricsProvider(name: "local-second", result: .match(localMatch))
        ])
        let isolated = await remoteOnly.search(track: track, identity: identity)
        guard case .match(let isolatedMatch) = isolated.result else {
            XCTFail("Later provider success must survive earlier failure, got \(isolated.result)")
            return
        }
        XCTAssertEqual(isolatedMatch.source, .local)
        XCTAssertTrue(isolated.diagnostics.contains { diagnostic in
            if case .failed(.timedOut) = diagnostic.outcome { return true }
            return false
        })

        let conflicting = LyricsCandidate(
            id: "wrong-artist", identity: identity, title: track.title, artist: "Unrelated Singer", album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "fixture")], source: .lrclib, confidence: 1
        )
        let unconfirmed = await LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "wrong-artist", result: .candidates([conflicting])),
            ProviderFailureFixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let identityFailure) = unconfirmed.result,
              case .identityUnconfirmed(let rejectedCount, let sourceError) = identityFailure else {
            XCTFail("Rejected identity must stay distinct from unavailable service")
            return
        }
        XCTAssertGreaterThan(rejectedCount, 0)
        XCTAssertTrue(sourceError.contains("限流"))
        XCTAssertEqual(identityFailure.userFacingTitle, "歌词身份待确认")
        XCTAssertTrue(identityFailure.recoveryMessage.contains("未能确认"))
        XCTAssertTrue(identityFailure.recoveryMessage.contains("限流"))
        XCTAssertTrue(unconfirmed.alternatives.isEmpty)
        XCTAssertNil(unconfirmed.automaticDecision, "Hard-rejected wrong artist must not be exposed or auto-adopted")

        let nearbyTitle = LyricsCandidate(
            id: "nearby-title", identity: identity, title: "Different Title", artist: track.artist, album: track.album,
            duration: track.duration + 0.1, lines: [LyricLine(timestamp: 0, originalText: "fixture")],
            source: .neteaseExperimental, confidence: 1
        )
        let unrelatedTitle = LyricsCandidate(
            id: "unrelated-title", identity: identity, title: "无关长歌", artist: track.artist, album: "Other Album",
            duration: track.duration + 90, lines: nearbyTitle.lines, source: .neteaseExperimental, confidence: 1
        )
        let titleMismatch = await LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "nearby-source", result: .candidates([unrelatedTitle, nearbyTitle])),
            ProviderFailureFixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let titleFailure) = titleMismatch.result else {
            XCTFail("Title mismatch must remain a failed identity check")
            return
        }
        XCTAssertTrue(titleFailure.recoveryMessage.contains("Different Title"))
        XCTAssertTrue(titleFailure.recoveryMessage.contains(track.title))
        XCTAssertTrue(titleFailure.recoveryMessage.contains("标题"))
        XCTAssertFalse(titleFailure.recoveryMessage.contains("无关长歌"))
        XCTAssertTrue(titleFailure.recoveryMessage.contains("限流"))
        XCTAssertTrue(titleMismatch.alternatives.isEmpty)
        XCTAssertNil(titleMismatch.automaticDecision)

        let translatedTitleTrack = Track(title: "meaning of tears", artist: "tear", album: "meaning of tears", duration: 234.66)
        let translatedTitleIdentity = TrackIdentity(track: translatedTitleTrack)
        func translatedTitle(_ title: String, duration: Double = 234.659) -> LyricsCandidate {
            LyricsCandidate(
                id: title, identity: translatedTitleIdentity, title: title, artist: "TEAR", album: title,
                duration: duration, lines: [LyricLine(timestamp: 1, originalText: "fixture")],
                isSynchronized: true, source: .neteaseExperimental, confidence: 0.5
            )
        }
        let inferred = await LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "localized-source", result: .candidates([translatedTitle("涙の意味")]))
        ]).search(track: translatedTitleTrack, identity: translatedTitleIdentity)
        guard case .match = inferred.result else {
            XCTFail("Unique cross-script title with same artist and recording duration must auto-select")
            return
        }
        XCTAssertTrue(inferred.automaticDecision?.reasons.contains("localizedTitleArtistDuration") == true)

        let ambiguousCandidates = [
            [translatedTitle("涙の意味"), translatedTitle("別の曲")],
            [translatedTitle("涙の意味", duration: 239)],
            [translatedTitle("Unrelated Song")],
            [translatedTitle("2024")],
            [translatedTitle("☆")]
        ]
        for candidates in ambiguousCandidates {
            let result = await LyricsSearchManager(providers: [
                ProviderFailureFixedLyricsProvider(name: "source", result: .candidates(candidates))
            ]).search(track: translatedTitleTrack, identity: translatedTitleIdentity)
            XCTAssertNil(result.automaticDecision, "Ambiguous, distant, same-script or non-letter titles must not use localization inference")
        }

        let localizedTrack = Track(title: "ai", artist: "LOVELY BOMB", album: "ai", duration: 168.58)
        let localizedIdentity = TrackIdentity(track: localizedTrack)
        let localizedCandidate = LyricsCandidate(
            id: "localized-title", identity: localizedIdentity, title: "愛", artist: "LOVELY BOMB", album: "愛", duration: 168.646,
            lines: [LyricLine(timestamp: 1, originalText: "fixture")],
            isSynchronized: true, source: .neteaseExperimental, confidence: 1
        )
        let localizedResult = await LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "localized-source", result: .candidates([localizedCandidate]))
        ]).search(track: localizedTrack, identity: localizedIdentity)
        guard case .match(let localizedDocument) = localizedResult.result else {
            XCTFail("Manager should automatically select 愛 for ai with matching artist and duration")
            return
        }
        XCTAssertEqual(localizedDocument.title, "愛")
        XCTAssertNotNil(localizedResult.automaticDecision)

        let onlyLimited = await LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let networkFailure) = onlyLimited.result,
              case .rateLimited = networkFailure else {
            XCTFail("HTTP 429 must remain a real provider failure")
            return
        }
        XCTAssertEqual(networkFailure.userFacingTitle, "歌词暂不可用")
        XCTAssertTrue(networkFailure.recoveryMessage.contains("限流"))
    }
}
