import SwiftUI

/// Hover uses the same controls and actions as the full panels, without their explanations.
struct V3ToolbarQuickControls<Controls: View>: View {
    let panel: V3ToolbarModel.Panel
    @V3ContentPlaybackState var state: PlaybackState
    @ObservedObject var search: SongSearchManager
    let openLibrary: () -> Void
    let openSearch: () -> Void
    @ViewBuilder var controls: () -> Controls
    @StateObject private var library = PersonalLyricsLibraryService()
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(panel.title).font(.system(size: 12, weight: .semibold))
                switch panel {
                case .library:
                    PersonalLibraryTrackDetailView(service: library,
                        stableKey: state.liveTrackIdentity?.stableKey ?? "", compact: true)
                        .environmentObject(state)
                    Divider()
                    Button("打开歌词库", action: openLibrary)
                case .search:
                    searchControls
                    Button("全部结果", action: openSearch)
                default: controls()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 360, height: 520)
        .font(.system(size: 12))
        .controlSize(.small)
        .toggleStyle(.switch)
        .task(id: state.liveTrackIdentity) {
            if panel == .library, let key = state.liveTrackIdentity?.stableKey {
                library.selectTrack(stableKey: key)
            }
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索歌曲或艺人", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search.search(query: SongSearchQuery(text: query)) }
            if case .results(_, let results) = search.state {
                ForEach(Array(results.prefix(5))) { result in
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

}
