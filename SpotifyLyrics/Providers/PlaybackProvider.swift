import Foundation

public enum PlaybackProviderState: Equatable, Sendable {
    case mockPreview
    case connecting
    case ready
    case notInstalled
    case notRunning
    case permissionDenied
    case noTrack
    case unavailable(String)

    public var userFacingMessage: String {
        userFacingMessage(for: "Spotify Desktop")
    }

    public func userFacingMessage(for providerName: String) -> String {
        switch self {
        case .mockPreview:
            return "Mock 预览"
        case .connecting:
            return "正在连接 \(providerName)"
        case .ready:
            return "\(providerName) 已连接"
        case .notInstalled:
            return "未安装 \(providerName)"
        case .notRunning:
            return "\(providerName) 未运行"
        case .permissionDenied:
            return "未获得控制 \(providerName) 的权限"
        case .noTrack:
            return "\(providerName) 当前没有播放歌曲"
        case .unavailable(let message):
            return "\(providerName) 不可用：\(message)"
        }
    }

    public var isReady: Bool {
        self == .ready
    }
}

/// The provider that produced a playback snapshot. This is deliberately
/// separate from process discovery: a running application is not proof that
/// it is the active playback source.
public enum PlaybackSourceIdentity: String, Codable, Equatable, Sendable {
    case spotifyDesktop = "spotify"
    case appleMusic = "appleMusic"
    case mockPreview = "mockPreview"
    case unknown = "unknown"
}

/// Inputs to the automatic live-capture capability gate. The gate is shared
/// by the product job and the capture coordinator; external process and
/// ScreenCaptureKit I/O happen only after it allows the request.
public struct AutomaticLiveCaptureContext: Equatable, Sendable {
    public let source: PlaybackSourceIdentity
    public let providerIsReady: Bool
    public let hasLiveTrack: Bool
    public let isMockPreview: Bool
    public let isPlaying: Bool
    public let identityKey: String?

    public init(
        source: PlaybackSourceIdentity,
        providerIsReady: Bool,
        hasLiveTrack: Bool,
        isMockPreview: Bool,
        isPlaying: Bool,
        identityKey: String?
    ) {
        self.source = source
        self.providerIsReady = providerIsReady
        self.hasLiveTrack = hasLiveTrack
        self.isMockPreview = isMockPreview
        self.isPlaying = isPlaying
        self.identityKey = identityKey
    }
}

public struct AutomaticLiveCaptureEligibility: Equatable, Sendable {
    public let isAllowed: Bool
    public let reason: String

    public init(isAllowed: Bool, reason: String) {
        self.isAllowed = isAllowed
        self.reason = reason
    }

    public var isUnsupportedSource: Bool {
        reason.hasPrefix("unsupported_source:") || reason == "mock_preview"
    }
}

/// Source capability for the current automatic live-capture implementation.
/// Spotify Desktop is the only supported live source in A0. Local-file
/// alignment does not use this gate.
public enum AutomaticLiveCaptureSourceGate {
    public static func evaluate(
        _ context: AutomaticLiveCaptureContext,
        requiresPlaying: Bool = true
    ) -> AutomaticLiveCaptureEligibility {
        if context.isMockPreview {
            return AutomaticLiveCaptureEligibility(isAllowed: false, reason: "mock_preview")
        }
        guard context.source == .spotifyDesktop else {
            return AutomaticLiveCaptureEligibility(
                isAllowed: false,
                reason: "unsupported_source:\(context.source.rawValue)"
            )
        }
        guard context.providerIsReady else {
            return AutomaticLiveCaptureEligibility(isAllowed: false, reason: "playback_unavailable")
        }
        guard context.hasLiveTrack, let identityKey = context.identityKey, !identityKey.isEmpty else {
            return AutomaticLiveCaptureEligibility(isAllowed: false, reason: "no_track_identity")
        }
        if requiresPlaying, !context.isPlaying {
            return AutomaticLiveCaptureEligibility(isAllowed: false, reason: "not_playing")
        }
        return AutomaticLiveCaptureEligibility(isAllowed: true, reason: "spotify_supported")
    }
}

/// In-memory provenance for one automatic capture job. It extends the
/// existing generation/identity guard without changing any persisted schema.
public struct AutomaticLiveCaptureSessionGuard: Equatable, Sendable {
    public let source: PlaybackSourceIdentity
    public let identityKey: String
    public let generation: UInt64

    public init(source: PlaybackSourceIdentity, identityKey: String, generation: UInt64) {
        self.source = source
        self.identityKey = identityKey
        self.generation = generation
    }

    public func accepts(
        source: PlaybackSourceIdentity,
        identityKey: String?,
        generation: UInt64,
        providerReady: Bool
    ) -> Bool {
        providerReady
            && self.source == .spotifyDesktop
            && source == self.source
            && identityKey == self.identityKey
            && generation == self.generation
    }
}

public struct ProviderTrack: Equatable, Sendable {
    /// Spotify's stable track identifier when the provider can read one.
    /// It is optional so identity can correctly fall back to metadata when
    /// Spotify does not expose an ID/URI/ISRC.
    public let id: String?
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let artworkURL: URL?
    public let spotifyURL: URL?
    public let isrc: String?

    public init(
        id: String? = nil,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        artworkURL: URL? = nil,
        spotifyURL: URL? = nil,
        isrc: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.spotifyURL = spotifyURL
        self.isrc = isrc
    }
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public let status: PlaybackProviderState
    public let track: ProviderTrack?
    public let position: TimeInterval
    public let isPlaying: Bool
    public let sourceIdentity: PlaybackSourceIdentity

    public init(
        status: PlaybackProviderState,
        track: ProviderTrack? = nil,
        position: TimeInterval = 0,
        isPlaying: Bool = false,
        sourceIdentity: PlaybackSourceIdentity = .unknown
    ) {
        self.status = status
        self.track = track
        self.position = position
        self.isPlaying = isPlaying
        self.sourceIdentity = sourceIdentity
    }
}

public enum PlaybackProviderError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case notRunning
    case permissionDenied
    case noTrack
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return PlaybackProviderState.notInstalled.userFacingMessage
        case .notRunning:
            return PlaybackProviderState.notRunning.userFacingMessage
        case .permissionDenied:
            return PlaybackProviderState.permissionDenied.userFacingMessage
        case .noTrack:
            return PlaybackProviderState.noTrack.userFacingMessage
        case .commandFailed(let message):
            return message
        }
    }
}

@MainActor
public protocol PlaybackProvider: AnyObject {
    var displayName: String { get }

    func refresh() async -> PlaybackSnapshot
    func play() async throws
    func pause() async throws
    func previous() async throws
    func next() async throws
    func seek(to position: TimeInterval) async throws
}
