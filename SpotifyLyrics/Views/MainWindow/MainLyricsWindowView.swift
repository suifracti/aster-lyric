import SwiftUI
import AppKit

struct MainLyricsWindowView: View {
    @EnvironmentObject private var state: PlaybackState
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var directionDAdapter: DirectionDProductStateAdapter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var isSearchPresented = false

    private var layoutStyle: MainWindowLayoutStyle {
        settings.mainWindowLayoutStyle
    }

    private var layoutStyleBinding: Binding<String> {
        Binding(
            get: { settings.mainWindowLayoutStyleRawValue },
            set: { rawValue in
                guard let style = MainWindowLayoutStyle(rawValue: rawValue) else { return }
                // Keep the legacy raw setting and the PresentationSelectionStore
                // in one write path.  This preserves V3 as the default while
                // making a user-selected Direction D V4 survive relaunch and
                // remain visible in Experience Library.
                _ = settings.applyPresentationSelection(
                    category: .mainWindow,
                    stableID: style.presentationStableID
                )
            }
        )
    }

    var body: some View {
        Group {
            if layoutStyle == .appleMusicImmersiveV3 {
                AppleMusicImmersiveV3WindowView(
                    state: state,
                    settings: settings,
                    layoutStyleRawValue: layoutStyleBinding
                )
            } else if layoutStyle == .directionDV4 {
                DirectionDMainWindowPresentationFactory.makeMainWindow(
                    stableID: MainWindowLayoutStyle.directionDV4.presentationStableID,
                    playbackState: state,
                    adapter: directionDAdapter,
                    router: directionDRouter
                )
            } else {
                legacyWindowBody
            }
        }
        .frame(
            minWidth: layoutStyle == .appleMusicImmersiveV3
                ? MainWindowResponsiveThresholds.minimumWidth
                : layoutStyle == .directionDV4
                    ? DirectionDDesignTokens.Spacing.windowSmall
                : LyricsDesignTokens.minimumMainWindowSize.width,
            minHeight: layoutStyle == .appleMusicImmersiveV3
                ? MainWindowResponsiveThresholds.minimumHeight
                : layoutStyle == .directionDV4
                    ? 520
                : LyricsDesignTokens.minimumMainWindowSize.height
        )
        .preferredColorScheme(.dark)
        .background(Color.clear)
        .background(WindowStateAccessor(settings: settings))
        .ignoresSafeArea()
        .popover(
            isPresented: Binding(
                get: { layoutStyle == .directionDV4 && isSearchPresented },
                set: { isSearchPresented = $0 }
            ),
            arrowEdge: .top
        ) {
            SongSearchPopover(
                manager: state.songSearchManager,
                playbackState: state
            )
        }
#if DEBUG
        // Single Assist explain-sheet host for V3 + classic + lyrics-focus.
        // Do not also attach AssistExplainSheet under LyricsCanvasView.
        .sheet(isPresented: Binding(
            get: { state.isAssistExplainSheetPresented },
            set: { presented in
                if presented {
                    state.isAssistExplainSheetPresented = true
                } else {
                    // Esc / click-outside / swipe: leave explaining without capture.
                    state.dismissListeningAssistExplanation()
                }
            }
        )) {
            AssistExplainSheet(state: state)
        }
        .onChange(of: state.assistEditorOpenToken) { _, _ in
            openWindow(id: "lyrics-editor")
        }
#endif
        .onAppear {
            MenuBarLyricsController.shared.setOpenEditorHandler { [openWindow] in
                openWindow(id: "lyrics-editor")
            }
            MenuBarLyricsController.shared.setOpenSettingsHandler { [openSettings] in
                openSettings()
            }
            MenuBarLyricsController.shared.setOpenMainWindowHandler { [openWindow] in
                openWindow(id: "main-window")
            }
            MenuBarLyricsController.shared.setOpenLibraryHandler { [openWindow] in
                openWindow(id: "personal-library-activity")
            }
        }
        .task {
            state.startProvider(connectSpotify: settings.connectSpotifyOnLaunch)
            WindowManager.shared.restoreFloatingWindowIfConfigured(state: state)
            // Let WindowStateAccessor attach the real SwiftUI main window so
            // the capsule follows its screen rather than only NSScreen.main.
            await Task.yield()
            WindowManager.shared.restoreCapsuleWindowIfConfigured(state: state)
        }
    }

