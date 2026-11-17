import SwiftUI

/// Read-only adapters for the Preview Lab.  They render the visual grammar of
/// a catalog entry from one immutable snapshot; they do not call a formal
/// surface, own business state, or reproduce any playback command.
struct PresentationPreviewAdapterView: View {
    let entry: PresentationMetadata
    let context: PresentationPreviewContext

    private let registry = PresentationPreviewRendererRegistry.shared

    private var descriptor: PresentationPreviewRendererDescriptor? {
        guard let descriptor = registry.descriptor(for: entry.stableID),
              descriptor.category == entry.category else {
            return nil
        }
        return descriptor
    }

    private var supportsCurrentSource: Bool {
        context.source == .mock ? entry.supportsMockPreview : entry.supportsLivePreview
    }

    var body: some View {
        Group {
            if let descriptor, supportsCurrentSource {
                rendered(kind: descriptor.kind)
            } else {
                unsupportedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func rendered(kind: String) -> some View {
        switch kind {
        case "main.lyricsFocus":
            MainLyricsFocusPreview(context: context)
        case "main.immersiveSplit":
            MainImmersiveSplitPreview(context: context)
        case "main.appleMusicImmersiveV3":
            MainAppleMusicImmersiveV3Preview(context: context)
        case "main.directionD":
            MainDirectionDPreview(context: context)
        case "fullscreen.borderlessPanel":
            FullscreenPreview(context: context)
        case "capsule.legacy":
            CapsuleLegacyPreview(context: context)
        case "capsule.controlFocused":
            CapsuleControlFocusedPreview(context: context)
        case "capsule.dynamicIslandDark":
            CapsuleDynamicIslandDarkPreview(context: context)
        case "floating.legacyPanel":
            FloatingLegacyPreview(context: context)
        case "floating.transparent":
            FloatingTransparentPreview(context: context)
        case let value where value.hasPrefix("backdrop."):
            BackdropPreview(context: context, preset: value)
        case let value where value.hasPrefix("lyricsTransition."):
            LyricsTransitionPreview(context: context, kind: value)
        case let value where value.hasPrefix("lyricsState."):
            LyricsStatePreview(context: context, kind: value)
        case let value where value.hasPrefix("progress."):
            ProgressPreview(context: context, kind: value)
        case let value where value.hasPrefix("layout."):
            ResponsiveLayoutPreview(context: context, kind: value)
        default:
            unsupportedView
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("暂不支持预览")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(entry.stableID)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.22))
    }
}

private struct PreviewArtwork: View {
    let context: PresentationPreviewContext
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
        }
        .accessibilityLabel("专辑封面占位")
    }
}

private struct PreviewTrackHeader: View {
    let context: PresentationPreviewContext
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            PreviewArtwork(context: context, size: compact ? 28 : 54)
            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                Text(context.track.title)
                    .font(.system(size: compact ? 12 : 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(context.track.artist)
                    .font(.system(size: compact ? 10 : 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(compact ? 0.66 : 0.72))
                    .lineLimit(1)
            }
        }
    }
}

private struct PreviewLyricBlock: View {
    let context: PresentationPreviewContext
    let titleSize: CGFloat
    let includeKana: Bool
    let includeRomaji: Bool
    let includeTranslation: Bool
    let dimmed: Bool

    private var currentLine: LyricLine? {
        guard let index = context.currentLineIndex,
              context.lyrics.indices.contains(index) else { return nil }
        return context.lyrics[index]
    }

    var body: some View {
        if let currentLine {
            VStack(alignment: .leading, spacing: 6) {
                if includeKana, let kana = currentLine.kanaText, !kana.isEmpty {
                    Text(kana)
                        .font(.system(size: max(10, titleSize * 0.42), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(dimmed ? 0.42 : 0.66))
                        .lineLimit(1)
                }
                Text(currentLine.originalText)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(dimmed ? 0.56 : 0.98))
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
                if includeTranslation,
                   let translation = currentLine.translationText,
                   !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: max(11, titleSize * 0.47), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(dimmed ? 0.30 : 0.62))
                        .lineLimit(1)
                }
                if includeRomaji,
                   let romaji = currentLine.romajiText,
                   !romaji.isEmpty {
                    Text(romaji)
                        .font(.system(size: max(10, titleSize * 0.38), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(dimmed ? 0.24 : 0.46))
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(context.lyricsState.displayName)
                    .font(.system(size: titleSize * 0.75, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                Text("当前没有可用的当前行")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.44))
            }
        }
    }
}

