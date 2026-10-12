import SwiftUI

/// The real Direction D main-window presentation.
///
/// This surface is deliberately a projection of the application's existing
/// `PlaybackState` and Direction D product adapter.  It does not create a
/// player, lyric session, provider, repository, timer, or a second current-line
/// calculator.  Preview fixtures live in the Preview Lab, never in this view.
public struct DirectionDMainWindowView: View {
    @ObservedObject public var playbackState: PlaybackState
    @ObservedObject public var adapter: DirectionDProductStateAdapter
    public var router: DirectionDActionRouter
    public let presentationStableID: String
    public let userLayoutMode: DirectionDLayoutMode?

    @State private var isInspectorOpen = false
    @State private var isSmallSheetOpen = false
    @State private var draftSeek: Double?
    @State private var lastDirectionDScrollTargetID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        playbackState: PlaybackState,
        adapter: DirectionDProductStateAdapter,
        router: DirectionDActionRouter = DirectionDActionRouter(),
        presentationStableID: String = "mainWindow.directionD.v4",
        userLayoutMode: DirectionDLayoutMode? = nil
    ) {
        self._playbackState = ObservedObject(wrappedValue: playbackState)
        self._adapter = ObservedObject(wrappedValue: adapter)
        self.router = router
        self.presentationStableID = presentationStableID
        self.userLayoutMode = userLayoutMode
    }

    private var currentTrack: Track { playbackState.currentTrack }
    private var trackTitle: String { currentTrack.title }
    private var artistName: String { currentTrack.artist }
    private var albumName: String { currentTrack.album }
    private var trackSummaryTitle: String {
        DirectionDTrackSummaryPresentation.displayTitle(
            trackTitle,
            hasCurrentTrack: playbackState.hasLiveTrack || playbackState.isMockPreviewMode
        )
    }
    private var isPlaying: Bool { playbackState.isPlaying }
    private var currentTime: Double { playbackState.currentTime }
    private var totalDuration: Double { max(1, currentTrack.duration) }

    /// Forced states are restricted to DEBUG acceptance launches.  Normal
    /// Direction D always renders the live projection, never a search preview.
    private var isControlledAcceptanceState: Bool {
#if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DIRECTION_D_HOST_STATE"] else {
            return false
        }
        return DirectionDProductStateAdapter.isAcceptanceFixtureKey(raw)
#else
        return false
#endif
    }

    private var projectedLyrics: [LyricLine] {
        if isControlledAcceptanceState {
            return adapter.lyricsLines
        }
        guard playbackState.liveLyricsDocumentMatchesCurrentTrack else { return [] }
        return playbackState.liveLyrics
    }

    private var projectedCurrentLineIndex: Int? {
        if isControlledAcceptanceState {
            return projectedLyrics.isEmpty ? nil : 0
        }
        guard playbackState.liveLyricsDocumentMatchesCurrentTrack else { return nil }
        return playbackState.liveCurrentLineIndex
    }

    /// Direction D keeps the one-auxiliary-layer rule, but the selected layer
    /// still comes from the shared display preferences.  The main-window
    /// surface must not invent a second reading/translation preference store.
    private var lyricPolicy: DirectionDLyricsPolicy {
        let auxiliary: DirectionDLyricsPolicy.AuxiliaryChoice
        if playbackState.preferences.kanaDisplayMode != .hidden {
            auxiliary = .ruby
        } else if playbackState.preferences.showTranslation {
            auxiliary = .translation
        } else {
            auxiliary = .none
        }
        return DirectionDLyricsPolicy(
            defaultAuxiliaryChoice: auxiliary,
            hideDistantAuxiliary: playbackState.preferences.hideDistantAuxiliary
        )
    }

#if DEBUG
    private var debugAcceptanceState: String {
        ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DIRECTION_D_HOST_STATE"]?.lowercased() ?? ""
    }

    private func applyDebugAcceptanceSurfaceState() {
        switch debugAcceptanceState {
        case "wide-inspector", "wide_inspector", "inspector":
            isInspectorOpen = true
        case "small-sheet", "small_sheet", "sheet":
            isSmallSheetOpen = true
        default:
            break
        }
    }
