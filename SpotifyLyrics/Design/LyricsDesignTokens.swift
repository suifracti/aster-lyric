import SwiftUI
import AppKit

/// Stable, presentation-only policies for lyric row reflow.  The policy
/// owns neither playback state nor a scroll position; it only chooses how an
/// already-computed lyric projection changes its layout.
enum LyricsTransitionStyle: String, CaseIterable, Identifiable, Sendable {
    case systemV1 = "lyricsTransition.system.v1"
    case smoothRelayoutV1 = "lyricsTransition.smoothRelayout.v1"
    case noneV1 = "lyricsTransition.none.v1"

    static var active: LyricsTransitionStyle {
        guard let raw = UserDefaults.lyricsQ.string(
            forKey: PresentationSelectionStore.runtimeKey(for: .lyricsTransition)
        ), let selected = LyricsTransitionStyle(rawValue: raw) else {
            return .smoothRelayoutV1
        }
        return selected
    }

    var id: String { rawValue }

    func animation(reduceMotion: Bool) -> Animation? {
        guard self != .noneV1 else { return nil }
        if reduceMotion {
            return .easeOut(duration: LyricsDesignTokens.Motion.reduceMotionDuration)
        }

        switch self {
        case .systemV1:
            return .easeInOut(duration: LyricsDesignTokens.Motion.interfaceDuration)
        case .smoothRelayoutV1:
            return .easeInOut(duration: LyricsDesignTokens.Motion.lyricDuration)
        case .noneV1:
            return nil
        }
    }
}

/// A small Equatable value that changes only when a row's layout inputs
/// change.  Playback time is deliberately not part of this signature.
struct LyricsLayoutSignature: Equatable {
    let lineID: UUID
    let contentHash: Int
    let widthBucket: Int
    let visibleLayerCount: Int
    let isSynchronized: Bool
    let distance: Int
    let kanaMode: KanaDisplayMode
}

/// Main-window follow motion is isolated from wrap/layout. Wrap points use a
/// single reading weight so becoming the current line cannot reflow the row.
enum V3LyricMotionPolicy {
    static let followDuration: Double = 0.40
    static let layoutWeight: Font.Weight = .semibold
    /// Matches `Font.Weight.semibold` in the V3 row renderer.
    static let layoutNSWeight: CGFloat = 0.3

    static func followAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: followDuration)
    }
}

enum LyricsTransitionPolicy {
    static var activeStyle: LyricsTransitionStyle { LyricsTransitionStyle.active }

    static func animation(
        style: LyricsTransitionStyle = activeStyle,
        reduceMotion: Bool
    ) -> Animation? {
        style.animation(reduceMotion: reduceMotion)
    }

    static func perform(
        style: LyricsTransitionStyle = activeStyle,
        reduceMotion: Bool,
        _ action: () -> Void
    ) {
        guard let animation = animation(style: style, reduceMotion: reduceMotion) else {
            action()
            return
        }
        withAnimation(animation, action)
    }

    static func signature(
        line: LyricLine,
        preferences: DisplayPreferences,
        availableWidth: CGFloat,
        visibleLayerCount: Int,
        isSynchronized: Bool,
        distance: Int
    ) -> LyricsLayoutSignature {
        var hasher = Hasher()
        hasher.combine(line.originalText)
        hasher.combine(line.translationText)
        hasher.combine(line.romajiText)
        hasher.combine(line.kanaText)
        hasher.combine(line.rubyTokens)
        hasher.combine(preferences.showOriginal)
        hasher.combine(preferences.showTranslation)
        hasher.combine(preferences.showRomaji)
        hasher.combine(preferences.kanaDisplayMode)
        hasher.combine(preferences.hideDistantAuxiliary)

        return LyricsLayoutSignature(
            lineID: line.id,
            contentHash: hasher.finalize(),
            widthBucket: Int((max(0, availableWidth) / 8).rounded()),
            visibleLayerCount: visibleLayerCount,
            isSynchronized: isSynchronized,
            distance: distance,
            kanaMode: preferences.kanaDisplayMode
        )
    }
}

enum LyricsDesignTokens {
    // Kept as documented compatibility values for the original UI contract;
    // V2 uses the smaller responsive blur values below to avoid fuzzy text.
    // blurRadius: 0.6 / blurRadius: 1.8
    static let defaultMainWindowSize = CGSize(width: 1040, height: 680)
    /// The smallest window that can still be opened by the app. It is not the
    /// same thing as the comfortable reference size used by responsive layout.
    static let technicalMinimumMainWindowSize = CGSize(width: 760, height: 520)
    /// The reference floor at which the medium layout is expected to remain
    /// comfortably readable without entering the small-window degradation.
    static let comfortableMainWindowSize = CGSize(width: 800, height: 600)
    /// Compatibility name retained for the older window-size contract.
    static let minimumMainWindowSize = technicalMinimumMainWindowSize

