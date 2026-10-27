import SwiftUI

struct V3SearchPanel: View {
    @V3ContentPlaybackState var state: PlaybackState
    @ObservedObject var search: SongSearchManager
    @State private var selectedCandidate: LyricsCandidate?
    @State private var selectedSongKey: String?
    @State private var hoveredCandidate: String?
    @State private var adoptionRequest: UUID?
    @State private var catalogDuration: Double?

    private var candidates: [LyricsCandidate] {
        var values = state.liveLyricsCandidates
        if let document = state.lyricsSession.activeDocument,
           state.liveLyricsDocumentMatchesCurrentTrack,
           !values.contains(where: { $0.lines == document.lines && $0.source == document.source }) {
            values.insert(LyricsCandidate(id: "active-" + (state.liveLyricsVersionID?.uuidString ?? "session"),
                identity: document.identity, title: document.title ?? state.currentTrack.title, artist: document.artist ?? state.currentTrack.artist,
                album: document.album ?? "", duration: document.duration ?? 0, lines: document.lines,
                isSynchronized: document.isSynchronized, source: document.source, confidence: document.confidence,
                providerSourceID: document.providerSourceID, language: document.language), at: 0)
        }
        return values
    }
    private var songs: [SongSearchResult] {
        guard case .results(_, let results) = search.state else { return [] }
        return Self.otherSongs(results, current: state.hasLiveTrack ? state.currentTrack : nil)
    }
    static func otherSongs(_ results: [SongSearchResult], current: Track?) -> [SongSearchResult] {
        var seen = Set<String>()
        return results.filter { result in
            if let current {
                let lhs = TrackIdentity(track: result.track), rhs = TrackIdentity(track: current)
                if let id = lhs.spotifyTrackID, let currentID = rhs.spotifyTrackID {
                    if id == currentID { return false }
                } else if TrackTextNormalizer.normalize(result.track.title) == TrackTextNormalizer.normalize(current.title),
                   TrackTextNormalizer.normalizeArtistToken(result.track.artist) == TrackTextNormalizer.normalizeArtistToken(current.artist) { return false }
            }
            return seen.insert(result.searchMergeKey).inserted
        }.sorted { $0.isSavedLocally && !$1.isSavedLocally }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("这首歌的歌词").font(.headline)
                        if state.hasLiveTrack {
                            Text(state.currentTrack.title + " · " + state.currentTrack.artist).font(.caption).foregroundStyle(.secondary)
                            ForEach(candidates) { candidate in candidateRow(candidate) }
                            Button(state.isSearchingAdditionalLyricsVersions ? "搜索中…" : "查找更多歌词版本") {
                                state.clearSearchPreview()
                                state.searchAdditionalLyricsVersions()
                            }.disabled(state.isSearchingAdditionalLyricsVersions)
                        } else { Text("当前没有播放歌曲").foregroundStyle(.secondary) }
                        Divider()
                        Text("其他歌曲").font(.headline)
                        ForEach(songs, id: \.searchMergeKey) { result in
                            SongSearchResultRow(result: result, state: state, isSelected: result.searchMergeKey == selectedSongKey,
                                onViewLyrics: { selectedCandidate = nil; adoptionRequest = nil; selectedSongKey = result.searchMergeKey })
                        }
                        if case .searching = search.state { ProgressView().controlSize(.small) }
                        if case .failed(_, let message) = search.state { Text(message).font(.caption).foregroundStyle(.secondary) }
                        if !state.songSearchSelectionMessage.isEmpty {
                            Text(state.songSearchSelectionMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12)
                }.frame(width: min(300, geometry.size.width * 0.43))
                Divider()
                Group {
                    if let candidate = selectedCandidate ?? (selectedSongKey == nil ? candidates.first : nil) {
                        LyricsCandidatePreviewSheet(candidate: candidate,
                            onAdopt: { state.clearSearchPreview(); return try await state.adoptLyricsCandidate(candidate) },
                            onConfirmLocked: { try await state.confirmPendingManualLyricsAdoption() },
                            onCancelLocked: state.cancelPendingManualLyricsAdoption,
                            embedded: true, adoptionRequest: adoptionRequest)
                            .id(candidate.id)
                    } else if selectedSongKey != nil {
                        LyricsStateContentFirstView(state: state, compact: true, lyricsFocus: false, onSearch: nil)
                            .padding(14)
                    } else { Text("选择歌词版本或歌曲").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: state.liveTrackIdentity) {
            selectedCandidate = nil; selectedSongKey = nil; adoptionRequest = nil; catalogDuration = nil
            if let track = await SpotifyTrackArtistResolver.shared.matchingTrack(for: state.currentTrack) { catalogDuration = track.duration }
            else if state.playbackSourceIdentity == .appleMusic { catalogDuration = state.currentTrack.duration }
        }
    }
    private func candidateRow(_ candidate: LyricsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(candidate.providerName ?? candidate.source.displayName).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(candidate.lines.contains { $0.timedSpans?.isEmpty == false } ? "逐字" : candidate.isSynchronized ? "逐行" : "纯文本")
                    .font(.system(size: 10)).padding(3).background(.white.opacity(0.08), in: Capsule())
            }
            Text(catalogDuration.map { String(format: "时长差 %+.1fs", candidate.duration - $0) } ?? "时长差未知")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("采用此版本") { selectedSongKey = nil; selectedCandidate = candidate; adoptionRequest = UUID() }
                if hoveredCandidate == candidate.id {
                    Button("预览") { selectedSongKey = nil; selectedCandidate = candidate; adoptionRequest = nil }
                }
            }.controlSize(.small)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background((selectedCandidate?.id == candidate.id) ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { selectedSongKey = nil; selectedCandidate = candidate; adoptionRequest = nil }
        .onHover { hoveredCandidate = $0 ? candidate.id : nil }
    }
}
