import Foundation

/// Experimental QQ Music lyrics provider.
/// Enabled because single-track audit for 水曜日の約束/Kawasaki.Rio proved
/// programmatic plain-text body is available for the correct artist, while
/// NetEase only had an empty catalog hit and LRCLIB had none.
/// Still experimental: undocumented endpoints; failures isolated.
public final class QQExperimentalLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "QQ Music Experimental"
    public let timeoutInterval: TimeInterval

    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession? = nil, timeout: TimeInterval = 6) {
        self.timeoutInterval = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: config)
        }
        self.timeout = timeout
    }

    public func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        if Task.isCancelled { return .failed(.cancelled) }
        do {
            let songs = try await search(title: track.title, artist: track.artist)
            if Task.isCancelled { return .failed(.cancelled) }
            guard !songs.isEmpty else { return .noMatch }

            var candidates: [LyricsCandidate] = []
            for song in songs.prefix(6) {
                if Task.isCancelled { return .failed(.cancelled) }
                guard let lyric = try await fetchLyric(songmid: song.songmid), !lyric.original.isEmpty else {
                    continue
                }
                let conf = score(song: song, track: track)
                // Reject obvious wrong-artist same-title hits for auto path.
                if conf < 0.45 { continue }

                let lines: [LyricLine]
                let synced: Bool
                if let doc = LRCParser.parse(lyric.original, identity: identity, source: .qqExperimental), !doc.lines.isEmpty {
                    let translated = TimedLyricsCompanionMerger.merge(
                        lyric.translation,
                        into: doc.lines,
                        layer: .translation
                    )
                    lines = TimedLyricsCompanionMerger.merge(
                        lyric.romaji,
                        into: translated,
                        layer: .romaji
                    )
                    synced = doc.isSynchronized
                } else {
                    let plainLines = lyric.original
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .map { LyricLine(timestamp: 0, originalText: $0) }
                    let translated = PlainLyricsCompanionMerger.merge(
                        lyric.translation,
                        original: lyric.original,
                        into: plainLines,
                        layer: .translation
                    )
                    lines = PlainLyricsCompanionMerger.merge(
                        lyric.romaji,
                        original: lyric.original,
                        into: translated,
                        layer: .romaji
                    )
                    synced = false
                }
                guard !lines.isEmpty else { continue }
                candidates.append(
                    LyricsCandidate(
                        id: "qq:\(song.songmid)",
                        identity: identity,
                        title: song.name,
                        artist: song.artists.joined(separator: ", "),
                        album: song.album,
                        duration: song.duration,
                        lines: lines,
                        isSynchronized: synced,
                        source: .qqExperimental,
                        confidence: conf,
                        providerSourceID: "qq:\(song.songmid)"
                    )
                )
            }

            if candidates.isEmpty {
                LyricsE2ELog.log("QQ no body candidates for title=\(track.title) artist=\(track.artist)")
                return .noMatch
            }
            let sorted = candidates.sorted { $0.confidence > $1.confidence }
            if let best = sorted.first {
                LyricsE2ELog.log("QQ best mid-candidate title=\(best.title) artist=\(best.artist) conf=\(best.confidence) lines=\(best.lines.count) sync=\(best.isSynchronized)")
            }
            if let best = sorted.first, best.confidence >= 0.75,
               sorted.dropFirst().first.map({ best.confidence - $0.confidence >= 0.05 }) ?? true {
                LyricsE2ELog.log("QQ MATCH lines=\(best.lines.count) conf=\(best.confidence) first=\(best.lines.first?.originalText ?? "")")
                return .match(
                    LyricsDocument(
                        identity: identity,
                        title: best.title,
                        artist: best.artist,
                        album: best.album,
                        duration: best.duration,
                        lines: best.lines,
                        isSynchronized: best.isSynchronized,
                        source: .qqExperimental,
                        confidence: best.confidence,
                        providerSourceID: best.providerSourceID
                    )
                )
            }
            return .candidates(sorted)
        } catch let failure as LyricsFailure {
            return .failed(failure)
        } catch {
            if Task.isCancelled { return .failed(.cancelled) }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut: return .failed(.timedOut)
                case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                    return .failed(.networkUnavailable)
                case .cancelled: return .failed(.cancelled)
                default: break
                }
            }
            return .failed(.unknown(error.localizedDescription))
        }
    }

    private func search(title: String, artist: String) async throws -> [QQSong] {
        var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        components.queryItems = [
            URLQueryItem(name: "w", value: "\(title) \(artist)"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "8"),
            URLQueryItem(name: "cr", value: "1"),
            URLQueryItem(name: "g_tk", value: "5381")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsFailure.parseFailure }
        guard (200..<300).contains(http.statusCode) else { throw LyricsFailure.serverError(http.statusCode) }
        let decoded = try JSONDecoder().decode(QQSearchResponse.self, from: data)
        return (decoded.data?.song?.list ?? []).compactMap { $0.asSong }
    }

    private func fetchLyric(songmid: String) async throws -> QQLyricPayload? {
        var components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        components.queryItems = [
            URLQueryItem(name: "songmid", value: songmid),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nobase64", value: "1"),
            URLQueryItem(name: "g_tk", value: "5381")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsFailure.parseFailure }
        guard (200..<300).contains(http.statusCode) else { throw LyricsFailure.serverError(http.statusCode) }
        let decoded = try JSONDecoder().decode(QQLyricResponse.self, from: data)
        if let ret = decoded.retcode, ret != 0 {
            // -1310/-1901 often mean login/anti-abuse or missing lyric
            return nil
        }
        guard let original = decodedLyricsField(decoded.lyric), !original.isEmpty else { return nil }
        return QQLyricPayload(
            original: original,
            translation: decodedLyricsField(decoded.trans),
            romaji: decodedLyricsField(decoded.roma)
        )
    }

    private func decodedLyricsField(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("[") && !value.contains("\n"),
           let data = Data(base64Encoded: value),
           let decoded = String(data: data, encoding: .utf8),
           decoded.contains("[") || decoded.contains("\n") {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private func score(song: QQSong, track: Track) -> Double {
        var score = 0.3
        let nt = TrackTextNormalizer.normalize(track.title)
        let ns = TrackTextNormalizer.normalize(song.name)
        if nt == ns { score += 0.3 } else if ns.contains(nt) || nt.contains(ns) { score += 0.12 }

        let na = TrackTextNormalizer.normalize(
            TrackTextNormalizer.splitFeaturedArtists(track.artist).primary
        )
        let artists = TrackTextNormalizer.normalize(song.artists.joined(separator: " "))
        if artists == na || artists.contains(na) || na.contains(artists) {
            score += 0.3
        } else {
            // Hard penalty: 水曜日の約束 has many same-title different artists.
            score -= 0.35
        }

        if track.duration > 0, song.duration > 0 {
            let diff = abs(track.duration - song.duration)
            if diff <= 2 { score += 0.15 }
            else if diff <= 8 { score += 0.08 }
            else if diff > 25 { score -= 0.2 }
        }

        let candTags = TrackTextNormalizer.extractVersionTags(fromTitle: song.name)
        let metaTags = TrackTextNormalizer.extractVersionTags(fromTitle: track.title)
        if candTags.contains(.live), metaTags.isEmpty { score -= 0.25 }
        return min(1, max(0.05, score))
    }
}

private struct QQSong {
    let songmid: String
    let name: String
    let artists: [String]
    let album: String
    let duration: TimeInterval
}

private struct QQLyricPayload {
    let original: String
    let translation: String?
    let romaji: String?
}

private struct QQSearchResponse: Decodable {
    let data: QQSearchData?
}

private struct QQSearchData: Decodable {
    let song: QQSongList?
}

private struct QQSongList: Decodable {
    let list: [QQSongDTO]?
}

private struct QQSongDTO: Decodable {
    let songmid: String?
    let songname: String?
    let singer: [QQSingerDTO]?
    let albumname: String?
    let interval: Int?

    var asSong: QQSong? {
        guard let songmid, let songname else { return nil }
        return QQSong(
            songmid: songmid,
            name: songname,
            artists: (singer ?? []).map(\.name),
            album: albumname ?? "",
            duration: TimeInterval(interval ?? 0)
        )
    }
}

private struct QQSingerDTO: Decodable {
    let name: String
}

private struct QQLyricResponse: Decodable {
    let retcode: Int?
    let code: Int?
    let lyric: String?
    let trans: String?
    let roma: String?
}
