import SwiftUI

/// Lyric Island Phase 3.1 & 3.2 Direction D Design Tokens.
/// Synthesizes Quiet Default Companion (A), Inspector Workbench IA (B),
/// and Light Contextual Actions (C) into a single, unified token system.
public enum DirectionDDesignTokens {
    // MARK: - Spacing & Geometry Tokens
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let windowWide: CGFloat = 1200
        public static let windowSmall: CGFloat = 520
        public static let windowFocus: CGFloat = 680
        public static let inspectorWidth: CGFloat = 360 // Adaptable 340-380px
        public static let desktopLyricsWidth: CGFloat = 760
    }

    public enum CornerRadius {
        public static let control: CGFloat = 8
        public static let card: CGFloat = 12
        public static let inspector: CGFloat = 16
        public static let mainContainer: CGFloat = 12
        public static let capsuleCollapsed: CGFloat = 18
        public static let capsuleExpanded: CGFloat = 26
    }

    // MARK: - Surface & Material Tokens
    public enum Surface {
        public static let quietVeilOpacity: Double = 0.15
        public static let glassMaterialOpacity: Double = 0.12
        public static let glassMaterialHoverOpacity: Double = 0.18
        public static let glassBorderOpacity: Double = 0.10
        public static let inspectorPanelOpacity: Double = 0.92
        public static let backdropGlowIntensity: Double = 0.35
        public static let quietToolbarIdleOpacity: Double = 0.58
        public static let quietToolbarHoverOpacity: Double = 1.0
        public static let quietControlOpacity: Double = 0.07
        public static let quietControlHoverOpacity: Double = 0.14
        public static let hairlineOpacity: Double = 0.10

        /// Unified consistent background gradient across Quiet and Hover states
        public static var defaultCanvasGradient: LinearGradient {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.08, blue: 0.22),
                    Color(red: 0.05, green: 0.04, blue: 0.12),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Typography Tokens (Multi-language & Dynamic Type Aware)
    public enum Typography {
        /// Current Hero Line Font (26pt Bold)
        public static func heroLine(availableWidth: CGFloat) -> Font {
            let size: CGFloat = availableWidth >= 900 ? 26 : (availableWidth <= 520 ? 18 : 22)
            return .system(size: size, weight: .semibold, design: .default)
        }

        /// Lyrics Focus Mode Large Font (32pt Extra Bold)
        public static let lyricsFocusHero = Font.system(size: 32, weight: .bold, design: .default)

        /// Auxiliary Layer Font (Translation / Ruby / Romaji, 14pt Regular)
        public static func auxiliaryLayer(availableWidth: CGFloat) -> Font {
            let size: CGFloat = availableWidth >= 900 ? 14 : 12
            return .system(size: size, weight: .regular, design: .default)
        }

        /// Ruby Interlinear Character Font (11pt)
        public static let rubyInterlinear = Font.system(size: 11, weight: .medium, design: .default)

        /// Track Metadata Title (20pt Bold)
        public static let trackTitle = Font.system(size: 20, weight: .semibold, design: .default)

        /// Track Metadata Subtitle / Artist (14pt Medium)
        public static let trackArtist = Font.system(size: 14, weight: .medium, design: .default)

        /// Inspector Section Header (12pt Semibold Uppercase)
        public static let inspectorSectionTitle = Font.system(size: 12, weight: .semibold, design: .default)

        /// User Task Language Badge (11pt Semibold)
        public static let userTaskBadge = Font.system(size: 11, weight: .semibold, design: .default)

        /// Status Message Language (13pt Regular)
        public static let statusMessage = Font.system(size: 13, weight: .regular, design: .default)
    }

    /// Semantic lyric-layer tokens.  These control hierarchy only; they do
    /// not own the live line index or any scrolling state.
    public enum Lyrics {
        public static let maxReadableLineWidth: CGFloat = 720
        // ScrollViewReader on macOS has a reliable center anchor; the
        // surrounding lyric canvas supplies the small visual bias through
        // its asymmetric context spacing without losing the target row.
        // Keep the active row in the middle-to-lower reading band without
        // changing the shared live line index or introducing a second
        // scrolling model.
        public static let readingAnchor = UnitPoint(x: 0.5, y: 0.55)
        public static let activeScale: CGFloat = 1.01
        public static let rubyText = Color(red: 0.78, green: 0.73, blue: 0.68)
        public static let auxiliaryText = Color(red: 0.86, green: 0.86, blue: 0.88)
    }

    // MARK: - Motion Tokens
    public enum Motion {
        public static let hoverDuration: Double = 0.20
        public static let inspectorSlideDuration: Double = 0.28
        public static let sheetPopupDuration: Double = 0.32
        public static let lyricTransitionDuration: Double = 0.30
        public static let reduceMotionDuration: Double = 0.10

        public static func animation(reduceMotion: Bool, duration: Double = hoverDuration) -> Animation {
            reduceMotion ? .easeOut(duration: reduceMotionDuration) : .easeInOut(duration: duration)
        }
    }

    // MARK: - User-Facing Task Language Tokens (Strict: NO Engineering Terms)
    public enum UserTaskLanguage {
        public static let lyricsCategory = "歌词"
        public static let translationCategory = "翻译"
        public static let phoneticsCategory = "读音"
        public static let timeSyncCategory = "时间同步"
        public static let historyCategory = "历史版本"
        public static let importExportCategory = "导入与导出"

        public static let idleMessage = "等待 Spotify 播放"
        public static let spotifyNotRunningMessage = "请打开 Spotify 并开始播放"
        public static let searchingMessage = "正在搜索歌词"
        public static let notFoundMessage = "暂未找到歌词"
        public static let networkErrorMessage = "网络连接失败"
        public static let syncingMessage = "正在同步歌词"
        public static let partialSavedMessage = "已保存部分进度"
        /// Secondary: auto-align waiting to resume capture.
        public static let waitingContinueMessage = "等待继续播放"
        /// Legacy alias used by product-state model (maps to waiting continue).
        public static let waitingForPlaybackMessage = waitingContinueMessage
        public static let syncCompleteMessage = "同步完成"
        public static let cannotCompleteReliablyMessage = "本次无法可靠完成"
        public static let syncNotReadyMessage = "同步功能尚未准备好"
        public static let permissionRequiredMessage = "需要允许 Aster · Lyric 读取 Spotify 播放状态"
        public static let networkWithCacheMessage = "网络连接失败，正在显示已保存的歌词"
        public static let manualSyncAction = "校准时间"
    }

    // MARK: - Accessibility Overrides
    public enum Accessibility {
        public static func textOpacity(
            baseOpacity: Double,
            increaseContrast: Bool
        ) -> Double {
            increaseContrast ? min(1.0, baseOpacity + 0.25) : baseOpacity
        }

        public static func backgroundVeil(
            baseOpacity: Double,
            reduceTransparency: Bool
        ) -> Double {
            reduceTransparency ? max(0.92, baseOpacity + 0.25) : baseOpacity
        }
    }
}
