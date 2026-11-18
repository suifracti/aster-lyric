import SwiftUI

struct V3LibrarySearchPresentation: Equatable {
    enum Tab: String, CaseIterable, Identifiable {
        case library, history, statistics, search, playlists
        var id: Self { self }
        var title: String {
            switch self {
            case .library: return "歌词库"; case .history: return "最近播放"; case .statistics: return "统计"
            case .search: return "搜索"; case .playlists: return "歌单"
            }
        }
        /// Pages that list what was listened to; they have no search field.
        var isListening: Bool { self == .history || self == .statistics }
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
    @ObservedObject var library: PersonalLyricsLibraryService
    @ObservedObject var search: SongSearchManager
    let browsing: PersonalLibraryBrowsing
    @State private var batchArchiveKey: String?
    @State private var listeningTrackKey: String?
    @State private var statisticsTimeRange: ListeningStatisticsTimeRange = .allTime

    private var libraryResults: (entries: [PersonalLyricsLibraryEntry], selectedKey: String?) {
        let scope = browsing.scope
        let matches = library.entries(for: scope.query)
        let current = PersonalLyricsLibraryEntry.current(in: matches, trackKey: state.liveTrackIdentity?.stableKey,
                                                        lyricsVersionID: state.liveLyricsVersionID)
        let entries = matches.filter { scope.filter.includes($0, currentTrackKey: current?.trackStableKey) }
        let selected = entries.first { $0.id == browsing.selectedTrackKey }?.id
        return (entries, batchArchiveKey ?? selected ?? entries.first { $0.id == current?.id }?.id ?? entries.first?.id)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.32)
                    .contentShape(Rectangle())
                    .onTapGesture { presentation.dismiss() }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        // The tool panels' segmented control: a neutral selection,
                        // not the system's black filled tab.
                        V3SegmentedPicker("歌词库与搜索", selection: Binding(
                            get: { presentation.tab ?? .library },
                            set: { presentation.open($0) }
                        ), options: V3LibrarySearchPresentation.Tab.allCases.map { ($0.title, $0) },
                           showsLabel: false, height: 28)
                        .frame(width: 360)
                        if presentation.tab?.isListening == true, listeningTrackKey != nil {
                            Button(presentation.tab == .history ? "返回最近播放" : "返回统计", systemImage: "chevron.left") {
                                listeningTrackKey = nil
                            }
                                .buttonStyle(.borderless)
                            Spacer(minLength: 0)
                        } else if presentation.tab?.isListening == true {
                            Spacer(minLength: 0)
                            Button {
                                if presentation.tab == .history { state.refreshListeningHistory() }
                                else { state.refreshListeningStatistics(for: statisticsTimeRange) }
                            } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("刷新")
                        } else {
                            searchField
                            managementMenu
                        }
                        Button("在新窗口打开", action: openInNewWindow)
                        .font(.caption).buttonStyle(.borderless)
                        Button { presentation.dismiss() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭歌词库与搜索")
                    }
                    .padding(12)
                    Divider()
                    Group {
                        if presentation.tab == .playlists {
                            V3PlaylistPanel(browser: state.playlistBrowser, currentTrackID: state.playlistTrackID, currentArtworkURL: state.currentTrack.artworkURL)
                        } else if presentation.tab == .search {
                            V3SearchPanel(state: state, search: search)
                        } else if presentation.tab?.isListening == true {
                            listeningContent
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
            .onAppear {
                if presentation.tab == .library { library.search(browsing.scope.query, immediately: true) }
                if presentation.tab == .search { prepareSongSearch() }
            }
            .onChange(of: browsing.scope.filter) { _, _ in batchArchiveKey = nil }
            .onChange(of: browsing.scope.query) { _, query in
                batchArchiveKey = nil
                if presentation.tab == .library { library.search(query) }
            }
            .onChange(of: state.playlistBrowser.source) { _, _ in
                if presentation.tab == .search { prepareSongSearch() }
            }
            .onChange(of: presentation.tab) { _, tab in
                listeningTrackKey = nil
                if tab == .library { library.search(browsing.scope.query, immediately: true) }
                else if tab == .search { prepareSongSearch() }
            }
        }
    }
    private var listeningContent: some View {
        ZStack {
            Group {
                if presentation.tab == .history {
                    ListeningHistoryView(openTrack: { listeningTrackKey = $0 })
                } else {
                    ListeningStatisticsView(timeRange: $statisticsTimeRange, openTrack: { listeningTrackKey = $0 })
                }
            }
            .opacity(listeningTrackKey == nil ? 1 : 0)
            .allowsHitTesting(listeningTrackKey == nil)
            .accessibilityHidden(listeningTrackKey != nil)
            if let listeningTrackKey {
                PersonalLibraryTrackDetailView(service: library, stableKey: listeningTrackKey)
                    .id(listeningTrackKey)
            }
        }
    }

