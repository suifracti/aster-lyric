import AppKit
import Foundation

extension ProviderTrack {
    func withArtworkURL(_ url: URL) -> ProviderTrack {
        ProviderTrack(id: id, title: title, artist: artist, album: album, duration: duration,
                      artworkURL: url, spotifyURL: spotifyURL, isrc: isrc)
    }

    var desktopRecordingKey: String {
        let track = Track(title: title, artist: artist, album: album, duration: duration,
                          spotifyId: id, spotifyURL: spotifyURL)
        return TrackIdentity.playbackID(for: track) ?? desktopRecordingIdentity.stableKey
    }

    var desktopRecordingIdentity: TrackIdentity {
        TrackIdentity(title: title, artist: artist, album: album, duration: duration,
                      spotifyTrackID: id, spotifyURI: spotifyURL?.absoluteString, isrc: isrc)
    }
}

/// Metadata comes from desktop-player broadcasts. Position-only corrections
/// cannot introduce a different recording or undo a newer broadcast.
struct DesktopPlaybackUpdate: Sendable {
    let source: PlaybackSourceIdentity
    let isPlaying: Bool
    let isStopped: Bool
    let track: ProviderTrack?
    let identityHint: String?
    let position: TimeInterval?

    static func decode(name: Notification.Name, userInfo: [AnyHashable: Any]) -> Self? {
        let source: PlaybackSourceIdentity
        switch name {
        case DesktopPlaybackEvents.spotifyPlaybackChanged: source = .spotifyDesktop
        case DesktopPlaybackEvents.musicPlayerInfo: source = .appleMusic
        default: return nil
        }
        func text(_ key: String) -> String? {
            guard let raw = userInfo[key] as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func number(_ key: String) -> Double? {
            let value = (userInfo[key] as? NSNumber)?.doubleValue ?? text(key).flatMap(Double.init)
            return value.flatMap { $0.isFinite ? $0 : nil }
        }
        guard let state = text("Player State")?.lowercased(),
              ["playing", "paused", "stopped"].contains(state) else { return nil }
        let id: String?
        if source == .spotifyDesktop {
            id = text("Track ID")
        } else if let numeric = userInfo["PersistentID"] as? NSNumber {
            id = "applemusic:" + String(format: "%016llX", numeric.uint64Value)
        } else {
            id = (text("PersistentID") ?? text("Persistent ID")).map { "applemusic:" + $0.uppercased() }
        }
        let milliseconds = source == .spotifyDesktop ? number("Duration") : number("Total Time")
        let duration = milliseconds.map { $0 / 1000 }
        let track: ProviderTrack?
        if let title = text("Name"), let duration, duration > 0 {
            track = ProviderTrack(id: id, title: title, artist: text("Artist") ?? "",
                album: text("Album") ?? "", duration: duration,
                artworkURL: (text("Artwork URL") ?? text("Art URL")).flatMap(URL.init(string:)),
                spotifyURL: source == .spotifyDesktop ? id.flatMap { raw in
                    TrackIdentity.canonicalSpotifyTrackID(raw).flatMap { URL(string: "https://open.spotify.com/track/" + $0) }
                } : nil)
        } else { track = nil }
        return Self(source: source, isPlaying: state == "playing", isStopped: state == "stopped",
                    track: track, identityHint: id,
                    position: number("Playback Position") ?? number("Player Position"))
    }

    func snapshot(previous: PlaybackSnapshot?, estimatedPosition: TimeInterval) -> PlaybackSnapshot? {
        if isStopped {
            return PlaybackSnapshot(status: .noTrack, track: nil, position: 0, isPlaying: false, sourceIdentity: source)
        }
        let prior = previous?.sourceIdentity == source ? previous?.track : nil
        let next: ProviderTrack
        if let track {
            let sameID = track.id != nil && track.id == prior?.id
            let merged = ProviderTrack(id: track.id, title: track.title,
                artist: track.artist.isEmpty && sameID ? (prior?.artist ?? "") : track.artist,
                album: track.album.isEmpty && sameID ? (prior?.album ?? "") : track.album,
                duration: track.duration)
            let sameRecording = prior?.desktopRecordingKey == merged.desktopRecordingKey
            next = ProviderTrack(id: track.id ?? (sameRecording ? prior?.id : nil),
                title: merged.title, artist: merged.artist, album: merged.album, duration: merged.duration,
                artworkURL: track.artworkURL ?? (sameRecording ? prior?.artworkURL : nil),
                spotifyURL: track.spotifyURL ?? (sameRecording ? prior?.spotifyURL : nil),
                isrc: sameRecording ? prior?.isrc : nil)
        } else if let prior, identityHint == nil || prior.id == identityHint {
            next = prior
        } else { return nil }
        let sameRecording = prior?.desktopRecordingKey == next.desktopRecordingKey
        let value = position ?? (track == nil || sameRecording ? estimatedPosition : 0)
        return PlaybackSnapshot(status: .ready, track: next, position: min(max(0, value), next.duration),
                                isPlaying: isPlaying, sourceIdentity: source)
    }
}

@MainActor
public final class DesktopPlaybackEvents {
    nonisolated static let spotifyPlaybackChanged = Notification.Name("com.spotify.client.PlaybackStateChanged")
    nonisolated static let musicPlayerInfo = Notification.Name("com.apple.Music.playerInfo")
    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let windowCenter: NotificationCenter
    private let applicationIsRunning: (PlaybackSourceIdentity) -> Bool
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var onUpdate: ((DesktopPlaybackUpdate) -> Void)?
    private var onApplicationChanged: ((PlaybackSourceIdentity, Bool) -> Void)?
    private var onVisibilityChanged: (() -> Void)?

