import SwiftUI
import AppKit

/// Small, directly usable hover controls. Full panels remain separate windows.
struct V3ToolbarQuickControls: View {
    let panel: V3ToolbarModel.Panel
    @ObservedObject var settings: AppSettingsStore
    @V3ContentPlaybackState var state: PlaybackState
    @ObservedObject var search: SongSearchManager
    let canTranslate: Bool
    let openLibrary: () -> Void
    let windowModes: AnyView
    @State private var versions: [StoredEditableLyricsVersion] = []
    @State private var query = ""
    @State private var message: String?
    @State private var thumbnail: NSImage?
    @State private var tint = Color.accentColor

    private var height: CGFloat {
        switch panel {
        case .library: return 160
        case .search: return 200
        case .translation: return 130
        case .text: return 120
        case .picture: return 252
        case .more: return 350
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(panel.title).font(.system(size: 12, weight: .semibold))
            switch panel {
            case .library: libraryControls
            case .search: searchControls
            case .translation: translationControls
            case .text: textControls
            case .picture: pictureControls
            case .more:
                windowModes
                Divider()
                V3QuickOffsetControls(store: settings.lyricsOffsetStore)
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .toggleStyle(.switch)
        .padding(14)
        .frame(width: 320, height: height, alignment: .topLeading)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Color.white.opacity(0.12).frame(width: 1) }
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(versions, id: \.record.id) { version in
                        Button {
                            Task { @MainActor in
                                do { _ = try await state.adoptCurrentLyricsVersion(versionID: version.record.id) }
                                catch { message = error.localizedDescription }
                            }
                        } label: {
                            Label(version.document.source.displayName + " · " + version.record.createdAt.formatted(date: .numeric, time: .shortened),
                                  systemImage: state.liveLyricsVersionID == version.record.id ? "checkmark.circle.fill" : "circle")
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                    if versions.isEmpty { Text(message ?? "暂无已保存歌词版本").foregroundStyle(.secondary) }
                }
            }
            .frame(height: 60)
            Divider()
            Button("打开歌词库", action: openLibrary)
        }
        .task(id: state.liveLyricsVersionID) {
            do { versions = try await state.loadCurrentLyricsVersions() }
            catch { message = error.localizedDescription }
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索歌曲或艺人", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search.search(query: SongSearchQuery(text: query)) }
            if case .results(_, let results) = search.state {
                ForEach(Array(results.prefix(3))) { result in
                    Button { state.loadSearchResult(result) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.track.title).fontWeight(.medium).lineLimit(1)
                            Text(result.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            } else if case .searching = search.state {
                ProgressView().controlSize(.small)
            } else if case .failed(_, let error) = search.state {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text("没有找到歌曲").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            query = state.hasLiveTrack ? SongSearchQuery(track: state.currentTrack).text : ""
        }
        .onChange(of: query) { _, value in
            search.search(query: SongSearchQuery(text: value), debounceNanoseconds: 250_000_000)
        }
    }

    private var translationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("原文", isOn: displayBinding(\.showOriginal))
                Toggle("中文", isOn: displayBinding(\.showTranslation))
                Toggle("读音", isOn: displayBinding(\.showKana))
            }
            Text("当前译文 · " + (state.selectedTranslation?.record.translationSourceTitle ?? "尚未采用"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("翻译整首") { state.translateCurrentLyrics() }
                .disabled(!canTranslate || !settings.aiTranslationConfiguration.isConfigured || state.liveLyrics.isEmpty)
        }
    }

    private var textControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("字号")
                Spacer()
                Button("−") { changeFontSize(-1) }.accessibilityLabel("缩小歌词字号")
                Text("\(Int(settings.displayPreferences.fontSize)) pt").monospacedDigit()
                Button("+") { changeFontSize(1) }.accessibilityLabel("增大歌词字号")
            }
            HStack {
                Text("对齐")
                Spacer()
                ForEach(["left", "center", "right"], id: \.self) { alignment in
                    Button { settings.v3LyricsPosition = alignment } label: {
                        Image(systemName: alignment == "left" ? "text.alignleft" : alignment == "center" ? "text.aligncenter" : "text.alignright")
                            .foregroundStyle(settings.v3LyricsPosition == alignment ? Color.accentColor : Color.primary)
                    }
                    .accessibilityLabel(alignment == "left" ? "左对齐" : alignment == "center" ? "居中" : "右对齐")
                }
            }
        }
    }

    private var pictureControls: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(V3SceneFamily.allCases) { family in
                Button {
                    let target = family.target(settings: settings)
                    if let scene = target.0 { settings.selectV3Scene(scene, renderer: target.1) }
                    else { settings.selectLegacyV3Presentation(target.1) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        LyricIslandSceneThumbnail(scene: family.primaryScene, image: thumbnail, accent: tint)
                        Label(family.title, systemImage: family.symbolName).font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: state.currentTrack.artworkURL) {
            thumbnail = await ArtworkImageLoader.shared.image(for: state.currentTrack.artworkURL)
            let colors = await LyricIslandArtworkColors.palette(for: state.currentTrack.artworkURL)
            guard !Task.isCancelled else { return }
            tint = LyricIslandArtworkColors.edgeAccent(colors)
        }
    }

    private func displayBinding(_ keyPath: WritableKeyPath<DisplayPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { settings.displayPreferences[keyPath: keyPath] }, set: { value in
            var next = settings.displayPreferences
            next[keyPath: keyPath] = value
            settings.displayPreferences = next
        })
    }

    private func changeFontSize(_ delta: CGFloat) {
        var next = settings.displayPreferences
        next.fontSize = min(42, max(14, next.fontSize + delta))
        settings.displayPreferences = next
    }
}

private struct V3QuickOffsetControls: View {
    @ObservedObject var store: ScopedLyricsOffsetStore
    var body: some View {
        HStack {
            Text("歌词偏移")
            Button("−0.1s") { _ = store.setActiveValue(store.activeOffset - 0.1) }
            Text(String(format: "%+.1fs", store.activeOffset)).monospacedDigit()
            Button("+0.1s") { _ = store.setActiveValue(store.activeOffset + 0.1) }
        }
        .disabled(store.activeScope == nil)
    }
}
