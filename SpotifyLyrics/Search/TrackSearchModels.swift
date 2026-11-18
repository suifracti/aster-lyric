import Foundation

/// Search-facing metadata. SwiftUI and the lyrics/session layers use this
/// stable model instead of depending on Spotify Web API JSON DTOs.
public struct TrackArtistMetadata: Equatable, Hashable, Sendable {
    public let id: String?
    public let name: String
    public let uri: String?

    public init(id: String? = nil, name: String, uri: String? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
    }
}

public struct TrackSearchMetadata: Equatable, Hashable, Sendable {
    public let spotifyID: String?
    public let spotifyURI: String?
    public let title: String
    public let artists: [TrackArtistMetadata]
    public let artistDisplay: String
    public let album: String
    public let albumID: String?
    public let albumURI: String?
    public let duration: TimeInterval
    public let artworkURL: URL?
    public let isrc: String?
    public let explicit: Bool
    public let releaseDate: String?
    public let popularity: Int?

    public init(
        spotifyID: String? = nil,
        spotifyURI: String? = nil,
        title: String,
        artists: [TrackArtistMetadata],
        artistDisplay: String? = nil,
        album: String,
        albumID: String? = nil,
        albumURI: String? = nil,
        duration: TimeInterval,
        artworkURL: URL? = nil,
        isrc: String? = nil,
        explicit: Bool = false,
        releaseDate: String? = nil,
        popularity: Int? = nil
    ) {
        self.spotifyID = spotifyID
        self.spotifyURI = spotifyURI
        self.title = title
        self.artists = artists
        self.artistDisplay = artistDisplay ?? artists.map(\.name).joined(separator: ", ")
        self.album = album
        self.albumID = albumID
        self.albumURI = albumURI
        self.duration = duration
        self.artworkURL = artworkURL
        self.isrc = isrc
        self.explicit = explicit
        self.releaseDate = releaseDate
        self.popularity = popularity
    }
}

/// Metadata-only track search hit. Must never carry lyrics body text.
public struct TrackSearchResult: Identifiable, Equatable {
    public let id: String
    public let source: SongSearchSource
    public let track: Track
    public let confidence: Double
    public let artworkURL: URL?
    public let catalogMetadata: TrackSearchMetadata?
    public let savedLibraryEntry: PersonalLyricsLibraryEntry?
    public let savedPassage: LibraryPassageTarget?

    public init(
        id: String,
        source: SongSearchSource,
        track: Track,
        confidence: Double,
        artworkURL: URL? = nil,
        catalogMetadata: TrackSearchMetadata? = nil,
        savedLibraryEntry: PersonalLyricsLibraryEntry? = nil,
        savedPassage: LibraryPassageTarget? = nil
    ) {
        self.id = id
        self.source = source
        self.track = track
        self.confidence = max(0, min(confidence, 1))
        self.artworkURL = artworkURL
        self.catalogMetadata = catalogMetadata
        self.savedLibraryEntry = savedLibraryEntry
        self.savedPassage = savedPassage
    }

    public var spotifyID: String? { catalogMetadata?.spotifyID ?? track.spotifyId }
    public var spotifyURI: String? { catalogMetadata?.spotifyURI ?? track.spotifyURL?.absoluteString }
    public var artistDisplay: String { catalogMetadata?.artistDisplay ?? track.artist }
    public var album: String { catalogMetadata?.album ?? track.album }
    public var duration: TimeInterval { catalogMetadata?.duration ?? track.duration }
    public var isrc: String? { catalogMetadata?.isrc ?? track.isrc }

    public var metadataKey: String {
        TrackIdentity.metadataFingerprint(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration
        )
    }

    public var searchMergeKey: String {
        if let id = TrackIdentity.playbackID(for: track) { return id }
        if let id = TrackIdentity.canonicalSpotifyURI(spotifyID ?? spotifyURI) { return id }
        if let isrc = TrackIdentity.normalizeIdentifier(isrc) { return "isrc:\(isrc)" }
        return savedLibraryEntry?.trackStableKey ?? "metadata:\(metadataKey)"
    }

    var searchGroupKey: String {
        if TrackIdentity.playbackID(for: track) != nil || spotifyID != nil || spotifyURI != nil || isrc != nil || savedLibraryEntry != nil {
            return searchMergeKey
        }
        return TrackTextNormalizer.normalize(track.title) + "|" + TrackTextNormalizer.normalizeArtistToken(track.artist)
    }

    /// Compatibility bridge used by existing UI/session code.
    public func asSongSearchResult(lyrics: LyricsDocument? = nil) -> SongSearchResult {
        SongSearchResult(
            id: id,
            source: source,
            track: track,
            confidence: confidence,
            lyrics: lyrics,
            artworkURL: artworkURL,
            catalogMetadata: catalogMetadata,
            savedLibraryEntry: savedLibraryEntry, savedPassage: savedPassage
        )
    }
}

public enum TrackSearchState: Equatable {
    case idle
    case searching(SongSearchQuery)
    case results(SongSearchQuery, [TrackSearchResult])
    case noResults(SongSearchQuery)
    case failed(SongSearchQuery, String)

    public var query: SongSearchQuery? {
        switch self {
        case .idle: return nil
        case .searching(let query), .results(let query, _), .noResults(let query), .failed(let query, _):
            return query
        }
    }

    public var songSearchState: SongSearchState {
        switch self {
        case .idle:
            return .idle
        case .searching(let query):
            return .searching(query)
        case .results(let query, let results):
            return .results(query, results.map { $0.asSongSearchResult() })
        case .noResults(let query):
            return .noResults(query)
        case .failed(let query, let message):
            return .failed(query, message)
        }
    }
}

public typealias TrackSearchQuery = SongSearchQuery
public typealias TrackSearchError = SongSearchError
