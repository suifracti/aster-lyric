import SwiftUI

struct ImmersiveSplitWindowView: View {
    @ObservedObject var state: PlaybackState

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= LyricsDesignTokens.immersiveSplitBreakpoint {
                wideLayout
            } else {
                narrowLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wideLayout: some View {
        GeometryReader { geometry in
            let columnWidth = min(
                max(geometry.size.width * 0.4, 300),
                max(300, min(430, geometry.size.width * 0.42))
            )
            let availableArtwork = min(
                max(geometry.size.height - 274, 190),
                columnWidth - 44
            )
            let artworkSize = min(
                LyricsDesignTokens.immersiveArtworkSize,
                max(190, availableArtwork)
            )

            HStack(spacing: 0) {
                artworkColumn(size: artworkSize)
                    .frame(width: columnWidth)

                Divider()
                    .overlay(LyricsDesignTokens.controlBorder.opacity(0.8))

                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, LyricsDesignTokens.immersiveWindowPadding)
        .padding(.vertical, 20)
    }

    private var narrowLayout: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 20) {
                    artworkColumn(
                        size: min(
                            270,
                            max(190, geometry.size.width - 76)
                        )
                    )
                    lyricsColumn
                        .frame(minHeight: 360)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func artworkColumn(size: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 16) {
            HStack {
                Spacer(minLength: 0)
                ArtworkView(
                    track: state.currentTrack,
                    size: size,
                    showsAlbumLabel: false
                )
                Spacer(minLength: 0)
            }

            TrackMetadataView(
                track: state.currentTrack,
                titleSize: min(24, max(19, size * 0.075)),
                alignment: .center
            )

            PlaybackControlsView(state: state, vertical: true)

            if !state.canControlSpotify || state.isUsingMockPreview {
                statusSummary
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 14)
    }

    private var lyricsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("歌词")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
                    .textCase(.uppercase)
                Spacer()
                if !state.canControlSpotify || state.isUsingMockPreview {
                    Circle()
                        .fill(state.isUsingMockPreview ? Color.orange : Color.orange.opacity(0.86))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("播放来源异常或为预览模式")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            LyricsViewport(state: state)
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.canControlSpotify ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(state.providerStatusMessage)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("播放来源：\(state.providerStatusMessage)")
    }
}
