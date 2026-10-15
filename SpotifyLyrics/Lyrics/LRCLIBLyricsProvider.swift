import Foundation

public protocol LRCLIBSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: LRCLIBSession {}

/// Isolated online lyrics provider. Failures never mutate local files or playback.
/// Does not persist downloaded lyrics by default.
public final class LRCLIBLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "LRCLIB"

    private let session: LRCLIBSession
    private let baseURL: URL
    private let timeout: TimeInterval
    private let maxAutomaticRetries: Int

    public init(
        session: LRCLIBSession = URLSession.shared,
        baseURL: URL? = nil,
        timeout: TimeInterval = 8,
        maxAutomaticRetries: Int = 1
    ) {
        self.session = session
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.timeout = timeout
        self.maxAutomaticRetries = max(0, maxAutomaticRetries)
    }

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        if Task.isCancelled {
            return .failed(.cancelled)
        }

        var attempt = 0
        while true {
            if Task.isCancelled {
                return .failed(.cancelled)
            }

            do {
                let records = try await fetchRecords(for: track)
                if Task.isCancelled {
                    return .failed(.cancelled)
                }
                return rank(records: records, track: track, identity: identity) ?? .noMatch
            } catch let error as LRCLIBError {
                let failure = Self.failure(for: error)
                if Self.shouldRetry(failure), attempt < maxAutomaticRetries {
                    attempt += 1
                    let delay = Self.retryDelay(for: failure, attempt: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return mapTerminal(failure)
            } catch {
                if Task.isCancelled {
                    return .failed(.cancelled)
                }
                let failure = Self.failure(for: error)
                if Self.shouldRetry(failure), attempt < maxAutomaticRetries {
                    attempt += 1
                    let delay = Self.retryDelay(for: failure, attempt: attempt)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return .failed(failure)
            }
        }
    }

    private func fetchRecords(for track: Track) async throws -> [LRCLIBRecord] {
        // Exact lookup needs an artist. A planned artist-free query is a
        // free-text search, not an exact request with an empty artist filter.
        if track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await searchRecords(for: track)
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        if !track.album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: track.album))
        }
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SpotifyLyrics/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LRCLIBError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 404:
            // Fall back to search endpoint for broader matching.
            return try await searchRecords(for: track)
        case 400:
            throw LRCLIBError.httpStatus(400)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw LRCLIBError.rateLimited(retryAfter)
        default:
            throw LRCLIBError.httpStatus(httpResponse.statusCode)
        }

        do {
            let record = try JSONDecoder().decode(LRCLIBRecord.self, from: data)
            return [record]
        } catch {
            // Some deployments may return an array from search-compatible proxies.
            if let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) {
                return records
            }
            throw LRCLIBError.parseFailure
        }
    }

    private func searchRecords(for track: Track) async throws -> [LRCLIBRecord] {
        if Task.isCancelled { throw CancellationError() }

        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        if track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.queryItems = [URLQueryItem(name: "q", value: track.title)]
        } else {
            components.queryItems = [
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: track.artist),
                URLQueryItem(name: "q", value: "\(track.title) \(track.artist)")
            ]
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SpotifyLyrics/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LRCLIBError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 404:
            return []
        case 400:
            throw LRCLIBError.httpStatus(400)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw LRCLIBError.rateLimited(retryAfter)
        default:
            throw LRCLIBError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode([LRCLIBRecord].self, from: data)
        } catch {
            throw LRCLIBError.parseFailure
        }
    }

    private func rank(records: [LRCLIBRecord], track: Track, identity: TrackIdentity) -> LyricsLookupResult? {
        var candidates: [LyricsCandidate] = []

        for (index, record) in records.enumerated() {
            if record.instrumental == true {
                continue
            }
            guard let parsed = parseLyrics(from: record), !parsed.lines.isEmpty else { continue }
            let base = LyricsCandidate(
                id: "lrclib:\(record.id.map(String.init) ?? String(index))",
                identity: identity,
                title: record.trackName ?? track.title,
                artist: record.artistName ?? track.artist,
                album: record.albumName ?? track.album,
                duration: record.duration ?? track.duration,
                lines: parsed.lines,
                isSynchronized: parsed.isSynchronized,
                source: .lrclib,
                confidence: 0,
                providerSourceID: "lrclib:\(record.id.map(String.init) ?? String(index))"
            )
            let score = LyricsMatcher.score(track: track, candidate: base)
            candidates.append(
                LyricsCandidate(
                    id: base.id,
                    identity: identity,
                    title: base.title,
                    artist: base.artist,
                    album: base.album,
                    duration: base.duration,
                    lines: base.lines,
                    isSynchronized: base.isSynchronized,
                    source: .lrclib,
                    confidence: score,
                    providerSourceID: base.providerSourceID
                )
            )
        }

        let sorted = candidates
            .filter { LyricsMatcher.isCandidate($0.confidence) }
            .sorted { $0.confidence > $1.confidence }

        guard let best = sorted.first else {
            // A broad search can contain other recordings or empty vocal
            // records. Neither proves that the requested track is lyric-free.
            if records.contains(where: { record in
                guard record.instrumental == true,
                      let title = record.trackName, let artist = record.artistName,
                      let duration = record.duration, duration.isFinite, duration > 0,
                      track.duration.isFinite, track.duration > 0, abs(duration - track.duration) <= 2,
                      TrackTextNormalizer.normalize(title) == TrackTextNormalizer.normalize(track.title) else { return false }
                let expected = TrackTextNormalizer.artistTokens(track.artist)
                let actual = TrackTextNormalizer.artistTokens(artist)
                let expectedNames = Set(expected.all.map(TrackTextNormalizer.normalizeArtistToken).filter { !$0.isEmpty })
                let actualNames = Set(actual.all.map(TrackTextNormalizer.normalizeArtistToken).filter { !$0.isEmpty })
                return !expectedNames.isEmpty && expectedNames == actualNames
                    && TrackTextNormalizer.normalizeArtistToken(expected.primary) == TrackTextNormalizer.normalizeArtistToken(actual.primary)
            }) {
                return .noLyrics
            }
            return .noMatch
        }

        if LyricsMatcher.isHighConfidence(best.confidence),
           sorted.dropFirst().first.map({ best.confidence - $0.confidence >= 0.05 }) ?? true {
            return .match(
                LyricsDocument(
                    identity: identity,
                    title: best.title,
                    artist: best.artist,
                    album: best.album,
                    duration: best.duration,
                    lines: best.lines,
                    isSynchronized: best.isSynchronized,
                    source: .lrclib,
                    confidence: best.confidence,
                    providerSourceID: best.providerSourceID
                )
            )
        }
        return .candidates(sorted)
    }

    private func parseLyrics(from record: LRCLIBRecord) -> ParsedLyrics? {
        if let syncedLyrics = record.syncedLyrics,
           let document = LRCParser.parse(
               syncedLyrics,
               identity: TrackIdentity(
                   title: record.trackName ?? "",
                   artist: record.artistName ?? "",
                   album: record.albumName ?? "",
                   duration: record.duration ?? 0
               ),
               source: .lrclib
           ) {
            return ParsedLyrics(lines: document.lines, isSynchronized: true)
        }

        guard let plainLyrics = record.plainLyrics else { return nil }
        let lines = plainLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { LyricLine(timestamp: 0, originalText: $0) }
        return lines.isEmpty ? nil : ParsedLyrics(lines: lines, isSynchronized: false)
    }

    private func mapTerminal(_ failure: LyricsFailure) -> LyricsLookupResult {
        switch failure {
        case .serverError(404):
            return .noMatch
        default:
            return .failed(failure)
        }
    }

    private static func shouldRetry(_ failure: LyricsFailure) -> Bool {
        switch failure {
        case .timedOut, .networkUnavailable, .rateLimited, .serverError(500), .serverError(502), .serverError(503), .serverError(504):
            return true
        default:
            return false
        }
    }

    private static func retryDelay(for failure: LyricsFailure, attempt: Int) -> TimeInterval {
        if case .rateLimited(let retryAfter) = failure, let retryAfter, retryAfter > 0 {
            return min(retryAfter, 3)
        }
        return min(0.25 * Double(attempt), 1.0)
    }

    private static func failure(for error: LRCLIBError) -> LyricsFailure {
        switch error {
        case .notFound:
            return .serverError(404)
        case .httpStatus(let status):
            return .serverError(status)
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter)
        case .invalidResponse, .parseFailure:
            return .parseFailure
        }
    }

    private static func failure(for error: Error) -> LyricsFailure {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                return .networkUnavailable
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            default:
                break
            }
        }
        return .unknown(error.localizedDescription)
    }

    private static var defaultBaseURL: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_LRCLIB_BASE_URL"],
           let url = URL(string: override),
           url.scheme != nil,
           url.host != nil {
            return url
        }
        #endif
        return URL(string: "https://lrclib.net/api")!
    }
}

private enum LRCLIBError: Error {
    case notFound
    case httpStatus(Int)
    case rateLimited(TimeInterval?)
    case invalidResponse
    case parseFailure
}

private struct LRCLIBRecord: Decodable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: TimeInterval?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

private struct ParsedLyrics {
    let lines: [LyricLine]
    let isSynchronized: Bool
}
