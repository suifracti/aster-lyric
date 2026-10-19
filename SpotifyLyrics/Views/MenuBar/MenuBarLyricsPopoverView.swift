import SwiftUI
import AppKit

public struct MenuBarLyricsPopoverView: View {
    @ObservedObject var controller: MenuBarLyricsController
    @ObservedObject private var settings: AppSettingsStore
    @State private var islandAccent: Color = .accentColor
    @State private var didCopyFullLyrics = false
    @State private var isAppearanceExpanded = false
    @State private var readingHeight: CGFloat = 72
    @State private var cachedArtwork: NSImage?

    public init(controller: MenuBarLyricsController) {
        self.controller = controller
        self.settings = controller.settings
    }

    public var body: some View {
        Group {
            if let fullLyrics = controller.fullLyricsSnapshot {
                fullLyricsPage(fullLyrics)
            } else if isAppearanceExpanded {
                appearancePage
            } else {
                playbackPage
            }
        }
        .onChange(of: controller.fullLyricsSnapshot) { _, _ in
            didCopyFullLyrics = false
            controller.resizePopoverToContent()
        }
        .onChange(of: isAppearanceExpanded) { _, _ in controller.resizePopoverToContent() }
        .onChange(of: controller.presentationGeneration) { _, _ in
            isAppearanceExpanded = false
            captureReadingHeight()
        }
        .onChange(of: contentPhase) { _, _ in captureReadingHeight() }
        .onChange(of: controller.currentSnapshot.trackTitle) { _, _ in captureReadingHeight() }
        .onAppear { captureReadingHeight() }
        .task(id: controller.currentSnapshot.artworkURL) {
            let image = await ArtworkImageLoader.shared.image(for: controller.currentSnapshot.artworkURL)
            guard !Task.isCancelled else { return }
            cachedArtwork = image
        }
        .lyricIslandSongTint(artworkURL: controller.currentSnapshot.artworkURL, accent: $islandAccent)
    }

    private var playbackPage: some View {
        let snapshot = controller.currentSnapshot
        let artist = snapshot.artistName ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                artworkView(snapshot.artworkURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.trackTitle ?? "等待播放音乐")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(artist.isEmpty ? "当前播放" : artist)
                        .font(.system(size: 11))
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

            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(islandAccent.opacity(0.9))
                    .frame(width: 2, height: 30)
                    .padding(.top, 4)
                ScrollView {
                    lyricsContent(snapshot)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: readingHeight)
                .accessibilityElement(children: .contain)
            }

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

            HStack(spacing: 22) {
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
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if snapshot.hasLiveTrack && !snapshot.canControlPlayback {
                Text("播放连接暂不可用，可在主窗口查看连接状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    shortcut("主窗口", icon: "macwindow") { controller.openMainWindow() }
                    shortcut("歌词库", icon: "books.vertical") { controller.openLibrary() }
                    shortcut("设置", icon: "gearshape") { controller.openSettings() }
                }
                GridRow {
                    shortcut("桌面歌词", icon: "text.bubble") { controller.toggleFloatingLyrics() }
                    shortcut("顶部胶囊", icon: "capsule") { controller.toggleCapsule() }
                    shortcut("恢复拖动", icon: "hand.draw") { controller.restoreFloatingInteraction() }
                        .help("解除桌面歌词的锁定或鼠标穿透，让窗口恢复拖动")
                }
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

            Button {
                isAppearanceExpanded = true
            } label: {
                HStack {
                    Label("状态栏文字外观", systemImage: "textformat.size")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }.font(.system(size: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.top, 4)

        }
        .padding(14)
        .frame(width: 340)
    }

    private var contentPhase: String {
        switch controller.currentSnapshot.state {
        case .synchronized: return "timed"
        case .unsynchronized: return "plain"
        case .loading: return "loading"
        default: return "status"
        }
    }

    private func captureReadingHeight() {
        let snapshot = controller.currentSnapshot
        func height(_ text: String?, font: CGFloat) -> CGFloat {
            guard let text, !text.isEmpty else { return 0 }
            return ceil((text as NSString).boundingRect(
                with: NSSize(width: 284, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: font)]).height)
        }
        let natural = height(snapshot.currentLineText, font: 17)
            + height(snapshot.currentTranslationText, font: 14)
            + height(snapshot.nextLineText, font: 11) + 24
        let next = contentPhase == "status" ? 112 : contentPhase == "loading" ? 58 : min(210, max(54, natural))
        if abs(readingHeight - next) > 1 { readingHeight = next }
        // New song, page or status family only. Never resize at every clock tick
        // or every synchronized line; overflow stays inside this song's budget.
        controller.resizePopoverToContent()
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { isAppearanceExpanded = false } label: {
                Label("返回播放", systemImage: "chevron.left")
            }.buttonStyle(.borderless).keyboardShortcut(.escape, modifiers: [])
            Text("状态栏文字").font(.headline)
            Text(settings.menuBarLyricsEnabled ? "所有文字层共用同一占用宽度。" : "目前已关闭显示，仍可配置下次启用时的外观。")
                .font(.caption).foregroundStyle(.secondary)
            let preview = MenuBarTextFormatter.statusItemTitle(snapshot: controller.currentSnapshot,
                lyricsEnabled: true, appearance: MenuBarLyricsAppearance(
                    showsFullLine: true, showsOriginal: settings.menuBarLyricsShowsOriginal,
                    showsTranslation: settings.menuBarLyricsShowsTranslation,
                    showsKana: settings.menuBarLyricsShowsKana, showsRomaji: settings.menuBarLyricsShowsRomaji,
                    fontSize: settings.menuBarLyricsFontSize, readingsAbove: settings.menuBarLyricsReadingsAbove))
            Text(preview.isEmpty ? "♪ Lyric Island" : preview)
                .font(.system(size: CGFloat(settings.menuBarLyricsFontSize)))
                .lineLimit(2).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("文字内容预览；实际菜单栏超长显示遵循下方设置")
            ScrollView {
                MenuBarLyricsAppearanceControls(settings: settings)
                    .padding(.vertical, 4)
            }.frame(height: min(410, max(260, (NSScreen.main?.visibleFrame.height ?? 800) - 320)))
        }.padding(16).frame(width: 340)
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
                        Text("下一句")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(islandAccent)
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
        IslandTransportButton(
            systemImage: symbol, label: title, enabled: enabled,
            primary: prominent, tint: islandAccent, glyph: .primary, action: action
        )
    }

