import Foundation

/// Public publisher catalog + its own lyric pages. No credentials, copied cookies,
/// search-engine scraping, song-specific routes, or query-echo identity assertions.
public final class LinkCoreLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "LinkCore / TuneCore"
    public let executionLane: LyricsProviderExecutionLane = .network
    public let timeoutInterval: TimeInterval = 16
    private let catalog: LinkCoreCatalog

    public init(session: URLSession? = nil) {
        catalog = session.map { LinkCoreCatalog(session: $0) } ?? .shared
    }

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        do {
            let matches = try await catalog.matches(for: track)
            guard !Task.isCancelled else { return .failed(.cancelled) }
            guard !matches.isEmpty else { return .noMatch }
            var candidates: [LyricsCandidate] = []
            var sourceHadNoBody = false
            var firstFailure: LyricsFailure?
            // Directory -> verified artist -> matching release/song -> bounded body.
            // Neither a whole discography nor every generated query fetches lyrics.
            for match in matches.prefix(2) {
                try Task.checkCancellation()
                do {
                    guard let page = try await catalog.lyrics(for: match) else {
                        sourceHadNoBody = true; continue
                    }
                    let artist = match.artistNames.first {
                        LinkCoreHTML.key($0) == LinkCoreHTML.key(page.artist)
                    }
                    guard artist != nil,
                          match.titles.contains(where: { LinkCoreHTML.key($0) == LinkCoreHTML.key(page.title) }) else {
                        firstFailure = .identityUnconfirmed(1, "发行目录与歌词页面的歌名或艺人不一致")
                        continue
                    }
                    // A localized artist name is chosen from the *same official
                    // source entity*, never fabricated from the caller's query.
                    let primary = TrackTextNormalizer.artistTokens(track.artist).primary
                    let displayArtist = match.artistNames.first { LinkCoreHTML.key($0) == LinkCoreHTML.key(primary) }
                        ?? page.artist
                    let id = "linkcore:\(match.artistID):\(match.releaseCode):\(match.songID)"
                    let lines = page.lines.map { LyricLine(timestamp: 0, originalText: $0) }
                    candidates.append(LyricsCandidate(id: id, identity: identity,
                        title: match.versionedTitle, artist: displayArtist, album: match.album,
                        duration: match.duration, lines: lines, isSynchronized: false,
                        source: .linkcore, confidence: 0, providerSourceID: id,
                        language: ScriptDetector.guessLanguage(page.lines.prefix(4).joined(separator: " ")),
                        providerName: name, declaredTitleAliases: match.titles))
                } catch let error as LinkCoreRequestError {
                    if error.failure == .cancelled { return .failed(.cancelled) }
                    firstFailure = firstFailure ?? error.failure
                }
            }
            if !candidates.isEmpty { return .candidates(candidates) }
            if let firstFailure { return .failed(firstFailure) }
            return sourceHadNoBody ? .failed(.lyricsBodyUnavailable("已匹配发行方的歌曲目录，但该发行页尚未提供公开歌词正文。其他来源仍可继续查询。")) : .noMatch
        } catch let error as LinkCoreRequestError {
            return .failed(error.failure)
        } catch {
            return .failed(Task.isCancelled || error is CancellationError ? .cancelled : .parseFailure)
        }
    }
}

struct LinkCoreSong: Equatable, Sendable {
    let artistID: String
    let artistNames: [String]
    let releaseCode: String
    let songID: String
    let titles: [String]
    let versionedTitle: String
    let album: String
    let duration: TimeInterval
    var lyricURL: URL? { URL(string: "https://linkco.re/\(releaseCode)/songs/\(songID)/lyrics?lang=ja") }
}
struct LinkCoreArtist: Sendable {
    let id: String
    let names: [String]
    let spotifyArtists: [String]
    let songs: [LinkCoreSong]
}
struct LinkCoreLyricsPage: Sendable { let title: String; let artist: String; let lines: [String] }
private struct LinkCoreRequestError: Error { let failure: LyricsFailure }

