import Foundation

// MARK: - Spotify Web API DTOs

/// These DTOs are private to the Spotify integration boundary. UI and lyrics
/// code consume TrackSearchMetadata/Track, never these response-shaped types.
struct SpotifyPagingDTO<Item: Decodable>: Decodable {
    let href: String?
    let limit: Int?
    let next: String?
    let offset: Int?
    let previous: String?
    let total: Int?
    let items: [Item]
}

struct SpotifySearchResponseDTO: Decodable {
    let tracks: SpotifyPagingDTO<SpotifyTrackDTO>
}

struct SpotifyTrackDTO: Decodable {
    let album: SpotifyAlbumDTO
    let artists: [SpotifyArtistDTO]
    let durationMS: Int
    let explicit: Bool
    let externalIDs: SpotifyExternalIDsDTO?
    let id: String
    let name: String
    let popularity: Int?
    let uri: String

    enum CodingKeys: String, CodingKey {
        case album
        case artists
        case durationMS = "duration_ms"
        case explicit
        case externalIDs = "external_ids"
        case id
        case name
        case popularity
        case uri
    }
}

struct SpotifyAlbumDTO: Decodable {
    let albumType: String?
    let artists: [SpotifyArtistDTO]?
    let id: String?
    let images: [SpotifyImageDTO]
    let name: String
    let releaseDate: String?
    let uri: String?

    enum CodingKeys: String, CodingKey {
        case albumType = "album_type"
        case artists
        case id
        case images
        case name
        case releaseDate = "release_date"
        case uri
    }
}

struct SpotifyArtistDTO: Decodable {
    let id: String?
    let name: String
    let uri: String?
}

struct SpotifyImageDTO: Decodable {
    let height: Int?
    let url: String
    let width: Int?
}

struct SpotifyExternalIDsDTO: Decodable {
    let isrc: String?
}

struct SpotifyTokenResponseDTO: Decodable {
    let accessToken: String
    let tokenType: String?
    let scope: String?
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

// MARK: - Playlists

struct SpotifyPlaylistPageDTO: Decodable {
    let items: [SpotifyPlaylistDTO]
    let total: Int?
    let next: String?
}

struct SpotifyPlaylistDTO: Decodable {
    let id: String
    let name: String
    let snapshotID: String?
    let images: [SpotifyImageDTO]?
    let items: SpotifyPlaylistCountDTO?
    /// Older responses still carry the deprecated `tracks` count object.
    let tracks: SpotifyPlaylistCountDTO?
    let collaborative: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case snapshotID = "snapshot_id"
        case images
        case items
        case tracks
        case collaborative
    }

    var trackCount: Int { items?.total ?? tracks?.total ?? 0 }
}

struct SpotifyPlaylistCountDTO: Decodable {
    let total: Int?
}

struct SpotifyPlaylistItemPageDTO: Decodable {
    let items: [SpotifyPlaylistItemDTO]
    let total: Int?
    let next: String?
}

struct SpotifyPlaylistItemDTO: Decodable {
    /// Current responses use `item`; older ones use the deprecated `track`.
    let item: SpotifyPlaylistItemTrackDTO?
    let track: SpotifyPlaylistItemTrackDTO?

    var trackIDs: [String] {
        let value = item ?? track
        return [value?.id, value?.linked_from?.id].compactMap { $0 }
    }
}

struct SpotifyPlaylistItemTrackDTO: Decodable {
    let id: String?
    let linked_from: OriginalTrack?
    struct OriginalTrack: Decodable { let id: String? }
}

struct SpotifyAPIErrorEnvelope: Decodable {
    let error: SpotifyAPIErrorBody
}

struct SpotifyAPIErrorBody: Decodable {
    let status: Int?
    let message: String?
}