    private func shortcut(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
    }

    private var pairedLineMark: some View {
        VStack(alignment: .leading, spacing: 2) {
            Capsule().frame(width: 10, height: 1.5)
            Capsule().frame(width: 7, height: 1.5)
        }
        .foregroundStyle(islandAccent)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func artworkView(_ url: URL?) -> some View {
        if let image = cachedArtwork {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        } else { fallbackArtwork }
    }

    private var fallbackArtwork: some View {
        Image(systemName: "music.note")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(islandAccent)
            .frame(width: 48, height: 48)
            .background(islandAccent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct MenuBarLyricsAppearanceControls: View {
    @ObservedObject var settings: AppSettingsStore

    private var fontSize: Double {
        Double(MenuBarLyricsAppearance(fontSize: settings.menuBarLyricsFontSize).effectiveFontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("占用宽度", selection: $settings.menuBarWidthMode) {
                Text("随内容伸缩").tag("adaptive")
                Text("固定宽度").tag("fixed")
            }.pickerStyle(.segmented)
            Text(settings.menuBarWidthMode == "fixed" ? "固定宽度" : "最大宽度")
                .font(.system(size: 11, weight: .medium))
            V3NumericSlider(value: $settings.menuBarWidth, in: 120...480, step: 1, unit: "pt")
                .accessibilityLabel("菜单栏歌词占用宽度")
            Picker("长句显示", selection: $settings.menuBarOverflow) {
                Text("缓慢滚动").tag("scroll")
                Text("省略").tag("ellipsis")
            }.pickerStyle(.segmented)
            Text("固定宽度不会随每句推挤其他图标。滚动只在播放且可见时运行；减少动态效果时静止，悬停可看全文。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                Toggle("原文", isOn: $settings.menuBarLyricsShowsOriginal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                Toggle("译文", isOn: $settings.menuBarLyricsShowsTranslation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                Toggle("假名", isOn: $settings.menuBarLyricsShowsKana)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                Toggle("罗马音 / 拼音", isOn: $settings.menuBarLyricsShowsRomaji)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.checkbox)
            Picker("注音位置", selection: $settings.menuBarLyricsReadingsAbove) {
                Text("原文上方").tag(true)
                Text("同一行").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .disabled(!settings.menuBarLyricsShowsOriginal || (!settings.menuBarLyricsShowsKana && !settings.menuBarLyricsShowsRomaji))
            VStack(alignment: .leading, spacing: 5) {
                Text("字号")
                V3NumericSlider(value: Binding(get: { fontSize }, set: { settings.menuBarLyricsFontSize = $0 }),
                                in: 10...18, step: 1, unit: "pt")
                    .accessibilityLabel("状态栏歌词字号")
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
