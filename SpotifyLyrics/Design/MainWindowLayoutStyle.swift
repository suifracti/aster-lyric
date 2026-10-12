import Foundation

enum MainWindowLayoutStyle: String, CaseIterable, Identifiable {
    case lyricsFocus
    case immersiveSplit
    case appleMusicImmersiveV3
    case directionDV4 = "directionD"

    var id: String { rawValue }

    /// Maintained product families. The legacy lyrics-focus identity remains
    /// decodable for migration and historical previews, but the split layout
    /// already adapts to narrow windows and now owns the combined V1 entry.
    static let userSelectableCases: [MainWindowLayoutStyle] = [
        .immersiveSplit,
        .appleMusicImmersiveV3,
        .directionDV4
    ]

    var title: String {
        switch self {
        case .lyricsFocus:
            return "歌词专注（已融合）"
        case .immersiveSplit:
            return "经典伴随 V1"
        case .appleMusicImmersiveV3:
            return "专辑沉浸 V3"
        case .directionDV4:
            return "实验工作台 V0"
        }
    }

    var systemImage: String {
        switch self {
        case .lyricsFocus:
            return "text.alignleft"
        case .immersiveSplit:
            return "rectangle.split.2x1"
        case .appleMusicImmersiveV3:
            return "music.note.house"
        case .directionDV4:
            return "rectangle.inset.filled"
        }
    }

    /// Stable catalog identity for this selectable main-window presentation.
    /// V3 remains a separate identity and the default runtime value.
    var presentationStableID: String {
        switch self {
        case .lyricsFocus: return "mainWindow.lyricsFocus.v1"
        case .immersiveSplit: return "mainWindow.immersiveSplit.v2"
        case .appleMusicImmersiveV3: return "mainWindow.appleMusicImmersiveV3.v3"
        case .directionDV4: return "mainWindow.directionD.v4"
        }
    }
}

/// The two maintained classic surfaces share one product family and playback
/// state. Automatic selects the split canvas for comfortable windows and the
/// lyrics-first surface when horizontal space is constrained.
enum ClassicCompanionPresentation: String, CaseIterable, Identifiable {
    case automatic
    case split
    case lyricsFocus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自适应"
        case .split: return "沉浸分栏"
        case .lyricsFocus: return "歌词专注"
        }
    }

    func resolved(forWidth width: CGFloat) -> ClassicCompanionPresentation {
        guard self == .automatic else { return self }
        return width >= LyricsDesignTokens.immersiveSplitBreakpoint ? .split : .lyricsFocus
    }
}

/// Pure size projection for the Apple Music V3 canvas. This describes the
/// temporary presentation chosen by the available window geometry; it does
/// not replace the user's persisted layout family.
enum MainWindowResponsiveMode: String, Equatable, Sendable {
    case wide
    case medium
    case small
    case lyricsFocus

    static func resolve(
        width: CGFloat,
        height: CGFloat,
        automaticLyricsFocus: Bool,
        wideBreakpoint: CGFloat = 1_080,
        comfortableSize: CGSize = LyricsDesignTokens.comfortableMainWindowSize,
        compactFocusWidth: CGFloat = 900,
        compactFocusHeight: CGFloat = 640
    ) -> MainWindowResponsiveMode {
        if let raw = UserDefaults.lyricsQ.string(
            forKey: PresentationSelectionStore.runtimeKey(for: .responsiveLayout)
        ) {
            switch raw {
            case "responsiveLayout.wide.v1": return .wide
            case "responsiveLayout.medium.v1": return .medium
            case "responsiveLayout.small.v1": return .small
            case "responsiveLayout.lyricsFocus.v1": return .lyricsFocus
            default: break
            }
        }

        if automaticLyricsFocus,
           width <= compactFocusWidth || height <= compactFocusHeight {
            return .lyricsFocus
        }

        if width >= wideBreakpoint {
            return .wide
        }

        // V3 keeps the same adaptive split below the comfort floor. Its
        // metrics already clamp the cover and reserve transport chrome, so
        // switching to a separate vertical poster here causes the visible
        // one-point resize jump users experience while dragging the window.
        // `small` remains a decodable compatibility value for forced runtime
        // previews, but normal resolution intentionally stays continuous.
        _ = comfortableSize
        return .medium
    }
}
