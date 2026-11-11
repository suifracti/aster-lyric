import Foundation

/// プチリリ (petitlyrics.com): a Japanese lyric catalogue with good coverage of
/// independent releases. The public pages supply plain text only, with their
/// own title and artist. No account, no copied cookie and no app key: each
/// lookup opens its own short-lived session the way a browser tab would.
public final class PetitLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "プチリリ"
    public let executionLane: LyricsProviderExecutionLane = .network
    public let timeoutInterval: TimeInterval
    private let makeSession: @Sendable () -> URLSession
    private static let bodyLimit = 1_048_576
    private static let origin = "https://petitlyrics.com"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(session: URLSession? = nil, timeout: TimeInterval = 8) {
        let bounded = timeout.isFinite ? min(15, max(0.1, timeout)) : 8
        timeoutInterval = bounded
        if let session {
            makeSession = { session }
        } else {
            makeSession = {
                // The site ties the lyric request to the session that opened
                // the page, so cookies stay inside this one lookup.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = min(4, bounded)
                configuration.timeoutIntervalForResource = bounded
                configuration.httpMaximumConnectionsPerHost = 2
                configuration.urlCache = nil
                return URLSession(configuration: configuration)
            }
        }
    }

    struct SearchRow: Equatable, Sendable {
        let id: String
        let title: String
        let artist: String
        let album: String
    }

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        if Task.isCancelled { return .failed(.cancelled) }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .noMatch }
        let artist = TrackTextNormalizer.artistTokens(track.artist).primary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let session = makeSession()
        do {
            var query = [URLQueryItem(name: "title", value: title)]
            if !artist.isEmpty { query.append(URLQueryItem(name: "artist", value: artist)) }
            let search = try await text(session, path: "/search_lyrics", query: query)
            var rows = Self.parseSearch(search)
            if rows.isEmpty, !artist.isEmpty {
                // The site may write the artist differently (加藤MILIYAH /
                // 加藤 ミリヤ). Search by title alone and open only records
                // whose artist shares a name with ours; matching still decides.
                let names = [artist] + TrackTextNormalizer.parentheticalArtistNames(artist)
                rows = Self.parseSearch(try await text(session, path: "/search_lyrics",
                    query: [URLQueryItem(name: "title", value: title)])).filter { row in
                    names.contains { TrackTextNormalizer.artistsShareNamePart($0, row.artist) }
                }
            }
            guard !rows.isEmpty else { return .noMatch }

            var candidates: [LyricsCandidate] = []
            var token: String?
            var firstFailure: LyricsFailure?
            // Two records at most: a single and its album entry.
            for row in rows.prefix(2) {
                try Task.checkCancellation()
                do {
                    let page = "/lyrics/\(row.id)"
                    _ = try await text(session, path: page)
                    if token == nil {
                        token = Self.parseToken(try await text(session, path: "/lib/pl-lib.js", referer: page))
                    }
                    guard let token else { throw LyricsFailure.parseFailure }
                    let body = try await data(session, path: "/com/get_lyrics.ajax", referer: page,
                        form: "lyrics_id=\(row.id)", token: token)
                    let lines = try Self.parseBody(body)
                    guard lines.contains(where: { !$0.isEmpty }) else { continue }
                    let id = "petitlyrics:\(row.id)"
                    candidates.append(LyricsCandidate(id: id, identity: identity,
                        title: row.title, artist: row.artist, album: row.album, duration: 0,
                        lines: lines.map { LyricLine(timestamp: 0, originalText: $0) },
                        isSynchronized: false, source: .petitLyrics, confidence: 0, providerSourceID: id,
                        language: ScriptDetector.guessLanguage(lines.prefix(4).joined(separator: " ")),
                        providerName: name))
                } catch {
                    let failure = Self.failure(error)
                    if failure == .cancelled { return .failed(.cancelled) }
                    if firstFailure == nil { firstFailure = failure }
                }
            }
            if Task.isCancelled { return .failed(.cancelled) }
            if !candidates.isEmpty { return .candidates(candidates) }
            if let firstFailure { return .failed(firstFailure) }
            return .noMatch
        } catch {
            return .failed(Self.failure(error))
        }
    }

    // MARK: - Parsing

    /// Rows of the search table: `/lyrics/<id>`, title, artist and album.
    static func parseSearch(_ html: String) -> [SearchRow] {
        var rows: [SearchRow] = []
        var seen = Set<String>()
        for block in html.components(separatedBy: "<tr>").dropFirst() {
            guard let id = firstGroup(#"href="/lyrics/(\d+)"><span class="lyrics-list-title">"#, in: block),
                  let title = firstGroup(#"<span class="lyrics-list-title">(.*?)</span>"#, in: block),
                  let artist = firstGroup(#"<span class="lyrics-list-artist">(.*?)</span>"#, in: block) else { continue }
            let cleanTitle = decode(title), cleanArtist = decode(artist)
            guard !cleanTitle.isEmpty, !cleanArtist.isEmpty, seen.insert(id).inserted else { continue }
            let album = firstGroup(#"<span class="lyrics-list-album">(.*?)</span>"#, in: block).map(decode) ?? ""
            rows.append(SearchRow(id: id, title: cleanTitle, artist: cleanArtist, album: album))
        }
        return rows
    }

    static func parseToken(_ script: String) -> String? {
        firstGroup(#"'X-CSRF-Token',\s*'([0-9A-Za-z]{16,64})'"#, in: script)
    }

    /// `[{"lyrics": "<base64 UTF-8 line>"}, …]`, one entry per lyric line.
    static func parseBody(_ data: Data) throws -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LyricsFailure.parseFailure
        }
        return try rows.map { row in
            guard let encoded = row["lyrics"] as? String,
                  let decoded = Data(base64Encoded: encoded),
                  let line = String(data: decoded, encoding: .utf8) else { throw LyricsFailure.parseFailure }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Search cells carry numeric character references and a few named ones.
    static func decode(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: text),
                      let hexFlag = Range(match.range(at: 1), in: text),
                      let digits = Range(match.range(at: 2), in: text),
                      let value = UInt32(text[digits], radix: text[hexFlag].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(value) else { continue }
                text.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Requests

    private func text(_ session: URLSession, path: String, query: [URLQueryItem] = [], referer: String? = nil) async throws -> String {
        let body = try await data(session, path: path, query: query, referer: referer)
        guard let text = String(data: body, encoding: .utf8) else { throw LyricsFailure.parseFailure }
        return text
    }

    private func data(_ session: URLSession, path: String, query: [URLQueryItem] = [], referer: String? = nil,
                      form: String? = nil, token: String? = nil) async throws -> Data {
        guard var components = URLComponents(string: Self.origin + path) else { throw LyricsFailure.parseFailure }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw LyricsFailure.parseFailure }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(4, timeoutInterval)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(Self.origin + referer, forHTTPHeaderField: "Referer") }
        if let form {
            request.httpMethod = "POST"
            request.httpBody = Data(form.utf8)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        if let token { request.setValue(token, forHTTPHeaderField: "X-CSRF-Token") }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsFailure.parseFailure }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw LyricsFailure.rateLimited(nil) }
            throw LyricsFailure.serverError(http.statusCode)
        }
        guard body.count <= Self.bodyLimit else { throw LyricsFailure.parseFailure }
        return body
    }

    private static func failure(_ error: Error) -> LyricsFailure {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if let failure = error as? LyricsFailure { return failure }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            default: return .networkUnavailable
            }
        }
        return .parseFailure
    }
}
