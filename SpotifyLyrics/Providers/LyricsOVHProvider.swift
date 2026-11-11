import Foundation

/// Plain-text aggregator. The response supplies no independent track metadata;
/// the title/artist below are query echoes and must never authorize auto-adoption.
public final class LyricsOVHProvider: LyricsProvider, @unchecked Sendable {
    public let name = "lyrics.ovh"
    public let executionLane: LyricsProviderExecutionLane = .network
    public let timeoutInterval: TimeInterval
    private let session: URLSession
    private let maximumBodyBytes = 1_048_576

    /// 267 real lookups (2026-10-24…11-10) gave 11 candidates and no adoption,
    /// while a miss usually took 5–6 s. Three seconds keeps the fast answers.
    public init(session: URLSession? = nil, timeout: TimeInterval = 3) {
        let boundedTimeout = timeout.isFinite ? min(15, max(0.1, timeout)) : 3
        timeoutInterval = boundedTimeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = boundedTimeout
            configuration.timeoutIntervalForResource = boundedTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        if Task.isCancelled { return .failed(.cancelled) }
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { return .noMatch }
        // Encode each path segment independently, including slash, percent and
        // query delimiters. Never let a song title create another URL segment.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~")
        guard let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)") else {
            return .failed(.parseFailure)
        }
        let recordID = "lyricsOVH:\(encodedArtist)/\(encodedTitle)"
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SpotifyLyrics/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { return .failed(.parseFailure) }
            switch response.statusCode {
            case 404: return .noMatch
            case 429: return .failed(.rateLimited(nil))
            case 200: break
            default: return .failed(.serverError(response.statusCode))
            }
            guard response.expectedContentLength <= maximumBodyBytes else { return .failed(.parseFailure) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBodyBytes else { return .failed(.parseFailure) }
                data.append(byte)
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let lines = payload.lyrics.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { LyricLine(timestamp: 0, originalText: $0) }
            guard !lines.isEmpty else { return .noMatch }
            return .candidates([LyricsCandidate(
                id: recordID, identity: identity, title: title, artist: artist,
                album: "", duration: 0, lines: lines, isSynchronized: false,
                source: .lyricsOVH, confidence: 0, providerSourceID: recordID,
                providerName: name
            )])
        } catch {
            if Task.isCancelled || error is CancellationError { return .failed(.cancelled) }
            if let error = error as? URLError {
                switch error.code {
                case .cancelled: return .failed(.cancelled)
                case .timedOut: return .failed(.timedOut)
                default: return .failed(.networkUnavailable)
                }
            }
            return .failed(.parseFailure)
        }
    }

    private struct Payload: Decodable { let lyrics: String }
}
