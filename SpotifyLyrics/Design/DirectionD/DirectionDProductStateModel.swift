import Foundation
import SwiftUI

/// Unified presentation state model for Direction D (Phase 3.3).
/// Maps existing real product state machines into clear, non-engineering user presentation states.
public enum DirectionDPresentationState: String, CaseIterable, Equatable, Sendable {
    case waitingForPlayback          = "waitingForPlayback"          // 等待 Spotify 播放
    case spotifyNotRunning           = "spotifyNotRunning"           // 请打开 Spotify 并开始播放
    case spotifyUnavailable          = "spotifyUnavailable"          // 暂时无法连接 Spotify
    case permissionRequired          = "permissionRequired"          // 需要允许 Lyric Island 读取 Spotify 播放状态
    case loadingLyrics               = "loadingLyrics"               // 正在搜索歌词
    case noLyrics                    = "noLyrics"                    // 暂未找到歌词
    case networkUnavailable          = "networkUnavailable"          // 网络连接失败
    case usingCachedLyrics           = "usingCachedLyrics"           // 网络连接失败，正在显示已保存的歌词
    case automaticSyncRunning        = "automaticSyncRunning"        // 正在同步歌词
    case automaticSyncProgressSaved  = "automaticSyncProgressSaved"  // 已保存部分进度
    case automaticSyncWaiting        = "automaticSyncWaiting"        // 等待继续播放
    case automaticSyncCompleted      = "automaticSyncCompleted"      // 同步完成
    case automaticSyncUnreliable     = "automaticSyncUnreliable"     // 本次无法可靠完成
    case automaticSyncUnavailable   = "automaticSyncUnavailable"   // 同步功能尚未准备好
    case normalLyrics                = "normalLyrics"                // 正常歌词阅读状态，无 Banner

    /// Associated user task language string.
    public var userFacingMessage: String {
        switch self {
        case .waitingForPlayback: return DirectionDDesignTokens.UserTaskLanguage.idleMessage
        case .spotifyNotRunning: return DirectionDDesignTokens.UserTaskLanguage.spotifyNotRunningMessage
        case .spotifyUnavailable: return "暂时无法连接 Spotify"
        case .permissionRequired: return DirectionDDesignTokens.UserTaskLanguage.permissionRequiredMessage
        case .loadingLyrics: return DirectionDDesignTokens.UserTaskLanguage.searchingMessage
        case .noLyrics: return DirectionDDesignTokens.UserTaskLanguage.notFoundMessage
        case .networkUnavailable: return DirectionDDesignTokens.UserTaskLanguage.networkErrorMessage
        case .usingCachedLyrics: return DirectionDDesignTokens.UserTaskLanguage.networkWithCacheMessage
        case .automaticSyncRunning: return DirectionDDesignTokens.UserTaskLanguage.syncingMessage
        case .automaticSyncProgressSaved: return DirectionDDesignTokens.UserTaskLanguage.partialSavedMessage
        case .automaticSyncWaiting: return DirectionDDesignTokens.UserTaskLanguage.waitingContinueMessage
        case .automaticSyncCompleted: return DirectionDDesignTokens.UserTaskLanguage.syncCompleteMessage
        case .automaticSyncUnreliable: return DirectionDDesignTokens.UserTaskLanguage.cannotCompleteReliablyMessage
        case .automaticSyncUnavailable: return DirectionDDesignTokens.UserTaskLanguage.syncNotReadyMessage
        case .normalLyrics: return ""
        }
    }
}

/// Resolves the song-summary title from playback identity and title metadata.
/// An absent track is an idle state; a present track with a blank title is
/// unknown metadata rather than a fabricated song name.
public enum DirectionDTrackSummaryPresentation {
    public static func displayTitle(_ title: String?, hasCurrentTrack: Bool) -> String {
        guard hasCurrentTrack else { return "等待歌曲" }
        guard let title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "歌曲标题未知"
        }
        return title
    }
}

/// Primary vs Secondary state breakdown for Direction D.
public enum DirectionDPrimaryState: Equatable, Sendable {
    case permissionRequired
    case spotifyUnavailable
    case spotifyNotRunning
    case waitingForPlayback
    case loadingLyrics
    case noLyrics
    case networkUnavailableNoCache
    case showingLyrics(hasLyrics: Bool, isCached: Bool)
}

