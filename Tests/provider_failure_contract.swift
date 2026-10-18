import Foundation

private final class StubLRCLIBSession: LRCLIBSession, @unchecked Sendable {
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

    init(responses: [Response]) {
        self.responses = responses
    }

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
        } else {
            response = responses.last!
        }
        if response.delay > 0 {
            try await Task.sleep(nanoseconds: response.delay)
        }
        try Task.checkCancellation()
        if let error = response.error {
            throw error
        }
        let url = request.url ?? URL(string: "https://lrclib.net/api/get")!
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (response.data, http)
    }
}

private struct FixedLyricsProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { result }
}

private struct DelayedLyricsProvider: LyricsProvider {
    let name: String
    let delay: UInt64
    let result: LyricsLookupResult
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        try? await Task.sleep(nanoseconds: delay)
        if Task.isCancelled { return .failed(.cancelled) }
        return result
    }
}

private struct CountingLyricsProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    let counter: Counter
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        counter.value += 1
        return result
    }
}

private final class Counter: @unchecked Sendable {
    var value = 0
}

private final class NetEaseFixtureStore: @unchecked Sendable {
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

private final class NetEaseFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = NetEaseFixtureStore()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "music.163.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.store.body(for: request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct ProviderFailureContract {
    static func main() async {
        let track = Track(
            title: "LRCLIB Song",
            artist: "LRCLIB Artist",
            album: "LRCLIB Album",
            duration: 210
        )
        let identity = TrackIdentity(track: track)

        // NetEase catalog title aliases are independent metadata, not query echoes.
        let neteaseConfig = URLSessionConfiguration.ephemeral
        neteaseConfig.protocolClasses = [NetEaseFixtureURLProtocol.self]
        let neteaseSession = URLSession(configuration: neteaseConfig)
        let fireworkTrack = Track(title: "Fireworks", artist: "Fixture Artist", album: "Fixture Album", duration: 120)
        let fireworkIdentity = TrackIdentity(track: fireworkTrack)
        let fireworkSearch = try! JSONSerialization.data(withJSONObject: ["result": ["songs": [[
            "id": 9001, "name": "花火", "alias": [], "transNames": ["Fireworks"],
            "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture Album"], "duration": 120_000
        ]]]])
        let lyricBody = try! JSONSerialization.data(withJSONObject: ["lrc": ["lyric": "[00:01.00]fixture line"],
            "tlyric": ["lyric": ""], "yrc": ["lyric": ""]])
        NetEaseFixtureURLProtocol.store.reset(searchBody: fireworkSearch, lyricBodies: ["9001": lyricBody])
        let fireworkResult = await NetEaseExperimentalLyricsProvider(session: neteaseSession)
            .lookup(track: fireworkTrack, identity: fireworkIdentity)
        guard case .candidates(let fireworkCandidates) = fireworkResult,
              let fireworkCandidate = fireworkCandidates.first else {
            fatalError("NetEase provider should return a translated-title candidate, got \(fireworkResult)")
        }
        precondition(fireworkCandidate.declaredTitleAliases == ["Fireworks"],
            "NetEase transNames should be retained as independent title metadata")
        let fireworkDecision = LyricsSafeMatcher.decide(
            candidate: fireworkCandidate,
            metadata: TrackMetadata.bootstrap(from: fireworkTrack)
        )
        precondition(fireworkDecision.tier == .autoMedium
            && fireworkDecision.reasons.contains("titleProviderAliasConfirmed"),
            "a provider-declared English title with matching artist and duration should auto-match")

        let echoSearch = try! JSONSerialization.data(withJSONObject: ["result": ["songs": [[
            "id": 9002, "name": "花火", "alias": [], "transNames": [],
            "artists": [["name": "Fixture Artist"]], "album": ["name": "Fixture Album"], "duration": 120_000
        ]]]])
        NetEaseFixtureURLProtocol.store.reset(searchBody: echoSearch, lyricBodies: ["9002": lyricBody])
        let echoResult = await NetEaseExperimentalLyricsProvider(session: neteaseSession)
            .lookup(track: fireworkTrack, identity: fireworkIdentity)
        guard case .candidates(let echoCandidates) = echoResult, let echoCandidate = echoCandidates.first else {
            fatalError("unaliased NetEase title should remain a candidate for matcher rejection, got \(echoResult)")
        }
        precondition(echoCandidate.declaredTitleAliases.isEmpty,
            "the query title must not be copied into provider-declared aliases")
        let echoDecision = LyricsSafeMatcher.decide(candidate: echoCandidate, metadata: TrackMetadata.bootstrap(from: fireworkTrack))
        precondition(echoDecision.tier == .reject && echoDecision.reasons.contains("titleMismatch"),
            "an absent provider alias must not turn a translated-title guess into a match")