    init(center: NotificationCenter = DistributedNotificationCenter.default(),
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         windowCenter: NotificationCenter = .default,
         applicationIsRunning: @escaping (PlaybackSourceIdentity) -> Bool = { source in
             let bundle = source == .spotifyDesktop ? "com.spotify.client" : "com.apple.Music"
             return !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
         }) {
        self.center = center; self.workspaceCenter = workspaceCenter
        self.windowCenter = windowCenter; self.applicationIsRunning = applicationIsRunning
    }

    func isRunning(_ source: PlaybackSourceIdentity) -> Bool {
        guard source == .spotifyDesktop || source == .appleMusic else { return false }
        return applicationIsRunning(source)
    }

    func start(onUpdate: @escaping (DesktopPlaybackUpdate) -> Void,
               onApplicationChanged: @escaping (PlaybackSourceIdentity, Bool) -> Void,
               onVisibilityChanged: @escaping () -> Void) {
        guard tokens.isEmpty else { return }
        self.onUpdate = onUpdate; self.onApplicationChanged = onApplicationChanged
        self.onVisibilityChanged = onVisibilityChanged
        for name in [Self.spotifyPlaybackChanged, Self.musicPlayerInfo] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let update = DesktopPlaybackUpdate.decode(name: notification.name, userInfo: notification.userInfo ?? [:]) else { return }
                Task { @MainActor [weak self] in self?.onUpdate?(update) }
            }
            tokens.append((center, token))
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let source: PlaybackSourceIdentity
                switch app.bundleIdentifier {
                case "com.spotify.client": source = .spotifyDesktop
                case "com.apple.Music": source = .appleMusic
                default: return
                }
                let running = notification.name == NSWorkspace.didLaunchApplicationNotification
                Task { @MainActor [weak self] in self?.applicationChanged(source: source, isRunning: running) }
            }
            tokens.append((workspaceCenter, token))
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSWindow.didExposeNotification, NSWindow.didBecomeKeyNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            let token = windowCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onVisibilityChanged?() }
            }
            tokens.append((windowCenter, token))
        }
    }

    func applicationChanged(source: PlaybackSourceIdentity, isRunning: Bool) {
        onApplicationChanged?(source, isRunning)
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }
}
