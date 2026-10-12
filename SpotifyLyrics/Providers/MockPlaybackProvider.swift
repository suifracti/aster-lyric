import Foundation

@MainActor
public final class MockPlaybackProvider: PlaybackProvider {
    public let displayName = "Mock 预览"

    private var isPlaying = false

    public init() {}

    public func refresh() async -> PlaybackSnapshot {
        PlaybackSnapshot(
            status: .mockPreview,
            track: ProviderTrack(mockTrack: MockData.sampleTrack),
            position: 0,
            isPlaying: isPlaying,
            sourceIdentity: .mockPreview
        )
    }

    public func play() async throws {
        isPlaying = true
    }

    public func pause() async throws {
        isPlaying = false
    }

    public func previous() async throws {}

    public func next() async throws {}

    public func seek(to position: TimeInterval) async throws {}
}

private extension ProviderTrack {
    init(mockTrack: Track) {
        self.init(
            id: mockTrack.id,
            title: mockTrack.title,
            artist: mockTrack.artist,
            album: mockTrack.album,
            duration: mockTrack.duration,
            artworkURL: mockTrack.artworkURL,
            spotifyURL: mockTrack.spotifyURL
        )
    }
}
