import SwiftUI
import AppKit

struct SongSearchPopover: View {
    @ObservedObject var manager: SongSearchManager
    @ObservedObject var playbackState: PlaybackState
    var embedded = false
    @State private var query = ""
    @State private var isApplyingPreview = false
    @State private var isLockConfirmationPresented = false
    @State private var previewAdoptionMessage: String?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("查找歌曲")
                .font(.system(size: 18, weight: .bold))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索已存歌词、歌曲或艺人", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        search()
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                    .accessibilityLabel("清除搜索")
                }

                Button("搜索", action: search)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .controlSize(.small)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if playbackState.hasLiveTrack {
                HStack(spacing: 7) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    Text("当前播放")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(playbackState.currentTrack.title) · \(playbackState.currentTrack.artist)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }

            Text("保存的歌词与本地文件可直接搜索；连接 Spotify 后也能查在线曲库。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            spotifyAuthorizationSection
            if playbackState.isShowingSearchPreview, playbackState.hasLiveTrack {
                searchPreviewActionBanner
            }

            content
        }
        .padding(16)
        .frame(width: embedded ? nil : 440, height: embedded ? nil : 470, alignment: .top)
        .onAppear {
            if let existing = manager.state.query?.text, !existing.isEmpty {
                query = existing
            } else if playbackState.hasLiveTrack {
                query = SongSearchQuery(track: playbackState.currentTrack).text
            }
            isSearchFieldFocused = true
        }
        .onChange(of: query) { _, value in
            let next = SongSearchQuery(text: value)
            manager.search(query: next, debounceNanoseconds: 300_000_000)
        }
    }

    private var spotifyAuthorizationSection: some View {
        HStack(spacing: 7) {
                Image(systemName: playbackState.spotifyAuthorizationManager.state.isAuthorized ? "checkmark.seal.fill" : "globe")
                    .foregroundStyle(playbackState.spotifyAuthorizationManager.state.isAuthorized ? Color.accentColor : .secondary)
                Text(playbackState.spotifyAuthorizationManager.isConfigured
                    ? playbackState.spotifyAuthorizationManager.state.userFacingMessage
                    : "本地搜索可用 · 在线曲库尚未连接")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if playbackState.spotifyAuthorizationManager.isConfigured,
                   !playbackState.spotifyAuthorizationManager.state.isAuthorized {
                    Button("授权") {
                        playbackState.spotifyAuthorizationManager.authorize()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .controlSize(.small)
                    .disabled(isAuthorizing)
                } else {
                    SettingsLink {
                        Label("在线搜索设置", systemImage: "gearshape")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .idle:
            emptyState(icon: "music.note", title: "搜索歌曲或歌词", detail: "输入歌名、艺人，或已保存歌词中的一句话。")
        case .searching:
            emptyState(
                icon: "magnifyingglass",
                title: "正在搜索",
                detail: "正在查找歌曲和艺人"
            )
        case .noResults:
            emptyState(
                icon: "books.vertical",
                title: "没有找到歌曲",
                detail: playbackState.spotifyAuthorizationManager.state.isAuthorized
                    ? "换个标题、艺人名或 Spotify 链接再试。"
                    : "已搜索保存的歌词、本地文件和当前歌曲。换个关键词，或连接 Spotify 扩展搜索。",
                actionTitle: "重新搜索",
                action: search
            )
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 10) {
                emptyState(
                    icon: "exclamationmark.triangle",
                    title: "搜索暂时未完成",
                    detail: message
                )
                Button("重新搜索", action: search)
                    .buttonStyle(.bordered)
                    .tint(Color.accentColor)
            }
        case .results(_, let results):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        resultRow(result, showsSeparator: index < results.count - 1)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }

        if !playbackState.songSearchSelectionMessage.isEmpty {
            Text(playbackState.songSearchSelectionMessage)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultRow(_ result: SongSearchResult, showsSeparator: Bool) -> some View {
        SongSearchResultRow(result: result, state: playbackState, showsSeparator: showsSeparator)
    }

    private var searchPreviewActionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .foregroundStyle(Color.accentColor)
            Text(playbackState.searchPreviewTrack.map { "已载入预览：「\($0.title)」" } ?? "已载入预览歌词")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let previewAdoptionMessage {
                Text(previewAdoptionMessage)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("应用到当前歌曲") {
                applySearchPreview(confirmingLocks: false)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .controlSize(.small)
            .disabled(isApplyingPreview)

            Button("退出预览") {
                playbackState.clearSearchPreview()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor.opacity(0.65)).frame(width: 2)
        }
        .padding(.leading, 8)
        .confirmationDialog(
            "歌词版本已锁定",
            isPresented: $isLockConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("仍采用此版本", role: .destructive) {
                applySearchPreview(confirmingLocks: true)
            }
            Button("取消", role: .cancel) {
                playbackState.cancelPendingManualLyricsAdoption()
            }
        } message: {
            Text("当前歌曲有 \(playbackState.pendingManualLyricsAdoptionLockedVersionCount) 个锁定歌词版本。继续会将预览歌词设为当前，并保留原版本的锁定标记。")
        }
    }

    private func applySearchPreview(confirmingLocks: Bool) {
        guard !isApplyingPreview else { return }
        isApplyingPreview = true
        previewAdoptionMessage = nil
        Task { @MainActor in
            do {
                let result: LyricsPersistenceSaveResult?
                if confirmingLocks {
                    result = try await playbackState.confirmPendingManualLyricsAdoption()
                } else {
                    result = try await playbackState.adoptSearchPreviewLyrics()
                }
                guard let result else {
                    previewAdoptionMessage = "预览已失效，未更改当前版本。"
                    isApplyingPreview = false
                    return
                }
                switch result.disposition {
                case .inserted, .duplicate:
                    if result.versionID == nil {
                        previewAdoptionMessage = "没有返回持久版本身份，未显示采用成功。"
                    }
                case .lockedConflict:
                    isLockConfirmationPresented = true
                case .skippedLocked:
                    previewAdoptionMessage = "歌词仍受锁定保护，未采用。"
                case .rejected(let message):
                    previewAdoptionMessage = message
                }
            } catch {
                previewAdoptionMessage = "歌词未能保存：\(error.localizedDescription)"
            }
            isApplyingPreview = false
        }
    }

    private var isAuthorizing: Bool {
        if case .authorizing = playbackState.spotifyAuthorizationManager.state {
            return true
        }
        return false
    }

    private func emptyState(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .tint(Color.accentColor)
                    .controlSize(.small)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func search() {
        manager.search(query: SongSearchQuery(text: query))
    }


}

private struct SearchRecordMark: View {
    var body: some View {
        VStack(spacing: 3) {
            Capsule().frame(width: 16, height: 2)
            Capsule().frame(width: 11, height: 2).frame(width: 16, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// One result row for both the complete search page and toolbar panel.
struct SongSearchResultRow: View {
    let result: SongSearchResult
    @V3ContentPlaybackState var state: PlaybackState
    var showsSeparator = true
    var isSelected = false
    var onViewLyrics: (() -> Void)? = nil

    private var matchesDisplayedTrack: Bool {
        TrackIdentity(track: result.track) == TrackIdentity(track: state.displayedTrack)
            || (!state.isShowingSearchPreview && state.liveLyricsVersionID != nil
                && state.liveLyricsVersionID == result.savedLibraryEntry?.activeLyricsVersionID)
    }

    private var isLoading: Bool {
        if case .loading = state.lyricsState { return matchesDisplayedTrack }
        return false
    }
    private var isAdopted: Bool { matchesDisplayedTrack && !state.lyrics.isEmpty && !isLoading }

    var body: some View {
        HStack(spacing: 8) {
            Button { onViewLyrics?(); state.loadSearchResult(result) } label: {
                HStack(spacing: 10) {
                    AsyncImage(url: result.artworkURL ?? result.track.artworkURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.secondary.opacity(0.1))
                    }
                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.track.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(1)
                        Text("\(result.track.artist) · \(result.track.album.isEmpty ? "未知专辑" : result.track.album)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(formatDuration(result.catalogMetadata?.duration ?? result.track.duration))
                                .monospacedDigit()
                            ForEach(result.savedLayerLabels, id: \.self) { label in
                                Text(label).padding(.horizontal, 3)
                                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            }
                            if let metadata = result.catalogMetadata {
                                Text(metadata.releaseDate ?? "发行日期未知").lineLimit(1)
                                if metadata.explicit { Text("Explicit") }
                            }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        if isAdopted { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        Text(isLoading ? "搜索中…" : "查看歌词")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
                        Text(result.source.displayName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 9)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if TrackIdentity.spotifyRequestTrackID(result.track.spotifyId ?? result.track.spotifyURL?.absoluteString) != nil {
                Button { state.playSearchTrack(result.track) } label: {
                    Image(systemName: "play.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("播放这首歌")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) { if showsSeparator { Divider() } }
        .accessibilityLabel("歌曲结果：\(result.track.title)，\(result.track.artist)")
        .accessibilityHint("查看这首歌的歌词")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "已选中" : isAdopted ? "已采用" : "查看歌词")
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "时长未知" }
        let seconds = Int(value)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct SongSearchResultGroup: Identifiable {
    let title: String
    let results: [SongSearchResult]
    var id: String { title }

    static func panelGroups(_ results: [SongSearchResult]) -> [Self] {
        [Self(title: "本地已存", results: Array(results.filter(\.isSavedLocally).prefix(5))),
         Self(title: "在线", results: Array(results.filter { !$0.isSavedLocally }.prefix(5)))]
            .filter { !$0.results.isEmpty }
    }
}

extension SongSearchResult {
    var isSavedLocally: Bool { savedLibraryEntry != nil || source == .local }
    var savedLayerLabels: [String] {
        guard let entry = savedLibraryEntry else { return source == .local ? ["词"] : [] }
        return [(entry.lyricsVersionCount > 0 ? "词" : nil),
                (entry.translationVersionCount > 0 ? "译" : nil),
                (entry.readingVersionCount > 0 ? "读" : nil)].compactMap { $0 }
    }
}