    private var legacyWindowBody: some View {
        GeometryReader { geometry in
            let classicPresentation = resolvedClassicPresentation(width: geometry.size.width)
            let usesLyricsFocus = layoutStyle == .lyricsFocus
                || (layoutStyle == .immersiveSplit && classicPresentation == .lyricsFocus)
            let topBarHeight: CGFloat = usesLyricsFocus ? 116 : 64
            let contentHeight = max(0, geometry.size.height - topBarHeight)

            ZStack(alignment: .top) {
                ArtworkBackgroundView(state: state)

                layoutBody(classicPresentation: classicPresentation)
                    .animation(.easeInOut(duration: 0.24), value: layoutStyle)
                    .animation(.easeInOut(duration: 0.24), value: classicPresentation)
                    .frame(maxWidth: .infinity)
                    .frame(height: contentHeight, alignment: .top)
                    .offset(y: topBarHeight)

                VStack(spacing: 0) {
                    topBar(usesLyricsFocus: usesLyricsFocus)
                        .padding(.horizontal, LyricsDesignTokens.immersiveWindowPadding)
                        .padding(.top, usesLyricsFocus ? 18 : 8)
                        .padding(.bottom, usesLyricsFocus ? 14 : 8)

                    Divider()
                        .overlay(LyricsDesignTokens.controlBorder)

                }
                .frame(height: topBarHeight)
                .background {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(usesLyricsFocus ? 0.22 : 0.14)
                }
            }
        }
    }

    @ViewBuilder
    private func layoutBody(
        classicPresentation: ClassicCompanionPresentation
    ) -> some View {
        switch layoutStyle {
        case .lyricsFocus:
            lyricsFocusLayout
        case .immersiveSplit:
            if classicPresentation == .lyricsFocus {
                lyricsFocusLayout
            } else {
                ImmersiveSplitWindowView(state: state)
            }
        case .appleMusicImmersiveV3:
            EmptyView()
        case .directionDV4:
            EmptyView()
        }
    }

    private func resolvedClassicPresentation(width: CGFloat) -> ClassicCompanionPresentation {
        settings.classicCompanionPresentation.resolved(forWidth: width)
    }

    /// Direction D V4 is a layout projection only.  All commands still route
    /// to the existing PlaybackState and lyric entry points; this router does
    /// not own a second session, timer or search manager.
    private var directionDRouter: DirectionDActionRouter {
        DirectionDActionRouter(
            onRetryPlaybackDetection: {
                state.startProvider(connectSpotify: settings.connectSpotifyOnLaunch)
            },
            onRetryLyricsSearch: {
                state.retryLyrics()
            },
            onOpenManualLyricsSearch: {
                isSearchPresented = true
            },
            onImportLyrics: {
                DirectionDActionRouter.performManualLyricsImport(
                    prepare: { state.prepareManualLyricsFromTXT() },
                    openEditor: { openWindow(id: "lyrics-editor") }
                )
            },
            onOpenSettings: {
                openSettings()
            },
            onRetryAutomaticAlignment: {
                AutomaticAlignmentJobController.shared.retry()
            },
            onStopAutomaticAlignment: {
                AutomaticAlignmentJobController.shared.cancelCurrentJob(userInitiated: true)
            }
        )
    }

    private func topBar(usesLyricsFocus: Bool) -> some View {
        HStack(spacing: LyricsDesignTokens.headerSpacing) {
            windowModeMenu

            if usesLyricsFocus {
                TrackHeaderView(track: state.currentTrack)
            } else {
                Image(systemName: MainWindowLayoutStyle.immersiveSplit.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LyricsDesignTokens.accent)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("当前主窗口布局：经典伴随沉浸分栏")
            }

            Spacer(minLength: 20)

            providerStatusMenu
            searchButton
            layoutMenu
            preferencesButton
        }
    }

    private var lyricsFocusLayout: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if !state.canControlSpotify || state.isUsingMockPreview {
                    providerRecoveryBar
                        .padding(.horizontal, LyricsDesignTokens.immersiveWindowPadding)
                        .padding(.top, 10)
                }

