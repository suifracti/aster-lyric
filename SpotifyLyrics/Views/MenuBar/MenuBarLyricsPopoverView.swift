import SwiftUI

public struct MenuBarLyricsPopoverView: View {
    @ObservedObject var controller: MenuBarLyricsController

    public init(controller: MenuBarLyricsController) {
        self.controller = controller
    }

    public var body: some View {
        let snapshot = controller.currentSnapshot
        VStack(alignment: .leading, spacing: 12) {
            // Header: Cover artwork + Track title & Artist
            HStack(alignment: .center, spacing: 10) {
                artworkView(snapshot.artworkURL)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.trackTitle ?? "未在播放歌曲")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text(snapshot.artistName ?? "Spotify")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Divider()

            // Lyrics display area
            VStack(alignment: .leading, spacing: 6) {
                switch snapshot.state {
                case .idle:
                    Text("暂无播放中的曲目")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)

                case .loading:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载歌词…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)

                case .synchronized(let current, let next):
                    if current.isEmpty && (next == nil || next?.isEmpty == true) {
                        Text("♪ (前奏 / 间奏)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        if !current.isEmpty {
                            Text(current)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Prefer the adopted Chinese line over the next original
                        // line. Missing translations retain the old next-line preview.
                        if let translated = snapshot.currentTranslationText, !translated.isEmpty {
                            Text(translated)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.76))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("中文译文：\(translated)")
                        } else if let next, !next.isEmpty {
                            Text(next)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                case .unsynchronized:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("歌词尚未同步")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("可在主窗口或编辑器中查看与排轴")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)

                case .noLyrics:
                    Text("未找到歌词")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)

                case .failed:
                    Text("歌词加载失败")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            .frame(minHeight: 44)

            Divider()

            // Transport Controls
            HStack(alignment: .center, spacing: 18) {
                Spacer()

                Button(action: {
                    controller.previousTrack()
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.hasLiveTrack)

                Button(action: {
                    controller.togglePlayPause()
                }) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.hasLiveTrack)

                Button(action: {
                    controller.nextTrack()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.hasLiveTrack)

                Spacer()
            }
            .padding(.vertical, 2)

            Divider()

            Toggle("在菜单栏显示歌词", isOn: Binding(
                get: { controller.menuBarLyricsEnabled },
                set: { controller.menuBarLyricsEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .help("关闭后保留播放状态图标，点击图标仍可打开此菜单")

            // Entrypoints
            VStack(spacing: 2) {
                menuRow(title: "打开 Lyric Island", icon: "macwindow") {
                    controller.openMainWindow()
                }

                menuRow(title: "歌词库与收听记录", icon: "music.note.list") {
                    controller.openLibrary()
                }

                menuRow(title: "设置…", icon: "gearshape") {
                    controller.openSettings()
                }

                Divider()
                    .padding(.vertical, 4)

                menuRow(title: "退出 Lyric Island", icon: "power") {
                    controller.quit()
                }
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    @ViewBuilder
    private func artworkView(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .failure, .empty:
                    fallbackArtwork
                @unknown default:
                    fallbackArtwork
                }
            }
            .frame(width: 38, height: 38)
        } else {
            fallbackArtwork
        }
    }

    private var fallbackArtwork: some View {
        Image(systemName: "music.note")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 38, height: 38)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func menuRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}

private struct HoverRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : (configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear))
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
