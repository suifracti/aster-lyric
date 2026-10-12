import SwiftUI

/// Line-level contextual action menu popover.
public struct DirectionDLineContextMenuView: View {
    public let onEditTranslation: () -> Void
    public let onAdjustPhonetics: () -> Void
    public let onAdjustTiming: () -> Void
    public let onClose: () -> Void

    public init(
        onEditTranslation: @escaping () -> Void,
        onAdjustPhonetics: @escaping () -> Void,
        onAdjustTiming: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onEditTranslation = onEditTranslation
        self.onAdjustPhonetics = onAdjustPhonetics
        self.onAdjustTiming = onAdjustTiming
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onEditTranslation) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text("修正译文")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("Direction D 暂不支持逐行修正译文；请在歌曲操作中管理翻译版本。")

            Divider()
                .frame(height: 14)
                .background(Color.white.opacity(0.3))

            Button(action: onAdjustPhonetics) {
                HStack(spacing: 4) {
                    Image(systemName: "character.phonetic")
                        .font(.system(size: 11, weight: .semibold))
                    Text("调整注音")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("Direction D 暂不支持逐行调整注音；请在歌曲操作中管理读音版本。")

            Divider()
                .frame(height: 14)
                .background(Color.white.opacity(0.3))

            Button(action: onAdjustTiming) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .semibold))
                    Text("校准时间")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("Direction D 暂不支持逐行校准时间；可在歌词编辑器中编辑时间轴。")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DirectionDDesignTokens.CornerRadius.control)
                .fill(Color(red: 0.12, green: 0.10, blue: 0.20))
                .shadow(color: Color.black.opacity(0.6), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DirectionDDesignTokens.CornerRadius.control)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Direction D Lyric Row View component.
/// Enforces the strict rule: Default displays Original + MAX 1 Auxiliary Layer.
/// Displays a subtle contextual trigger dot on hover for quick line-level actions.
public struct DirectionDLyricRowView: View {
    public let line: LyricLine
    public let isActive: Bool
    public let distance: Int
    public let policy: DirectionDLyricsPolicy
    public let availableWidth: CGFloat

    @State private var isHovered = false
    @State private var isContextOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    private var increaseContrast: Bool { colorSchemeContrast == .increased }

    public init(
        line: LyricLine,
        isActive: Bool,
        distance: Int,
        policy: DirectionDLyricsPolicy = DirectionDLyricsPolicy(),
        availableWidth: CGFloat = DirectionDDesignTokens.Spacing.windowWide
    ) {
        self.line = line
        self.isActive = isActive
        self.distance = distance
        self.policy = policy
        self.availableWidth = availableWidth
    }

    public var body: some View {
        let layers = policy.resolveVisibleLayers(isActive: isActive, distance: distance, isRowExpanded: isContextOpen)
        let emphasis = policy.resolveRowEmphasis(isActive: isActive, distance: distance, increaseContrast: increaseContrast)
        let readableWidth = min(
            max(0, availableWidth - 48),
            DirectionDDesignTokens.Lyrics.maxReadableLineWidth
        )

        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                // Ruby layer (Furigana annotations above kanji)
                if layers.showRuby, let kanaText = line.kanaText, !kanaText.isEmpty {
                    Text(kanaText)
                        .font(DirectionDDesignTokens.Typography.rubyInterlinear)
                        .foregroundStyle(DirectionDDesignTokens.Lyrics.rubyText.opacity(
                            emphasis.opacity * 0.88
                        ))
                        .lineSpacing(1)
                }

                // Original Lyric Text (Hero) - Fully legible white text
                Text(line.originalText)
                    .font(DirectionDDesignTokens.Typography.heroLine(availableWidth: readableWidth))
                    .foregroundColor(Color.white.opacity(emphasis.opacity))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true) // Prevents clipping

                // Translation Layer (Max 1 auxiliary by default)
                if layers.showTranslation, let translationText = line.translationText, !translationText.isEmpty {
                    Text(translationText)
                        .font(DirectionDDesignTokens.Typography.auxiliaryLayer(availableWidth: readableWidth))
                        .foregroundStyle(DirectionDDesignTokens.Lyrics.auxiliaryText.opacity(
                            emphasis.opacity * 0.74
                        ))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: readableWidth, alignment: .leading)

            Spacer(minLength: 8)

            // Light Context Trigger Dot - Appears softly on hover for current line
            if isActive && (isHovered || isContextOpen) {
                Button(action: { isContextOpen.toggle() }) {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isContextOpen, arrowEdge: .trailing) {
                    DirectionDLineContextMenuView(
                        onEditTranslation: { isContextOpen = false },
                        onAdjustPhonetics: { isContextOpen = false },
                        onAdjustTiming: { isContextOpen = false },
                        onClose: { isContextOpen = false }
                    )
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .scaleEffect(emphasis.scale)
        // Direction D uses crisp type at every depth.  `blurRadius` remains
        // part of the policy value for source compatibility, but visual depth
        // is intentionally expressed through opacity/weight instead.
        .blur(radius: 0)
        .onHover { isHovered = $0 }
        .animation(DirectionDDesignTokens.Motion.animation(reduceMotion: reduceMotion), value: isActive)
    }
}