/// Small parsed metadata caches only. No retained multi-megabyte HTML documents;
/// network failures are never cached as 'this song has no lyrics'.
actor LinkCoreCatalog {
    static let shared = LinkCoreCatalog()
    private struct Entry<T: Sendable>: Sendable { let value: T; let expires: Date }
    private let session: URLSession
    private var directories: [String: Entry<[String]>] = [:]
    private var directoryTasks: [String: Task<[String], Error>] = [:]
    private var artists: [String: Entry<LinkCoreArtist>] = [:]
    private var artistTasks: [String: Task<LinkCoreArtist, Error>] = [:]
    private var lyricPages: [String: Entry<LinkCoreLyricsPage?>] = [:]
    private var lyricTasks: [String: Task<LinkCoreLyricsPage?, Error>] = [:]
    private var aliasesByTrack: [String: Entry<[TrackAlias]>] = [:]

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 6
            configuration.httpMaximumConnectionsPerHost = 2
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func matches(for track: Track) async throws -> [LinkCoreSong] {
        try Task.checkCancellation()
        let primary = TrackTextNormalizer.artistTokens(track.artist).primary
        let titleKey = LinkCoreHTML.key(track.title)
        guard primary.count >= 2, primary.count <= 120, !titleKey.isEmpty else { return [] }
        let ids = try await artistIDs(named: primary)
        var matches: [LinkCoreSong] = []
        for id in ids.prefix(2) {
            try Task.checkCancellation()
            let artist = try await artist(id: id)
            guard artist.names.contains(where: { LinkCoreHTML.key($0) == LinkCoreHTML.key(primary) }) else { continue }
            let found = artist.songs.filter { song in
                song.titles.contains { LinkCoreHTML.key($0) == titleKey }
                    && Self.compatibleVersions(track.title, song.versionedTitle)
                    && (song.duration <= 0 || track.duration <= 0 || abs(song.duration - track.duration) <= 4)
            }
            matches += found
            if !found.isEmpty {
                // Entity scope + matching recording title + real single duration:
                // available to this search only, not a global arbitrary-name rewrite.
                let sameDuration = found.contains { $0.duration > 0 && track.duration > 0 && abs($0.duration - track.duration) <= 2 }
                if sameDuration {
                    let aliases = artist.names.enumerated().map { index, name in
                        TrackAlias(id: "linkcore-entity:\(artist.id):artist:\(index)", field: .artist,
                            kind: .localizedTitle, value: name, script: ScriptDetector.detect(name),
                            source: .provider, confidence: 1, isOfficial: true)
                    }
                    insert(Entry(value: aliases, expires: Date().addingTimeInterval(3600)),
                           into: &aliasesByTrack, key: Self.aliasKey(track), limit: 96)
                }
            }
        }
        return Array(matches.prefix(4))
    }

    private static func aliasKey(_ track: Track) -> String {
        [TrackIdentity(track: track).stableKey, LinkCoreHTML.key(track.title),
         LinkCoreHTML.key(TrackTextNormalizer.artistTokens(track.artist).primary),
         String(track.duration)].joined(separator: "\u{1F}")
    }

    func cachedAliases(for track: Track) -> [TrackAlias] {
        let key = Self.aliasKey(track)
        guard let entry = aliasesByTrack[key], entry.expires > Date() else { return [] }
        return entry.value
    }

    func lyrics(for song: LinkCoreSong) async throws -> LinkCoreLyricsPage? {
        guard let url = song.lyricURL else { return nil }
        let key = url.absoluteString
        if let entry = lyricPages[key], entry.expires > Date() { return entry.value }
        if let task = lyricTasks[key] { return try await task.value }
        let task = Task<LinkCoreLyricsPage?, Error> { [session] in
            guard let html = try await Self.fetch(url, session: session) else { return nil }
            return LinkCoreHTML.lyricPage(html)
        }
        lyricTasks[key] = task
        defer { lyricTasks[key] = nil }
        let value = try await task.value
        insert(Entry(value: value, expires: Date().addingTimeInterval(value == nil ? 300 : 3600)),
               into: &lyricPages, key: key, limit: 16)
        try Task.checkCancellation()
        return value
    }

    private func artistIDs(named name: String) async throws -> [String] {
        let key = LinkCoreHTML.key(name)
        if let entry = directories[key], entry.expires > Date() { return entry.value }
        if let task = directoryTasks[key] { return try await task.value }
        var url = URLComponents(string: "https://www.tunecore.co.jp/artists")!
        url.queryItems = [URLQueryItem(name: "keyword", value: name), URLQueryItem(name: "lang", value: "en")]
        let requestURL = url.url!
        let task = Task<[String], Error> { [session] in
            guard let html = try await Self.fetch(requestURL, session: session) else { return [] }
            return LinkCoreHTML.artistDirectory(html, matching: name)
        }
        directoryTasks[key] = task
        defer { directoryTasks[key] = nil }
        let list = try await task.value
        try Task.checkCancellation()
        insert(Entry(value: list, expires: Date().addingTimeInterval(list.isEmpty ? 300 : 86400)),
               into: &directories, key: key, limit: 96)
        return list
    }

    private func artist(id: String) async throws -> LinkCoreArtist {
        if let entry = artists[id], entry.expires > Date() { return entry.value }
        if let task = artistTasks[id] { return try await task.value }
        guard id.allSatisfy(\.isNumber), !id.isEmpty, id.count <= 12 else { throw LinkCoreRequestError(failure: .parseFailure) }
        let url = URL(string: "https://www.tunecore.co.jp/artists?id=\(id)&lang=en")!
        let task = Task<LinkCoreArtist, Error> { [session] in
            guard let html = try await Self.fetch(url, session: session),
                  let artist = LinkCoreHTML.artistPage(html), artist.id == id else {
                throw LinkCoreRequestError(failure: .parseFailure)
            }
            return artist
        }
        artistTasks[id] = task
        defer { artistTasks[id] = nil }
        let value = try await task.value
        insert(Entry(value: value, expires: Date().addingTimeInterval(86400)), into: &artists, key: id, limit: 48)
        return value
    }

    private func insert<T>(_ value: Entry<T>, into map: inout [String: Entry<T>], key: String, limit: Int) {
        map = map.filter { $0.value.expires > Date() }
        if map.count >= limit, map[key] == nil,
           let oldest = map.min(by: { $0.value.expires < $1.value.expires })?.key { map[oldest] = nil }
        map[key] = value
    }
    private static func compatibleVersions(_ lhs: String, _ rhs: String) -> Bool {
        let a = Set(TrackTextNormalizer.extractVersionTags(fromTitle: lhs).map { $0.rawValue })
        let b = Set(TrackTextNormalizer.extractVersionTags(fromTitle: rhs).map { $0.rawValue })
        return a == b
    }
    private static func fetch(_ url: URL, session: URLSession) async throws -> String? {
        guard LinkCoreHTML.isAllowed(url) else { throw LinkCoreRequestError(failure: .parseFailure) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("LyricIsland/1.0 (public publisher lyrics)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url, LinkCoreHTML.isAllowed(finalURL) else { throw LinkCoreRequestError(failure: .parseFailure) }
            if response.statusCode == 404 { return nil }
            if response.statusCode == 429 { throw LinkCoreRequestError(failure: .rateLimited(nil)) }
            guard response.statusCode == 200 else { throw LinkCoreRequestError(failure: .serverError(response.statusCode)) }
            let maximum = 1_500_000
            guard response.expectedContentLength <= maximum else { throw LinkCoreRequestError(failure: .parseFailure) }
            var data = Data(); data.reserveCapacity(min(maximum, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                if data.count % 16384 == 0 { try Task.checkCancellation() }
                guard data.count < maximum else { throw LinkCoreRequestError(failure: .parseFailure) }
                data.append(byte)
            }
            guard let result = String(data: data, encoding: .utf8) else { throw LinkCoreRequestError(failure: .parseFailure) }
            return result
        } catch let error as LinkCoreRequestError { throw error }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw LinkCoreRequestError(failure: .cancelled) }
            throw LinkCoreRequestError(failure: error.code == .timedOut ? .timedOut : .networkUnavailable)
        } catch {
            throw LinkCoreRequestError(failure: Task.isCancelled || error is CancellationError ? .cancelled : .parseFailure)
        }
    }
}

