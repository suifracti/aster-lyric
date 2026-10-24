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

private final class ProviderFailureToggle: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    var isFailing: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failing
        }
        set {
            lock.lock()
            failing = newValue
            lock.unlock()
        }
    }
}

private struct ProviderFailureScriptedLyricsProvider: LyricsProvider {
    let name: String
    let toggle: ProviderFailureToggle
    let result: LyricsLookupResult
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        toggle.isFailing ? .failed(.timedOut) : result
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

    func testSearchEndAppendsOneParseableSourceStatsLine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-stats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("source-stats.jsonl")
        let stats = LyricsSourceStats(fileURL: fileURL)
        let controller = LyricsSessionController(
            providers: [ProviderFailureFixedLyricsProvider(name: "QQ Music Experimental", result: .noMatch)],
            sourceStats: stats
        )
        let track = Track(title: "Stats Song", artist: "Stats Artist", album: "Stats Album", duration: 200)
        let identity = TrackIdentity(track: track)

        controller.begin(track: track, identity: identity)
        for _ in 0..<100 {
            if !controller.isSearchInProgress { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "one finished search must append exactly one line")
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["outcome"] as? String, "none")
        XCTAssertEqual(object?["retry"] as? Bool, false)
        XCTAssertNotNil(object?["sources"] as? [[String: Any]])
    }

    func testAWaitingTimedVersionBeatsPlainTextInTheSameRound() async throws {
        // Real data: the second play reports 228.5 s. LRCLIB answered first
        // with plain text while NetEase and KuGou offered the same recording
        // with a real timeline moments later.
        let track = Track(id: "spotify:track:4YlXzUxQGF2K8TTqaE7fuZ", title: "YOU & IDOL",
                          artist: "相対性理論", album: "TOWN AGE", duration: 228.5,
                          spotifyId: "spotify:track:4YlXzUxQGF2K8TTqaE7fuZ")
        let identity = TrackIdentity(track: track)
        let text = "君の声が聞こえる"
        let plain = LyricsCandidate(id: "lrclib", identity: identity, title: "YOU & IDOL",
            artist: "相対性理論", album: "TOWN AGE", duration: 228.5,
            lines: [LyricLine(timestamp: 0, originalText: text)], isSynchronized: false,
            source: .lrclib, confidence: 0.95, providerSourceID: "lrclib")
        let wordSpan = TimedTextSpan(id: 0, text: text, startTime: 12, endTime: 15,
            utf16Start: 0, utf16Length: text.utf16.count)
        let wordTimed = LyricsCandidate(id: "netease", identity: identity, title: "YOU & IDOL",
            artist: "相対性理論", album: "TOWN AGE", duration: 228.6,
            lines: [LyricLine(timestamp: 12, originalText: text, timedSpans: [wordSpan])],
            isSynchronized: true, source: .neteaseExperimental, confidence: 0.9, providerSourceID: "netease")
        let lineTimed = LyricsCandidate(id: "kuwo", identity: identity, title: "YOU & IDOL",
            artist: "相対性理論", album: "TOWN AGE", duration: 229,
            lines: [LyricLine(timestamp: 12, originalText: text)], isSynchronized: true,
            source: .kuwoExperimental, confidence: 0.9, providerSourceID: "kuwo")
        let manager = LyricsSearchManager(providers: [
            ProviderFailureDelayedLyricsProvider(name: "LRCLIB", delay: 20_000_000, result: .candidates([plain])),
            ProviderFailureDelayedLyricsProvider(name: "NetEase Experimental", delay: 300_000_000, result: .candidates([wordTimed])),
            ProviderFailureDelayedLyricsProvider(name: "Kuwo Experimental", delay: 500_000_000, result: .candidates([lineTimed]))
        ])

        let outcome = await manager.search(track: track, identity: identity)

        guard case .match(let document) = outcome.result else {
            XCTFail("Expected an automatic adoption, got \(outcome.result)")
            return
        }
        XCTAssertEqual(document.source, .neteaseExperimental)
        XCTAssertTrue(document.lines.first?.hasValidTimedSpans() == true)
    }

    func testMultipleSourcesAgreeingOnOneRecordingAdoptDespiteSpotifyDurationGap() async throws {
        // Real data: Spotify lists YOU & IDOL as 3:21 (201 s) while every
        // source offers the full 3:46–3:49 master (~226–229 s).
        let track = Track(id: "spotify:track:4YlXzUxQGF2K8TTqaE7fuZ", title: "YOU & IDOL",
                          artist: "相対性理論", album: "TOWN AGE", duration: 201,
                          spotifyId: "spotify:track:4YlXzUxQGF2K8TTqaE7fuZ")
        let identity = TrackIdentity(track: track)
        func candidate(_ id: String, duration: TimeInterval, source: LyricsSource) -> LyricsCandidate {
            LyricsCandidate(
                id: id, identity: identity, title: "YOU & IDOL", artist: "相対性理論",
                album: "TOWN AGE", duration: duration,
                lines: [LyricLine(timestamp: 12, originalText: "君の声が聞こえる")],
                isSynchronized: true, source: source, confidence: 0.9, providerSourceID: id
            )
        }
        let manager = LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "NetEase Experimental",
                result: .candidates([candidate("ne", duration: 226.0, source: .neteaseExperimental)])),
            ProviderFailureFixedLyricsProvider(name: "QQ Music Experimental",
                result: .candidates([candidate("qq", duration: 227.6, source: .qqExperimental)])),
            ProviderFailureFixedLyricsProvider(name: "Kuwo Experimental",
                result: .candidates([candidate("kuwo", duration: 228.9, source: .kuwoExperimental)]))
        ])

        let outcome = await manager.search(track: track, identity: identity)

        guard case .match(let document) = outcome.result else {
            XCTFail("Expected the agreeing sources to be adopted, got \(outcome.result)")
            return
        }
        XCTAssertFalse(document.lines.isEmpty)
        XCTAssertEqual(outcome.automaticDecision?.tier, .autoMedium)
        XCTAssertEqual(outcome.automaticSelection?.sourceCount, 3)
        XCTAssertEqual(outcome.automaticSelection?.durationDelta ?? 0, 25, accuracy: 0.1)
    }

    func testSourceStatsKeepTestSearchesOutOfTheRealLog() {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SpotifyLyrics/source-stats.jsonl")
        XCTAssertNotEqual(LyricsSourceStats.shared.fileURL, real)
        XCTAssertTrue(LyricsSourceStats.shared.fileURL.path.hasPrefix(NativeTestRuntime.root.path + "/"))
    }

    func testRetriedFailedSourceIsAdoptedOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stats = LyricsSourceStats(fileURL: root.appendingPathComponent("source-stats.jsonl"))
        let track = Track(title: "Retry Song", artist: "Retry Artist", album: "Retry Album", duration: 200)
        let identity = TrackIdentity(track: track)
        let qqToggle = ProviderFailureToggle()
        let reviewCandidate = LyricsCandidate(
            id: "review-candidate", identity: identity, title: "Retry Song", artist: track.artist,
            album: track.album, duration: 260, lines: [LyricLine(timestamp: 0, originalText: "review")],
            source: .local, confidence: 0.7
        )
        let retriedDocument = LyricsDocument(
            identity: identity, title: track.title, artist: track.artist, album: track.album,
            duration: track.duration, lines: [LyricLine(timestamp: 1, originalText: "retried")],
            isSynchronized: true, source: .qqExperimental, confidence: 0.95
        )
        let controller = LyricsSessionController(
            providers: [
                ProviderFailureFixedLyricsProvider(name: "local-review", result: .candidates([reviewCandidate])),
                ProviderFailureScriptedLyricsProvider(name: "QQ Music Experimental", toggle: qqToggle, result: .match(retriedDocument))
            ],
            sourceStats: stats,
            sourceRetryDelay: 0.15
        )

        controller.begin(track: track, identity: identity)
        for _ in 0..<100 {
            if case .candidates = controller.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .candidates = controller.state else {
            XCTFail("Expected a review result before the retry, got \(controller.state)")
            return
        }

        qqToggle.isFailing = false
        for _ in 0..<150 {
            if controller.activeDocument != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(controller.activeDocument?.source, .qqExperimental)
        XCTAssertEqual(controller.activeDocument?.lines.first?.originalText, "retried")
        try await Task.sleep(nanoseconds: 100_000_000)

        let contents = try String(contentsOf: stats.fileURL, encoding: .utf8)
        let retryLines = contents.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["retry"] as? Bool == true else { return nil }
            return object
        }
        XCTAssertEqual(retryLines.count, 1)
        XCTAssertEqual(retryLines.first?["outcome"] as? String, "adopted")
    }
}
