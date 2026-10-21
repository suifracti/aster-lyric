import Foundation

public struct SongSearchQuery: Equatable, Hashable {
    public let text: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?

    public init(
        text: String = "",
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.duration = duration
    }

    public init(track: Track) {
        self.init(
            text: "\(track.title) \(track.artist)",
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration
        )
    }

    public var normalizedText: String {
        Self.normalizeSearchText(text)
    }

    public var tokens: [String] {
        normalizedText.split(separator: " ").map(String.init)
    }

    public var isEmpty: Bool {
        normalizedText.isEmpty && [title, artist, album].compactMap { $0 }.allSatisfy {
            Self.normalizeSearchText($0).isEmpty
        }
    }

    /// Resolve a direct Spotify track URL, URI, or bare track id before doing
    /// a free-text catalog request.
    public var spotifyTrackID: String? {
        Self.spotifyTrackID(from: text)
    }

    public var spotifyQueryText: String {
        if let title, !title.isEmpty, let artist, !artist.isEmpty {
            return "track:\"\(title)\" artist:\"\(artist)\""
        }
        if let title, !title.isEmpty {
            return "track:\"\(title)\""
        }
        return text
    }

    public static func spotifyTrackID(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("spotify:track:") {
            let id = String(trimmed.dropFirst("spotify:track:".count))
                .split(separator: "?").first.map(String.init)
            return isLikelySpotifyID(id)
        }

        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host == "open.spotify.com" || host == "play.spotify.com" {
            let components = url.pathComponents
            if let trackIndex = components.firstIndex(of: "track"),
               components.indices.contains(trackIndex + 1) {
                return isLikelySpotifyID(components[trackIndex + 1])
            }
        }

        return isLikelySpotifyID(trimmed) != nil ? trimmed : nil
    }

    private static func isLikelySpotifyID(_ value: String?) -> String? {
        guard let value, value.count == 22,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) ||
                  (65...90).contains($0.value) ||
                  (97...122).contains($0.value)
              }) else { return nil }
        return value
    }

    public static func normalizeSearchText(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { $0.isWhitespace || $0.isNewline }
            .joined(separator: " ")
            .lowercased()
    }
}

public enum SongSearchSource: String, CaseIterable, Identifiable {
    case local
    case spotifyCurrentTrack
    case spotifyCatalog
    case lrclib

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: return "本地歌词"
        case .spotifyCurrentTrack: return "Spotify 当前歌曲"
        case .spotifyCatalog: return "Spotify 在线曲库"
        case .lrclib: return "LRCLIB"
        }
    }
}

/// Compatibility search result. Track search paths leave `lyrics` nil; lyrics body
/// is resolved later by `LyricsSearchManager` / local index for a confirmed identity.
public struct SongSearchResult: Identifiable, Equatable {
    public let id: String
    public let source: SongSearchSource
    public let track: Track
    public let confidence: Double
    public let lyrics: LyricsDocument?
    public let artworkURL: URL?
    public let catalogMetadata: TrackSearchMetadata?
    public let savedLibraryEntry: PersonalLyricsLibraryEntry?

    public init(
        id: String,
        source: SongSearchSource,
        track: Track,
        confidence: Double,
        lyrics: LyricsDocument? = nil,
        artworkURL: URL? = nil,
        catalogMetadata: TrackSearchMetadata? = nil,
        savedLibraryEntry: PersonalLyricsLibraryEntry? = nil
    ) {
        self.id = id
        self.source = source
        self.track = track
        self.confidence = max(0, min(confidence, 1))
        self.lyrics = lyrics
        self.artworkURL = artworkURL
        self.catalogMetadata = catalogMetadata
        self.savedLibraryEntry = savedLibraryEntry
    }

    public var searchMergeKey: String {
        asTrackSearchResult().searchMergeKey
    }

    public func asTrackSearchResult() -> TrackSearchResult {
        TrackSearchResult(
            id: id,
            source: source,
            track: track,
            confidence: confidence,
            artworkURL: artworkURL,
            catalogMetadata: catalogMetadata,
            savedLibraryEntry: savedLibraryEntry
        )
    }
}

public enum SongSearchState: Equatable {
    case idle
    case searching(SongSearchQuery)
    case results(SongSearchQuery, [SongSearchResult])
    case noResults(SongSearchQuery)
    case failed(SongSearchQuery, String)

    public var query: SongSearchQuery? {
        switch self {
        case .idle: return nil
        case .searching(let query), .results(let query, _), .noResults(let query), .failed(let query, _):
            return query
        }
    }
}

public enum SongSearchError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case forbidden
    case badRequest
    case notFound
    case networkUnavailable
    case timedOut
    case rateLimited(TimeInterval?)
    case serverError(Int)
    case parseFailure
    case cancelled
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置 Spotify Client ID"
        case .unauthorized: return "尚未授权 Spotify 在线曲库"
        case .forbidden: return "Spotify 拒绝了目录请求"
        case .badRequest: return "Spotify 搜索请求无效"
        case .notFound: return "Spotify 曲目不存在"
        case .networkUnavailable: return "网络不可用"
        case .timedOut: return "搜索请求超时"
        case .rateLimited: return "搜索服务限流"
        case .serverError(let code): return "搜索服务错误（HTTP \(code)）"
        case .parseFailure: return "搜索结果解析失败"
        case .cancelled: return "搜索已取消"
        case .unknown(let message): return message.isEmpty ? "未知搜索错误" : message
        }
    }
}

enum SongSearchScoring {
    static func score(track: Track, query: SongSearchQuery) -> Double {
        let titleScore = fieldScore(track.title, explicit: query.title, query: query)
        let artistScore = fieldScore(track.artist, explicit: query.artist, query: query)
        let albumScore = fieldScore(track.album, explicit: query.album, query: query)

        var score = titleScore * 0.55 + artistScore * 0.35 + albumScore * 0.10

        if let duration = query.duration, duration > 0, track.duration > 0 {
            let delta = abs(track.duration - duration)
            if delta <= 2 { score += 0.05 }
            else if delta >= 15 { score -= 0.15 }
        }

        if score < 0.20, !query.tokens.isEmpty {
            let haystack = SongSearchQuery.normalizeSearchText("\(track.title) \(track.artist) \(track.album)")
            let matched = query.tokens.filter { haystack.contains($0) }.count
            if matched == query.tokens.count {
                score = max(score, 0.45)
            } else if matched > 0 {
                score = max(score, Double(matched) / Double(query.tokens.count) * 0.4)
            }
        }

        return max(0, min(score, 1))
    }

    private static func fieldScore(_ value: String, explicit: String?, query: SongSearchQuery) -> Double {
        let normalizedValue = SongSearchQuery.normalizeSearchText(value)
        if let explicit, !explicit.isEmpty {
            let normalizedExplicit = SongSearchQuery.normalizeSearchText(explicit)
            if normalizedValue == normalizedExplicit { return 1 }
            if normalizedValue.contains(normalizedExplicit) || normalizedExplicit.contains(normalizedValue) {
                return 0.8
            }
            return tokenOverlap(normalizedValue, normalizedExplicit)
        }

        guard !query.tokens.isEmpty else { return 0 }
        return tokenOverlap(normalizedValue, query.normalizedText)
    }

    private static func tokenOverlap(_ value: String, _ other: String) -> Double {
        let left = Set(value.split(separator: " ").map(String.init))
        let right = Set(other.split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        return Double(intersection) / Double(max(left.count, right.count))
    }
}
