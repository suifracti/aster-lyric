import AppKit
import Foundation

@MainActor
public final class ActivePlaybackProvider: PlaybackProvider {
    public private(set) var activeProvider: PlaybackProvider

    public let spotifyProvider: SpotifyDesktopProvider
    public let appleMusicProvider: AppleMusicDesktopProvider
    private let settings: AppSettingsStore

    public var displayName: String {
        activeProvider.displayName
    }

    public init(
        settings: AppSettingsStore = .shared,
        spotifyProvider: SpotifyDesktopProvider? = nil,
        appleMusicProvider: AppleMusicDesktopProvider? = nil
    ) {
        self.settings = settings
        let spotify = spotifyProvider ?? SpotifyDesktopProvider()
        let appleMusic = appleMusicProvider ?? AppleMusicDesktopProvider()
        self.spotifyProvider = spotify
        self.appleMusicProvider = appleMusic
        self.activeProvider = spotify
    }

    public func refresh() async -> PlaybackSnapshot {
        switch settings.playbackSourceMode {
        case .spotify:
            activeProvider = spotifyProvider
            return await spotifyProvider.refresh()

        case .appleMusic:
            activeProvider = appleMusicProvider
            return await appleMusicProvider.refresh()

        case .auto:
            let spotifyRunning = isApplicationRunning(bundleIdentifier: "com.spotify.client")
            let appleMusicRunning = isApplicationRunning(bundleIdentifier: "com.apple.Music")

            if !spotifyRunning && !appleMusicRunning {
                return PlaybackSnapshot(status: .notRunning, track: nil, position: 0, isPlaying: false)
            }

            if spotifyRunning && !appleMusicRunning {
                activeProvider = spotifyProvider
                return await spotifyProvider.refresh()
            }

            if appleMusicRunning && !spotifyRunning {
                activeProvider = appleMusicProvider
                return await appleMusicProvider.refresh()
            }

            // Both players are running: prioritize the one that is currently playing.
            if activeProvider === appleMusicProvider {
                let musicSnapshot = await appleMusicProvider.refresh()
                if musicSnapshot.isPlaying {
                    return musicSnapshot
                }
                let spotifySnapshot = await spotifyProvider.refresh()
                if spotifySnapshot.isPlaying {
                    activeProvider = spotifyProvider
                    return spotifySnapshot
                }
                if musicSnapshot.track != nil {
                    return musicSnapshot
                }
                if spotifySnapshot.track != nil {
                    activeProvider = spotifyProvider
                    return spotifySnapshot
                }
                return musicSnapshot
            } else {
                let spotifySnapshot = await spotifyProvider.refresh()
                if spotifySnapshot.isPlaying {
                    return spotifySnapshot
                }
                let musicSnapshot = await appleMusicProvider.refresh()
                if musicSnapshot.isPlaying {
                    activeProvider = appleMusicProvider
                    return musicSnapshot
                }
                if spotifySnapshot.track != nil {
                    return spotifySnapshot
                }
                if musicSnapshot.track != nil {
                    activeProvider = appleMusicProvider
                    return musicSnapshot
                }
                return spotifySnapshot
            }
        }
    }

    public func play() async throws {
        try await activeProvider.play()
    }

    func acceptDesktopSnapshot(_ snapshot: PlaybackSnapshot) {
        switch snapshot.sourceIdentity {
        case .spotifyDesktop:
            spotifyProvider.acceptDesktopSnapshot(snapshot)
            activeProvider = spotifyProvider
        case .appleMusic:
            appleMusicProvider.acceptDesktopSnapshot(snapshot)
            activeProvider = appleMusicProvider
        default: break
        }
    }

    public func calibratePosition() async -> PlaybackSnapshot {
        await activeProvider.calibratePosition()
    }

    public func artworkURL(for track: ProviderTrack, source: PlaybackSourceIdentity) async -> URL? {
        switch source {
        case .spotifyDesktop: return await spotifyProvider.artworkURL(for: track, source: source)
        case .appleMusic: return await appleMusicProvider.artworkURL(for: track, source: source)
        default: return nil
        }
    }

    public func pause() async throws {
        try await activeProvider.pause()
    }

    public func previous() async throws {
        try await activeProvider.previous()
    }

    public func next() async throws {
        try await activeProvider.next()
    }

    public func seek(to position: TimeInterval) async throws {
        try await activeProvider.seek(to: position)
    }

    private func isApplicationRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