    static let contentCornerRadius: CGFloat = 20
    static let headerSpacing: CGFloat = 16
    static let lyricRowSpacing: CGFloat = 24
    static let canvasHorizontalPadding: CGFloat = 40
    static let canvasVerticalPadding: CGFloat = 72
    static let artworkSize: CGFloat = 84
    static let backdropArtworkSize: CGFloat = 260
    static let immersiveSplitBreakpoint: CGFloat = 900
    static let immersiveArtworkSize: CGFloat = 320
    static let immersiveColumnSpacing: CGFloat = 26
    static let immersiveWindowPadding: CGFloat = 28
    /// Display-only reading measure. Source lyrics and timing remain intact;
    /// wide windows wrap rows before they become difficult to scan.
    static let readableLyricLineMaxWidth: CGFloat = 680

    // MARK: Shared Phase 2.3 tokens

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let windowWide: CGFloat = 64
        static let windowMedium: CGFloat = 32
        static let windowSmall: CGFloat = 24
    }

    enum CornerRadius {
        static let control: CGFloat = 10
        static let card: CGFloat = 16
        static let canvas: CGFloat = 20
        static let artwork: CGFloat = 14
    }

    enum Typography {
        static let windowTitle = Font.system(size: 30, weight: .semibold, design: .rounded)
        static let sectionTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 15, weight: .regular, design: .rounded)
        static let auxiliary = Font.system(size: 13, weight: .medium, design: .rounded)
        static let metadata = Font.system(size: 12, weight: .medium, design: .rounded)
    }

    enum Material {
        static let panelOpacity: Double = 0.18
        static let controlOpacity: Double = 0.08
        static let borderOpacity: Double = 0.12
        static let primaryTextOpacity: Double = 0.92
        static let secondaryTextOpacity: Double = 0.64
        static let mutedTextOpacity: Double = 0.46
    }

    /// Semantic background tokens.  These describe the visual role of a
    /// layer rather than exposing raw blur/opacity controls as user settings.
    /// Preset-specific values are resolved by BackdropPresentationID.
    enum Backdrop {
        static let textureIntensity: Double = 1.0
        static let paletteSaturation: Double = 0.78
        static let glowIntensity: Double = 0.62
        static let lyricVeilMultiplier: Double = 0.68
        static let minimumLyricVeil: Double = 0.22
        static let vignetteIntensity: Double = 0.42
        static let noiseIntensity: Double = 0.035
        static let transitionDuration: Double = 0.42
        static let outgoingTransitionDuration: Double = 0.18
    }

    /// Surface tokens are intentionally separate from the artwork backdrop.
    /// Materials belong to controls and utility surfaces, not to the entire
    /// lyric canvas.
    enum Surface {
        static let localMaterialOpacity: Double = 0.66
        static let localKeylineOpacity: Double = 0.12
        static let localShadowOpacity: Double = 0.20
        static let lyricSurfaceVeilOpacity: Double = 0.30
    }

    /// Progress is intentionally a quieter visual layer than the lyric
    /// content.  Playback progress describes transport position; lyric
    /// timing is represented separately by the viewport's timing status.
    enum Progress {
        static let trackHeight: CGFloat = 3
        static let compactTrackHeight: CGFloat = 2
        static let hoverTrackHeight: CGFloat = 4
        static let inactiveOpacity: Double = 0.16
        static let hoverInactiveOpacity: Double = 0.28
        static let activeOpacity: Double = 0.58
        static let hoverActiveOpacity: Double = 0.82
        static let thumbSize: CGFloat = 8
        static let hoverThumbSize: CGFloat = 10
        static let focusWidth: CGFloat = 132
        /// Small-window transport stays compact instead of spanning the full canvas.
        static let smallMaxWidth: CGFloat = 280
    }

    enum Shadow {
        static let opacity: Double = 0.20
        static let radius: CGFloat = 18
        static let y: CGFloat = 8
    }

    enum Motion {
        static let quickDuration: Double = 0.18
        static let interfaceDuration: Double = 0.24
        static let lyricDuration: Double = 0.34
        static let reduceMotionDuration: Double = 0.12

        static func animation(reduceMotion: Bool, duration: Double = interfaceDuration) -> Animation {
            reduceMotion
                ? .easeOut(duration: reduceMotionDuration)
                : .easeInOut(duration: duration)
        }

        static func lyricAnimation(reduceMotion: Bool) -> Animation {
            animation(reduceMotion: reduceMotion, duration: lyricDuration)
        }
    }

    static let primaryText = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let secondaryText = Color(red: 0.77, green: 0.78, blue: 0.80)
    static let mutedText = Color(red: 0.58, green: 0.60, blue: 0.64)
    static let accent = Color(red: 0.86, green: 0.76, blue: 0.58)
    static let controlBackground = Color.white.opacity(0.08)
    static let controlBorder = Color.white.opacity(0.12)

    static let backdropGradient = LinearGradient(
        colors: [
            Color(red: 0.035, green: 0.045, blue: 0.075),
            Color(red: 0.085, green: 0.080, blue: 0.105),
            Color(red: 0.025, green: 0.030, blue: 0.055)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func lyricEmphasis(
        isActive: Bool,
        distance: Int,
        isSynchronized: Bool = true,
        availableWidth: CGFloat = defaultMainWindowSize.width,
        visibleLayerCount: Int = 1
    ) -> LyricEmphasis {
        let width = min(max(availableWidth, 520), 1_360)
        let widthProgress = (width - 520) / 840
        let layerPenalty = CGFloat(max(0, visibleLayerCount - 2))
        let activePrimary = min(34, max(26, 27 + widthProgress * 8 - layerPenalty * 1.5))
        let activeSecondary = min(20, max(14, 15 + widthProgress * 5 - layerPenalty * 0.8))

        if !isSynchronized {
            return LyricEmphasis(
                primaryFontSize: max(22, activePrimary - 3),
                secondaryFontSize: max(13, activeSecondary - 1),
                opacity: 0.85,
                blurRadius: 0,
                verticalPadding: visibleLayerCount >= 4 ? 6 : 8
            )
        }

        if isActive {
            return LyricEmphasis(
                primaryFontSize: activePrimary,
                secondaryFontSize: activeSecondary,
                opacity: 1.0,
                blurRadius: 0,
                verticalPadding: visibleLayerCount >= 4 ? 10 : 14
            )
        }

        if distance == 1 {
            return LyricEmphasis(
                primaryFontSize: max(24, activePrimary - 2.0),
                secondaryFontSize: max(13, activeSecondary - 0.8),
                opacity: 0.58,
                blurRadius: 0.4,
                verticalPadding: visibleLayerCount >= 4 ? 6 : 9
            )
        }

        return LyricEmphasis(
            primaryFontSize: max(22, activePrimary - 4.0),
            secondaryFontSize: max(12, activeSecondary - 1.5),
            opacity: 0.36,
            blurRadius: 1.6,
            verticalPadding: visibleLayerCount >= 4 ? 5 : 7
        )
    }

    static func lyricRowSpacing(for availableWidth: CGFloat, visibleLayerCount: Int) -> CGFloat {
        let width = min(max(availableWidth, 520), 1_360)
        let widthProgress = (width - 520) / 840
        let layerPenalty = CGFloat(max(0, visibleLayerCount - 2)) * 1.5
        return max(24, min(30, 24 + widthProgress * 6 - layerPenalty))
    }
}

/// Presentation-only policy for loading, empty, error and candidate states.
/// It deliberately does not live in AppSettingsStore: the two renderings use
/// the same live LyricsLoadState and commands, and the recommended rendering
/// can evolve without creating a second persisted state machine.
enum LyricsStatePresentation: String, CaseIterable, Identifiable, Sendable {
    case systemV1 = "lyricsStatePresentation.system.v1"
    case contentFirstV1 = "lyricsStatePresentation.contentFirst.v1"

    static var active: LyricsStatePresentation {
        guard let raw = UserDefaults.lyricsQ.string(
            forKey: PresentationSelectionStore.runtimeKey(for: .lyricsState)
        ), let selected = LyricsStatePresentation(rawValue: raw) else {
            return .contentFirstV1
        }
        return selected
    }

    var id: String { rawValue }
}

struct LyricEmphasis {
    let primaryFontSize: CGFloat
    let secondaryFontSize: CGFloat
    let opacity: Double
    let blurRadius: CGFloat
    let verticalPadding: CGFloat
}

// Song colour is shared by listening surfaces; management windows retain their
// stable semantic palette. The cache is also used by the main backdrop.
private struct LyricIslandAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}
extension EnvironmentValues {
    var lyricIslandAccent: Color {
        get { self[LyricIslandAccentKey.self] }
        set { self[LyricIslandAccentKey.self] = newValue }
    }
}
extension View {
    func lyricIslandSongTint(artworkURL: URL?, accent: Binding<Color>) -> some View {
        modifier(LyricIslandSongTint(artworkURL: artworkURL, accent: accent))
    }
}
private struct LyricIslandSongTint: ViewModifier {
    let artworkURL: URL?
    @Binding var accent: Color

    func body(content: Content) -> some View {
        content.environment(\.lyricIslandAccent, accent)
            .task(id: artworkURL) {
                accent = .accentColor
                let palette = await LyricIslandArtworkColors.palette(for: artworkURL)
                guard !Task.isCancelled else { return }
                let value = palette.glow
                // Menu sheets can be light while listening windows are dark.
                // Resolve the same song hue against each surface appearance.
                accent = Color(nsColor: NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let scale = dark ? 0.76 : 0.48
                    let lift = dark ? 0.24 : 0.0
                    return NSColor(red: value.red * scale + lift,
                                   green: value.green * scale + lift,
                                   blue: value.blue * scale + lift, alpha: 1)
                })
            }
    }
}
