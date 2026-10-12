import SwiftUI
import AppKit

struct SongSearchPopover: View {
    @ObservedObject var manager: SongSearchManager
    @ObservedObject var playbackState: PlaybackState
    @State private var query = ""
    @State private var isApplyingPreview = false
    @State private var isLockConfirmationPresented = false
    @State private var previewAdoptionMessage: String?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LyricsDesignTokens.mutedText)

                TextField("搜索歌曲、艺人或专辑", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        search()
                    }

                Button("搜索", action: search)
                    .buttonStyle(.borderedProminent)
                    .tint(LyricsDesignTokens.accent)
                    .controlSize(.small)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LyricsDesignTokens.controlBackground)
            )

            Text("在线目录搜索需要 Spotify Web 授权；歌词正文仍由当前歌词 Provider 链负责")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)

            spotifyAuthorizationSection
            if playbackState.isShowingSearchPreview, playbackState.hasLiveTrack {
                searchPreviewActionBanner
            }

            content
        }
        .padding(16)
        .frame(width: 440, height: 470, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            if let existing = manager.state.query?.text, !existing.isEmpty {
                query = existing
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
                    .foregroundStyle(playbackState.spotifyAuthorizationManager.state.isAuthorized ? LyricsDesignTokens.accent : LyricsDesignTokens.mutedText)
                Text(playbackState.spotifyAuthorizationManager.state.userFacingMessage)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
                Spacer(minLength: 6)
                if playbackState.spotifyAuthorizationManager.isConfigured,
                   !playbackState.spotifyAuthorizationManager.state.isAuthorized {
                    Button("授权") {
                        playbackState.spotifyAuthorizationManager.authorize()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LyricsDesignTokens.accent)
                    .controlSize(.small)
                    .disabled(isAuthorizing)
                } else {
                    SettingsLink {
                        Label("设置", systemImage: "gearshape")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LyricsDesignTokens.accent)
                }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LyricsDesignTokens.controlBackground.opacity(0.62))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .idle:
            emptyState(icon: "music.note", title: "搜索歌曲或歌词", detail: "输入标题、艺人或专辑后开始")
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
                detail: "换个标题、艺人名或 Spotify 链接再试。",
                actionTitle: "重新搜索",
                action: search
            )
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 10) {
                let needsAuthorization = message.contains("Client ID") || message.contains("未授权")
                emptyState(
                    icon: needsAuthorization ? "person.badge.key" : "exclamationmark.triangle",
                    title: needsAuthorization ? "需要授权 Spotify" : "搜索失败",
                    detail: needsAuthorization
                        ? "授权后即可搜索 Spotify 在线曲库。"
                        : "暂时无法完成搜索，请检查网络后重试。"
                )
                if needsAuthorization {
                    Button("授权 Spotify") {
                        playbackState.spotifyAuthorizationManager.authorize()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LyricsDesignTokens.accent)
                    .disabled(isAuthorizing)
                } else {
                    Button("重新搜索", action: search)
                        .buttonStyle(.bordered)
                        .tint(LyricsDesignTokens.accent)
                }
            }
        case .results(_, let results):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(results) { result in
                        resultRow(result)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }

        if !playbackState.songSearchSelectionMessage.isEmpty {
            Text(playbackState.songSearchSelectionMessage)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultRow(_ result: SongSearchResult) -> some View {
        HStack(spacing: 8) {
            Button {
                playbackState.loadSearchResult(result)
            } label: {
                HStack(spacing: 10) {
                Image(systemName: result.lyrics == nil ? "music.note" : "text.quote")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LyricsDesignTokens.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(LyricsDesignTokens.controlBackground))

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.track.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(LyricsDesignTokens.primaryText)
                        .lineLimit(1)
                    Text("\(result.track.artist) · \(result.track.album.isEmpty ? "未知专辑" : result.track.album)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(LyricsDesignTokens.mutedText)
                        .lineLimit(1)
                    if let metadata = result.catalogMetadata {
                        Text("\(formatDuration(metadata.duration)) · \(metadata.releaseDate ?? "发行日期未知")\(metadata.explicit ? " · Explicit" : "")")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(LyricsDesignTokens.mutedText.opacity(0.82))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(result.source.displayName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(LyricsDesignTokens.mutedText)
                    Text(result.lyrics == nil ? "查看歌词" : "加载歌词")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(LyricsDesignTokens.accent)
                }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if result.source == .spotifyCatalog,
               let url = result.track.spotifyURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(LyricsDesignTokens.mutedText)
                }
                .buttonStyle(.plain)
                .help("在 Spotify 打开")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LyricsDesignTokens.controlBackground.opacity(0.72))
        )
        .accessibilityLabel("歌曲结果：\(result.track.title)，\(result.track.artist)")
        .accessibilityHint(result.lyrics == nil ? "查看这首歌的歌词" : "加载这首歌的歌词")
    }

    private var searchPreviewActionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .foregroundStyle(LyricsDesignTokens.accent)
            Text(playbackState.searchPreviewTrack.map { "已载入预览：「\($0.title)」" } ?? "已载入预览歌词")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.primaryText)
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
            .tint(LyricsDesignTokens.accent)
            .controlSize(.small)
            .disabled(isApplyingPreview)

            Button("退出预览") {
                playbackState.clearSearchPreview()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LyricsDesignTokens.controlBackground)
        )
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
                .foregroundStyle(LyricsDesignTokens.mutedText)
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.primaryText)
            Text(detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .tint(LyricsDesignTokens.accent)
                    .controlSize(.small)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func search() {
        manager.search(query: SongSearchQuery(text: query))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "时长未知" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
