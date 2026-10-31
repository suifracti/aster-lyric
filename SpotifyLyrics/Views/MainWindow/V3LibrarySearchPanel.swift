import SwiftUI

struct V3LibrarySearchPresentation: Equatable {
    enum Tab: String, CaseIterable, Identifiable {
        case library, search, playlists
        var id: Self { self }
        var title: String { switch self { case .library: return "歌词库"; case .search: return "搜索"; case .playlists: return "歌单" } }
    }
    var tab: Tab?
    var isPresented: Bool { tab != nil }
    mutating func open(_ tab: Tab) { self.tab = tab }
    mutating func toggle(_ tab: Tab) { self.tab = self.tab == tab ? nil : tab }
    mutating func dismiss() { tab = nil }

    static func size(in canvas: CGSize) -> CGSize {
        CGSize(width: max(1, min(760, canvas.width - 80)), height: max(1, min(600, canvas.height - 80)))
    }
}

/// Reuses the drawer's existing library and full search views without changing the canvas layout.
struct V3LibrarySearchPanel: View {
    @Binding var presentation: V3LibrarySearchPresentation
    @V3ContentPlaybackState var state: PlaybackState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var library = PersonalLyricsLibraryService()
    @StateObject private var batch = LyricsBatchCompletion()
    @State private var selectedKey: String?
    @State private var queries: [V3LibrarySearchPresentation.Tab: String] = [:]
    private var query: String {
        get { queries[presentation.tab ?? .library] ?? "" }
        nonmutating set { queries[presentation.tab ?? .library] = newValue }
    }
    @State private var filter: LibraryFilter = ProcessInfo.processInfo.arguments.contains("--library-missing") ? .missing : .all

