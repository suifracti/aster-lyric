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

private final class CatalogDurationFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = "0t5DDnfp0dkgeSnokvbIQY"
        let entity: [String: Any] = ["type": "track", "id": id, "uri": "spotify:track:\(id)",
            "title": "shion", "duration": 168000,
            "artists": [["name": "angelize", "uri": "spotify:artist:AAAAAAAAAAAAAAAAAAAAAA"]]]
        let json = try! JSONSerialization.data(withJSONObject: ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]])
        let body = Data(("<script id=\"__NEXT_DATA__\">" + String(decoding: json, as: UTF8.self) + "</script>").utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class QueuePreloadFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let queue = ["AAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC"].map { id in
            ["type": "track", "id": id, "uri": "spotify:track:\(id)", "name": id,
             "artists": [["name": "angelize"]], "album": ["name": "shion", "images": []],
             "duration_ms": 168000, "explicit": false] as [String: Any]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["queue": queue])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct PreloadCountingProvider: LyricsProvider {
    let name = "preload-fixture"
    let counter: ProviderFailureCounter
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        counter.increment()
        return .match(LyricsDocument(identity: identity, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 1, originalText: "電波を超え届く君のもとへ")],
            isSynchronized: track.spotifyId?.hasPrefix("A") == true, source: .qqExperimental, confidence: 0.95))
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

