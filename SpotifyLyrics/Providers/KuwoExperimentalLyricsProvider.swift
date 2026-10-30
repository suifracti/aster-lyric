import Foundation

/// Public Kuwo catalog + line-timed lyric endpoints. Results retain provider
/// metadata and remain candidates for the shared identity matcher to evaluate.
public final class KuwoExperimentalLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "Kuwo Experimental"
    public let timeoutInterval: TimeInterval
    private let session: URLSession
    private static let bodyLimit = 524_288

    public init(session: URLSession? = nil, timeout: TimeInterval = 6) {
        timeoutInterval = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        do {
            try Task.checkCancellation()
            let payload = try await request("https://search.kuwo.cn/r.s", parameters: [
                "all": "\(track.title) \(track.artist)", "ft": "music", "itemset": "web_2013",
                "client": "kt", "pn": "0", "rn": "10", "rformat": "json", "encoding": "utf8", "pcjson": "1"
            ], referer: "https://www.kuwo.cn/")
            guard let records = payload["abslist"] as? [[String: Any]] else { throw LyricsFailure.parseFailure }
            var seen = Set<String>()
            let songs = records.compactMap(Song.init).filter { seen.insert($0.id).inserted }
                .sorted { score($0, track: track, identity: identity) > score($1, track: track, identity: identity) }
            var candidates: [LyricsCandidate] = []
            var firstFailure: LyricsFailure?
            // One search and at most three serial bodies; no nested fan-out.
            for song in songs.prefix(3) {
                try Task.checkCancellation()
                do {
                    let body = try await request("https://kuwo.cn/openapi/v1/www/lyric/getlyric",
                        parameters: ["musicId": song.id], referer: "https://kuwo.cn/")
                    guard let data = body["data"] as? [String: Any] else {
                        if body["data"] is NSNull { continue }
                        throw LyricsFailure.parseFailure
                    }
                    // Kuwo returns a successful empty object when this recording has no lyrics.
                    if data.isEmpty, body["code"] as? Int == 200, body["success"] as? Bool == true { continue }
                    guard let records = data["lrclist"] as? [[String: Any]] else { throw LyricsFailure.parseFailure }
                    let lines = records.compactMap { record -> LyricLine? in
                        guard let rawTime = record["time"] as? String,
                              let time = Double(rawTime), time.isFinite, time >= 0,
                              let rawText = record["lineLyric"] as? String else { return nil }
                        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return LyricLine(timestamp: time, originalText: text)
                    }.enumerated().sorted {
                        $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
                    }.map(\.element)
                    guard !lines.isEmpty else { continue }
                    candidates.append(song.candidate(identity: identity, lines: lines,
                        confidence: score(song, track: track, identity: identity)))
                } catch {
                    let failure = Self.failure(error)
                    if failure == .cancelled { return .failed(.cancelled) }
                    if firstFailure == nil { firstFailure = failure }
                }
            }
            if !candidates.isEmpty { return .candidates(candidates) }
            if let firstFailure { return .failed(firstFailure) }
            return .noMatch
        } catch { return .failed(Self.failure(error)) }
    }

    private func score(_ song: Song, track: Track, identity: TrackIdentity) -> Double {
        LyricsMatcher.score(track: track, candidate: song.candidate(identity: identity, lines: [], confidence: 0))
    }

    private func request(_ endpoint: String, parameters: [String: String], referer: String) async throws -> [String: Any] {
        var components = URLComponents(string: endpoint)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeoutInterval
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw LyricsFailure.parseFailure }
        guard (200..<300).contains(http.statusCode) else {
            bytes.task.cancel()
            if http.statusCode == 429 { throw LyricsFailure.rateLimited(nil) }
            throw LyricsFailure.serverError(http.statusCode)
        }
        guard response.expectedContentLength <= Self.bodyLimit else { bytes.task.cancel(); throw LyricsFailure.parseFailure }
        var data = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.bodyLimit else { throw LyricsFailure.parseFailure }
                data.append(byte)
            }
        } catch { bytes.task.cancel(); throw error }
        guard String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { throw LyricsFailure.parseFailure }
        return dictionary
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

    private struct Song {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval

        init?(_ record: [String: Any]) {
            guard let rawID = record["MUSICRID"] as? String,
                  let title = record["SONGNAME"] as? String,
                  let artist = record["ARTIST"] as? String,
                  let rawDuration = record["DURATION"] as? String,
                  let duration = Double(rawDuration), duration.isFinite, duration > 0 else { return nil }
            let id = rawID.hasPrefix("MUSIC_") ? String(rawID.dropFirst(6)) : rawID
            guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.id = id
            self.title = title
            self.artist = artist
            self.album = record["ALBUM"] as? String ?? ""
            self.duration = duration
        }

        func candidate(identity: TrackIdentity, lines: [LyricLine], confidence: Double) -> LyricsCandidate {
            LyricsCandidate(id: "kuwo:\(id)", identity: identity, title: title, artist: artist,
                album: album, duration: duration, lines: lines, isSynchronized: true,
                source: .kuwoExperimental, confidence: confidence, providerSourceID: "kuwo:\(id)")
        }
    }
}