    private func openInNewWindow() {
        let tab = presentation.tab
        let selectedKey = tab == .library ? libraryResults.selectedKey : nil
        presentation.dismiss()
        switch tab {
        case .search: openWindow(id: "song-search")
        case .playlists: openWindow(id: "playlist-browser")
        case .library, .history, .statistics, nil:
            if tab?.isListening == true, let listeningTrackKey { state.openLibraryTool(trackKey: listeningTrackKey) }
            else if tab == .history { state.openLibraryTool(tab: .history) }
            else if tab == .statistics { state.openLibraryTool(tab: .statistics) }
            else { state.openLibraryTool(scope: browsing.scope, trackKey: selectedKey) }
            openWindow(id: "personal-library-activity")
        }
    }

    private func prepareSongSearch() {
        search.prepareQuery(suggestedTrack: state.hasLiveTrack ? state.currentTrack : nil)
    }

    @ViewBuilder
    private var searchField: some View {
        switch presentation.tab {
        case .search:
            TextField("搜索歌曲、艺人或已存歌词", text: Binding(get: { search.queryText ?? "" }, set: { search.editQuery($0) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("songSearch.query")
                .onSubmit { search.submitQuery() }
        case .playlists:
            PlaylistFilterField(browser: state.playlistBrowser)
        default:
            TextField("搜索歌词库", text: Binding(get: { browsing.scope.query }, set: { browsing.scope.query = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { library.search(browsing.scope.query, immediately: true) }
        }
    }
    private var managementMenu: some View {
        Menu {
            if presentation.tab != .playlists {
                Button("导出", action: library.exportPersonalData)
                Button("导入数据", action: library.presentPersonalDataImportDialog)
                Button("导入资产", action: library.presentImportDialog)
            }
            Button("刷新") {
                switch presentation.tab {
                case .playlists: state.playlistBrowser.refresh()
                case .search: search.submitQuery()
                default: library.search(browsing.scope.query, immediately: true)
                }
            }
            if presentation.tab != .playlists {
                Menu("私人文件夹同步") {
                    Button("选择文件夹", action: library.selectSyncFolder).disabled(library.isSyncing)
                    Button("立即同步", action: library.syncNow).disabled(library.syncFolderURL == nil || library.isSyncing)
                    Button("取消同步", action: library.cancelSyncFolder).disabled(library.syncFolderURL == nil || library.isSyncing)
                }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().help("管理歌词库")
    }
    private var libraryContent: some View {
        let (entries, selectedKey) = libraryResults
        let filter = browsing.scope.filter
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(PersonalLibraryFilter.allCases) { value in
                                Button { browsing.scope.filter = value } label: {
                                    Text(value.rawValue).font(.system(size: 10))
                                        .padding(.horizontal, 5).padding(.vertical, 5)
                                        .background(filter == value ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(filter == value ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.top, 10)
                    LyricsBatchControls(playback: state, entries: filter == .missing && !library.isLoading ? entries : [],
                                        library: library, openTrack: { batchArchiveKey = $0 })
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                Button {
                                    batchArchiveKey = nil
                                    browsing.selectedTrackKey = entry.id
                                } label: {
                                    libraryRow(entry, isSelected: selectedKey == entry.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let notice = library.personalDataNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary).padding(8)
                    } else if library.statusMessage.contains("失败") {
                        Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
                .frame(width: min(300, geometry.size.width * 0.43))
                Divider()
                ScrollView {
                    if let selectedKey {
                        PersonalLibraryTrackDetailView(service: library, stableKey: selectedKey, compact: true, showsActions: true)
                            .padding(14)
                    } else if library.isLoading {
                        ProgressView("正在读取歌词库…").padding(24)
                    } else {
                        Text("没有符合条件的歌曲").foregroundStyle(.secondary).padding(24)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func libraryRow(_ entry: PersonalLyricsLibraryEntry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            CachedArtwork(url: entry.artworkURL) {
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
        .background(isSelected ? Color.primary.opacity(0.09) : .clear)
        .contentShape(Rectangle())
    }

}