/// Stands in for petitlyrics.com. Records every request so the test can
/// check the order and the headers the lyric request needs.
private final class PetitLyricsFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(_ responses: [String: (Int, Data)]) {
        lock.lock(); defer { lock.unlock() }
        self.responses = responses
        requests = []
    }

    static func recorded() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "petitlyrics.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        var key = request.url?.path ?? ""
        if key == "/search_lyrics", request.url?.query?.contains("artist=") != true { key += "#title-only" }
        let (status, body) = Self.responses[key] ?? (404, Data())
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ProviderFailureContractTests: XCTestCase {
    /// Real cases, 2026-11: lyrics existed but the artist was written differently.
    func testArtistWrittenDifferentlyIsRecognisedOrLeftForReview() {
        func candidate(_ artist: String, title: String = "Phone Number", duration: Double = 169, for track: Track) -> LyricsCandidate {
            LyricsCandidate(id: "fixture-\(artist)", identity: TrackIdentity(track: track), title: title, artist: artist,
                album: track.album, duration: duration, lines: [LyricLine(timestamp: 0, originalText: "Generated test line")],
                source: .lrclib, confidence: 0.9)
        }
        func isAutomatic(_ decision: LyricsMatchDecision) -> Bool { decision.tier == .autoHigh || decision.tier == .autoMedium }

        // Spotify shows a stage name with the artist's other name in brackets.
        let bracketed = Track(title: "Phone Number", artist: "GAN (岩田剛典)", album: "Phone Number", duration: 169.11)
        let bracketedMetadata = TrackMetadata.bootstrap(from: bracketed)
        for name in ["岩田剛典", "GAN", "GAN (岩田剛典)", "GAN（岩田剛典）"] {
            let decision = LyricsSafeMatcher.decide(candidate: candidate(name, for: bracketed), metadata: bracketedMetadata)
            XCTAssertTrue(isAutomatic(decision), "\(name): \(decision.tier) \(decision.reasons)")
            XCTAssertTrue(decision.reasons.contains("primaryArtistExact"), "\(name): \(decision.reasons)")
        }
        XCTAssertEqual(LyricsSafeMatcher.decide(candidate: candidate("山田太郎", for: bracketed), metadata: bracketedMetadata).tier, .reject)
        XCTAssertEqual(LyricsSafeMatcher.decide(candidate: candidate("岩田", for: bracketed), metadata: bracketedMetadata).tier, .reject,
            "half of a bracketed name is not that name")

        // Only part of the name agrees: worth showing, never adopted unattended.
        let partial = Track(title: "KILL MY LOVE", artist: "加藤MILIYAH", album: "KILL MY LOVE", duration: 198.028)
        let partialMetadata = TrackMetadata.bootstrap(from: partial)
        for (name, duration) in [("Miliyah", 204.0), ("加藤 ミリヤ", 0.0)] {
            let decision = LyricsSafeMatcher.decide(candidate: candidate(name, title: "KILL MY LOVE", duration: duration, for: partial),
                                                    metadata: partialMetadata)
            XCTAssertEqual(decision.tier, .candidates, "\(name) \(duration): \(decision.reasons)")
            XCTAssertTrue(decision.reasons.contains("primaryArtistPartialName"), "\(decision.reasons)")
            XCTAssertFalse(decision.hardReject)
        }
        // The same length as well as the same title: adopted, at the lower automatic tier.
        let sameLength = LyricsSafeMatcher.decide(candidate: candidate("加藤 ミリヤ", title: "KILL MY LOVE", duration: 198, for: partial),
                                                  metadata: partialMetadata)
        XCTAssertEqual(sameLength.tier, .autoMedium, "\(sameLength.reasons)")
        for (name, title) in [("佐藤 ミリヤ", "KILL MY LOVE"), ("Mili", "KILL MY LOVE"), ("加藤 ミリヤ", "KILL MY LOVE (Live)"),
                              ("加藤 ミリヤ", "Another Song")] {
            let decision = LyricsSafeMatcher.decide(candidate: candidate(name, title: title, duration: 198, for: partial), metadata: partialMetadata)
            XCTAssertFalse(isAutomatic(decision), "\(name) / \(title): \(decision.reasons)")
            if title != "KILL MY LOVE (Live)" { XCTAssertEqual(decision.tier, .reject, "\(name) / \(title): \(decision.reasons)") }
        }
        // A shared generic word or a short fragment is not a shared name.
        let band = Track(title: "Night Drive", artist: "Blue Harbor Band", album: "Night Drive", duration: 200)
        for name in ["Red River Band", "The Blue", "Harb"] {
            let decision = LyricsSafeMatcher.decide(candidate: candidate(name, title: "Night Drive", duration: 200, for: band),
                                                    metadata: TrackMetadata.bootstrap(from: band))
            XCTAssertEqual(decision.tier, .reject, "\(name): \(decision.reasons)")
        }
        // Two sources that only partly agree on the artist never adopt each other.
        XCTAssertFalse(LyricsSafeMatcher.decide(candidate: candidate("Miliyah", title: "KILL MY LOVE", duration: 198, for: partial),
            metadata: partialMetadata).reasons.contains("primaryArtistExact"))
    }

    /// The user must not have to choose while listening: two sources that give
    /// the same words under partly matching names settle it between them.
    func testPartlyMatchingArtistIsAdoptedWhenTwoSourcesGiveTheSameWords() async {
        let track = Track(title: "KILL MY LOVE", artist: "加藤MILIYAH", album: "KILL MY LOVE", duration: 198.028)
        let identity = TrackIdentity(track: track)
        let words = (1...12).map { "generated fixture sentence number \($0) for the agreement check" }
        func candidate(_ id: String, _ artist: String, _ lines: [LyricLine], duration: Double, timed: Bool, source: LyricsSource) -> LyricsCandidate {
            LyricsCandidate(id: id, identity: identity, title: "KILL MY LOVE", artist: artist, album: "", duration: duration,
                lines: lines, isSynchronized: timed, source: source, confidence: 0.9, providerSourceID: id)
        }
        let timed = candidate("timed", "Miliyah", words.enumerated().map { LyricLine(timestamp: Double($0.offset * 10 + 5), originalText: $0.element) },
            duration: 204, timed: true, source: .lrclib)
        // Same words, broken into different lines, as the plain-text site does.
        let plainLines = words.flatMap { line -> [String] in
            let parts = line.split(separator: " ")
            return [parts.prefix(3).joined(separator: " "), parts.dropFirst(3).joined(separator: " ")]
        }
        let plain = candidate("plain", "加藤 ミリヤ", plainLines.map { LyricLine(timestamp: 0, originalText: $0) },
            duration: 0, timed: false, source: .petitLyrics)
        let otherSong = candidate("other", "加藤 ミリヤ", (1...12).map { LyricLine(timestamp: 0, originalText: "an unrelated text line \($0) about something else") },
            duration: 0, timed: false, source: .petitLyrics)

        func search(_ first: LyricsCandidate, _ second: LyricsCandidate?) async -> SearchOutcome {
            var providers: [any LyricsProvider] = [ProviderFailureCountingLyricsProvider(name: "LRCLIB", result: .candidates([first]), counter: ProviderFailureCounter())]
            if let second {
                providers.append(ProviderFailureCountingLyricsProvider(name: "プチリリ", result: .candidates([second]), counter: ProviderFailureCounter()))
            }
            return await LyricsSearchManager(providers: providers).search(track: track, identity: identity)
        }

        let agreed = await search(timed, plain)
        guard case .match(let document) = agreed.result else { return XCTFail("the same words from two sources must be adopted: \(agreed.result)") }
        XCTAssertTrue(document.isSynchronized, "the timed version is preferred")
        XCTAssertEqual(document.source, .lrclib)
        XCTAssertEqual(agreed.automaticDecision?.tier, .autoMedium)
        XCTAssertTrue(agreed.automaticDecision?.reasons.contains("partialArtistLyricsAgreement") == true)

        let different = await search(timed, otherSong)
        guard case .candidates(let shown) = different.result else { return XCTFail("different words stay a choice: \(different.result)") }
        XCTAssertEqual(shown.count, 2)
        let alone = await search(timed, nil)
        guard case .candidates = alone.result else { return XCTFail("one source alone stays a choice: \(alone.result)") }
    }

    func testPetitLyricsSearchesByTitleWhenTheArtistSpellingFindsNothing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PetitLyricsFixtureURLProtocol.self]
        let provider = PetitLyricsProvider(session: URLSession(configuration: configuration))
        let track = Track(title: "KILL MY LOVE", artist: "加藤MILIYAH", album: "KILL MY LOVE", duration: 198)
        func row(_ id: Int, _ artist: String) -> String {
            "<tr><td><a href=\"/lyrics/\(id)\"><span class=\"lyrics-list-title\">KILL MY LOVE</span></a>"
                + "<span class=\"lyrics-list-artist\">\(artist)</span></td></tr>"
        }
        let line = try JSONSerialization.data(withJSONObject: [["lyrics": Data("fixture line".utf8).base64EncodedString()]])
        PetitLyricsFixtureURLProtocol.reset([
            "/search_lyrics": (200, Data("<table id=\"lyrics_list\"></table>".utf8)),
            "/search_lyrics#title-only": (200, Data((row(201, "Someone Else") + row(202, "加藤 ミリヤ") + row(203, "Other Band")).utf8)),
            "/lyrics/202": (200, Data()),
            "/lib/pl-lib.js": (200, Data("setRequestHeader('X-CSRF-Token', '0123456789abcdef0123456789abcdef');".utf8)),
            "/com/get_lyrics.ajax": (200, line)
        ])
        guard case .candidates(let candidates) = await provider.lookup(track: track, identity: TrackIdentity(track: track)) else {
            return XCTFail("the record under another spelling must be offered")
        }
        XCTAssertEqual(candidates.map(\.providerSourceID), ["petitlyrics:202"], "only the record sharing part of the name is opened")
        XCTAssertEqual(PetitLyricsFixtureURLProtocol.recorded().compactMap { $0.url?.path },
            ["/search_lyrics", "/search_lyrics", "/lyrics/202", "/lib/pl-lib.js", "/com/get_lyrics.ajax"])
        let decision = LyricsSafeMatcher.decide(candidate: candidates[0], metadata: TrackMetadata.bootstrap(from: track))
        XCTAssertEqual(decision.tier, .candidates, "\(decision.reasons)")

        PetitLyricsFixtureURLProtocol.reset([
            "/search_lyrics": (200, Data("<table id=\"lyrics_list\"></table>".utf8)),
            "/search_lyrics#title-only": (200, Data((row(201, "Someone Else") + row(203, "Other Band")).utf8))
        ])
        guard case .noMatch = await provider.lookup(track: track, identity: TrackIdentity(track: track)) else {
            return XCTFail("unrelated artists under the same title are not opened")
        }
        XCTAssertEqual(PetitLyricsFixtureURLProtocol.recorded().count, 2)
    }

    func testPetitLyricsReturnsPlainTextWithTheSitesOwnTitleAndArtist() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PetitLyricsFixtureURLProtocol.self]
        let provider = PetitLyricsProvider(session: URLSession(configuration: configuration))
        let track = Track(title: "夜明けの駅", artist: "Fixture Band, Guest", album: "夜明けの駅", duration: 201)
        let identity = TrackIdentity(track: track)
        func row(_ id: Int, _ title: String) -> String {
            """
            <tr><td><a href="/lyrics/\(id)"><span class="lyrics-list-title">\(title)</span></a><br>
            <a href="/lyrics/artist/9"><span class="lyrics-list-artist">Fixture Band </span></a>
            <a href="/lyrics/album/aa"><span class="lyrics-list-album">&#22812;&#26126;&#12369;&#12398;&#39365;</span></a></td></tr>
            """
        }
        let search = "<table id=\"lyrics_list\">" + row(101, "&#22812;&#26126;&#12369;&#12398;&#39365;")
            + row(102, "夜明けの駅 (Live)") + row(103, "Third &amp; unused") + "</table>"
        func body(_ lines: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: lines.map { ["lyrics": Data($0.utf8).base64EncodedString()] })
        }
        PetitLyricsFixtureURLProtocol.reset([
            "/search_lyrics": (200, Data(search.utf8)),
            "/lyrics/101": (200, Data("<html></html>".utf8)),
            "/lyrics/102": (200, Data("<html></html>".utf8)),
            "/lib/pl-lib.js": (200, Data("jqxhr.setRequestHeader('X-CSRF-Token', '0123456789abcdef0123456789abcdef');".utf8)),
            "/com/get_lyrics.ajax": (200, try body(["始発を待つ fixture line", "", "二行目の fixture line"]))
        ])

        guard case .candidates(let candidates) = await provider.lookup(track: track, identity: identity) else {
            return XCTFail("The two listed records must come back as candidates")
        }
        XCTAssertEqual(candidates.map(\.providerSourceID), ["petitlyrics:101", "petitlyrics:102"], "two records at most")
        let first = try XCTUnwrap(candidates.first)
        XCTAssertEqual(first.title, "夜明けの駅")
        XCTAssertEqual(first.artist, "Fixture Band")
        XCTAssertEqual(first.album, "夜明けの駅")
        XCTAssertEqual(first.source, .petitLyrics)
        XCTAssertFalse(first.isSynchronized, "the public page has no timeline")
        XCTAssertEqual(first.lines.map(\.originalText), ["始発を待つ fixture line", "", "二行目の fixture line"])
        XCTAssertTrue(first.lines.allSatisfy { $0.timestamp == 0 })

        let requests = PetitLyricsFixtureURLProtocol.recorded()
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/search_lyrics", "/lyrics/101", "/lib/pl-lib.js",
            "/com/get_lyrics.ajax", "/lyrics/102", "/com/get_lyrics.ajax"], "the lyric page is opened before its text is requested")
        let searchItems = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(searchItems?.first { $0.name == "artist" }?.value, "Fixture Band", "search by the primary artist only")
        let lyricRequest = try XCTUnwrap(requests.first { $0.url?.path == "/com/get_lyrics.ajax" })
        XCTAssertEqual(lyricRequest.httpMethod, "POST")
        XCTAssertEqual(lyricRequest.value(forHTTPHeaderField: "X-CSRF-Token"), "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(lyricRequest.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")

        // The site's own title, artist and album are identity evidence, so the
        // exact record can be adopted; the live record is a different version.
        // A song with a guest the site does not list stays a choice for review.
        let withGuest = LyricsSafeMatcher.decide(candidate: first, metadata: TrackMetadata.bootstrap(from: track))
        XCTAssertEqual(withGuest.tier, .candidates, "\(withGuest.reasons)")
        let metadata = TrackMetadata.bootstrap(from: Track(title: "夜明けの駅", artist: "Fixture Band", album: "夜明けの駅", duration: 201))
        let exact = LyricsSafeMatcher.decide(candidate: first, metadata: metadata)
        XCTAssertTrue(exact.tier == .autoHigh || exact.tier == .autoMedium, "\(exact.tier) \(exact.reasons)")
        let live = LyricsSafeMatcher.decide(candidate: candidates[1], metadata: metadata)
        XCTAssertFalse(live.tier == .autoHigh || live.tier == .autoMedium, "\(live.tier) \(live.reasons)")

        let noRows = Data("<table id=\"lyrics_list\"></table>".utf8)
        PetitLyricsFixtureURLProtocol.reset(["/search_lyrics": (200, noRows), "/search_lyrics#title-only": (200, noRows)])
        guard case .noMatch = await provider.lookup(track: track, identity: identity) else { return XCTFail("no rows is no match") }
        XCTAssertEqual(PetitLyricsFixtureURLProtocol.recorded().compactMap { $0.url?.path }, ["/search_lyrics", "/search_lyrics"],
            "without a row only the title-only search follows")

        PetitLyricsFixtureURLProtocol.reset(["/search_lyrics": (200, Data(search.utf8)),
            "/lyrics/101": (200, Data()), "/lyrics/102": (200, Data()), "/lib/pl-lib.js": (200, Data("changed".utf8))])
        guard case .failed(.parseFailure) = await provider.lookup(track: track, identity: identity) else {
            return XCTFail("a changed page must fail visibly, not return empty lyrics")
        }

        XCTAssertEqual(DatabaseSourceIdentifier.source(for: DatabaseSourceIdentifier.identifier(for: .petitLyrics)), .petitLyrics)
        let saved = LyricsProviderConfiguration(enabled: [.localFiles, .sqliteDatabase, .lrclib, .linkcore],
            order: [.localFiles, .sqliteDatabase, .amll, .lrclib, .netEaseExperimental, .qqExperimental,
                    .kuwoExperimental, .kugouExperimental, .linkcore, .lyricsOVH])
        XCTAssertTrue(saved.enabled.contains(.petitLyrics), "a setting saved before this source existed gains it")
        XCTAssertFalse(saved.enabled.contains(.qqExperimental), "an earlier explicit disable is kept")
        var disabled = saved
        disabled.enabled.remove(.petitLyrics)
        disabled.normalize()
        XCTAssertFalse(disabled.enabled.contains(.petitLyrics), "turning it off afterwards is kept")
    }
    func testPianoRecordingKeepsArrangementAndArtistIdentityRules() {
        let track = Track(title: "アーカイブ - Piano Ver.", artist: "stb", album: "アーカイブ", duration: 240, spotifyId: "5O45JO2bYhtyah2flZ9TI0")
        let identity = TrackIdentity(track: track)
        let metadata = TrackMetadata.bootstrap(from: track)
        let candidate = LyricsCandidate(id: "fixture", identity: identity, title: "アーカイブ", artist: "stb;NEA;ささ。", album: "アーカイブ", duration: 240, lines: [LyricLine(timestamp: 0, originalText: "Generated test line")], source: .qqExperimental, confidence: 0.87)
        let decision = LyricsSafeMatcher.decide(candidate: candidate, metadata: metadata)
        print("Decision", decision.tier, decision.score, decision.reasons)
        XCTAssert(decision.tier == .candidates, "Semicolon artist + arrangement title must yield selectable candidate, never automatic")
        XCTAssert(decision.versionConflict)
        XCTAssert(TrackTextNormalizer.extractVersionTags(fromTitle: "Piano Man").isEmpty)
        XCTAssert(TrackTextNormalizer.stripVersionMarkers(fromTitle: "Piano Man") == "Piano Man")
        for title in ["アーカイブ - Piano Ver.", "アーカイブ (Piano Version)", "アーカイブ（ピアノ版）"] {
            XCTAssert(TrackTextNormalizer.extractVersionTags(fromTitle: title).contains(.piano))
            XCTAssert(TrackTextNormalizer.stripVersionMarkers(fromTitle: title) == "アーカイブ")
        }
        XCTAssert(TrackTextNormalizer.artistTokens("stb;NEA;ささ。").primary == "stb")
        XCTAssert(TrackTextNormalizer.artistTokens("HUNTR/X").primary == "HUNTR/X")
        XCTAssert(LyricsQueryPlanner.plan(for: metadata).contains { $0.titleQuery == "アーカイブ" && $0.artistQuery == "stb" })
        let unrelated = LyricsCandidate(id: "unrelated", identity: identity, title: "アーカイブ", artist: "Other Artist;NEA", album: "アーカイブ", duration: 240, lines: candidate.lines, source: .qqExperimental, confidence: 0.9)
        XCTAssert(LyricsSafeMatcher.decide(candidate: unrelated, metadata: metadata).tier == .reject)
        func copy(title: String = "アーカイブ", artist: String = "stb;NEA;ささ。", spotifyID: String? = nil, explanation: [String] = []) -> LyricsCandidate {
            LyricsCandidate(id: "copy", identity: identity, title: title, artist: artist, album: candidate.album, duration: candidate.duration, lines: candidate.lines, source: candidate.source, confidence: candidate.confidence, spotifyTrackID: spotifyID, matchExplanation: explanation)
        }
        XCTAssert(LyricsSafeMatcher.decide(candidate: copy(spotifyID: "unrelated-recording"), metadata: metadata).tier == .reject)
        let exact = copy(title: track.title, artist: track.artist)
        let exactDecision = LyricsSafeMatcher.decide(candidate: exact, metadata: metadata)
        XCTAssert(!exactDecision.versionConflict)
        XCTAssert(exactDecision.tier == .autoHigh || exactDecision.tier == .autoMedium)
        XCTAssert(copy(explanation: decision.explanation).arrangementNotice != nil)
        XCTAssert(exact.arrangementNotice == nil)

        // Verified Spotify artists scenario: stb (Piano Ver.) with Spotify official artists stb, NEA, ささ。, KASUMI
        var enrichedMetadata = metadata
        enrichedMetadata.verifiedSpotifyArtists = ["stb", "NEA", "ささ。", "KASUMI"]

        // 1. Piano Ver. candidate with known collaborator subset (stb;NEA;ささ。) must be auto-adopted
        let pianoCandidate = copy(title: "アーカイブ (Piano Ver.)", artist: "stb;NEA;ささ。")
        let pianoDecision = LyricsSafeMatcher.decide(candidate: pianoCandidate, metadata: enrichedMetadata)
        XCTAssert(!pianoDecision.versionConflict, "Piano Ver. candidate must not have version conflict")
        XCTAssert(pianoDecision.tier == .autoHigh || pianoDecision.tier == .autoMedium,
                     "Piano Ver. candidate with verified Spotify artist subset must be auto-adopted: \(pianoDecision.tier)")
        XCTAssert(pianoDecision.reasons.contains("featuredArtistsVerifiedSubset"),
                     "Must record featuredArtistsVerifiedSubset evidence: \(pianoDecision.reasons)")
        XCTAssert(!pianoDecision.reasons.contains("missingFeaturedArtist"),
                     "Must not penalize missing secondary Spotify artist when candidate subset is verified")
        XCTAssert(!pianoDecision.reasons.contains("extraFeaturedArtist"),
                     "Must not flag extra featured artist when all candidate artists are in official list")

        // 2. Safety barrier: Plain アーカイブ must NEVER be auto-adopted for Piano Ver.
        let plainCandidate = copy(title: "アーカイブ", artist: "stb;NEA;ささ。")
        let plainDecision = LyricsSafeMatcher.decide(candidate: plainCandidate, metadata: enrichedMetadata)
        XCTAssert(plainDecision.versionConflict, "Plain arrangement must have version conflict for Piano Ver. track")
        XCTAssert(plainDecision.tier == .candidates, "Plain arrangement must NEVER be auto-adopted for Piano Ver. track: \(plainDecision.tier)")

        // 3. Unverified guest artist must remain .candidates
        let unverifiedCandidate = copy(title: "アーカイブ (Piano Ver.)", artist: "stb;NEA;RandomStranger")
        let unverifiedDecision = LyricsSafeMatcher.decide(candidate: unverifiedCandidate, metadata: enrichedMetadata)
        XCTAssert(unverifiedDecision.tier == .candidates, "Candidate with unverified artist must remain .candidates: \(unverifiedDecision.tier)")
        XCTAssert(unverifiedDecision.reasons.contains("extraFeaturedArtist"), "Must flag extraFeaturedArtist")

    }

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

    func testLowYieldSourcesWaitAndAreSkippedAfterAutomaticAdoption() async {
        let track = Track(title: "Known recording", artist: "Artist", album: "Album", duration: 180)
        let identity = TrackIdentity(track: track)
        let document = LyricsDocument(identity: identity, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, lines: [LyricLine(timestamp: 1, originalText: "Fixture")],
            isSynchronized: true, source: .qqExperimental, confidence: 0.95)
        for hasLyrics in [true, false] {
            let ovh = ProviderFailureCounter(), linkcore = ProviderFailureCounter(), petit = ProviderFailureCounter()
            defer { XCTAssertEqual(petit.value > 0, !hasLyrics, "プチリリ is asked only when nothing else can be adopted") }
            let manager = LyricsSearchManager(providers: [
                ProviderFailureCountingLyricsProvider(name: "lyrics.ovh", result: .noMatch, counter: ovh),
                ProviderFailureCountingLyricsProvider(name: "LinkCore / TuneCore", result: .noMatch, counter: linkcore),
                ProviderFailureCountingLyricsProvider(name: PetitLyricsProvider().name, result: .noMatch, counter: petit),
                ProviderFailureDelayedLyricsProvider(name: "QQ Music Experimental", delay: 20_000_000,
                    result: hasLyrics ? .match(document) : .noMatch)
            ])
            let outcome = await manager.search(track: track, identity: identity)
            if hasLyrics {
                guard case .match = outcome.result else { return XCTFail("Keep normal automatic adoption") }
                XCTAssertEqual(ovh.value, 0)
                XCTAssertEqual(linkcore.value, 0)
            } else {
                XCTAssertGreaterThan(ovh.value, 0, "The source remains available when earlier sources cannot adopt")
                XCTAssertGreaterThan(linkcore.value, 0)
            }
        }
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

    func testCatalogDurationOverridesDesktopDurationWithoutChangingIdentity() async throws {
        let track = Track(title: "shion", artist: "angelize", album: "shion", duration: 150.8,
                          spotifyId: "spotify:track:0t5DDnfp0dkgeSnokvbIQY")
        let identity = TrackIdentity(track: track)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogDurationFixture.self]
        let resolver = SpotifyTrackArtistResolver(session: URLSession(configuration: config))
        let providers = [LyricsSource.qqExperimental, .neteaseExperimental, .kuwoExperimental].enumerated().map { index, source in
            ProviderFailureFixedLyricsProvider(name: "source-\(index)", result: .candidates([
                LyricsCandidate(id: "source-\(index)", identity: identity, title: "shion", artist: "Angelize",
                    album: "shion", duration: 168,
                    lines: [LyricLine(timestamp: 1, originalText: "電波を超え届く君のもとへ")],
                    isSynchronized: true, source: source, confidence: 0.9)
            ]))
        }
        let outcome = await LyricsSearchManager(providers: providers, spotifyArtistResolver: resolver)
            .search(track: track, identity: identity)
        guard case .match(let document) = outcome.result else { return XCTFail("Expected catalog-backed adoption") }
        XCTAssertEqual(document.identity, identity)
        XCTAssertEqual(track.duration, 150.8)
        XCTAssertEqual(document.duration, 168)
        XCTAssertLessThan(outcome.automaticSelection?.durationDelta ?? 0, 0.5)
        XCTAssertTrue(outcome.automaticDecision?.reasons.contains("durationClose") == true)
    }

    func testShionSingleQQMatchUsesCatalogDurationRatherThanProviderConfidence() async throws {
        // 2026-10-26 07:38:06: QQ MATCH, 37 synchronized lines, confidence 0.9.
        let track = Track(title: "shion", artist: "angelize", album: "shion", duration: 150.8,
                          spotifyId: "spotify:track:0t5DDnfp0dkgeSnokvbIQY")
        let identity = TrackIdentity(track: track)
        let document = LyricsDocument(identity: identity, title: "shion", artist: "Angelize", album: "shion",
            duration: 168, lines: (0..<37).map { LyricLine(timestamp: Double($0 * 4), originalText: "電波を超え届く君のもとへ") },
            isSynchronized: true, source: .qqExperimental, confidence: 0.9, providerSourceID: "qq:shion")
        let source = ProviderFailureFixedLyricsProvider(name: "QQ Music Experimental", result: .match(document))
        let oldDuration = await LyricsSearchManager(providers: [source]).search(track: track, identity: identity)
        guard case .candidates = oldDuration.result else { return XCTFail("Expected to reproduce the reported downgrade") }
        XCTAssertTrue(oldDuration.diagnostics.flatMap(\.matchDecisions).contains { $0.reasons.contains("durationFar") })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogDurationFixture.self]
        let outcome = await LyricsSearchManager(providers: [source],
            spotifyArtistResolver: SpotifyTrackArtistResolver(session: URLSession(configuration: config)))
            .search(track: track, identity: identity)
        guard case .match(let adopted) = outcome.result else { return XCTFail("A single qualified QQ result must be adopted") }
        XCTAssertEqual(adopted.lines.count, 37)
        XCTAssertEqual(outcome.automaticDecision?.tier, .autoHigh)
        XCTAssertTrue(outcome.automaticDecision?.reasons.contains("durationClose") == true)
    }

    func testReviewedQueueSongIsPreloadedOnceButStillSearchedWhenPlayed() async {
        let track = Track(title: "活着", artist: "Sop天, 橙汁, BFG Music", album: "活着", duration: 165.373,
                          spotifyId: "1ww8Qq9GU6VxO293E2najn")
        let candidate = LyricsCandidate(id: "netease:1383422260", identity: TrackIdentity(track: track),
            title: "活着（Prod.By Red killer）", artist: "Sop天, 橙汁, BFG_Music", album: track.album,
            duration: 165.373, lines: [LyricLine(timestamp: 1, originalText: "Fixture")],
            source: .neteaseExperimental, confidence: 0.9)
        let counter = ProviderFailureCounter()
        let provider = ProviderFailureCountingLyricsProvider(name: "NetEase Experimental", result: .candidates([candidate]), counter: counter)
        let first = LyricsSessionController(providers: [provider], isPreload: true)
        await first.loadForPreloading(track: track)
        guard case .candidates = first.state else { return XCTFail("Reproduce the real review result") }
        let firstCalls = counter.value
        XCTAssertGreaterThan(firstCalls, 0)
        let requeued = LyricsSessionController(providers: [provider], isPreload: true)
        await requeued.loadForPreloading(track: track)
        XCTAssertEqual(counter.value, firstCalls, "The second queue appearance must not search again")
        let live = LyricsSessionController(providers: [provider])
        await live.loadForPreloading(track: track)
        XCTAssertGreaterThan(counter.value, firstCalls, "Normal playback must still follow its normal search path")
    }

    func testPreloadedQueueTrackPlaysFromStorageWithoutAnotherSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-preload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("test.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        let stats = LyricsSourceStats(fileURL: root.appendingPathComponent("stats.jsonl"))
        let counter = ProviderFailureCounter()
        let source = PreloadCountingProvider(counter: counter)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QueuePreloadFixture.self]
        let tracks = try await SpotifyCatalogService(session: URLSession(configuration: config))
            .upcomingTracks(accessToken: "fixture")
        XCTAssertEqual(tracks.count, 2)
        for track in tracks {
            let preload = LyricsSessionController(providers: [source], repository: repo, sourceStats: stats, isPreload: true)
            await preload.loadForPreloading(track: track)
        }
        XCTAssertEqual(counter.value, 2)
        for (index, queued) in tracks.enumerated() {
            // An adopted timed version survives Desktop's duration discrepancy;
            // a cached plain version is not searched again just to add timing.
            let playing = Track(title: queued.title, artist: queued.artist, album: queued.album,
                                duration: index == 0 ? 150.8 : queued.duration, spotifyId: queued.spotifyId)
            let live = LyricsSessionController(providers: [source], repository: repo, sourceStats: stats)
            await live.loadForPreloading(track: playing)
            XCTAssertEqual(live.lyrics.count, 1)
            XCTAssertNotNil(live.activeLyricsVersionID)
            XCTAssertEqual(counter.value, 2, "Playing the saved track must not start another provider search")
        }
        let returned = LyricsSessionController(providers: [source], repository: repo, sourceStats: stats)
        await returned.loadForPreloading(track: tracks[0]) // A → B → A uses the adopted cache.
        XCTAssertFalse(returned.lyrics.isEmpty)
        XCTAssertEqual(counter.value, 2)
        let lines = try String(contentsOf: stats.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(entry?["preload"] as? Bool, true)
        }
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

    func testOneSourceListingTheSameLyricsTwiceShowsOneCandidate() async throws {
        // Real data: NetEase lists YOU & IDOL twice, as a single and as an
        // album entry, with the same lyrics text. KuGou's copy carries the
        // same text too but is a different source, so both stay selectable.
        let track = Track(id: "spotify:track:4YlXzUxQGF2K8TTqaE7fuZ", title: "YOU & IDOL",
                          artist: "相対性理論", album: "TOWN AGE", duration: 201,
                          spotifyId: "spotify:track:4YlXzUxQGF2K8TTqaE7fuZ")
        let identity = TrackIdentity(track: track)
        func candidate(_ id: String, source: LyricsSource, duration: TimeInterval,
                       lines: [String]) -> LyricsCandidate {
            LyricsCandidate(
                id: id, identity: identity, title: "YOU & IDOL", artist: "相対性理論",
                album: "TOWN AGE", duration: duration,
                lines: lines.map { LyricLine(timestamp: 0, originalText: $0) },
                isSynchronized: false, source: source, confidence: 0.9, providerSourceID: id
            )
        }
        let lyrics = ["君の声が聞こえる", "この夜を越えて", "まだ見ぬ朝へ"]
        let manager = LyricsSearchManager(providers: [
            ProviderFailureFixedLyricsProvider(name: "NetEase Experimental", result: .candidates([
                candidate("1974443812", source: .neteaseExperimental, duration: 226.0, lines: lyrics),
                candidate("2626000001", source: .neteaseExperimental, duration: 226.2, lines: lyrics)
            ])),
            ProviderFailureFixedLyricsProvider(name: "Kuwo Experimental", result: .candidates([
                candidate("kuwo-8821", source: .kuwoExperimental, duration: 240.0, lines: lyrics),
                candidate("kuwo-9902", source: .kuwoExperimental, duration: 241.0,
                          lines: lyrics + ["違う歌詞の行"])
            ]))
        ])

        let outcome = await manager.search(track: track, identity: identity)

        guard case .candidates(let listed) = outcome.result else {
            XCTFail("Expected review candidates, got \(outcome.result)")
            return
        }
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(listed.filter { $0.source == .neteaseExperimental }.count, 1)
        XCTAssertEqual(listed.filter { $0.source == .kuwoExperimental }.count, 2)
        XCTAssertEqual(outcome.alternatives.count, 3)
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
