import SwiftUI

/// Experimental product-state host for Direction D (Phase 3.3).
/// Renders primary empty/error states and keeps lyrics visible under secondary banners.
/// Does not embed Preview Matrix tabs. All actions go through `DirectionDActionRouter`.
public struct DirectionDProductStateHostView: View {
    @ObservedObject public var adapter: DirectionDProductStateAdapter
    public var router: DirectionDActionRouter

    @State private var isInspectorOpen = false
    @State private var isSmallSheetOpen = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        adapter: DirectionDProductStateAdapter,
        router: DirectionDActionRouter = DirectionDActionRouter()
    ) {
        self.adapter = adapter
        self.router = router
    }

    public var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let isSmallViewport = availableWidth <= DirectionDDesignTokens.Spacing.windowSmall

            ZStack {
                DirectionDDesignTokens.Surface.defaultCanvasGradient
                    .opacity(reduceTransparency ? 1 : 0.98)
                    .edgesIgnoringSafeArea(.all)

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        DirectionDQuietToolbar(
                            isInspectorOpen: isInspectorOpen,
                            onToggleInspector: {
                                if isSmallViewport {
                                    isSmallSheetOpen.toggle()
                                } else {
                                    isInspectorOpen.toggle()
                                }
                                router.onOpenSongWorkbench()
                            },
                            onOpenSearch: { router.onOpenManualLyricsSearch() },
                            onOpenSettings: { router.onOpenSettings() }
                        )

                        Spacer(minLength: 12)

                        renderPrimaryContent(width: availableWidth)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        renderSecondaryBanner()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isSmallViewport && isInspectorOpen {
                        DirectionDInspectorView(
                            trackTitle: DirectionDTrackSummaryPresentation.displayTitle(
                                adapter.trackTitle,
                                hasCurrentTrack: adapter.hasTrackForDisplay
                            ),
                            artistName: adapter.trackArtist.isEmpty ? "—" : adapter.trackArtist,
                            albumName: adapter.trackAlbum,
                            onClose: { isInspectorOpen = false }
                        )
                        .frame(width: DirectionDDesignTokens.Spacing.inspectorWidth)
                        .transition(.move(edge: .trailing))
                    }
                }

                if isSmallViewport && isSmallSheetOpen {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.40)
                            .edgesIgnoringSafeArea(.all)
                            .onTapGesture { isSmallSheetOpen = false }
                        DirectionDSmallSheetView(
                            trackTitle: DirectionDTrackSummaryPresentation.displayTitle(
                                adapter.trackTitle,
                                hasCurrentTrack: adapter.hasTrackForDisplay
                            ),
                            artistName: adapter.trackArtist.isEmpty ? "—" : adapter.trackArtist,
                            albumName: adapter.trackAlbum,
                            onClose: { isSmallSheetOpen = false }
                        )
                            .transition(.move(edge: .bottom))
                    }
                }
            }
        }
        .accessibilityIdentifier("directionD.productStateHost")
    }

    @ViewBuilder
    private func renderPrimaryContent(width: CGFloat) -> some View {
        switch adapter.primaryState {
        case .permissionRequired:
            emptyActions(
                message: DirectionDDesignTokens.UserTaskLanguage.permissionRequiredMessage,
                icon: "lock.shield",
                primaryTitle: "打开系统设置",
                primary: { router.onOpenSystemSettings() },
                secondaryTitle: "重新检查",
                secondary: { router.onRetryPlaybackDetection() }
            )

        case .spotifyNotRunning:
            emptyActions(
                message: DirectionDDesignTokens.UserTaskLanguage.spotifyNotRunningMessage,
                icon: "music.note.tv",
                primaryTitle: "打开 Spotify",
                primary: { router.onOpenSpotify() },
                secondaryTitle: "重新检查",
                secondary: { router.onRetryPlaybackDetection() }
            )

        case .spotifyUnavailable:
            emptyActions(
                message: "暂时无法连接 Spotify",
                icon: "exclamationmark.triangle",
                primaryTitle: "重新检查",
                primary: { router.onRetryPlaybackDetection() },
                secondaryTitle: nil,
                secondary: nil
            )

        case .waitingForPlayback:
            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.55))
                Text(DirectionDDesignTokens.UserTaskLanguage.idleMessage)
                    .font(DirectionDDesignTokens.Typography.statusMessage)
                    .foregroundColor(.white.opacity(0.9))
            }

        case .loadingLyrics:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(DirectionDDesignTokens.UserTaskLanguage.searchingMessage)
                    .font(DirectionDDesignTokens.Typography.statusMessage)
                    .foregroundColor(.white.opacity(0.9))
            }

        case .noLyrics:
            emptyActions(
                message: DirectionDDesignTokens.UserTaskLanguage.notFoundMessage,
                icon: "text.magnifyingglass",
                primaryTitle: "手动搜索歌词",
                primary: { router.onOpenManualLyricsSearch() },
                secondaryTitle: "导入本地歌词",
                secondary: { router.onImportLyrics() }
            )

        case .networkUnavailableNoCache:
            emptyActions(
                message: DirectionDDesignTokens.UserTaskLanguage.networkErrorMessage,
                icon: "wifi.slash",
                primaryTitle: "重新尝试",
                primary: { router.onRetryLyricsSearch() },
                secondaryTitle: "导入本地歌词",
                secondary: { router.onImportLyrics() }
            )

        case .showingLyrics:
            // Keep lyrics visible for all secondary overlays (cache / auto-sync).
            lyricsCanvas(width: width)
        }
    }

    @ViewBuilder
    private func lyricsCanvas(width: CGFloat) -> some View {
        let lines = adapter.lyricsLines
        if lines.isEmpty {
            Text("—")
                .foregroundColor(.white.opacity(0.4))
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(Array(lines.prefix(12).enumerated()), id: \.element.id) { index, line in
                        DirectionDLyricRowView(
                            line: line,
                            isActive: index == 0,
                            distance: index,
                            availableWidth: width
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder
    private func emptyActions(
        message: String,
        icon: String,
        primaryTitle: String,
        primary: @escaping () -> Void,
        secondaryTitle: String?,
        secondary: (() -> Void)?,
        tertiaryTitle: String? = nil,
        tertiary: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Text(message)
                .font(DirectionDDesignTokens.Typography.statusMessage)
                .foregroundColor(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 12) {
                Button(primaryTitle, action: primary)
                    .buttonStyle(.borderedProminent)
                if let secondaryTitle, let secondary {
                    Button(secondaryTitle, action: secondary)
                        .buttonStyle(.bordered)
                }
            }
            if let tertiaryTitle, let tertiary {
                Button(tertiaryTitle, action: tertiary)
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.75))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func renderSecondaryBanner() -> some View {
        // Secondary is only meaningful when lyrics remain primary.
        switch adapter.secondaryState {
        case .none:
            EmptyView()
        case .networkUnavailableWithCache:
            DirectionDStatusBanner(
                stateKind: .networkError,
                customMessage: DirectionDDesignTokens.UserTaskLanguage.networkWithCacheMessage
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        case .automaticSyncRunning:
            DirectionDStatusBanner(stateKind: .syncing)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        case .automaticSyncProgressSaved:
            DirectionDStatusBanner(stateKind: .partialSaved)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        case .automaticSyncWaiting:
            DirectionDStatusBanner(stateKind: .waitingContinue)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        case .automaticSyncCompleted:
            DirectionDStatusBanner(stateKind: .syncComplete)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        case .automaticSyncUnreliable:
            DirectionDStatusBanner(stateKind: .syncUnreliable)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        case .automaticSyncUnavailable:
            DirectionDStatusBanner(stateKind: .engineNotReady)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }
}