private struct PreviewContextRows: View {
    let context: PresentationPreviewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(context.contextLineIndices, id: \.self) { index in
                if context.lyrics.indices.contains(index) {
                    Text(context.lyrics[index].originalText)
                        .font(.system(size: index == context.currentLineIndex ? 20 : 14,
                                      weight: index == context.currentLineIndex ? .semibold : .medium,
                                      design: .rounded))
                        .foregroundStyle(.white.opacity(index == context.currentLineIndex ? 1 : 0.34))
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct MainLyricsFocusPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.07, blue: 0.10)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("歌词专注")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.50))
                    Spacer()
                    Text(context.track.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer(minLength: 18)
                PreviewLyricBlock(
                    context: context,
                    titleSize: 28,
                    includeKana: context.showOriginal && context.kanaDisplayMode != .hidden,
                    includeRomaji: context.showRomaji,
                    includeTranslation: context.showTranslation,
                    dimmed: false
                )
                .padding(.horizontal, 34)
                Spacer(minLength: 18)

                HStack(spacing: 10) {
                    Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                    Text("歌词阅读优先")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.52))
                .padding(.horizontal, 34)
                .padding(.bottom, 18)
            }
        }
    }
}

private struct MainImmersiveSplitPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                PreviewArtwork(context: context, size: 112)
                Text(context.track.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(context.track.artist)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 14) {
                    Image(systemName: "backward.fill")
                    Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                    Image(systemName: "forward.fill")
                }
                .foregroundStyle(.white.opacity(0.80))
            }
            .frame(width: 190)
            .padding(20)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 16) {
                Text("歌词")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                PreviewContextRows(context: context)
                Spacer()
                Text("沉浸分栏 · 旧布局")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.30))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.025, green: 0.065, blue: 0.08))
    }
}

private struct MainAppleMusicImmersiveV3Preview: View {
    let context: PresentationPreviewContext

    var body: some View {
        ZStack {
            PreviewBackdropCanvas(preset: "backdrop.default", context: context)
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    PreviewArtwork(context: context, size: 132)
                    Text(context.track.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(context.track.artist)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                .frame(width: 165, alignment: .leading)

                VStack(alignment: .leading, spacing: 24) {
                    Text("歌词")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                    PreviewLyricBlock(
                        context: context,
                        titleSize: 25,
                        includeKana: context.kanaDisplayMode != .hidden,
                        includeRomaji: context.showRomaji,
                        includeTranslation: context.showTranslation,
                        dimmed: false
                    )
                    Spacer()
                    HStack(spacing: 14) {
                        Image(systemName: "heart")
                        Image(systemName: "ellipsis")
                        Text("V3 · 沉浸背景")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(24)
        }
    }
}

/// Read-only Direction D V4 preview.  This is intentionally a small preview
/// renderer, not a second runtime window or a copy of the V3 view.
private struct MainDirectionDPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        ZStack {
            PreviewBackdropCanvas(preset: "backdrop.default", context: context)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    PreviewArtwork(context: context, size: 118)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.track.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(context.track.artist)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "backward.fill")
                        Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                        Image(systemName: "forward.fill")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                }
                .frame(width: 164, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer(minLength: 4)
                    PreviewLyricBlock(
                        context: context,
                        titleSize: 25,
                        includeKana: context.kanaDisplayMode != .hidden,
                        includeRomaji: context.showRomaji,
                        includeTranslation: context.showTranslation,
                        dimmed: false
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(24)
        }
    }
}

private struct CapsuleLegacyPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "backward.end.fill")
                Image(systemName: "play.fill")
                Image(systemName: "forward.end.fill")
                Divider().frame(height: 24)
                PreviewTrackHeader(context: context, compact: true)
                Spacer()
            }
            if context.capsuleState != .collapsed {
                PreviewLyricBlock(
                    context: context,
                    titleSize: 14,
                    includeKana: false,
                    includeRomaji: false,
                    includeTranslation: false,
                    dimmed: true
                )
            }
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(14)
        .frame(width: capsuleWidth(for: context.capsuleState, base: 350),
               height: capsuleHeight(for: context.capsuleState, base: 64))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct CapsuleControlFocusedPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PreviewArtwork(context: context, size: context.capsuleState == .collapsed ? 26 : 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.track.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if context.capsuleState != .collapsed {
                        Text(context.track.artist)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if context.capsuleState != .collapsed {
                    HStack(spacing: 7) {
                        Image(systemName: "backward.end.fill")
                        Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                        Image(systemName: "forward.end.fill")
                    }
                    .font(.system(size: 12, weight: .bold))
                } else {
                    Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                }
            }

            if context.capsuleState == .expanded {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("播放控制")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                        Capsule().fill(Color.white.opacity(0.55)).frame(height: 3)
                    }
                    PreviewLyricBlock(
                        context: context,
                        titleSize: 15,
                        includeKana: false,
                        includeRomaji: false,
                        includeTranslation: context.showTranslation,
                        dimmed: false
                    )
                }
            }
        }
        .foregroundStyle(.white.opacity(0.94))
        .padding(14)
        .frame(width: capsuleWidth(for: context.capsuleState, base: 360),
               height: capsuleHeight(for: context.capsuleState, base: 62))
        .background(Color(red: 0.075, green: 0.08, blue: 0.095), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 0.8)
        }
    }
}

