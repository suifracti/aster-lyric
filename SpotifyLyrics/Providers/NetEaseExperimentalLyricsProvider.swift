import Foundation

/// Experimental, undocumented NetEase Cloud Music lyrics probe.
/// Not a core/default shipping source. Failures are isolated.
/// Catalog hit ≠ lyrics body (e.g. あやふや id may return empty lrc).
public final class NetEaseExperimentalLyricsProvider: LyricsProvider, @unchecked Sendable {
    public let name = "NetEase Experimental"
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
            let songs = try await searchSongs(title: track.title, artist: track.artist)
            if Task.isCancelled { return .failed(.cancelled) }
            guard !songs.isEmpty else { return .noMatch }

            var candidates: [LyricsCandidate] = []
            var exactMetadataOnlySong: NetEaseSong?
            for song in songs.prefix(5) {
                if Task.isCancelled { return .failed(.cancelled) }
                guard let lyric = try await fetchLyric(songID: song.id) else {
                    if exactMetadataOnlySong == nil,
                       hasExactCatalogIdentity(
                           title: song.name,
                           titleAliases: song.declaredTitleAliases,
                           artist: song.artists.joined(separator: ", "),
                           album: song.album,
                           duration: song.duration,
                           track: track,
                           identity: identity
                       ) {
                        exactMetadataOnlySong = song
                    }
                    continue
                }
                let parsed = parse(lyric: lyric, track: track, song: song, identity: identity)
                guard let document = parsed else { continue }
                candidates.append(
                    LyricsCandidate(
                        id: "netease:\(song.id)",
                        identity: identity,
                        title: song.name,
                        artist: song.artists.joined(separator: ", "),
                        album: song.album,
                        duration: song.duration,
                        lines: document.lines,
                        isSynchronized: document.isSynchronized,
                        source: .neteaseExperimental,
                        confidence: score(song: song, track: track),
                        providerSourceID: "netease:\(song.id)",
                        declaredTitleAliases: song.declaredTitleAliases
                    )
                )
            }

            if let exactMetadataOnlySong,
               !candidates.contains(where: {
                   hasExactCatalogIdentity(
                       title: $0.title,
                       titleAliases: $0.declaredTitleAliases,
                       artist: $0.artist,
                       album: $0.album,
                       duration: $0.duration,
                       track: track,
                       identity: identity
                   )
               }) {
                let artist = exactMetadataOnlySong.artists.joined(separator: ", ")
                return .failed(.lyricsBodyUnavailable(
                    "目录命中“\(exactMetadataOnlySong.name)”（\(artist)），但该来源没有歌词正文。"
                ))
            }

            if candidates.isEmpty {
                // Track may exist without lyric body.
                return .noMatch
            }

            let sorted = candidates.sorted { $0.confidence > $1.confidence }
            if let best = sorted.first, best.confidence >= 0.8,
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
                        source: .neteaseExperimental,
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