        let hanabiTrack = Track(title: "HANABI", artist: "SACBEN", album: "はなび", duration: 120.086)
        let hanabiIdentity = TrackIdentity(track: hanabiTrack)
        let exactHanabiSearch = try! JSONSerialization.data(withJSONObject: ["result": ["songs": [[
            "id": 2086887456, "name": "はなび", "alias": [], "transNames": ["花火"],
            "artists": [["name": "SACBEN"]], "album": ["name": "はなび"], "duration": 120_085
        ]]]])
        let noLyricsBody = try! JSONSerialization.data(withJSONObject: ["lrc": ["lyric": ""],
            "tlyric": ["lyric": ""], "yrc": ["lyric": ""]])
        NetEaseFixtureURLProtocol.store.reset(searchBody: exactHanabiSearch, lyricBodies: ["2086887456": noLyricsBody])
        let metadataOnlyResult = await NetEaseExperimentalLyricsProvider(session: neteaseSession)
            .lookup(track: hanabiTrack, identity: hanabiIdentity)
        guard case .failed(.lyricsBodyUnavailable(let metadataOnlyMessage)) = metadataOnlyResult else {
            fatalError("exact NetEase metadata without a lyric body must be reported distinctly, got \(metadataOnlyResult)")
        }
        precondition(metadataOnlyMessage.contains("目录命中") && metadataOnlyMessage.contains("没有歌词正文"),
            "metadata-only result must not be presented as instrumental")

