import Foundation

/// The search field reads the playback snapshot already accepted by the app.
public final class CurrentTrackResolver: TrackSearchProvider {
    public let name = "Current Track"
    public let isLocal = true
    private let current: @MainActor () async -> (Track, PlaybackSourceIdentity)?

    public init(playbackProvider: PlaybackProvider) {
        current = {
            let snapshot = await playbackProvider.refresh()
            guard snapshot.status.isReady, let track = snapshot.track else { return nil }
            return (Track(providerTrack: track), snapshot.sourceIdentity)
        }
    }

    init(current: @escaping @MainActor () -> (Track, PlaybackSourceIdentity)?) {
        self.current = current
    }

    public func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] {
        guard !query.isEmpty, let (track, source) = await current(), source != .mockPreview else { return [] }
        let score = SongSearchScoring.score(track: track, query: query)
        guard score >= 0.35 else { return [] }
        let isMusic = source == .appleMusic || TrackIdentity.playbackID(for: track)?.hasPrefix("applemusic:") == true
        return [
            TrackSearchResult(
                id: "current:\(TrackIdentity.playbackID(for: track) ?? TrackIdentity(track: track).stableKey)",
                source: isMusic ? .appleMusicCurrentTrack : .spotifyCurrentTrack,
                track: track,
                confidence: max(score, 0.85),
                artworkURL: track.artworkURL
            )
        ]
    }
}

/// Compatibility name retained for older call sites and contracts.
public typealias SpotifyCurrentTrackProvider = CurrentTrackResolver

@MainActor
final class PlayerCatalogSearchProvider: TrackSearchProvider {
    let name = "Player Catalog"
    private let spotify: TrackSearchProvider
    private let music: AppleMusicPlaylistCatalog
    private let source: @MainActor () -> PlaybackSourceIdentity

    init(spotify: TrackSearchProvider, music: AppleMusicPlaylistCatalog, source: @escaping @MainActor () -> PlaybackSourceIdentity) {
        self.spotify = spotify
        self.music = music
        self.source = source
    }

    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] {
        let active = source()
        guard active == .spotifyDesktop || active == .appleMusic else { return [] }
        if active == .spotifyDesktop || query.spotifyTrackID != nil { return try await spotify.search(query: query) }
        return try await music.searchLibrary(query).map { track in
            TrackSearchResult(id: "music-library:\(track.id)", source: .appleMusicLibrary, track: track,
                              confidence: max(0.5, SongSearchScoring.score(track: track, query: query)))
        }
    }
}