// BEGIN LINKCORE PURE PARSER
/// Parser works on bounded public HTML and official NEXT_DATA metadata. It does
/// not infer an artist alias from punctuation or trust arbitrary user URLs.
enum LinkCoreHTML {
    static func key(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return url.host == "linkco.re" || url.host == "www.tunecore.co.jp"
    }
    static func pageProps(_ html: String) -> [String: Any]? {
        guard html.utf8.count <= 1_500_000,
              let raw = capture(#"(?is)<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>(.*?)</script\s*>"#, html),
              let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = json["props"] as? [String: Any] else { return nil }
        return props["pageProps"] as? [String: Any]
    }
    static func artistDirectory(_ html: String, matching name: String) -> [String] {
        guard let props = pageProps(html), let list = props["artistList"] as? [[String: Any]] else { return [] }
        let expected = key(name)
        return Array(list.prefix(60).compactMap { item -> String? in
            let names = [item["nameEn"] as? String, item["nameJa"] as? String].compactMap { $0 }
            guard names.contains(where: { key($0) == expected }) else { return nil }
            let id = string(item["id"])
            return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
        }.prefix(2))
    }
    static func artistPage(_ html: String) -> LinkCoreArtist? {
        guard let artist = pageProps(html)?["artist"] as? [String: Any] else { return nil }
        let id = string(artist["id"])
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        let names = unique([string(artist["nameEn"]), string(artist["nameJa"])]).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let dsp = artist["dsp"] as? [String: Any] ?? [:]
        let spotify = ["spotifyEn", "spotifyJa", "spotify"].compactMap { name -> String? in
            guard let item = dsp[name] as? [String: Any], let raw = item["url"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host == "open.spotify.com",
                  url.pathComponents.count == 3, url.pathComponents[1] == "artist" else { return nil }
            return url.pathComponents[2]
        }
        let releases = (artist["releases"] as? [[String: Any]] ?? [])
            + (artist["featuringReleases"] as? [[String: Any]] ?? [])
        var songs: [LinkCoreSong] = []
        for release in releases.prefix(160) {
            guard let lc = release["linkcore"] as? [String: Any], let raw = lc["url"] as? String,
                  let url = URL(string: raw), isAllowed(url), url.host == "linkco.re",
                  url.pathComponents.count == 2 else { continue }
            let code = url.lastPathComponent
            guard (6...12).contains(code.count), code.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { continue }
            let album = string(release["nameEn"])
            let entries = release["songs"] as? [[String: Any]] ?? []
            for song in entries.prefix(80) {
                let songID = string(song["id"])
                guard !songID.isEmpty, songID.allSatisfy(\.isNumber) else { continue }
                let songNames = [string(song["nameEn"]), string(song["nameJa"])]
                let isSingle = entries.count == 1 && (release["songNum"] as? Int ?? 1) == 1
                let releaseNames = [string(release["nameEnFeatured"]), string(release["nameJaFeatured"]),
                                    string(release["nameEn"]), string(release["nameJa"])]
                let titles = unique((isSingle ? releaseNames : []) + songNames).filter { !$0.isEmpty }
                guard let title = titles.first else { continue }
                let duration = isSingle ? (release["totalSeconds"] as? NSNumber)?.doubleValue ?? 0 : 0
                // Composer/lyricist credits do not become the performing artist.
                let credited = (release["artists"] as? [[String: Any]] ?? []).filter { ($0["role"] as? String) == "primary" }
                let creditedNames = credited.flatMap { [string($0["nameEn"]), string($0["nameJa"])] }.filter { !$0.isEmpty }
                let performingNames = creditedNames.isEmpty ? names : unique(creditedNames)
                songs.append(LinkCoreSong(artistID: id, artistNames: performingNames,
                    releaseCode: code, songID: songID, titles: titles, versionedTitle: title,
                    album: album, duration: duration.isFinite ? max(0, duration) : 0))
            }
        }
        return LinkCoreArtist(id: id, names: names, spotifyArtists: spotify, songs: songs)
    }
    static func lyricPage(_ html: String) -> LinkCoreLyricsPage? {
        guard html.utf8.count <= 1_500_000,
              let header = capture(#"(?is)<section\b[^>]*\bclass\s*=\s*["'][^"']*\blyric_header\b[^"']*["'][^>]*>(.*?)</section\s*>"#, html),
              let titleRaw = capture(#"(?is)<h2\b[^>]*>(.*?)</h2>"#, header),
              let artistRaw = capture(#"(?is)<h3\b[^>]*>(.*?)</h3>"#, header),
              let block = capture(#"(?is)<div\b[^>]*\bclass\s*=\s*["'][^"']*\blyric_text\b[^"']*["'][^>]*>(.*?)</div\s*>"#, html) else { return nil }
        let separated = replace(#"(?is)<\s*(?:/?p\b[^>]*|br\s*/?)>"#, block, with: "\n")
        let body = plain(separated)
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...1200).contains(lines.count), body.utf8.count < 150_000 else { return nil }
        let title = plain(titleRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = plain(artistRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return LinkCoreLyricsPage(title: title, artist: artist, lines: lines)
    }
    private static func plain(_ text: String) -> String {
        var value = replace(#"(?is)<script\b[^>]*>.*?</script>|<style\b[^>]*>.*?</style>"#, text, with: "")
        value = replace(#"(?s)<[^>]*>"#, value, with: "")
        for (entity, literal) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            value = value.replacingOccurrences(of: entity, with: literal)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: value), let digitsRange = Range(match.range(at: 1), in: value) else { continue }
                let digits = String(value[digitsRange])
                let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let number, let scalar = UnicodeScalar(number) { value.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return value.replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func replace(_ pattern: String, _ text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    private static func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
// END LINKCORE PURE PARSER
