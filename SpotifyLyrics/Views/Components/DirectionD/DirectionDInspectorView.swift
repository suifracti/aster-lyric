import SwiftUI

/// Native macOS Inspector Component for Song Workbench (Direction D).
///
/// The primary surface uses continuous sections and user-task language rather
/// than a dashboard of status cards.  It remains a presentation-only view:
/// actions are supplied by the existing router/operation layer.
public struct DirectionDInspectorView: View {
    public let trackTitle: String
    public let artistName: String
    public let albumName: String
    public let artworkImage: Image?
    public let onClose: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        trackTitle: String = "丸ノ内サディスティック",
        artistName: String = "椎名林檎",
        albumName: String = "無罪モラトリアム",
        artworkImage: Image? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumName = albumName
        self.artworkImage = artworkImage
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))

                Text("歌曲工作台")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("关闭歌曲工作台")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()
                .overlay(Color.white.opacity(DirectionDDesignTokens.Surface.hairlineOpacity))

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    trackSummary
                    sectionDivider

                    inspectorSection(title: "Direction D 实验界面", icon: "info.circle") {
                        Text("这里显示当前歌曲信息。歌词版本、翻译、读音和时间轴状态暂未接入此工作台。")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    sectionDivider

                    inspectorSection(title: "工作台操作", icon: "ellipsis.circle") {
                        Text("候选切换、搜索、校准、历史版本及导入导出暂不可在此操作。请使用主窗口的搜索或现有歌词编辑入口。")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
        }
        .background {
            ZStack {
                Color.black.opacity(reduceTransparency ? 0.94 : 0.78)
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(reduceTransparency ? 0.04 : 0.30)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(DirectionDDesignTokens.Surface.hairlineOpacity))
                .frame(width: 1)
        }
    }

    private var trackSummary: some View {
        HStack(spacing: 12) {
            if let artworkImage {
                artworkImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.52))
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(trackTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(artistName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(albumName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(Color.white.opacity(DirectionDDesignTokens.Surface.hairlineOpacity))
            .padding(.vertical, 16)
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
            }
            content()
        }
    }


}

/// Small window Sheet Overlay component for Direction D.
/// Emerges from bottom of viewport, max height ~80%, legible dark glass surface with ScrollView.
public struct DirectionDSmallSheetView: View {
    public let trackTitle: String
    public let artistName: String
    public let albumName: String
    public let onClose: () -> Void

    public init(
        trackTitle: String = "丸ノ内サディスティック",
        artistName: String = "椎名林檎",
        albumName: String = "無罪モラトリアム",
        onClose: @escaping () -> Void
    ) {
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumName = albumName
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.40))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)

            DirectionDInspectorView(
                trackTitle: trackTitle,
                artistName: artistName,
                albumName: albumName,
                onClose: onClose
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(.thickMaterial)
                .opacity(0.92)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.48), radius: 16, x: 0, y: -4)
    }
}
