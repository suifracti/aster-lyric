import Foundation

/// Experimental public catalog → lyric lookup → LRC download chain.
/// All candidates retain returned metadata for the shared SafeMatcher; this
/// provider never turns request identifiers into independent identity evidence.
public final class KugouExperimentalLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "酷狗（实验）"
    public let executionLane: LyricsProviderExecutionLane = .network
    public let timeoutInterval: TimeInterval
    private let session: URLSession
    private let maximumBodyBytes = 1_048_576

    public init(session: URLSession? = nil, timeout: TimeInterval = 12) {
        let boundedTimeout = timeout.isFinite ? min(20, max(0.1, timeout)) : 12
        timeoutInterval = boundedTimeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = min(6, boundedTimeout)
            configuration.timeoutIntervalForResource = boundedTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        if Task.isCancelled { return .failed(.cancelled) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutInterval
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .noMatch }
        do {
            guard let result = try await requestJSON(
                "https://songsearch.kugou.com/song_search_v2",
                query: [("keyword", "\(title) \(track.artist)"), ("page", "1"), ("pagesize", "10"), ("platform", "WebFilter")],
                deadline: deadline
            ) else { return .noMatch }
            guard let data = result["data"] as? [String: Any], let rows = data["lists"] as? [[String: Any]] else {
                return .failed(.parseFailure)
            }
            var seen = Set<String>()
            let songs = rows.compactMap(Song.init).filter { seen.insert($0.hash).inserted }.prefix(3)
            if !rows.isEmpty && songs.isEmpty { return .failed(.parseFailure) }
            var candidates: [LyricsCandidate] = []
            var firstFailure: LyricsFailure?
            for song in songs {
                do {
                    try Task.checkCancellation()
                    if let candidate = try await fetch(song: song, identity: identity, deadline: deadline) {
                        candidates.append(candidate)
                    }
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

    private func fetch(song: Song, identity: TrackIdentity, deadline: TimeInterval) async throws -> LyricsCandidate? {
        var query = [("ver", "1"), ("man", "yes"), ("client", "pc"), ("hash", song.hash)]
        if let mixID = song.mixID { query.append(("album_audio_id", mixID)) }
        guard let result = try await requestJSON("https://lyrics.kugou.com/search", query: query, deadline: deadline) else { return nil }
        guard let choices = result["candidates"] as? [[String: Any]] else { throw LyricsFailure.parseFailure }
        guard let first = choices.first else { return nil }
        guard let id = Self.identifier(first["id"]), let key = Self.identifier(first["accesskey"]) else {
            throw LyricsFailure.parseFailure
        }
        // Word timing first (KRC); the plain LRC when KRC is missing or unreadable.
        var lines: [LyricLine]?
        if let krc = try? await requestJSON(
            "https://lyrics.kugou.com/download",
            query: [("ver", "1"), ("client", "pc"), ("id", id), ("fmt", "krc"), ("charset", "utf8"), ("accesskey", key)],
            deadline: deadline
        ), let content = krc["content"] as? String, !content.isEmpty,
           let text = KRCParser.decrypt(base64: content),
           let document = KRCParser.parse(text, identity: identity, source: .kugouExperimental),
           document.lines.contains(where: { $0.timedSpans?.isEmpty == false }) {
            lines = document.lines
        }
        if lines == nil {
            guard let downloaded = try await requestJSON(
                "https://lyrics.kugou.com/download",
                query: [("ver", "1"), ("client", "pc"), ("id", id), ("fmt", "lrc"), ("charset", "utf8"), ("accesskey", key)],
                deadline: deadline
            ) else { return nil }
            guard let content = downloaded["content"] as? String else { throw LyricsFailure.parseFailure }
            if content.isEmpty { return nil }
            guard let bytes = Data(base64Encoded: content), let lrc = String(data: bytes, encoding: .utf8),
                  let document = LRCParser.parse(lrc, identity: identity, source: .kugouExperimental),
                  document.lines.allSatisfy({ $0.timestamp.isFinite && $0.timestamp >= 0 }) else {
                throw LyricsFailure.parseFailure
            }
            lines = document.lines
        }
        guard let lines else { return nil }
        // Access keys are short-lived download parameters, never provenance.
        let recordID = "kugou:\(song.hash):\(id)"
        return LyricsCandidate(
            id: recordID, identity: identity, title: song.title, artist: song.artist,
            album: song.album, duration: song.duration, lines: lines,
            isSynchronized: true, source: .kugouExperimental, confidence: 0.5,
            providerSourceID: recordID, providerName: name
        )
    }

    private func requestJSON(_ endpoint: String, query: [(String, String)], deadline: TimeInterval) async throws -> [String: Any]? {
        try Task.checkCancellation()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw LyricsFailure.timedOut }
        var components = URLComponents(string: endpoint)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = min(6, remaining)
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LyricsFailure.parseFailure }
        switch response.statusCode {
        case 404: return nil
        case 429: throw LyricsFailure.rateLimited(nil)
        case 200: break
        default: throw LyricsFailure.serverError(response.statusCode)
        }
        guard response.expectedContentLength <= maximumBodyBytes else { throw LyricsFailure.parseFailure }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw LyricsFailure.timedOut }
            guard data.count < maximumBodyBytes else { throw LyricsFailure.parseFailure }
            data.append(byte)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LyricsFailure.parseFailure }
        return json
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
        // Never surface request URLs, which may contain a download access key.
        return .parseFailure
    }

    private static func identifier(_ value: Any?) -> String? {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private struct Song {
        let hash: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let mixID: String?
        init?(_ row: [String: Any]) {
            guard let hash = identifier(row["FileHash"]), let title = row["SongName"] as? String,
                  let artist = row["SingerName"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.hash = hash
            self.title = title
            self.artist = artist
            self.album = row["AlbumName"] as? String ?? ""
            let seconds = identifier(row["Duration"]).flatMap(Double.init) ?? 0
            self.duration = seconds.isFinite && seconds > 0 ? seconds : 0
            self.mixID = identifier(row["MixSongID"])
        }
    }
}
