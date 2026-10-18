import SwiftUI

/// Motion policy for the v4 island. Geometry and content use separate
/// transactions so the fixed top anchor never inherits the content cross-fade
/// and a spring cannot overshoot the 40/44 pt compact envelope.
private enum CapsuleV4Motion {
    static let collapsedToHoverDuration = 0.24
    static let hoverToExpandedDuration = 0.36
    static let contentFadeDuration = 0.12
    static let contentFadeDelay = 0.0

    static func geometryAnimation(
        for targetState: CapsulePresentationState,
        reduceMotion: Bool
    ) -> Animation {
        if reduceMotion {
            return .easeOut(duration: 0.10)
        }

        switch targetState {
        case .collapsed, .hover:
            return .spring(response: 0.28, dampingFraction: 0.9)
        case .expanded:
            return .spring(response: 0.34, dampingFraction: 0.9)
        }
    }

    static func contentAnimation(
        for targetState: CapsulePresentationState,
        reduceMotion: Bool
    ) -> Animation {
        if reduceMotion {
            return .easeOut(duration: 0.08)
        }

        let animation = Animation.easeOut(duration: contentFadeDuration)
        return targetState == .expanded
            ? animation.delay(contentFadeDelay)
            : animation
    }
}

/// Compact, hover and expanded presentations for the top capsule.  The view
/// observes the same PlaybackState as every other window and never owns a
/// timer, provider, lyric session or translation session.
struct CapsuleLyricsView: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var windowController: CapsuleLyricsWindowController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var islandAccent: Color = .accentColor
    @State private var draftPosition: Double?

    private var selection: CapsuleLyricsSelection {
        CapsuleLyricsPresentation.selection(
            lines: state.liveLyrics,
            currentIndex: state.liveCurrentLineIndex,
            isSynchronized: state.liveLyricsAreSynchronized,
            state: state.liveLyricsState
        )
    }

    private var visibleLayerCount: Int {
        let preferences = state.preferences
        return [
            preferences.showOriginal,
            preferences.showTranslation,
            preferences.showRomaji,
            preferences.showKana
        ].filter { $0 }.count
    }

    private var duration: Double {
        max(1, state.currentTrack.duration.isFinite ? state.currentTrack.duration : 1)
    }

    private var activePresentation: CapsuleLyricsPresentationVersion {
        windowController.activePresentation
    }

    private var isDynamicIslandDarkV4: Bool {
        activePresentation == .dynamicIslandDarkV4
    }

    private var isTopAttachedV4: Bool { isDynamicIslandDarkV4 && windowController.isTopAttachedEnvelope }

    private var shellCornerRadius: CGFloat {
        guard isDynamicIslandDarkV4 else { return 18 }
        return windowController.presentationState == .expanded ? 26 : 22
    }

    /// The artwork and title keep the same leading anchor in every v4 state.
    /// Only the island envelope changes; the content does not re-center inside
    /// each state-specific width.
    private var v4ContentHorizontalPadding: CGFloat {
        14
    }

    private var shellShape: CapsuleV4ShellShape {
        CapsuleV4ShellShape(
            cornerRadius: shellCornerRadius,
            topAttached: isTopAttachedV4,
            topAttachedCornerRadius: isTopAttachedV4
                ? (windowController.presentationState == .expanded ? 14 : 11)
                : 0
        )
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { draftPosition ?? min(max(0, state.currentTime), duration) },
            set: { draftPosition = min(max(0, $0), duration) }
        )
    }

    var body: some View {
        sizedContainer
        .contentShape(Rectangle())
        .onHover { inside in
            if !isTopAttachedV4 {
                inside ? windowController.pointerEntered() : windowController.pointerExited()
            }
        }
        .onTapGesture {
            if windowController.presentationState != .expanded {
                windowController.expand()
            }
        }
        .animation(
            isDynamicIslandDarkV4
                ? nil
                : (accessibilityReduceMotion
                    ? .easeOut(duration: 0.10)
                    : .spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.04)),
            value: windowController.presentationState
        )
        .environment(\.lyricAgentPresentationMap, LyricAgentPresentationMap(lines: state.liveLyrics))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("顶部胶囊")
        .lyricIslandSongTint(artworkURL: state.currentTrack.artworkURL, accent: $islandAccent)
    }

    @ViewBuilder
    private var sizedContainer: some View {
        if isTopAttachedV4 {
            let islandSize = windowController.islandSize
            ZStack(alignment: .top) {
                dynamicIslandDarkV4Container
                    .frame(width: islandSize.width, height: islandSize.height)
                    .clipShape(shellShape)
            }
            .frame(
                width: windowController.envelopeSize.width,
                height: windowController.envelopeSize.height,
                alignment: .top
            )
            .animation(
                CapsuleV4Motion.geometryAnimation(
                    for: windowController.presentationState,
                    reduceMotion: accessibilityReduceMotion
                ),
                value: windowController.presentationState
            )
        } else if isDynamicIslandDarkV4 {
            let size = CapsuleDynamicIslandDarkV4.targetSize(for: windowController.presentationState)
            dynamicIslandDarkV4Container
                .frame(width: size.width, height: size.height)
                .clipShape(shellShape)
                .animation(
                    CapsuleV4Motion.geometryAnimation(
                        for: windowController.presentationState,
                        reduceMotion: accessibilityReduceMotion
                    ),
                    value: windowController.presentationState
                )
        } else {
            capsuleContainer
        }
    }

    private var dynamicIslandDarkV4Container: some View {
        ZStack {
            capsuleBackground

            dynamicIslandDarkV4Content
                .padding(.horizontal, v4ContentHorizontalPadding)
                .padding(.vertical, windowController.presentationState == .expanded ? 12 : 6)
                .padding(.top, windowController.presentationState == .expanded
                    ? windowController.notchGeometry.expandedContentTop : 0)
        }
    }

    private var capsuleContainer: some View {
        ZStack {
            capsuleBackground

            content
                .padding(.horizontal, 14)
                .padding(.vertical, windowController.presentationState == .expanded ? 14 : 8)
        }
    }

    @ViewBuilder
    private var capsuleBackground: some View {
        if isDynamicIslandDarkV4 {
            shellShape
                .fill(Color(red: 0.018, green: 0.020, blue: 0.026).opacity(0.98))
                .overlay {
                    shellShape
                        .stroke(Color.white.opacity(0.105), lineWidth: 0.75)
                }
                .overlay(alignment: .leading) {
                    capsuleAccentRail
                        .padding(.leading, max(8, shellCornerRadius * 0.55))
                }
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .overlay(alignment: .leading) {
                    capsuleAccentRail.padding(.leading, 10)
                }
        }
    }

    private var capsuleAccentRail: some View {
        Capsule()
            .fill(islandAccent.opacity(state.hasLiveTrack ? 0.95 : 0.58))
            .frame(width: 2, height: windowController.presentationState == .expanded ? 28 : 12)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch activePresentation {
        case .legacyV1:
            legacyContent
        case .controlFocusedV2:
            controlFocusedContent
        case .dynamicIslandDarkV4:
            dynamicIslandDarkV4Content
        }
    }

    @ViewBuilder
    private var dynamicIslandDarkV4Content: some View {
        let presentation = windowController.presentationState
        Group {
            if presentation == .expanded {
                v4ExpandedContent
            } else if windowController.notchGeometry.reservedWidth > 0 {
                HStack(spacing: 0) {
                    v4Artwork(size: 24)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: windowController.notchGeometry.reservedWidth)
                    Button { windowController.expand() } label: {
                        Image(systemName: state.isPlaying ? "waveform" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .help("展开灵动岛")
                    .accessibilityLabel("展开灵动岛")
                }
            } else if presentation == .hover {
                v4HoverContent
            } else {
                v4CollapsedContent
            }
        }
        .transition(.opacity)
        .animation(CapsuleV4Motion.contentAnimation(for: presentation,
            reduceMotion: accessibilityReduceMotion), value: presentation)
    }

    /// Compact keeps one strong identity cue and one unambiguous playback
    /// state. It intentionally does not become a horizontal notification row
    /// full of secondary labels.
    private var v4CollapsedContent: some View {
        HStack(spacing: 8) {
            v4Artwork(size: 26)

            Text(state.hasLiveTrack ? state.currentTrack.title : "SpotifyLyrics")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.96))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { windowController.expand() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("展开灵动岛")
            .accessibilityLabel("展开灵动岛")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Hover keeps the same island outline and reveals controls after the
    /// identity block. The order is deliberately artwork → metadata →
    /// transport, never transport → artwork.
    private var v4HoverContent: some View {
        HStack(spacing: 10) {
            v4Artwork(size: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(state.hasLiveTrack ? state.currentTrack.title : "等待 Spotify 播放")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(state.hasLiveTrack ? state.currentTrack.artist : "Desktop")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                v4TransportButton("backward.end.fill", help: "上一首") { state.previousTrack() }
                v4TransportButton(
                    state.isPlaying ? "pause.fill" : "play.fill",
                    help: "播放/暂停"
                ) { state.togglePlayPause() }
                v4TransportButton("forward.end.fill", help: "下一首") { state.nextTrack() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Expanded is a single continuous island: controls and metadata stay on
    /// the left while the live current lyric owns the right side. No following
    /// row or text-heavy toolbar is rendered here.
    private var v4ExpandedContent: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    v4Artwork(size: 62)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.hasLiveTrack ? state.currentTrack.title : "等待 Spotify 播放")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.98))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(state.hasLiveTrack ? state.currentTrack.artist : "Spotify Desktop")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    v4ProgressSlider

                    Text("\(formatTime(draftPosition ?? state.currentTime)) / \(formatTime(duration))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.68))
                        .monospacedDigit()
                        .fixedSize()
                }

                HStack(spacing: 8) {
                    v4TransportButton("backward.end.fill", help: "上一首") { state.previousTrack() }
                    v4TransportButton(
                        state.isPlaying ? "pause.fill" : "play.fill",
                        help: "播放/暂停"
                    ) { state.togglePlayPause() }
                    v4TransportButton("forward.end.fill", help: "下一首") { state.nextTrack() }

                    Button { windowController.setMenuPresented(true) } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.84))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更多操作")
                    .help("更多操作")
                    .popover(isPresented: Binding(
                        get: { windowController.menuIsPresented },
                        set: { windowController.setMenuPresented($0) }
                    ), arrowEdge: .bottom) {
                        v4MoreActions
                            .environment(\.colorScheme, .dark)
                    }
                    Spacer(minLength: 0)
                    Button { windowController.collapse() } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .help("收起灵动岛")
                }
            }
            .frame(width: 236, alignment: .leading)

            v4LyricProjection
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var v4MoreActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            moreAction("打开主窗口", symbol: "macwindow") {
                MenuBarLyricsController.shared.openMainWindow()
            }
            moreAction("显示/隐藏桌面歌词", symbol: "text.bubble") {
                WindowManager.shared.toggleFloatingLyrics(state: state)
            }
            if state.canOpenLyricsEditor {
                moreAction("编辑歌词", symbol: "square.and.pencil") {
                    state.prepareLyricsEditor()
                    openWindow(id: "lyrics-editor")
                }
            }
        }
        .padding(10)
        .frame(width: 210)
    }

    private func moreAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            windowController.setMenuPresented(false)
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var v4ProgressSlider: some View {
        GeometryReader { proxy in
            let position = min(max(draftPosition ?? state.currentTime, 0), duration)
            let fraction = duration > 0 ? position / duration : 0
            let thumbSize: CGFloat = 7
            let travel = max(0, proxy.size.width - thumbSize)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.20))
                    .frame(height: 3)

                Capsule(style: .continuous)
                    .fill(islandAccent.opacity(0.92))
                    .frame(width: max(3, travel * fraction + thumbSize / 2), height: 3)

                Circle()
                    .fill(islandAccent)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: travel * fraction)

                // Keep the native slider's accessibility and drag semantics,
                // while drawing the track ourselves so the progress remains
                // legible against the near-black v4 island.
                Slider(value: progressBinding, in: 0...duration, onEditingChanged: { editing in
                    windowController.setSeeking(editing)
                    if !editing, let draftPosition {
                        state.seek(to: draftPosition, source: "capsule-v4-slider")
                        self.draftPosition = nil
                    }
                })
                .controlSize(.mini)
                .opacity(0.02)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 18)
        .accessibilityLabel("播放进度")
    }

    @ViewBuilder
    private var v4LyricProjection: some View {
        if let current = selection.current {
            CapsuleV4LyricRowView(
                line: current,
                preferences: state.preferences,
                availableWidth: 318,
                visibleLayerCount: visibleLayerCount,
                language: state.liveLyricsLanguage
            )
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 112, alignment: .center)
        } else if let status = selection.status {
            HStack(spacing: 8) {
                Image(systemName: selection.isSynchronized ? "music.note" : "text.quote")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(islandAccent)
                Text(v4StatusText(status))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 112, alignment: .center)
        } else {
            Text("—")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.42))
                .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 112, alignment: .center)
        }
    }

    private func v4StatusText(_ status: String) -> String {
        switch status {
        case "请回主窗口选择歌词", "未找到歌词", "未选择歌词", "等待歌词":
            return "暂无歌词"
        default:
            return status
        }
    }

    private func v4Artwork(size: CGFloat) -> some View {
        ArtworkView(
            track: state.currentTrack,
            size: size,
            showsAlbumLabel: false,
            cornerRadiusRatio: 0.16
        )
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.6)
        }
    }

    private func v4TransportButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.94))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.canInteractWithPlayback)
        .help(help)
    }

    @ViewBuilder
    private var controlFocusedContent: some View {
        switch windowController.presentationState {
        case .collapsed:
            collapsedContent
        case .hover:
            hoverContent
        case .expanded:
            expandedContent
        }
    }

    @ViewBuilder
    private var legacyContent: some View {
        switch windowController.presentationState {
        case .collapsed:
            collapsedContent
        case .hover:
            hoverContent
        case .expanded:
            legacyExpandedContent
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: 10) {
            ArtworkView(track: state.currentTrack, size: 28, showsAlbumLabel: false, cornerRadiusRatio: 0.12)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.currentTrack.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(state.currentTrack.artist)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if let current = selection.current {
                Text(current.originalText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let status = selection.status {
                CapsuleLyricsStatusView(status: status, compact: true)
            }

            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var hoverContent: some View {
        HStack(spacing: 10) {
            transportButton("backward.end.fill", help: "上一首") { state.previousTrack() }
            transportButton(state.isPlaying ? "pause.fill" : "play.fill", help: "播放/暂停") {
                state.togglePlayPause()
            }
            transportButton("forward.end.fill", help: "下一首") { state.nextTrack() }

            Divider().frame(height: 32)

            ArtworkView(track: state.currentTrack, size: 38, showsAlbumLabel: false, cornerRadiusRatio: 0.12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.currentTrack.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(state.currentTrack.artist)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let current = selection.current {
                    Text(current.originalText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                } else if let status = selection.status {
                    CapsuleLyricsStatusView(status: status, compact: true)
                }
                if let following = selection.following {
                    Text(following.originalText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ArtworkView(track: state.currentTrack, size: 46, showsAlbumLabel: false, cornerRadiusRatio: 0.1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.currentTrack.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(state.currentTrack.artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(state.currentTrack.album)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                transportButton("backward.end.fill", help: "上一首") { state.previousTrack() }
                transportButton(state.isPlaying ? "pause.fill" : "play.fill", help: "播放/暂停") {
                    state.togglePlayPause()
                }
                transportButton("forward.end.fill", help: "下一首") { state.nextTrack() }
            }

            if let current = selection.current {
                CapsuleLyricsRowView(
                    line: current,
                    preferences: state.preferences,
                    availableWidth: 580,
                    visibleLayerCount: visibleLayerCount,
                    language: state.liveLyricsLanguage
                )
            } else if let status = selection.status {
                CapsuleLyricsStatusView(status: status, compact: false)
            }

            HStack(spacing: 8) {
                Slider(value: progressBinding, in: 0...duration, onEditingChanged: { editing in
                    windowController.setSeeking(editing)
                    if !editing, let draftPosition {
                        state.seek(to: draftPosition, source: "capsule-slider")
                        self.draftPosition = nil
                    }
                })
                .controlSize(.small)

                Text("\(formatTime(draftPosition ?? state.currentTime)) / \(formatTime(duration))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("主窗口", systemImage: "macwindow")
                }
                Button {
                    WindowManager.shared.toggleFloatingLyrics(state: state)
                } label: {
                    Label("悬浮歌词", systemImage: "text.bubble")
                }
                if state.canOpenLyricsEditor {
                    Button {
                        state.prepareLyricsEditor()
                        openWindow(id: "lyrics-editor")
                    } label: {
                        Label("编辑歌词", systemImage: "square.and.pencil")
                    }
                }
                Spacer()
                Button {
                    windowController.collapse()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .help("收起顶部胶囊")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .buttonStyle(.borderless)
        }
    }

    private func transportButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!state.canInteractWithPlayback)
        .help(help)
    }

    /// Archived V1 renderer kept intact for an internal presentation
    /// rollback. It is not selected by `CapsuleLyricsPresentationVersion.current`.
    private var legacyExpandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ArtworkView(track: state.currentTrack, size: 46, showsAlbumLabel: false, cornerRadiusRatio: 0.1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.currentTrack.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(state.currentTrack.artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(state.currentTrack.album)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                transportButton("backward.end.fill", help: "上一首") { state.previousTrack() }
                transportButton(state.isPlaying ? "pause.fill" : "play.fill", help: "播放/暂停") {
                    state.togglePlayPause()
                }
                transportButton("forward.end.fill", help: "下一首") { state.nextTrack() }
            }

            if let current = selection.current {
                LyricLineView(
                    line: current,
                    isActive: true,
                    distance: 0,
                    isSynchronized: true,
                    preferences: state.preferences,
                    availableWidth: 580,
                    visibleLayerCount: visibleLayerCount,
                    language: state.liveLyricsLanguage
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                if let following = selection.following {
                    LyricLineView(
                        line: following,
                        isActive: false,
                        distance: 1,
                        isSynchronized: true,
                        preferences: state.preferences,
                        availableWidth: 580,
                        visibleLayerCount: visibleLayerCount,
                        language: state.liveLyricsLanguage
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let status = selection.status {
                CapsuleLyricsStatusView(status: status, compact: false)
            }

            HStack(spacing: 8) {
                Slider(value: progressBinding, in: 0...duration, onEditingChanged: { editing in
                    windowController.setSeeking(editing)
                    if !editing, let draftPosition {
                        state.seek(to: draftPosition, source: "capsule-slider")
                        self.draftPosition = nil
                    }
                })
                .controlSize(.small)

                Text("\(formatTime(draftPosition ?? state.currentTime)) / \(formatTime(duration))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button("主窗口") { NSApp.activate(ignoringOtherApps: true) }
                Button("悬浮歌词") { WindowManager.shared.toggleFloatingLyrics(state: state) }
                if state.canOpenLyricsEditor {
                    Button("编辑歌词") {
                        state.prepareLyricsEditor()
                        openWindow(id: "lyrics-editor")
                    }
                }
                Spacer()
                Button {
                    windowController.collapse()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .help("收起顶部胶囊")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .buttonStyle(.borderless)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// Independently implemented capsule shell. Legacy floating presentations use
/// rounded rectangles; the attached product keeps its shallow top corners.
struct CapsuleV4ShellShape: Shape {
    let cornerRadius: CGFloat
    let topAttached: Bool
    let topAttachedCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard topAttached else {
            return RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            ).path(in: rect)
        }

        let bottomRadius = min(
            max(0, cornerRadius),
            min(rect.width / 2, rect.height / 2)
        )
        let topRadius = min(
            max(0, topAttachedCornerRadius),
            min(rect.width / 2, rect.height / 2)
        )
        let bottomCurve = bottomRadius * 0.5522848
        let topCurve = topRadius * 0.5522848
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
            control1: CGPoint(x: rect.maxX - topRadius + topCurve, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + topRadius - topCurve)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        path.addCurve(
            to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius + bottomCurve),
            control2: CGPoint(x: rect.maxX - bottomRadius + bottomCurve, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
            control1: CGPoint(x: rect.minX + bottomRadius - bottomCurve, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius + bottomCurve)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        path.addCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + topRadius - topCurve),
            control2: CGPoint(x: rect.minX + topRadius - topCurve, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Capsule-only adapter for a single live lyric row. `LyricLineView` keeps
/// its global multi-layer semantics; this wrapper gives the expanded capsule
/// a hard vertical budget so ruby flow and auxiliary layers cannot resize the
/// panel. Text still receives the normal single-line truncation request, and
/// overflow is clipped inside this one-row viewport without changing the
/// stored lyric or the shared display/language gates.
private struct CapsuleLyricsRowView: View {
    static let rowHeight: CGFloat = 52

    let line: LyricLine
    let preferences: DisplayPreferences
    let availableWidth: CGFloat
    let visibleLayerCount: Int
    let language: String?

    var body: some View {
        LyricLineView(
            line: line,
            isActive: true,
            distance: 0,
            isSynchronized: true,
            preferences: preferences,
            availableWidth: availableWidth,
            visibleLayerCount: visibleLayerCount,
            language: language
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .lineLimit(1)
        .truncationMode(.tail)
        // RubyTokenFlowLayout and LyricLineView's vertical fixed sizing can
        // exceed the parent proposal. The fixed frame is the capsule-local
        // single-row boundary; clipping prevents the panel from growing.
        .frame(height: Self.rowHeight, alignment: .topLeading)
        .clipped()
    }
}

/// V4 keeps the shared LyricLineView renderer, but gives it a dedicated
/// single-current-line viewport.  That preserves the global language gates,
/// Ruby modes and translation selection without allowing the expanded island
/// to grow into a multi-line lyrics panel.
private struct CapsuleV4LyricRowView: View {
    let line: LyricLine
    let preferences: DisplayPreferences
    let availableWidth: CGFloat
    let visibleLayerCount: Int
    let language: String?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var v4Preferences: DisplayPreferences {
        var adjusted = preferences
        // The expanded island has a deliberately short lyric viewport. Keep
        // the current line visually primary even when the user has selected
        // compact global assistant sizes; the selected layers and language
        // gates remain unchanged.
        let compactLength = max(
            1,
            line.originalText.filter { !$0.isWhitespace && !$0.isNewline }.count
        )
        // Keep short lines in the 22–28 pt range, then reduce only as the
        // current line approaches the fixed one-row envelope. This prevents
        // a long lyric from being clipped while preserving a strong focal
        // size for ordinary lines.
        let lengthFit = max(18, min(28, 28 - CGFloat(max(0, compactLength - 12)) * 1.2))
        adjusted.fontSize = min(max(adjusted.fontSize, 18), lengthFit)
        adjusted.assistantFontSize = min(max(adjusted.assistantFontSize, 12), adjusted.fontSize * 0.62)
        adjusted.rubyFontSize = max(adjusted.rubyFontSize, 9)
        adjusted.opacity = 1
        return adjusted
    }

    private var v4ContentScale: CGFloat {
        let compactLength = max(
            1,
            line.originalText.filter { !$0.isWhitespace && !$0.isNewline }.count
        )
        // Ruby layouts are intentionally kept as one visual row in the
        // expanded island. Scale only unusually long current lines, keeping
        // ordinary lyric text at full size instead of shrinking every row.
        return max(0.72, min(1, 13 / CGFloat(compactLength)))
    }

    var body: some View {
        LyricLineView(
            line: line,
            isActive: true,
            distance: 0,
            isSynchronized: true,
            preferences: v4Preferences,
            availableWidth: availableWidth,
            visibleLayerCount: visibleLayerCount,
            language: language
        )
        .lineLimit(1)
        .truncationMode(.tail)
        .scaleEffect(v4ContentScale, anchor: .leading)
        .frame(maxWidth: .infinity, maxHeight: 112, alignment: .center)
        .clipped()
        .transaction { transaction in
            if accessibilityReduceMotion {
                transaction.animation = nil
            }
        }
    }
}