private struct CapsuleDynamicIslandDarkPreview: View {
    let context: PresentationPreviewContext

    private var stateSize: CGSize {
        switch context.capsuleState {
        case .collapsed: return CapsuleDynamicIslandDarkV4.collapsedSize
        case .hover: return CapsuleDynamicIslandDarkV4.hoverSize
        case .expanded: return CapsuleDynamicIslandDarkV4.expandedSize
        }
    }

    var body: some View {
        let index = context.currentLineIndex
        let current = index.flatMap { context.lyrics.indices.contains($0) ? context.lyrics[$0].originalText : nil }
        let expanded = context.capsuleState == .expanded
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PreviewArtwork(context: context, size: expanded ? 27 : 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(expanded ? context.track.title : (current ?? context.track.title))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if expanded || context.capsuleState == .hover {
                        Text(expanded ? context.track.artist : context.track.title)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                if expanded {
                    Label("定住这句", systemImage: "pin").font(.caption2)
                    Image(systemName: "bookmark")
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
            }
            if expanded {
                PreviewLyricBlock(context: context, titleSize: 22, includeKana: context.kanaDisplayMode != .hidden,
                                  includeRomaji: context.showRomaji, includeTranslation: context.showTranslation, dimmed: false)
                    .frame(maxHeight: .infinity, alignment: .leading)
                if let index, context.lyrics.indices.contains(index + 1) {
                    Text("下一句　" + context.lyrics[index + 1].originalText)
                        .font(.caption).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                }
                HStack(spacing: 12) {
                    Image(systemName: "backward.end.fill")
                    Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                    Image(systemName: "forward.end.fill")
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, expanded ? 10 : 5)
        .foregroundStyle(.white)
        .frame(width: stateSize.width, height: stateSize.height)
        .background(Color(white: 0.025), in: CapsuleV4ShellShape(cornerRadius: expanded ? 26 : 22,
                         topAttached: true, topAttachedCornerRadius: expanded ? 14 : 11))
    }
}

private func capsuleWidth(for state: PresentationPreviewCapsuleState, base: CGFloat) -> CGFloat {
    switch state {
    case .collapsed: return base * 0.82
    case .hover: return base
    case .expanded: return 520
    }
}

private func capsuleHeight(for state: PresentationPreviewCapsuleState, base: CGFloat) -> CGFloat {
    switch state {
    case .collapsed: return base * 0.72
    case .hover: return base
    case .expanded: return 142
    }
}

private struct FloatingLegacyPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("桌面歌词")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
            PreviewLyricBlock(context: context, titleSize: 21, includeKana: false, includeRomaji: false, includeTranslation: context.showTranslation, dimmed: false)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FloatingTransparentPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PreviewLyricBlock(context: context, titleSize: 24, includeKana: context.kanaDisplayMode != .hidden, includeRomaji: context.showRomaji, includeTranslation: context.showTranslation, dimmed: false)
            Text("透明歌词层 · 可读性阴影")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.clear)
        .shadow(color: .black.opacity(0.7), radius: 7, y: 2)
    }
}

private struct BackdropPreview: View {
    let context: PresentationPreviewContext
    let preset: String

    var body: some View {
        ZStack {
            PreviewBackdropCanvas(preset: preset, context: context)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PreviewTrackHeader(context: context, compact: true)
                    Spacer()
                    Text(preset.replacingOccurrences(of: "backdrop.", with: ""))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                }
                Spacer()
                PreviewLyricBlock(context: context, titleSize: 26, includeKana: true, includeRomaji: context.showRomaji, includeTranslation: context.showTranslation, dimmed: false)
                Spacer()
                Text("same immutable snapshot")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
            .padding(22)
        }
    }
}

private struct PreviewBackdropCanvas: View {
    let preset: String
    let context: PresentationPreviewContext