    private enum LibraryFilter: String, CaseIterable {
        case all = "全部", current = "当前歌曲", missing = "缺歌词", translations = "有译文", manual = "手动编辑"
    }
    private var currentEntry: PersonalLyricsLibraryEntry? {
        library.entries.first { $0.trackStableKey == state.liveTrackIdentity?.stableKey
            || ($0.activeLyricsVersionID != nil && $0.activeLyricsVersionID == state.liveLyricsVersionID) }
    }
    private var entries: [PersonalLyricsLibraryEntry] {
        library.entries.filter { entry in
            switch filter {
            case .all: return true
            case .current: return entry.id == currentEntry?.id
            case .missing: return entry.lyricsVersionCount == 0
            case .translations: return entry.translationVersionCount > 0
            case .manual: return entry.hasManualLyrics || entry.hasManualTranslation
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.32)
                    .contentShape(Rectangle())
                    .onTapGesture { presentation.dismiss() }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Picker("歌词库与搜索", selection: Binding(
                            get: { presentation.tab ?? .library },
                            set: { presentation.open($0) }
                        )) {
                            ForEach(V3LibrarySearchPresentation.Tab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                        TextField(presentation.tab == .search ? "搜索歌曲或艺人" : presentation.tab == .playlists ? "搜索歌单或歌曲" : "搜索歌词库", text: Binding(get: { query }, set: { query = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { updateSearch() }
                        managementMenu
                        Button("在新窗口打开") {
                            let tab = presentation.tab
                            presentation.dismiss()
                            openWindow(id: tab == .search ? "song-search" : tab == .playlists ? "playlist-browser" : "personal-library-activity")
                        }
                        .font(.caption).buttonStyle(.borderless)
                        Button { presentation.dismiss() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭歌词库与搜索")
                    }
                    .padding(12)
                    Divider()
                    Group {
                        if presentation.tab == .playlists {
                            V3PlaylistPanel(browser: state.playlistBrowser, query: query, currentTrackID: state.currentTrack.spotifyId)
                        } else if presentation.tab == .search {
                            V3SearchPanel(state: state, search: state.songSearchManager)
                        } else {
                            libraryContent
                        }
                    }
                    .environmentObject(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: V3LibrarySearchPresentation.size(in: geometry.size).width,
                       height: V3LibrarySearchPresentation.size(in: geometry.size).height)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .modifier(V3SystemAppearanceModifier())
                .accessibilityIdentifier("v3.librarySearchPanel")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onExitCommand { presentation.dismiss() }
            .modifier(PersonalLibrarySheets(service: library))
            .onAppear {
                library.refresh()
                if presentation.tab == .search, query.isEmpty { query = SongSearchQuery(track: state.currentTrack).text }
            }
            .onChange(of: library.entries) { _, _ in if selectedKey == nil { selectInitialEntry() } }
            .onChange(of: filter) { _, _ in selectInitialEntry() }
            .onChange(of: query) { _, _ in updateSearch() }
            .onChange(of: presentation.tab) { _, tab in
                if tab == .library { library.searchQuery = query; library.refresh(); selectInitialEntry() }
                else if tab == .search, query.isEmpty { query = SongSearchQuery(track: state.currentTrack).text }
            }
            .onChange(of: batch.isRunning) { _, running in if !running { library.refresh() } }
            .onDisappear { batch.stop() }
        }
    }
    private func updateSearch() {
        if presentation.tab == .search {
            state.songSearchManager.search(query: SongSearchQuery(text: query), debounceNanoseconds: 250_000_000)
        } else if presentation.tab == .library {
            library.searchQuery = query
            library.refresh()
        }
    }
    private func selectInitialEntry() {
        selectedKey = entries.first(where: { $0.id == currentEntry?.id })?.id ?? entries.first?.id
    }
    private var managementMenu: some View {
        Menu {
            if presentation.tab != .playlists {
                Button("导出", action: library.exportPersonalData)
                Button("导入数据", action: library.presentPersonalDataImportDialog)
                Button("导入资产", action: library.presentImportDialog)
            }
            Button("刷新") {
                if presentation.tab == .playlists { state.playlistBrowser.picker.load(); state.playlistBrowser.loadQueue(); state.playlistBrowser.select(state.playlistBrowser.selectedID) }
                else { library.refresh(); updateSearch() }
            }
            if presentation.tab != .playlists {
                Menu("私人文件夹同步") {
                    Button("选择文件夹", action: library.selectSyncFolder)
                    Button("立即同步", action: library.syncNow).disabled(library.syncFolderURL == nil || library.isSyncing)
                    Button("取消同步", action: library.cancelSyncFolder).disabled(library.syncFolderURL == nil)
                }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().help("管理歌词库")
    }
    private var libraryContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(LibraryFilter.allCases, id: \.self) { value in
                            Button { filter = value } label: {
                                Text(value.rawValue).font(.system(size: 10))
                                    .padding(.horizontal, 5).padding(.vertical, 5)
                                    .background(filter == value ? Color.accentColor.opacity(0.25) : .clear, in: Capsule())
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 10)
                    if batch.isRunning {
                        HStack { Text("\(batch.completed) / \(batch.total)").monospacedDigit(); Button("停止") { batch.stop() } }
                    } else if filter == .missing {
                        Button("全部补全") {
                            batch.start(tracks: entries.filter { !$0.hasManualLyrics && !$0.hasLockedLyrics }.map { library.libraryTrack(for: $0) }) {
                                await state.completeMissingLyrics(track: $0)
                            }
                        }.disabled(entries.isEmpty)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                Button { selectedKey = entry.id } label: { libraryRow(entry) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if library.statusMessage.contains("失败") {
                        Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
                .frame(width: min(300, geometry.size.width * 0.43))
                Divider()
                ScrollView {
                    if let selectedKey {
                        PersonalLibraryTrackDetailView(service: library, stableKey: selectedKey, compact: true, showsActions: true)
                            .padding(14)
                    } else {
                        Text("没有符合条件的歌曲").foregroundStyle(.secondary).padding(24)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func libraryRow(_ entry: PersonalLyricsLibraryEntry) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: entry.artworkURL) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.07))
            }.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.artist).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("词 \(entry.lyricsVersionCount) / 译 \(entry.translationVersionCount)").fixedSize()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedKey == entry.id ? .white.opacity(0.09) : .clear)
        .contentShape(Rectangle())
    }

}