        let wrongHanabi = LyricsCandidate(id: "wrong-hanabi", identity: hanabiIdentity,
            title: "Hanabi", artist: "黒川沙良", album: "Other Album", duration: 321.506,
            lines: [LyricLine(timestamp: 0, originalText: "fixture")], source: .neteaseExperimental, confidence: 1)
        let splitDiagnosis = await LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "wrong same-title source", result: .candidates([wrongHanabi])),
            FixedLyricsProvider(name: "NetEase Experimental", result: metadataOnlyResult)
        ]).search(track: hanabiTrack, identity: hanabiIdentity)
        guard case .failed(let splitFailure) = splitDiagnosis.result,
              case .lyricsBodyUnavailable = splitFailure else {
            fatalError("exact catalog without text must remain distinct from unrelated same-title candidates")
        }
        precondition(splitFailure.recoveryMessage.contains("目录命中")
            && splitFailure.recoveryMessage.contains("没有歌词正文")
            && splitFailure.userFacingTitle == "已找到歌曲，暂无歌词正文",
            "diagnostics should distinguish exact metadata-only source from wrong same-title results")
        precondition(!splitFailure.recoveryMessage.contains("黒川沙良")
            && !splitFailure.recoveryMessage.contains("322 秒"),
            "a candidate wrong on both artist and duration must not dominate the identity warning")

        // 200 success with synced lyrics
        let okPayload = """
        {
          "id": 1,
          "trackName": "LRCLIB Song",
          "artistName": "LRCLIB Artist",
          "albumName": "LRCLIB Album",
          "duration": 210,
          "syncedLyrics": "[00:01.00]hello\\n[00:02.00]world"
        }
        """.data(using: .utf8)!
        let okSession = StubLRCLIBSession(data: okPayload, statusCode: 200)
        let okResult = await LRCLIBLyricsProvider(session: okSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .match(let document) = okResult else {
            fatalError("expected 200 match, got \(okResult)")
        }
        precondition(document.identity == identity)
        precondition(document.isSynchronized)
        precondition(document.source == .lrclib)
        precondition(okSession.requests.first?.url?.absoluteString.contains("track_name=LRCLIB%20Song") == true)

        // Empty search records are not proof that the requested song has no vocals.
        for (label, title, artist, duration, instrumental) in [
            ("unrelated instrumental", "Other Song", "Other Artist", 210.0, true),
            ("different version", "LRCLIB Song (Instrumental)", "LRCLIB Artist", 210.0, true),
            ("different duration", "LRCLIB Song", "LRCLIB Artist", 300.0, true),
            ("empty vocal record", "LRCLIB Song", "LRCLIB Artist", 210.0, false)
        ] {
            let body = try! JSONSerialization.data(withJSONObject: ["id": 8, "trackName": title,
                "artistName": artist, "duration": duration, "instrumental": instrumental])
            let outcome = await LRCLIBLyricsProvider(session: StubLRCLIBSession(data: body), maxAutomaticRetries: 0)
                .lookup(track: track, identity: identity)
            guard case .noMatch = outcome else { fatalError("\(label) must not declare requested song lyric-free: \(outcome)") }
        }
        let instrumentalBody = try! JSONSerialization.data(withJSONObject: ["id": 9, "trackName": track.title,
            "artistName": track.artist, "duration": track.duration, "instrumental": true])
        let explicitNoLyrics = await LRCLIBLyricsProvider(session: StubLRCLIBSession(data: instrumentalBody), maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .noLyrics = explicitNoLyrics else { fatalError("exact instrumental metadata should retain noLyrics result") }
        print("PASS unrelated/empty instrumental records do not classify the requested recording")

        // 404 -> noMatch (via search empty)
        let notFoundSession = StubLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 404, headers: [:], error: nil, delay: 0),
            .init(data: Data("[]".utf8), statusCode: 200, headers: [:], error: nil, delay: 0)
        ])
        let notFound = await LRCLIBLyricsProvider(session: notFoundSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        guard case .noMatch = notFound else {
            fatalError("expected 404/noMatch, got \(notFound)")
        }

        // 400 bad request
        let badRequest = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(data: Data(), statusCode: 400),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.serverError(400)) = badRequest else {
            fatalError("expected 400 failure, got \(badRequest)")
        }

        // timeout
        let timeout = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(error: URLError(.timedOut)),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.timedOut) = timeout else {
            fatalError("expected timeout, got \(timeout)")
        }

        // network unavailable
        let network = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(error: URLError(.notConnectedToInternet)),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.networkUnavailable) = network else {
            fatalError("expected network failure, got \(network)")
        }

        // 429 rate limited with limited automatic retry then failure
        let rateSession = StubLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 429, headers: ["Retry-After": "0"], error: nil, delay: 0),
            .init(data: Data(), statusCode: 429, headers: ["Retry-After": "0"], error: nil, delay: 0)
        ])
        let rateLimited = await LRCLIBLyricsProvider(session: rateSession, maxAutomaticRetries: 1)
            .lookup(track: track, identity: identity)
        guard case .failed(.rateLimited) = rateLimited else {
            fatalError("expected rateLimited, got \(rateLimited)")
        }
        precondition(rateSession.requests.count == 2)

        // parse failure
        let parse = await LRCLIBLyricsProvider(
            session: StubLRCLIBSession(data: Data("not-json".utf8), statusCode: 200),
            maxAutomaticRetries: 0
        ).lookup(track: track, identity: identity)
        guard case .failed(.parseFailure) = parse else {
            fatalError("expected parse failure, got \(parse)")
        }

        // Automatic retry recovers once.
        let recoverSession = StubLRCLIBSession(responses: [
            .init(data: Data(), statusCode: 0, headers: [:], error: URLError(.timedOut), delay: 0),
            .init(data: okPayload, statusCode: 200, headers: [:], error: nil, delay: 0)
        ])
        let recovered = await LRCLIBLyricsProvider(session: recoverSession, maxAutomaticRetries: 1)
            .lookup(track: track, identity: identity)
        guard case .match = recovered else {
            fatalError("expected retry recovery, got \(recovered)")
        }
        precondition(recoverSession.requests.count == 2)

        // Fast identity switch cancels/suppresses stale lyrics.
        let slowDoc = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [LyricLine(timestamp: 1, originalText: "stale")],
            source: .lrclib
        )
        let trackB = Track(title: "Track B", artist: "Artist B", album: "Album", duration: 180)
        let identityB = TrackIdentity(track: trackB)
        let freshDoc = LyricsDocument(
            identity: identityB,
            title: trackB.title,
            artist: trackB.artist,
            album: trackB.album,
            duration: trackB.duration,
            lines: [LyricLine(timestamp: 1, originalText: "fresh")],
            source: .local
        )
        let controller = LyricsSessionController(
            provider: DelayedLyricsProvider(name: "slow", delay: 120_000_000, result: .match(slowDoc))
        )
        controller.begin(track: track, identity: identity)
        // Replace provider path by beginning a new identity quickly with a local match provider.
        let fastController = LyricsSessionController(
            provider: FixedLyricsProvider(name: "fast", result: .match(freshDoc))
        )
        fastController.begin(track: track, identity: identity)
        fastController.begin(track: trackB, identity: identityB)
        try? await Task.sleep(nanoseconds: 20_000_000)
        guard let loaded = fastController.state.document else {
            fatalError("expected fresh loaded state")
        }
        precondition(loaded.identity == identityB)
        precondition(loaded.lines.first?.originalText == "fresh")
        precondition(fastController.lyrics.first?.originalText == "fresh")

        // Partial provider failure must not hide a healthy local match.
        let localMatch = LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "local")],
            source: .local,
            confidence: 0.95
        )
        let localCounter = Counter()
        let remoteCounter = Counter()
        let manager = LyricsSearchManager(providers: [
            CountingLyricsProvider(name: "local", result: .match(localMatch), counter: localCounter),
            CountingLyricsProvider(name: "lrclib-fail", result: .failed(.networkUnavailable), counter: remoteCounter)
        ])
        let outcome = await manager.search(track: track, identity: identity)
        guard case .match(let matched) = outcome.result else {
            fatalError("local success must win despite remote failure")
        }
        precondition(matched.source == .local)
        precondition(localCounter.value == 1)
        // Local match short-circuits before remote; remote failure isolation still holds when local misses.
        let remoteOnly = LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "local-miss", result: .noMatch),
            FixedLyricsProvider(name: "lrclib-fail", result: .failed(.timedOut)),
            FixedLyricsProvider(
                name: "local-second",
                result: .match(localMatch)
            )
        ])
        let isolated = await remoteOnly.search(track: track, identity: identity)
        guard case .match(let isolatedMatch) = isolated.result else {
            fatalError("later provider success must survive earlier failure, got \(isolated.result)")
        }
        precondition(isolatedMatch.source == .local)
        precondition(isolated.diagnostics.contains { diagnostic in
            if case .failed(.timedOut) = diagnostic.outcome { return true }
            return false
        })

        let conflicting = LyricsCandidate(id: "wrong-artist", identity: identity, title: track.title,
            artist: "Unrelated Singer", album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored wrong-artist fixture")],
            source: .lrclib, confidence: 1)
        let unconfirmed = await LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "wrong-artist", result: .candidates([conflicting])),
            FixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let identityFailure) = unconfirmed.result,
              case .identityUnconfirmed(let rejectedCount, let sourceError) = identityFailure else {
            fatalError("rejected identity must stay distinct from unavailable service")
        }
        precondition(rejectedCount > 0 && sourceError.contains("限流"))
        precondition(identityFailure.userFacingTitle == "歌词身份待确认")
        precondition(identityFailure.recoveryMessage.contains("未能确认") && identityFailure.recoveryMessage.contains("限流"))
        precondition(unconfirmed.alternatives.isEmpty && unconfirmed.automaticDecision == nil,
            "presentation repair must not expose or auto-adopt a hard-rejected wrong artist")
        let nearbyTitle = LyricsCandidate(id: "nearby-title", identity: identity, title: "Different Title",
            artist: track.artist, album: track.album, duration: track.duration + 0.1,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored title mismatch fixture")],
            source: .neteaseExperimental, confidence: 1)
        let unrelatedTitle = LyricsCandidate(id: "unrelated-title", identity: identity, title: "无关长歌",
            artist: track.artist, album: "Other Album", duration: track.duration + 90,
            lines: nearbyTitle.lines, source: .neteaseExperimental, confidence: 1)
        let titleMismatch = await LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "nearby-source", result: .candidates([unrelatedTitle, nearbyTitle])),
            FixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let titleFailure) = titleMismatch.result else {
            fatalError("title mismatch must remain a failed identity check")
        }
        precondition(titleFailure.recoveryMessage.contains("Different Title")
            && titleFailure.recoveryMessage.contains(track.title)
            && titleFailure.recoveryMessage.contains("标题"),
            "identity refusal must explain the nearest result's title mismatch")
        precondition(!titleFailure.recoveryMessage.contains("无关长歌"), "explanation must exclude unrelated result noise")
        precondition(titleFailure.recoveryMessage.contains("限流"), "identity detail must retain source failures")
        precondition(titleMismatch.alternatives.isEmpty && titleMismatch.automaticDecision == nil,
            "explanations must not loosen candidate or automatic adoption eligibility")
        let translatedTitleTrack = Track(title: "meaning of tears", artist: "tear", album: "meaning of tears", duration: 234.66)
        let translatedTitleIdentity = TrackIdentity(track: translatedTitleTrack)
        func translatedTitle(_ title: String, duration: Double = 234.659) -> LyricsCandidate {
            LyricsCandidate(id: title, identity: translatedTitleIdentity, title: title, artist: "TEAR", album: title,
                duration: duration, lines: [LyricLine(timestamp: 1, originalText: "Self-authored fixture")],
                isSynchronized: true, source: .neteaseExperimental, confidence: 0.5)
        }
        let inferred = await LyricsSearchManager(providers: [FixedLyricsProvider(name: "localized-source",
            result: .candidates([translatedTitle("涙の意味")]))]).search(track: translatedTitleTrack, identity: translatedTitleIdentity)
        guard case .match = inferred.result else { fatalError("unique cross-script title with same artist and recording duration must auto-select") }
        precondition(inferred.automaticDecision?.reasons.contains("localizedTitleArtistDuration") == true)
        for list in [[translatedTitle("涙の意味"), translatedTitle("別の曲")], [translatedTitle("涙の意味", duration: 239)], [translatedTitle("Unrelated Song")], [translatedTitle("2024")], [translatedTitle("☆")]] {
            let result = await LyricsSearchManager(providers: [FixedLyricsProvider(name: "source", result: .candidates(list))])
                .search(track: translatedTitleTrack, identity: translatedTitleIdentity)
            precondition(result.automaticDecision == nil, "ambiguous, distant, same-script or non-letter titles must not use localization inference")
        }
        let localizedTrack = Track(title: "ai", artist: "LOVELY BOMB", album: "ai", duration: 168.58)
        let localizedIdentity = TrackIdentity(track: localizedTrack)
        let localizedCandidate = LyricsCandidate(id: "localized-title", identity: localizedIdentity, title: "愛",
            artist: "LOVELY BOMB", album: "愛", duration: 168.646,
            lines: [LyricLine(timestamp: 1, originalText: "Self-authored localization fixture")],
            isSynchronized: true, source: .neteaseExperimental, confidence: 1)
        let localizedResult = await LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "localized-source", result: .candidates([localizedCandidate]))
        ]).search(track: localizedTrack, identity: localizedIdentity)
        guard case .match(let localizedDocument) = localizedResult.result else {
            fatalError("full manager must automatically select 愛 for ai with matching artist and duration")
        }
        precondition(localizedDocument.title == "愛" && localizedResult.automaticDecision != nil)
        let onlyLimited = await LyricsSearchManager(providers: [
            FixedLyricsProvider(name: "limited-source", result: .failed(.rateLimited(1)))
        ]).search(track: track, identity: identity)
        guard case .failed(let networkFailure) = onlyLimited.result, case .rateLimited = networkFailure else {
            fatalError("HTTP 429 must remain a real provider failure")
        }
        precondition(networkFailure.userFacingTitle == "歌词暂不可用" && networkFailure.recoveryMessage.contains("限流"))
        print("PASS identity confirmation has its own presentation; hard rejection and HTTP 429 remain unchanged")

        // Lyrics search requires confirmed identity and never writes files.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-failure-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("marker.txt")
        try! "keep".write(to: marker, atomically: true, encoding: .utf8)
        let before = try! Data(contentsOf: marker)
        _ = await LRCLIBLyricsProvider(session: okSession, maxAutomaticRetries: 0)
            .lookup(track: track, identity: identity)
        let after = try! Data(contentsOf: marker)
        precondition(before == after, "LRCLIB must not persist or mutate local files")

        print("provider failure contract passed")
    }
}
