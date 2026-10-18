import SwiftUI

public struct MenuBarLyricsPopoverView: View {
    @ObservedObject var controller: MenuBarLyricsController
    @ObservedObject private var settings: AppSettingsStore
    @State private var didCopyFullLyrics = false
    @State private var isAppearanceExpanded = false

    public init(controller: MenuBarLyricsController) {
        self.controller = controller
        self.settings = controller.settings
    }

    public var body: some View {
        Group {
            if let fullLyrics = controller.fullLyricsSnapshot {
                fullLyricsPage(fullLyrics)
            } else {
                playbackPage
            }
        }
        .onChange(of: controller.fullLyricsSnapshot) { _, _ in didCopyFullLyrics = false }
    }

    private var playbackPage: some View {
        let snapshot = controller.currentSnapshot
        let artist = snapshot.artistName ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                artworkView(snapshot.artworkURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.trackTitle ?? "等待播放音乐")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(artist.isEmpty ? "Lyric Island" : artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if snapshot.hasLiveTrack {
                    Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(snapshot.isPlaying ? "正在播放" : "已暂停")
                }
            }

            ScrollView {
                lyricsContent(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .frame(height: isAppearanceExpanded ? 100 : 180)
                .padding(14)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)

            // Keep the complete-song action reachable even when one lyric
            // fills the scrollable preview above.
            switch snapshot.state {
            case .synchronized, .unsynchronized:
                Button("查看完整歌词") { controller.showFullLyrics() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            default:
                EmptyView()
            }

            HStack(spacing: 18) {
                Spacer()
                transportButton("backward.fill", title: "上一首", enabled: snapshot.canControlPlayback) {
                    controller.previousTrack()
                }
                transportButton(snapshot.isPlaying ? "pause.fill" : "play.fill",
                                title: snapshot.isPlaying ? "暂停" : "播放",
                                enabled: snapshot.canControlPlayback, prominent: true) {
                    controller.togglePlayPause()
                }
                transportButton("forward.fill", title: "下一首", enabled: snapshot.canControlPlayback) {
                    controller.nextTrack()
                }
                Spacer()
            }
            if snapshot.hasLiveTrack && !snapshot.canControlPlayback {
                Text("播放连接暂不可用，可在主窗口查看连接状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 6) {
                shortcut("主窗口", icon: "macwindow") { controller.openMainWindow() }
                shortcut("歌词库", icon: "books.vertical") { controller.openLibrary() }
                shortcut("设置", icon: "gearshape") { controller.openSettings() }
            }

            HStack(spacing: 6) {
                shortcut("桌面歌词", icon: "text.bubble") { controller.toggleFloatingLyrics() }
                shortcut("顶部胶囊", icon: "capsule") { controller.toggleCapsule() }
                shortcut("恢复拖动", icon: "hand.draw") { controller.restoreFloatingInteraction() }
                    .help("解除桌面歌词的锁定或鼠标穿透，让窗口恢复拖动")
            }

            HStack(spacing: 12) {
                Toggle("菜单栏显示歌词", isOn: $settings.menuBarLyricsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
                .help("关闭后保留播放状态图标，点击图标仍可打开此菜单")
                Spacer(minLength: 0)
                Menu {
                    Button("退出 Lyric Island") { controller.quit() }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }

            DisclosureGroup("状态栏文字外观", isExpanded: $isAppearanceExpanded) {
                ScrollView {
                    MenuBarLyricsAppearanceControls(settings: settings)
                        .padding(.top, 8)
                }
                .frame(height: 150)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .frame(width: 340)
    }

    private func fullLyricsPage(_ lyrics: MenuBarFullLyricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    controller.closeFullLyrics()
                } label: {
                    Label("返回播放", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    didCopyFullLyrics = NSPasteboard.general.setString(lyrics.copyText, forType: .string)
                } label: {
                    Label(didCopyFullLyrics ? "已复制" : "复制全部", systemImage: didCopyFullLyrics ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(lyrics.trackTitle).font(.headline).lineLimit(2).help(lyrics.trackTitle)
                if !lyrics.artistName.isEmpty {
                    Text(lyrics.artistName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                Text(lyrics.lyricsText)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
            }
            .frame(height: 360)
            Text("保留打开时的歌词，可选择文字复制。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 400)
    }

    @ViewBuilder
    private func lyricsContent(_ snapshot: MenuBarLyricsSnapshot) -> some View {
        switch snapshot.state {
        case .idle:
            statusContent("等待当前歌曲", detail: "在 Spotify 或 Apple Music 播放音乐后，这里会显示当前歌词。",
                          symbol: "music.note", actionTitle: "打开主窗口")
        case .loading:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载歌词…").font(.system(size: 13, weight: .medium))
                }
                Text("可先继续听歌，歌词就绪后会自动显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .synchronized(let current, let next):
            VStack(alignment: .leading, spacing: 10) {
                if current.isEmpty {
                    Label("前奏 / 间奏", systemImage: "music.note")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    lyricText(current, translation: snapshot.currentTranslationText)
                }
                if let next, !next.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(current.isEmpty ? "即将开始" : "下一句")
                            .font(.system(size: 10, weight: .medium))
                        Text(next)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        case .unsynchronized:
            VStack(alignment: .leading, spacing: 10) {
                Label("未同步 · 开头歌词", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if let text = snapshot.currentLineText, !text.isEmpty {
                    lyricText(text, translation: snapshot.currentTranslationText)
                }
            }
        case .candidates(_, let count):
            statusContent("找到 \(count) 份候选歌词", detail: "请在主窗口查看并选择要使用的版本。",
                          symbol: "text.badge.checkmark", actionTitle: "查看候选歌词")
        case .noSelection:
            statusContent("当前未采用歌词", detail: "你选择了暂不使用歌词，可随时在主窗口重新选择。",
                          symbol: "rectangle.slash", actionTitle: "查看歌词版本")
        case .notSearched:
            statusContent("尚未搜索歌词", detail: "可在主窗口手动查找歌词或选择已保存的版本。",
                          symbol: "magnifyingglass", actionTitle: "打开当前歌曲")
        case .noLyrics:
            statusContent("没有找到歌词", detail: "可在主窗口调整搜索词、选择其它版本或导入歌词。",
                          symbol: "text.magnifyingglass", actionTitle: "打开当前歌曲")
        case .failed:
            statusContent("歌词暂不可用", detail: "可在主窗口查看状态并重新搜索，播放不会因此中断。",
                          symbol: "exclamationmark.triangle", actionTitle: "查看歌词状态")
        }
    }

    private func lyricText(_ original: String, translation: String?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(original)
                .font(.system(size: 17, weight: .semibold))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("译文：\(translation)")
            }
        }
    }

    private func statusContent(_ title: String, detail: String, symbol: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle) { controller.openCurrentLyrics() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
    }

    private func transportButton(_ symbol: String, title: String, enabled: Bool,
                                 prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 17 : 13, weight: .semibold))
                .frame(width: prominent ? 40 : 32, height: prominent ? 40 : 32)
                .background(Color.primary.opacity(prominent ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .help(title)
    }

    private func shortcut(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
    }

    @ViewBuilder
    private func artworkView(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .failure, .empty:
                    fallbackArtwork
                @unknown default:
                    fallbackArtwork
                }
            }
            .frame(width: 44, height: 44)
        } else {
            fallbackArtwork
        }
    }

    private var fallbackArtwork: some View {
        Image(systemName: "music.note")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MenuBarLyricsAppearanceControls: View {
    @ObservedObject var settings: AppSettingsStore

    private var fontSize: Double {
        Double(MenuBarLyricsAppearance(fontSize: settings.menuBarLyricsFontSize).effectiveFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("显示长度", selection: $settings.menuBarLyricsShowsFullLine) {
                Text("紧凑").tag(false)
                Text("尽量完整").tag(true)
            }
            .pickerStyle(.segmented)
            .help("尽量完整会取消应用的长度限制，实际显示仍取决于系统菜单栏空间。")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                Toggle("原文", isOn: $settings.menuBarLyricsShowsOriginal)
                Toggle("译文", isOn: $settings.menuBarLyricsShowsTranslation)
                Toggle("假名", isOn: $settings.menuBarLyricsShowsKana)
                Toggle("罗马音 / 拼音", isOn: $settings.menuBarLyricsShowsRomaji)
            }
            .toggleStyle(.checkbox)
            Picker("注音位置", selection: $settings.menuBarLyricsReadingsAbove) {
                Text("原文上方").tag(true)
                Text("同一行").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!settings.menuBarLyricsShowsOriginal || (!settings.menuBarLyricsShowsKana && !settings.menuBarLyricsShowsRomaji))
            HStack(spacing: 8) {
                Text("字号")
                Slider(value: Binding(get: { fontSize }, set: { settings.menuBarLyricsFontSize = $0 }),
                       in: 10...18, step: 1)
                    .accessibilityLabel("状态栏歌词字号")
                Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            Text("只显示已有读音，不自动调用 AI。上方注音适应系统菜单栏高度；内容为空时显示歌名。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}

private struct HoverRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .onHover { isHovered = $0 }
    }
}