                LyricsViewport(state: state, onSearch: { isSearchPresented = true })
            }

            PlaybackControlsView(state: state)
                .padding(.horizontal, LyricsDesignTokens.immersiveWindowPadding)
                .padding(.top, 10)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.02),
                            Color.black.opacity(0.52)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                )
        }
    }

    private var preferencesButton: some View {
        SettingsLink {
            Label("显示设置", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LyricsDesignTokens.secondaryText)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help("打开设置")
        .accessibilityLabel("打开设置")
    }

    private var searchButton: some View {
        Button {
            isSearchPresented.toggle()
        } label: {
            Label("搜索歌曲", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LyricsDesignTokens.secondaryText)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isSearchPresented ? LyricsDesignTokens.controlBackground.opacity(1.5) : .clear)
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isSearchPresented, arrowEdge: .top) {
            SongSearchPopover(
                manager: state.songSearchManager,
                playbackState: state
            )
        }
        .help("搜索歌曲或歌词")
        .accessibilityLabel("搜索歌曲")
    }

    private var layoutMenu: some View {
        Menu {
            Section("主窗口布局") {
                ForEach(MainWindowLayoutStyle.userSelectableCases) { style in
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            _ = settings.applyPresentationSelection(
                                category: .mainWindow,
                                stableID: style.presentationStableID
                            )
                        }
                    } label: {
                        Label(style.title, systemImage: style.systemImage)
                    }
                }
            }
            if layoutStyle == .immersiveSplit {
                Section("经典伴随呈现") {
                    ForEach(ClassicCompanionPresentation.allCases) { presentation in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                settings.classicCompanionPresentation = presentation
                            }
                        } label: {
                            if settings.classicCompanionPresentation == presentation {
                                Label(presentation.title, systemImage: "checkmark")
                            } else {
                                Text(presentation.title)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("布局：\(layoutStyle.title)", systemImage: layoutStyle.systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LyricsDesignTokens.secondaryText)
                .frame(width: 36, height: 36)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("切换主窗口布局，不会重置播放或歌词位置")
        .accessibilityLabel("主窗口布局：\(layoutStyle.title)")
    }

    private var providerStatusMenu: some View {
        Menu {
            Text(state.providerStatusMessage)

            if state.isUsingMockPreview {
                Button("退出 Mock Preview") {
                    state.exitMockPreview()
                }
            } else if state.canControlSpotify {
                if state.canOpenLyricsEditor {
                    Button("编辑当前歌词", systemImage: "pencil.and.list.clipboard") {
                        state.prepareLyricsEditor()
                        openWindow(id: "lyrics-editor")
                    }
                }
                let showAutoComplete: Bool = {
                    switch state.liveLyricsState {
                    case .failed, .noMatch, .noLyrics, .alignmentQueued, .alignmentRunning, .alignmentPreview, .candidates, .loading:
                        return true
                    default:
                        return false
                    }
                }()
                if showAutoComplete {
                    Button("自动补全歌词") {
                        state.autoCompleteLyrics()
                    }
                }
            } else {
                Button("进入 Mock Preview") {
                    state.enterMockPreview()
                }
                Button("重试 Spotify") {
                    state.reconnectSpotify()
                }
            }
        } label: {
            Circle()
                .fill(state.canControlSpotify ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(14)
                .background(
                    Circle()
                        .fill(LyricsDesignTokens.controlBackground.opacity(0.58))
                )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("播放来源与歌词重试")
        .accessibilityLabel("播放来源：\(state.providerStatusMessage)")
    }

    private var providerRecoveryBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isUsingMockPreview ? Color.orange : Color.orange.opacity(0.86))
                .frame(width: 7, height: 7)

            Text(state.providerStatusMessage)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if state.isUsingMockPreview {
                Button("退出 Mock Preview") {
                    state.exitMockPreview()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LyricsDesignTokens.accent)
            } else {
                Button("进入 Mock Preview") {
                    state.enterMockPreview()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LyricsDesignTokens.accent)

                Button("重试 Spotify") {
                    state.reconnectSpotify()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LyricsDesignTokens.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(LyricsDesignTokens.controlBackground.opacity(0.52))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(LyricsDesignTokens.controlBorder.opacity(0.7), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("播放来源：\(state.providerStatusMessage)")
    }

    private var windowModeMenu: some View {
        Menu {
            Button("主窗口", systemImage: "macwindow") {
                state.currentMode = .mainWindow
            }
            Divider()
            Button("悬浮歌词", systemImage: "rectangle.on.rectangle") {
                WindowManager.shared.toggleFloatingLyrics(state: state)
            }
            Menu("悬浮歌词交互") {
                Button("可编辑 / 可拖动") {
                    WindowManager.shared.setFloatingInteractionMode(.interactive, state: state)
                }
                Button("锁定展示") {
                    WindowManager.shared.setFloatingInteractionMode(.locked, state: state)
                }
                Button("启用鼠标穿透") {
                    WindowManager.shared.setFloatingInteractionMode(.passThrough, state: state)
                }
                Divider()
                Button("解除鼠标穿透") {
                    WindowManager.shared.restoreFloatingInteractiveMode(state: state)
                }
            }
            Button("顶部胶囊", systemImage: "capsule") {
                WindowManager.shared.toggleCapsule(state: state)
            }
            Button("全屏歌词", systemImage: "arrow.up.left.and.arrow.down.right") {
                WindowManager.shared.toggleFullScreen(state: state)
            }
        } label: {
            Label("窗口模式", systemImage: "rectangle.on.rectangle")
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LyricsDesignTokens.secondaryText)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(LyricsDesignTokens.controlBackground)
                        .overlay(Circle().stroke(LyricsDesignTokens.controlBorder, lineWidth: 1))
                )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("窗口模式：主窗口、悬浮歌词、顶部胶囊或全屏歌词")
        .accessibilityLabel("窗口模式")
    }
}
