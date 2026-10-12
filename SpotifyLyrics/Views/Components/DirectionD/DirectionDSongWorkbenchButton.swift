import SwiftUI

/// Restrained Song Workbench Button component.
/// Displays a quiet "Song Workbench" affordance without permanent intense glowing or prominent borders.
/// Elevates visibility ONLY when attention is required (e.g., pending alignment or unverified source).
public struct DirectionDSongWorkbenchButton: View {
    public let isOpen: Bool
    public let hasAttentionItem: Bool
    public let compact: Bool
    public let action: () -> Void

    @State private var isHovered = false

    public init(
        isOpen: Bool,
        hasAttentionItem: Bool = false,
        compact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.isOpen = isOpen
        self.hasAttentionItem = hasAttentionItem
        self.compact = compact
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))

                if !compact {
                    Text("歌曲工作台")
                        .font(.system(size: 12, weight: .medium))
                }

                if hasAttentionItem {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, 5)
            .background(buttonBackground)
            .foregroundColor(buttonForeground)
            .cornerRadius(DirectionDDesignTokens.CornerRadius.control)
            .overlay(
                RoundedRectangle(cornerRadius: DirectionDDesignTokens.CornerRadius.control)
                    .strokeBorder(buttonBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // A pointer click should not leave an AppKit blue focus ring around
        // the quiet toolbar.  The button remains accessible to keyboard
        // navigation; the system focus indication is not part of the idle
        // visual treatment.
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .help("展开/收起当前歌曲工作台 (⌘I)")
    }

    private var buttonBackground: Color {
        if isOpen {
            return Color.white.opacity(0.14)
        } else if isHovered {
            return Color.white.opacity(DirectionDDesignTokens.Surface.quietControlHoverOpacity)
        } else if hasAttentionItem {
            return Color.orange.opacity(0.15)
        } else {
            return Color.white.opacity(DirectionDDesignTokens.Surface.quietControlOpacity)
        }
    }

    private var buttonForeground: Color {
        if isOpen {
            return Color.white
        } else if hasAttentionItem {
            return Color.orange
        } else {
            return Color.white.opacity(0.78)
        }
    }

    private var buttonBorder: Color {
        if isOpen {
            return Color.white.opacity(0.22)
        } else if isHovered {
            return Color.white.opacity(0.16)
        } else if hasAttentionItem {
            return Color.orange.opacity(0.4)
        } else {
            return Color.clear // Zero prominent border in quiet state
        }
    }
}

/// Quiet Toolbar component (Direction A + B synthesis).
/// Fades in smoothly when hovering over the top titlebar area or when Inspector is open.
public struct DirectionDQuietToolbar: View {
    public let isInspectorOpen: Bool
    public let canPresentWindowActions: Bool
    public let onToggleInspector: () -> Void
    public let onOpenSearch: () -> Void
    public let onOpenSettings: () -> Void
    public let compact: Bool

    @State private var isAreaHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        isInspectorOpen: Bool,
        canPresentWindowActions: Bool = true,
        onToggleInspector: @escaping () -> Void,
        onOpenSearch: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        compact: Bool = false
    ) {
        self.isInspectorOpen = isInspectorOpen
        self.canPresentWindowActions = canPresentWindowActions
        self.onToggleInspector = onToggleInspector
        self.onOpenSearch = onOpenSearch
        self.onOpenSettings = onOpenSettings
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Spacer()

            DirectionDSongWorkbenchButton(
                isOpen: isInspectorOpen,
                compact: compact,
                action: onToggleInspector
            )

            Button(action: onOpenSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                    .frame(width: compact ? 24 : 26, height: compact ? 24 : 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!canPresentWindowActions)
            .help(canPresentWindowActions ? "搜索歌词" : "此诊断窗口无法打开歌词搜索，请使用主窗口。")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                    .frame(width: compact ? 24 : 26, height: compact ? 24 : 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!canPresentWindowActions)
            .help(canPresentWindowActions ? "设置中心" : "此诊断窗口无法打开设置，请使用主窗口。")
        }
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, compact ? 6 : 8)

        // Keep the hit area stable while making the quiet state legible.  A
        // pointer hover reveals the complete toolbar without changing layout.
        .contentShape(Rectangle())
        .opacity(isAreaHovered || isInspectorOpen
            ? DirectionDDesignTokens.Surface.quietToolbarHoverOpacity
            : DirectionDDesignTokens.Surface.quietToolbarIdleOpacity)
        .animation(DirectionDDesignTokens.Motion.animation(reduceMotion: reduceMotion), value: isAreaHovered)
        .onHover { isAreaHovered = $0 }
    }
}