    private func searchSongs(title: String, artist: String) async throws -> [NetEaseSong] {
        var components = URLComponents(string: "https://music.163.com/api/search/get/web")!
        components.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "8")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsFailure.parseFailure }
        guard (200..<300).contains(http.statusCode) else {
            throw LyricsFailure.serverError(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(NetEaseSearchResponse.self, from: data)
        return (decoded.result?.songs ?? []).map(\.asSong)
    }

    private func fetchLyric(songID: Int) async throws -> NetEaseLyricPayload? {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1"),
            URLQueryItem(name: "yv", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsFailure.parseFailure }
        guard (200..<300).contains(http.statusCode) else {
            throw LyricsFailure.serverError(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(NetEaseLyricResponse.self, from: data)
        let lrc = decoded.lrc?.lyric?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tlyric = decoded.tlyric?.lyric?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let yrc = decoded.yrc?.lyric?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if lrc.isEmpty && yrc.isEmpty { return nil }
        return NetEaseLyricPayload(
            lrc: lrc,
            tlyric: tlyric.isEmpty ? nil : tlyric,
            yrc: yrc.isEmpty ? nil : yrc
        )
    }

    private func parse(
        lyric: NetEaseLyricPayload,
        track: Track,
        song: NetEaseSong,
        identity: TrackIdentity
    ) -> LyricsDocument? {
        if let yrcContent = lyric.yrc,
           let yrcDoc = YRCParser.parse(yrcContent, identity: identity, source: .neteaseExperimental) {
            let lines = TimedLyricsCompanionMerger.merge(
                lyric.tlyric,
                into: yrcDoc.lines,
                layer: .translation
            )
            return LyricsDocument(
                identity: identity,
                title: song.name,
                artist: song.artists.joined(separator: ", "),
                album: song.album,
                duration: song.duration,
                lines: lines,
                isSynchronized: yrcDoc.isSynchronized,
                source: .neteaseExperimental,
                confidence: score(song: song, track: track),
                providerSourceID: "netease:\(song.id)"
            )
        }

        if let synced = LRCParser.parse(
            lyric.lrc,
            identity: identity,
            source: .neteaseExperimental
        ) {
            let lines = TimedLyricsCompanionMerger.merge(
                lyric.tlyric,
                into: synced.lines,
                layer: .translation
            )
            return LyricsDocument(
                identity: identity,
                title: song.name,
                artist: song.artists.joined(separator: ", "),
                album: song.album,
                duration: song.duration,
                lines: lines,
                isSynchronized: synced.isSynchronized,
                source: .neteaseExperimental,
                confidence: score(song: song, track: track),
                providerSourceID: "netease:\(song.id)"
            )
        }

        let plain = lyric.lrc
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            .map { LyricLine(timestamp: 0, originalText: $0) }
        guard !plain.isEmpty else { return nil }
        return LyricsDocument(
            identity: identity,
            title: song.name,
            artist: song.artists.joined(separator: ", "),
            album: song.album,
            duration: song.duration,
            lines: plain,
            isSynchronized: false,
            source: .neteaseExperimental,
            confidence: score(song: song, track: track),
            providerSourceID: "netease:\(song.id)"
        )
    }

    private func score(song: NetEaseSong, track: Track) -> Double {
        var score = 0.35
        let nt = TrackTextNormalizer.normalize(track.title)
        let ns = TrackTextNormalizer.normalize(song.name)
        if nt == ns { score += 0.3 } else if ns.contains(nt) || nt.contains(ns) { score += 0.15 }
        let na = TrackTextNormalizer.normalize(track.artist)
        let artists = TrackTextNormalizer.normalize(song.artists.joined(separator: " "))
        if artists.contains(na) || na.contains(artists) { score += 0.25 }
        if track.duration > 0, song.duration > 0 {
            let diff = abs(track.duration - song.duration)
            if diff <= 2 { score += 0.15 }
            else if diff <= 5 { score += 0.08 }
            else if diff > 20 { score -= 0.2 }
        }
        let tags = TrackTextNormalizer.extractVersionTags(fromTitle: song.name)
        if tags.contains(.live), TrackTextNormalizer.extractVersionTags(fromTitle: track.title).isEmpty {
            score -= 0.25
        }
        return min(1, max(0.05, score))
    }

    private func hasExactCatalogIdentity(
        title: String,
        titleAliases: [String],
        artist: String,
        album: String,
        duration: TimeInterval,
        track: Track,
        identity: TrackIdentity
    ) -> Bool {
        let candidate = LyricsCandidate(
            id: "netease-metadata-only",
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lines: [],
            source: .neteaseExperimental,
            confidence: 0,
            declaredTitleAliases: titleAliases
        )
        let decision = LyricsSafeMatcher.decide(
            candidate: candidate,
            metadata: TrackMetadata.bootstrap(from: track)
        )
        let reasons = Set(decision.reasons)
        let hasExactTitleEvidence = !reasons.isDisjoint(with: [
            "titleExact", "titleTypographyExact", "titleParallelExact", "titleLatinSpacingExact",
            "titleProviderAliasConfirmed", "titleReadingExact"
        ])
        let hasExactArtistEvidence = reasons.contains("primaryArtistExact")
            || reasons.contains("primaryArtistReadingExact")
        return !decision.hardReject
            && !decision.versionConflict
            && hasExactTitleEvidence
            && hasExactArtistEvidence
            && reasons.contains("durationClose")
    }
}

private struct NetEaseSong {
    let id: Int
    let name: String
    let declaredTitleAliases: [String]
    let artists: [String]
    let album: String
    let duration: TimeInterval
}

private struct NetEaseLyricPayload {
    let lrc: String
    let tlyric: String?
    let yrc: String?
}

private struct NetEaseSearchResponse: Decodable {
    let result: NetEaseSearchResult?
}

private struct NetEaseSearchResult: Decodable {
    let songs: [NetEaseSongDTO]?
}

private struct NetEaseSongDTO: Decodable {
    let id: Int
    let name: String
    let alias: [String]?
    let transNames: [String]?
    let artists: [NetEaseArtistDTO]?
    let album: NetEaseAlbumDTO?
    let duration: Int?

    var asSong: NetEaseSong {
        var seen = Set<String>()
        let titleAliases = ((alias ?? []) + (transNames ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                let normalized = TrackTextNormalizer.normalize(value)
                guard !normalized.isEmpty,
                      normalized != TrackTextNormalizer.normalize(name),
                      seen.insert(normalized).inserted else { return false }
                return true
            }
        return NetEaseSong(
            id: id,
            name: name,
            declaredTitleAliases: titleAliases,
            artists: (artists ?? []).map(\.name),
            album: album?.name ?? "",
            duration: TimeInterval(duration ?? 0) / 1000.0
        )
    }
}

private struct NetEaseArtistDTO: Decodable { let name: String }
private struct NetEaseAlbumDTO: Decodable { let name: String? }

private struct NetEaseLyricResponse: Decodable {
    let lrc: NetEaseLyricLine?
    let tlyric: NetEaseLyricLine?
    let yrc: NetEaseLyricLine?
}

private struct NetEaseLyricLine: Decodable {
    let lyric: String?
}