#endif

    public var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let availableHeight = geometry.size.height
            let mode = DirectionDResponsiveLayout.resolveMode(
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                userOverrideMode: userLayoutMode
            )
            ZStack {
                // Reuse the production artwork/palette pipeline.  Playback
                // progress is not part of its task key.
                ArtworkBackgroundView(state: playbackState)
                    .environment(\.directionDBackdropTreatment, true)

                switch mode {
                case .wide:
                    renderWideLayout(width: availableWidth, height: availableHeight)
                case .small:
                    renderSmallLayout(width: availableWidth, height: availableHeight)
                case .lyricsFocus:
                    renderLyricsFocusLayout(width: availableWidth, height: availableHeight)
                }

                if mode == .small && isSmallSheetOpen {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .onTapGesture { isSmallSheetOpen = false }

                        DirectionDSmallSheetView(
                            trackTitle: trackSummaryTitle,
                            artistName: artistName.isEmpty ? "—" : artistName,
                            albumName: albumName,
                            onClose: { isSmallSheetOpen = false }
                        )
                            .frame(
                                maxWidth: max(0, availableWidth - 24),
                                maxHeight: min(availableHeight * 0.74, 560)
                            )
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom))
                    }
                }
            }
            .animation(
                DirectionDDesignTokens.Motion.animation(reduceMotion: reduceMotion),
                value: mode
            )
        }
        .preferredColorScheme(.dark)
        // Keep a direct Debug host from autosizing to the intrinsic height of
        // a transient status view while the live document is being replaced.
        // This is a presentation envelope only; responsive mode still comes
        // from the actual window geometry above.
        .frame(minWidth: DirectionDDesignTokens.Spacing.windowSmall, minHeight: 520)
        .accessibilityIdentifier(presentationStableID)
        .onAppear {
            adapter.bind(playback: playbackState)
#if DEBUG
            applyDebugAcceptanceSurfaceState()
#endif
        }
        .onDisappear { adapter.unbind() }
    }

    // MARK: - Layouts

    @ViewBuilder
    private func renderWideLayout(width: CGFloat, height: CGFloat) -> some View {
        let leftWidth = min(320, max(280, width * 0.28))
        let metadataHeight: CGFloat = 76
        let progressHeight: CGFloat = 56
        let controlsHeight: CGFloat = 44
        let verticalSpacing: CGFloat = 18 * 2 + 16
        let availableArtworkHeight = max(
            164,
            height - 48 - metadataHeight - progressHeight - controlsHeight - verticalSpacing
        )
        let artworkSize = min(244, max(184, min(leftWidth - 48, availableArtworkHeight)))

        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                ArtworkView(track: currentTrack, size: artworkSize, showsAlbumLabel: false)

                VStack(alignment: .leading, spacing: 5) {
                    Text(trackTitle.isEmpty ? "等待歌曲" : trackTitle)
                        .font(DirectionDDesignTokens.Typography.trackTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(artistName.isEmpty ? "—" : artistName)
                        .font(DirectionDDesignTokens.Typography.trackArtist)
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                    Text(albumName.isEmpty ? "—" : albumName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 16) {
                    playbackProgress
                    playbackControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(width: leftWidth, height: height, alignment: .center)

            VStack(spacing: 0) {
                DirectionDQuietToolbar(
                    isInspectorOpen: isInspectorOpen,
                    canPresentWindowActions: router.canPresentWindowActions,
                    onToggleInspector: {
                        isInspectorOpen.toggle()
                        router.onOpenSongWorkbench()
                    },
                    onOpenSearch: { router.onOpenManualLyricsSearch() },
                    onOpenSettings: { router.onOpenSettings() }
                )

                renderLyricsSurface(
                    availableWidth: width - leftWidth - (isInspectorOpen ? DirectionDDesignTokens.Spacing.inspectorWidth : 0),
                    availableHeight: max(1, height - 48)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isInspectorOpen {
                DirectionDInspectorView(
                    trackTitle: trackSummaryTitle,
                    artistName: artistName.isEmpty ? "—" : artistName,
                    albumName: albumName,
                    onClose: { isInspectorOpen = false }
                )
                .frame(width: DirectionDDesignTokens.Spacing.inspectorWidth)
                .transition(.move(edge: .trailing))
            }
        }
        // The responsive projection is a full-height surface inside the
        // outer ZStack.  Making that contract explicit prevents SwiftUI from
        // centering an intrinsic status/lyrics proposal at the bottom of the
        // window while the player column is still using the bounded height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func renderSmallLayout(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ArtworkView(track: currentTrack, size: 36, showsAlbumLabel: false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(trackTitle.isEmpty ? "等待歌曲" : trackTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(artistName.isEmpty ? "—" : artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: { playbackState.togglePlayPause() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                DirectionDQuietToolbar(
                    isInspectorOpen: isSmallSheetOpen,
                    canPresentWindowActions: router.canPresentWindowActions,
                    onToggleInspector: {
                        isSmallSheetOpen.toggle()
                        router.onOpenSongWorkbench()
                    },
                    onOpenSearch: { router.onOpenManualLyricsSearch() },
                    onOpenSettings: { router.onOpenSettings() },
                    compact: true
                )
                .layoutPriority(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.24))

            renderLyricsSurface(
                availableWidth: width,
                availableHeight: max(1, height - 58)
            )
        }
    }

    @ViewBuilder
    private func renderLyricsFocusLayout(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            DirectionDQuietToolbar(
                isInspectorOpen: isInspectorOpen,
                canPresentWindowActions: router.canPresentWindowActions,
                onToggleInspector: {
                    isInspectorOpen.toggle()
                    router.onOpenSongWorkbench()
                },
                onOpenSearch: { router.onOpenManualLyricsSearch() },
                onOpenSettings: { router.onOpenSettings() }
            )

            renderLyricsSurface(
                availableWidth: width,
                isFocusMode: true,
                availableHeight: max(1, height - 96)
            )

            HStack(spacing: 16) {
                Text(trackTitle.isEmpty ? "等待歌曲" : "\(trackTitle) — \(artistName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Spacer()

                Button(action: { playbackState.togglePlayPause() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))

        }
    }

    // MARK: - Shared playback controls

    private var playbackProgress: some View {
        VStack(spacing: 6) {
            Slider(
                value: seekBinding,
                in: 0...max(totalDuration, 1)
            ) { editing in
                if !editing, let draftSeek {
                    playbackState.seek(to: draftSeek, source: "direction-d-main-window-slider")
                    self.draftSeek = nil
                }
            }
            .tint(.white)

            HStack {
                Text(formatTime(currentTime))
                Spacer()
                Text(formatTime(currentTrack.duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.60))
        }
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: { draftSeek ?? min(max(0, currentTime), max(totalDuration, 1)) },
            set: { draftSeek = $0 }
        )
    }

    private var playbackControls: some View {
        HStack(spacing: 24) {
            Button(action: { playbackState.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .buttonStyle(.plain)

            Button(action: { playbackState.togglePlayPause() }) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(action: { playbackState.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Lyrics and state projection

    /// Keeps the secondary product-status banner in the same bounded surface
    /// as the lyric projection.  Overlaying it avoids the old greedy
    /// ScrollView frame compressing the banner to zero height while leaving
    /// the lyric document readable behind it.
    @ViewBuilder
    private func renderLyricsSurface(
        availableWidth: CGFloat,
        isFocusMode: Bool = false,
        availableHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .bottom) {
            renderLyricsCanvas(
                availableWidth: availableWidth,
                isFocusMode: isFocusMode,
                availableHeight: availableHeight
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            renderSecondaryStatusBanner()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderLyricsCanvas(
        availableWidth: CGFloat,
        isFocusMode: Bool = false,
        availableHeight: CGFloat
    ) -> some View {
        switch adapter.primaryState {
        case .permissionRequired:
            statusActions(
                message: DirectionDDesignTokens.UserTaskLanguage.permissionRequiredMessage,
                icon: "lock.shield",
                primaryTitle: "打开系统设置",
                primary: { router.onOpenSystemSettings() },
                secondaryTitle: "重新检查",
                secondary: { router.onRetryPlaybackDetection() }
            )
        case .spotifyNotRunning:
            statusActions(
                message: DirectionDDesignTokens.UserTaskLanguage.spotifyNotRunningMessage,
                icon: "music.note.tv",
                primaryTitle: "打开 Spotify",
                primary: { router.onOpenSpotify() },
                secondaryTitle: "重新检查",
                secondary: { router.onRetryPlaybackDetection() }
            )
        case .spotifyUnavailable:
            statusActions(
                message: "暂时无法连接 Spotify",
                icon: "exclamationmark.triangle",
                primaryTitle: "重新检查",
                primary: { router.onRetryPlaybackDetection() }
            )
        case .waitingForPlayback:
            DirectionDStatusBanner(stateKind: .idle)
        case .loadingLyrics:
            DirectionDStatusBanner(stateKind: .loading)
        case .noLyrics:
            statusActions(
                message: DirectionDDesignTokens.UserTaskLanguage.notFoundMessage,
                icon: "text.magnifyingglass",
                primaryTitle: "手动搜索歌词",
                primary: { router.onOpenManualLyricsSearch() },
                primaryDisabledReason: router.canPresentWindowActions ? nil : "此诊断窗口无法打开歌词搜索，请使用主窗口。",
                secondaryTitle: "导入本地歌词",
                secondary: { router.onImportLyrics() },
                secondaryDisabledReason: router.canPresentWindowActions ? nil : "此诊断窗口无法打开歌词编辑器，请使用主窗口导入。"
            )
        case .networkUnavailableNoCache:
            statusActions(
                message: DirectionDDesignTokens.UserTaskLanguage.networkErrorMessage,
                icon: "wifi.slash",
                primaryTitle: "重新尝试",
                primary: { router.onRetryLyricsSearch() },
                secondaryTitle: "导入本地歌词",
                secondary: { router.onImportLyrics() },
                secondaryDisabledReason: router.canPresentWindowActions ? nil : "此诊断窗口无法打开歌词编辑器，请使用主窗口导入。"
            )
        case .showingLyrics:
            if projectedLyrics.isEmpty {
                DirectionDStatusBanner(stateKind: .notFound)
            } else {
                GeometryReader { canvasGeometry in
                    let viewportHeight = max(canvasGeometry.size.height, availableHeight)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: isFocusMode ? 22 : 14) {
                                Color.clear
                                    .frame(height: viewportHeight * DirectionDDesignTokens.Lyrics.readingAnchor.y)
                                    .allowsHitTesting(false)

                                ForEach(Array(projectedLyrics.enumerated()), id: \.element.id) { index, line in
                                    let activeIndex = projectedCurrentLineIndex
                                    let isActive = activeIndex == index
                                    let distance = activeIndex.map { abs(index - $0) } ?? index + 1

                                    if isActive {
                                        // Anchor immediately before the active
                                        // row so the row itself grows downward
                                        // from the shared reading band. A
                                        // one-point view-only marker keeps the
                                        // lyric stream and live line index
                                        // unchanged while avoiding the old
                                        // bottom-biased layout.
                                        Color.clear
                                            .frame(height: 1)
                                            .id(directionDReadingTargetID(for: line.id))
                                            .allowsHitTesting(false)
                                    }

                                    DirectionDLyricRowView(
                                        line: line,
                                        isActive: isActive,
                                        distance: distance,
                                        policy: lyricPolicy,
                                        availableWidth: availableWidth
                                    )
                                    .id(line.id)
                                }

                                Color.clear
                                    .frame(height: viewportHeight * (1 - DirectionDDesignTokens.Lyrics.readingAnchor.y))
                                    .allowsHitTesting(false)
                            }
                            .padding(.horizontal, isFocusMode ? 30 : 20)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                        }
                        // Give ScrollViewReader a concrete viewport. Without
                        // this explicit proposal on macOS, a lazy lyric
                        // document can accept its content height and the
                        // row-ID scroll request leaves the active line near
                        // the bottom instead of the shared reading band.
                        .frame(
                            width: canvasGeometry.size.width,
                            height: viewportHeight,
                            alignment: .top
                        )
                        .scrollIndicators(.hidden)
                        .onAppear {
                            lastDirectionDScrollTargetID = nil
                            scrollDirectionDToCurrentLine(using: proxy, animated: false)
                        }
                        .onChange(of: projectedLyrics.count) { _, _ in
                            // The document may arrive after the first layout
                            // pass.  Reset the view-only target so the shared
                            // live index is applied once the rows exist.
                            lastDirectionDScrollTargetID = nil
                            scrollDirectionDToCurrentLine(using: proxy, animated: false)
                        }
                        .onChange(of: projectedCurrentLineIndex) { _, _ in
                            scrollDirectionDToCurrentLine(using: proxy, animated: true)
                        }
                        .onChange(of: playbackState.liveLyricsSessionRevision) { _, _ in
                            lastDirectionDScrollTargetID = nil
                            scrollDirectionDToCurrentLine(using: proxy, animated: false)
                        }
                        .onChange(of: playbackState.liveLyricsDocumentMatchesCurrentTrack) { _, matches in
                            guard matches else { return }
                            lastDirectionDScrollTargetID = nil
                            scrollDirectionDToCurrentLine(using: proxy, animated: false)
                        }
                        .onChange(of: canvasGeometry.size) { _, _ in
                            // A resize changes only the view projection. Keep
                            // the shared current line and re-apply its row ID
                            // to the new reading band.
                            lastDirectionDScrollTargetID = nil
                            scrollDirectionDToCurrentLine(using: proxy, animated: false)
                        }
                    }
                }
                .frame(height: availableHeight)
            }
        }
    }

    /// Adapts the existing shared `liveCurrentLineIndex` to Direction D's
    /// local ScrollViewReader.  This is a view-only scroll coordinator: it
    /// does not calculate a second line index, own a timer, or mutate the
    /// lyric session.  A scroll target is valid only for the identity-guarded
    /// live projection already used to render the row.
    private func scrollDirectionDToCurrentLine(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard playbackState.liveLyricsDocumentMatchesCurrentTrack,
              let currentIndex = projectedCurrentLineIndex,
              projectedLyrics.indices.contains(currentIndex) else {
            return
        }

        let line = projectedLyrics[currentIndex]
        guard lastDirectionDScrollTargetID != line.id else { return }
        let action = {
            // Use the rendered row as the final macOS anchor. The adjacent
            // one-point marker remains the stable view-only target for
            // diagnostics, while anchoring the row itself avoids LazyVStack
            // resolving the marker at the wrong edge of the viewport.
            proxy.scrollTo(line.id, anchor: .top)
            lastDirectionDScrollTargetID = line.id
#if DEBUG
            if let identity = playbackState.liveTrackIdentity {
                let timeText = String(format: "%.3f", playbackState.currentTime)
                let lineStartText = String(format: "%.3f", line.timestamp)
                LyricsE2ELog.log(
                    "D_SCROLL identity=\(identity.stableKey) time=\(timeText) index=\(currentIndex) lineStart=\(lineStartText) targetID=\(line.id.uuidString)"
                )
            }
#endif
        }

        if animated {
            LyricsTransitionPolicy.perform(reduceMotion: reduceMotion, action)
        } else {
            action()
        }

        // ScrollViewReader can receive the first identity update before the
        // newly arrived rows have been laid out. Re-issue the same target on
        // the next main-queue turn; this is a one-shot view-layout retry, not
        // a polling timer or a second current-line algorithm.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard playbackState.liveLyricsDocumentMatchesCurrentTrack,
                  let retryIndex = projectedCurrentLineIndex,
                  projectedLyrics.indices.contains(retryIndex),
                  projectedLyrics[retryIndex].id == line.id else {
                return
            }
            proxy.scrollTo(line.id, anchor: .top)
        }
    }

    private func directionDReadingTargetID(for lineID: UUID) -> String {
        "direction-d-reading-target-\(lineID.uuidString)"
    }

    @ViewBuilder
    private func statusActions(
        message: String,
        icon: String,
        primaryTitle: String,
        primary: @escaping () -> Void,
        primaryDisabledReason: String? = nil,
        secondaryTitle: String? = nil,
        secondary: (() -> Void)? = nil,
        secondaryDisabledReason: String? = nil,
        tertiaryTitle: String? = nil,
        tertiary: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Text(message)
                .font(DirectionDDesignTokens.Typography.statusMessage)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Button(primaryTitle, action: primary)
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryDisabledReason != nil)
                    .help(primaryDisabledReason ?? primaryTitle)
                if let secondaryTitle, let secondary {
                    Button(secondaryTitle, action: secondary)
                        .buttonStyle(.bordered)
                        .disabled(secondaryDisabledReason != nil)
                        .help(secondaryDisabledReason ?? secondaryTitle)
                }
            }
            if primaryDisabledReason != nil || secondaryDisabledReason != nil {
                Text("此诊断窗口无法打开搜索或歌词编辑器；请使用主窗口完成这些操作。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
            }

            if let tertiaryTitle, let tertiary {
                Button(tertiaryTitle, action: tertiary)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.74))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderSecondaryStatusBanner() -> some View {
        switch adapter.secondaryState {
        case .none:
            EmptyView()
        case .networkUnavailableWithCache:
            DirectionDStatusBanner(
                stateKind: .networkError,
                customMessage: DirectionDDesignTokens.UserTaskLanguage.networkWithCacheMessage
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(2)
        case .automaticSyncRunning:
            DirectionDStatusBanner(stateKind: .syncing)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        case .automaticSyncProgressSaved:
            DirectionDStatusBanner(stateKind: .partialSaved)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        case .automaticSyncWaiting:
            DirectionDStatusBanner(stateKind: .waitingContinue)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        case .automaticSyncCompleted:
            DirectionDStatusBanner(stateKind: .syncComplete)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        case .automaticSyncUnreliable:
            DirectionDStatusBanner(stateKind: .syncUnreliable)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        case .automaticSyncUnavailable:
            DirectionDStatusBanner(stateKind: .engineNotReady)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        return String(format: "%02d:%02d", Int(safe) / 60, Int(safe) % 60)
    }
}

/// Minimal runtime factory for the four Direction D catalog identities.  All
/// identities intentionally resolve to the same live main-window surface; the
/// catalog selects presentation metadata while PlaybackState remains singular.
@MainActor
public enum DirectionDMainWindowPresentationFactory {
    public static let supportedStableIDs: Set<String> = [
        "mainWindow.directionD.v4",
        // Historical Direction D identities remain resolvable for existing
        // debug evidence and rollback, but are not aliases for V3.
        "mainWindow.directionDQuiet.v1",
        "mainWindow.directionDWorkbenchInspector.v1",
        "lyricsStatePresentation.directionDUserLanguage.v1",
        "responsiveLayout.directionDInspector.v1"
    ]

    public static func makeMainWindow(
        stableID: String,
        playbackState: PlaybackState,
        adapter: DirectionDProductStateAdapter,
        router: DirectionDActionRouter
    ) -> DirectionDMainWindowView {
        let resolvedID = supportedStableIDs.contains(stableID)
            ? stableID
            : "mainWindow.directionD.v4"
        return DirectionDMainWindowView(
            playbackState: playbackState,
            adapter: adapter,
            router: router,
            presentationStableID: resolvedID
        )
    }
}