    private var colors: [Color] {
        switch preset {
        case "backdrop.clear":
            return [Color(red: 0.08, green: 0.11, blue: 0.14), Color(red: 0.15, green: 0.17, blue: 0.18)]
        case "backdrop.immersive":
            return [Color(red: 0.20, green: 0.055, blue: 0.18), Color(red: 0.03, green: 0.12, blue: 0.28)]
        case "backdrop.highContrast":
            return [Color.black, Color(red: 0.05, green: 0.05, blue: 0.07)]
        case "backdrop.legacyV3":
            return [Color(red: 0.04, green: 0.10, blue: 0.15), Color(red: 0.13, green: 0.11, blue: 0.16)]
        default:
            return [Color(red: 0.08, green: 0.07, blue: 0.18), Color(red: 0.06, green: 0.18, blue: 0.22)]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [colors[0].opacity(preset == "backdrop.clear" ? 0.16 : 0.72), .clear],
                center: .topLeading,
                startRadius: 6,
                endRadius: 280
            )
            if preset != "backdrop.clear" && preset != "backdrop.highContrast" {
                Rectangle()
                    .fill(Color.white.opacity(preset == "backdrop.immersive" ? 0.035 : 0.015))
                    .blendMode(.overlay)
            }
            Color.black.opacity(context.reduceTransparency || context.increaseContrast ? 0.54 : (preset == "backdrop.highContrast" ? 0.62 : 0.34))
        }
    }
}

private struct FullscreenPreview: View {
    let context: PresentationPreviewContext

    var body: some View {
        ZStack {
            PreviewBackdropCanvas(preset: "backdrop.highContrast", context: context)
            VStack(spacing: 16) {
                PreviewTrackHeader(context: context, compact: false)
                Spacer()
                PreviewLyricBlock(context: context, titleSize: 30, includeKana: context.kanaDisplayMode != .hidden, includeRomaji: context.showRomaji, includeTranslation: context.showTranslation, dimmed: false)
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                    Text("Esc 隐藏全屏歌词")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.44))
            }
            .padding(26)
        }
    }
}

private struct LyricsTransitionPreview: View {
    let context: PresentationPreviewContext
    let kind: String

    var body: some View {
        VStack(spacing: 18) {
            Text(kind.replacingOccurrences(of: "lyricsTransition.", with: ""))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.54))
            HStack(spacing: 14) {
                Text("上一行")
                    .foregroundStyle(.white.opacity(0.32))
                Image(systemName: kind.contains("none") ? "arrow.right" : "arrow.right.circle.fill")
                    .foregroundStyle(kind.contains("smooth") ? .cyan : .white.opacity(0.62))
                Text("当前行")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text(kind.contains("smooth") ? "稳定行容器 · 高度平滑重排" : kind.contains("none") ? "直接布局切换" : "系统基础过渡")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.035, green: 0.045, blue: 0.07))
    }
}

private struct LyricsStatePreview: View {
    let context: PresentationPreviewContext
    let kind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.contains("content") ? "内容优先状态" : "系统状态")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(context.lyricsState.displayName)
                .font(.system(size: 27, weight: .bold, design: .rounded))
            Text(kind.contains("content") ? "一个主操作 · 技术细节收起" : "共享歌词状态")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
            Button("查看歌词") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ProgressPreview: View {
    let context: PresentationPreviewContext
    let kind: String

    private var fraction: Double {
        guard context.duration > 0 else { return 0 }
        return min(1, max(0, context.currentTime / context.duration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind.replacingOccurrences(of: "progress.", with: ""))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: kind.contains("focus") ? 2 : 5)
                    Capsule().fill(Color.white.opacity(0.82)).frame(width: proxy.size.width * fraction, height: kind.contains("focus") ? 2 : 5)
                }
            }
            .frame(height: 8)
            HStack {
                Image(systemName: context.isPlaying ? "pause.fill" : "play.fill")
                Text(kind.contains("compact") ? "Hover 增强轨道" : kind.contains("focus") ? "歌词阅读优先" : "播放进度")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                Spacer()
                Text(formatTime(context.currentTime) + " / " + formatTime(context.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.50))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(red: 0.035, green: 0.05, blue: 0.08))
    }
}

private struct ResponsiveLayoutPreview: View {
    let context: PresentationPreviewContext
    let kind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.replacingOccurrences(of: "layout.", with: ""))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            if kind.contains("lyricsFocus") {
                PreviewLyricBlock(context: context, titleSize: 24, includeKana: true, includeRomaji: context.showRomaji, includeTranslation: context.showTranslation, dimmed: false)
            } else {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.14)).frame(width: kind.contains("wide") ? 120 : 76)
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)).frame(maxWidth: .infinity)
                }
                .frame(height: 82)
                PreviewLyricBlock(context: context, titleSize: kind.contains("wide") ? 23 : 18, includeKana: false, includeRomaji: false, includeTranslation: context.showTranslation, dimmed: false)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.04, green: 0.05, blue: 0.08))
    }
}

private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", value / 60, value % 60)
}