public enum DirectionDSecondaryState: Equatable, Sendable {
    case none
    case networkUnavailableWithCache
    case automaticSyncRunning
    case automaticSyncProgressSaved
    case automaticSyncWaiting
    case automaticSyncCompleted
    case automaticSyncUnreliable
    case automaticSyncUnavailable
}

/// Deterministic Priority Resolver to prevent conflicting empty states.
public enum DirectionDStatePriority {
    /// Resolves primary and secondary presentation states given system input conditions.
    public static func resolve(
        hasPermission: Bool,
        isSpotifyRunning: Bool,
        isSpotifyAvailable: Bool,
        isPlayingOrPaused: Bool,
        hasTrack: Bool,
        isLoadingLyrics: Bool,
        hasLyrics: Bool,
        isCachedLyrics: Bool,
        isNetworkAvailable: Bool,
        alignmentJobState: String? // Alignment state if running
    ) -> (primary: DirectionDPrimaryState, secondary: DirectionDSecondaryState) {
        // Priority 1: System permission blocked
        if !hasPermission {
            return (.permissionRequired, .none)
        }

        // Priority 2: Spotify unavailable or not running
        if !isSpotifyRunning {
            return (.spotifyNotRunning, .none)
        }
        if !isSpotifyAvailable {
            return (.spotifyUnavailable, .none)
        }

        // Priority 3: No current track identity only (pause must NOT drop to idle).
        // `isPlayingOrPaused` is accepted for API stability but ignored here —
        // presence of a live track keeps the lyrics path alive while paused.
        _ = isPlayingOrPaused
        if !hasTrack {
            return (.waitingForPlayback, .none)
        }

        // Priority 4: Lyrics currently loading (and we do not yet have content)
        if isLoadingLyrics && !hasLyrics {
            return (.loadingLyrics, .none)
        }

        // Priority 5: Network failure or no lyrics found (No cache)
        if !hasLyrics {
            if !isNetworkAvailable {
                return (.networkUnavailableNoCache, .none)
            }
            return (.noLyrics, .none)
        }

        // Priority 6: Lyrics are available (Primary state is showingLyrics)
        let primary: DirectionDPrimaryState = .showingLyrics(hasLyrics: true, isCached: isCachedLyrics)

        // Priority 7: Secondary state evaluation (Overlayed on top of lyrics)
        // At most one secondary banner.
        var secondary: DirectionDSecondaryState = .none

        if !isNetworkAvailable {
            // Cached lyrics + network failure → secondary only, keep primary lyrics.
            secondary = .networkUnavailableWithCache
        } else if let jobState = alignmentJobState {
            switch jobState.lowercased() {
            case "running", "aligning", "capturing", "evaluating", "accumulating":
                // "accumulating" during job still means work in progress for banner
                // but progress-saved is a distinct post-segment state.
                if jobState.lowercased() == "accumulating" {
                    secondary = .automaticSyncProgressSaved
                } else {
                    secondary = .automaticSyncRunning
                }
            case "progresssaved":
                secondary = .automaticSyncProgressSaved
            case "waiting", "deferred", "paused", "waitingforplayback":
                secondary = .automaticSyncWaiting
            case "completed":
                secondary = .automaticSyncCompleted
            case "failed", "unreliable":
                secondary = .automaticSyncUnreliable
            case "unavailable", "deferred_engine", "engine":
                secondary = .automaticSyncUnavailable
            default:
                secondary = .none
            }
        }

        return (primary, secondary)
    }

    /// Maps `AutomaticAlignmentJobController.State` raw values into resolver job tokens.
    public static func alignmentToken(from jobStateRaw: String?) -> String? {
        guard let raw = jobStateRaw?.lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "capturing", "aligning", "evaluating":
            return "running"
        case "accumulating":
            return "accumulating"
        case "paused", "deferred":
            return raw == "paused" ? "paused" : "deferred"
        case "completed":
            return "completed"
        case "failed":
            return "failed"
        case "idle", "canceled", "cancelled":
            return nil
        default:
            return raw
        }
    }
}
