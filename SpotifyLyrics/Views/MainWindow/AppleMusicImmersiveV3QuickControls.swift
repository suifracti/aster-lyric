import SwiftUI

/// Hover uses the same controls and actions as the full panels, without their explanations.
struct V3ToolbarQuickControls<Controls: View>: View {
    let panel: V3ToolbarModel.Panel
    @V3ContentPlaybackState var state: PlaybackState
    @ObservedObject var search: SongSearchManager
    let openLibrary: () -> Void
    let openSearch: () -> Void
    let openPlaylists: () -> Void
    @ViewBuilder var controls: () -> Controls
    @StateObject private var library = PersonalLyricsLibraryService()
    @State private var query = ""
    @State private var selectedSearchResultKey: String?
    @State private var contentHeight: CGFloat = 520
    @Environment(\.v3ToolPanelTopInset) private var topInset

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(panel == .playlists ? "接下来播放" : panel.title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if panel == .playlists { Button("全部", action: openPlaylists).buttonStyle(.plain).foregroundStyle(.secondary) }
                    if panel == .library { Button("打开歌词库", action: openLibrary).buttonStyle(.plain).foregroundStyle(.secondary) }
                    if panel == .search { Button("全部结果", action: openSearch).buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                switch panel {
                case .library:
                    Text("\(state.liveLyricsSource?.displayName ?? "暂无歌词") · \(state.liveLyricsVersionID == nil ? "未采用版本" : "已采用版本") · \(state.liveLyrics.count) 行")
                        .font(.caption).foregroundStyle(.secondary)
                    PersonalLibraryTrackDetailView(service: library,
                        stableKey: state.liveTrackIdentity?.stableKey ?? "", compact: true)
                        .environmentObject(state)

                case .playlists:
                    V3PlaylistQueuePreview(browser: state.playlistBrowser, currentTrackID: state.currentTrack.spotifyId)
                case .search:
                    searchControls

                default: controls()
                }
            }
            .padding(14)
            .padding(.bottom, panel == .picture ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: V3ToolPanelHeight.self, value: geometry.size.height)
            })
        }
        .mask {
            if panel == .picture && contentHeight > viewportHeight {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            } else { Rectangle() }
        }
        .onChange(of: selectedSearchResultKey) { _, id in
            if let id { proxy.scrollTo(id, anchor: .center) }
        }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: panel == .playlists ? 300 : 360, height: viewportHeight)
        .onPreferenceChange(V3ToolPanelHeight.self) { height in
            if height > 0 { contentHeight = ceil(height) }
        }
        .modifier(PersonalLibrarySheets(service: library))
        .font(.system(size: 12))
        .controlSize(.small)
        .toggleStyle(.switch)
        .disclosureGroupStyle(V3PanelDisclosureStyle())
        .task(id: state.liveTrackIdentity) {
            if panel == .library, let key = state.liveTrackIdentity?.stableKey {
                library.selectTrack(stableKey: key)
            }
        }
    }

    private var viewportHeight: CGFloat { min(contentHeight, 520 - topInset) }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索歌曲或艺人", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let selected = visibleSearchResults.first(where: { $0.searchMergeKey == selectedSearchResultKey }) {
                        state.loadSearchResult(selected)
                    } else { search.search(query: SongSearchQuery(text: query)) }
                }
                .onKeyPress(.downArrow) { moveSearchSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSearchSelection(-1); return .handled }
            if case .results(_, let results) = search.state {
                ForEach(SongSearchResultGroup.panelGroups(results)) { group in
                    Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.results) { result in
                        SongSearchResultRow(result: result, state: state,
                                            isSelected: selectedSearchResultKey == result.searchMergeKey)
                            .id(result.searchMergeKey)
                    }
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
            selectedSearchResultKey = nil
            search.search(query: SongSearchQuery(text: value), debounceNanoseconds: 250_000_000)
        }
    }

    private var visibleSearchResults: [SongSearchResult] {
        guard case .results(_, let results) = search.state else { return [] }
        return SongSearchResultGroup.panelGroups(results).flatMap(\.results)
    }

    private func moveSearchSelection(_ direction: Int) {
        let results = visibleSearchResults
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.searchMergeKey == selectedSearchResultKey } ?? (direction > 0 ? -1 : results.count)
        selectedSearchResultKey = results[min(max(0, current + direction), results.count - 1)].searchMergeKey
    }

}

struct V3PanelDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded { configuration.content }
        }
    }
}
