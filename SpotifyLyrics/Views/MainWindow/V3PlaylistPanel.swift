import SwiftUI

struct PlaylistFilterField: View {
    @ObservedObject var browser: PlaylistBrowserModel

    var body: some View {
        HStack(spacing: 6) {
            TextField("搜索歌单、歌曲或专辑", text: $browser.filterText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("playlist.filter")
            if !browser.filterText.isEmpty {
                Button { browser.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清空歌单搜索")
            }
        }
    }
}

struct PlaylistBrowserWindow: View {
    @V3ContentPlaybackState var state: PlaybackState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PlaylistFilterField(browser: state.playlistBrowser)
                PlaylistLyricsBatchButton(state: state, browser: state.playlistBrowser)
                TranslationBatchButton(state: state, browser: state.playlistBrowser)
                Button { state.playlistBrowser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("刷新歌单与队列")
                    .accessibilityLabel("刷新歌单与队列")
            }
            .padding(12)
            if state.lyricsBatch.total > 0 || state.isPreparingPlaylistLyricsBatch {
                PlaylistLyricsBatchStatus(state: state, batch: state.lyricsBatch)
                    .padding([.horizontal, .bottom], 12)
            }
            if state.translationBatchProgress != nil {
                TranslationBatchStatus(state: state).padding([.horizontal, .bottom], 12)
            }
            Divider()
            V3PlaylistPanel(browser: state.playlistBrowser, currentTrackID: state.playlistTrackID,
                            currentArtworkURL: state.currentTrack.artworkURL)
        }
    }
}

struct V3PlaylistPanel: View {
    @ObservedObject var browser: PlaylistBrowserModel
    @ObservedObject private var picker: PlaylistPickerModel
    let currentTrackID: String?
    let currentArtworkURL: URL?
    @State private var playingAccent = Color.accentColor
    @State private var hoveredSidebarID: String?
    @State private var hoveredTrackOffset: Int?
    init(browser: PlaylistBrowserModel, currentTrackID: String? = nil, currentArtworkURL: URL? = nil) {
        self.currentTrackID = currentTrackID
        self.currentArtworkURL = currentArtworkURL
        self.browser = browser
        _picker = ObservedObject(wrappedValue: browser.picker)
#if DEBUG
        // Offscreen fixture state only; never moves the user's pointer.
        if ProcessInfo.processInfo.arguments.contains("--queue-hover-fixture") {
            _hoveredTrackOffset = State(initialValue: 0)
        }
        if ProcessInfo.processInfo.arguments.contains("--playlist-hover-fixture") {
            _hoveredSidebarID = State(initialValue: "morning")
            _hoveredTrackOffset = State(initialValue: 0)
        }
#endif
    }
    var body: some View {
        let tracks = browser.filteredTracks
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        destination(browser.queueTitle, symbol: "list.bullet", id: PlaylistBrowserModel.queueID)
                        destination(picker.likedRowTitle, symbol: "heart.fill", id: PlaylistBrowserModel.likedID)
                        Divider().padding(.vertical, 6)
                        ForEach(browser.filteredPlaylists) { playlist in
                            destination(playlist.name, symbol: "music.note.list", id: playlist.id, playlist: playlist)
                                .onAppear { picker.ensureMembership(for: playlist) }
                                .onChange(of: currentTrackID) { _, _ in picker.ensureMembership(for: playlist) }
                        }
                        if case .loading = picker.phase { ProgressView().controlSize(.small).padding() }
                        if case .failed(let error) = picker.phase { Text(error).font(.caption).padding() }
                        if let notice = picker.notice { Text(notice).font(.caption).padding() }
                    }
                }.frame(width: min(300, geometry.size.width * 0.43))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    selectedHeader(firstVisible: tracks.first)
                    Divider().padding(.horizontal, 12)
                    if browser.selectedTracksAreLoading { ProgressView().controlSize(.small).padding() }
                    if let message = browser.emptyMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).padding(12)
                    } else if browser.isFiltering, tracks.isEmpty, !browser.selectedTracksAreLoading {
                        Text("此列表没有符合条件的歌曲").font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tracks) { item in
                                if browser.selectedID == PlaylistBrowserModel.queueID {
                                    trackRow(item)
                                } else {
                                    trackRow(item).onTapGesture(count: 2) { browser.play(item) }
                                }
                            }
                        }
                    }
                    if let notice = browser.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(12) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { browser.open() }
        .onChange(of: browser.source) { _, _ in browser.open() }
        .task(id: currentArtworkURL) {
            let palette = await LyricIslandArtworkColors.palette(for: currentArtworkURL)
            guard !Task.isCancelled else { return }
            playingAccent = LyricIslandArtworkColors.listeningAccent(palette) ?? .accentColor
        }
    }
    private var selectedTitle: String {
        if browser.selectedID == PlaylistBrowserModel.queueID { return browser.queueContextName ?? browser.queueTitle }
        if browser.selectedID == PlaylistBrowserModel.likedID { return picker.likedRowTitle }
        return picker.playlists.first { $0.id == browser.selectedID }?.name ?? "歌单"
    }
    private func selectedHeader(firstVisible: SpotifyPlaylistTrack?) -> some View {
        let playlist = picker.playlists.first { $0.id == browser.selectedID }
        let isQueue = browser.selectedID == PlaylistBrowserModel.queueID
        let isMusicOrder = isQueue && browser.queueContextName != nil
        let count = playlist?.trackCount ?? (isQueue ? browser.queue.count : picker.likedCount ?? browser.tracks.count)
        return HStack(spacing: 12) {
            Group {
                if let playlist { PlaylistCover(url: playlist.imageURL) }
                else { Image(systemName: isQueue ? "list.bullet" : "heart.fill")
                    .font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.07)) }
            }.frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedTitle).font(.title3.weight(.semibold)).lineLimit(2)
                Text([browser.source == .appleMusic ? "Apple Music" : browser.source == .spotifyDesktop ? "Spotify" : nil,
                      isMusicOrder ? "按歌单顺序" : nil,
                      browser.isFiltering ? "\(browser.filteredTracks.count) 首匹配" : "\(count) 首"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !isQueue {
                Button(browser.isFiltering ? "播放首个结果" : "播放", systemImage: "play.fill") {
                    if let firstVisible { browser.play(firstVisible) }
                }.disabled(firstVisible == nil || browser.isLoading)
            }
        }.padding(12)
    }

    private func destination(_ title: String, symbol: String, id: String, playlist: PlaylistSummary? = nil) -> some View {
        HStack(spacing: 4) {
            Button { browser.select(id) } label: {
                HStack(spacing: 8) {
                    Group {
                        if let playlist { PlaylistCover(url: playlist.imageURL) }
                        else { Image(systemName: symbol).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5)) }
                    }.frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).lineLimit(1)
                        if let playlist { Text("\(playlist.trackCount) 首").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if id != PlaylistBrowserModel.queueID, currentTrackID != nil {
                let checked = playlist.map { picker.isMember($0) } ?? picker.isLiked
                let busy = playlist.map { picker.isPending($0) || picker.isChecking($0) }
                    ?? picker.pending.contains(PlaylistPickerModel.likedRowID)
                Button {
                    if let playlist { picker.toggle(playlist) } else { picker.toggleLikedSongs() }
                } label: { membershipCircle(checked: checked, busy: busy) }
                    .buttonStyle(.plain).disabled(busy)
                    .opacity(checked || busy || hoveredSidebarID == id ? 1 : 0)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 6)
        .background(browser.selectedID == id ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hoveredSidebarID = $0 ? id : nil }
        .padding(.horizontal, 6)
    }

    private func trackRow(_ item: SpotifyPlaylistTrack) -> some View {
        let playing = browser.selectedID != PlaylistBrowserModel.queueID && currentTrackID.map {
            $0 == PlaybackState.playlistRequestTrackID(for: item.track, source: browser.source)
        } == true
        return HStack(spacing: 8) {
            if browser.selectedID == PlaylistBrowserModel.queueID {
                Button { browser.play(item) } label: { trackRowLabel(item, playing: playing) }
                    .buttonStyle(.plain)
            } else { trackRowLabel(item, playing: playing) }
            if browser.selectedID == PlaylistBrowserModel.queueID {
                V3QueueSkipButton(browser: browser, item: item, hovered: hoveredTrackOffset == item.offset)
            } else {
                V3QueueInsertButton(browser: browser, track: item.track, hovered: hoveredTrackOffset == item.offset)
                Button { browser.play(item) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.plain).help("播放这首歌")
                    .opacity(hoveredTrackOffset == item.offset ? 1 : 0)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(hoveredTrackOffset == item.offset ? Color.primary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hoveredTrackOffset = $0 ? item.offset : nil }
    }
    private func trackRowLabel(_ item: SpotifyPlaylistTrack, playing: Bool) -> some View {
        HStack(spacing: 8) {
            CachedArtwork(url: item.track.artworkURL) {
                if browser.source == .appleMusic, browser.selectedID != PlaylistBrowserModel.likedID {
                    Text("\(item.offset + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("歌单第 \(item.offset + 1) 首")
                } else { Image(systemName: "music.note") }
            }.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading) {
                Text(item.track.title).lineLimit(1).foregroundStyle(playing ? playingAccent : .primary)
                Text([item.track.artist, item.track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if playing { Image(systemName: "waveform").foregroundStyle(playingAccent).accessibilityLabel("正在播放") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    private func membershipCircle(checked: Bool, busy: Bool) -> some View {
        Group {
            if checked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.primary) }
            else if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: "circle").foregroundStyle(Color.primary.opacity(0.4)) }
        }.frame(width: 24, height: 28)
    }
}

struct V3PlaylistQueuePreview: View {
    @ObservedObject var browser: PlaylistBrowserModel
    @State private var hoveredRow: Int? = {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--queue-hover-fixture") { return 0 }
#endif
        return nil
    }()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let context = browser.queueContextName {
                Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.bottom, 5)
            }
            ForEach(Array(browser.queueItems.prefix(5).enumerated()), id: \.element.id) { position, item in
                let index = item.offset
                let track = item.track
                HStack(spacing: 8) {
                    Button { browser.jumpToQueuedTrack(at: item.offset, expecting: track) } label: {
                        HStack(spacing: 8) {
                            CachedArtwork(url: track.artworkURL) { Image(systemName: "music.note") }
                                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).fontWeight(position == 0 ? .semibold : .medium).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if position == 0 {
                                Text("下一首").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.primary.opacity(0.06), in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    V3QueueSkipButton(browser: browser, item: item, hovered: hoveredRow == index)
                }
                .frame(height: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hoveredRow == index ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onHover { hoveredRow = $0 ? index : nil }
            }
            if browser.showsQueueLoading { ProgressView().controlSize(.small) }
            else if browser.queue.isEmpty, browser.queueNotice == nil {
                Text(browser.emptyQueueMessage).foregroundStyle(.secondary)
            }
            if let notice = browser.queueNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { browser.loadQueue() }
        .onChange(of: browser.source) { _, _ in browser.loadQueue() }
    }
}

struct PlaylistLyricsBatchButton: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var browser: PlaylistBrowserModel
    @ObservedObject private var batch: LyricsBatchCompletion
    @State private var pending: Request?
    @State private var showsConfirmation = false

    private struct Request {
        let title: String
        let tracks: [Track]
    }

    init(state: PlaybackState, browser: PlaylistBrowserModel) {
        self.state = state
        self.browser = browser
        self.batch = state.lyricsBatch
    }

    var body: some View {
        Menu("批量查原词", systemImage: "text.magnifyingglass") {
            let queue = browser.queueItems.map(\.track)
            Button("补全播放队列原词") { offer("补全队列原词", queue) }.disabled(queue.isEmpty)
            Button("补全所选歌单原词") {
                let name = browser.picker.playlists.first { $0.id == browser.selectedID }?.name ?? "所选歌单"
                offer("补全「\(name)」原词", browser.tracks.map(\.track))
            }.disabled(browser.selectedID == PlaylistBrowserModel.queueID || browser.selectedTracksAreLoading || browser.tracks.isEmpty)
        }
        .disabled(state.isPreparingPlaylistLyricsBatch || batch.isRunning)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .confirmationDialog(pending?.title ?? "批量查原词", isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("开始免费查词") {
                if let pending { state.startPlaylistLyricsBatch(tracks: pending.tracks) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("列表共 \(pending?.tracks.count ?? 0) 首。会自动跳过已有本地原词的歌曲，仅查缺失原词（不消耗 AI 翻译额度），整轮结束后自动同步到 GitHub。")
        }
    }

    private func offer(_ title: String, _ tracks: [Track]) {
        pending = .init(title: title, tracks: TranslationSessionController.uniqueBatchTracks(tracks))
        showsConfirmation = true
    }
}

struct PlaylistLyricsBatchStatus: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var batch: LyricsBatchCompletion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.isPreparingPlaylistLyricsBatch {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在筛选未缓存原词的歌曲…").foregroundStyle(.secondary)
                }
            } else if batch.total > 0 {
                HStack {
                    Text(batch.isRunning ? "批量查原词中" : (batch.wasStopped ? "批量查原词已停止" : "批量查原词完成"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    let current = batch.retryProgress?.completed ?? batch.completed
                    let total = batch.retryProgress?.total ?? batch.total
                    Text("\(current)/\(total)").monospacedDigit()
                    if batch.isRunning {
                        Button(batch.wasStopped ? "停止中" : "停止") { batch.stop() }
                            .buttonStyle(.borderless)
                            .disabled(batch.wasStopped)
                    } else if batch.pendingCount > 0 {
                        Button("继续未查(\(batch.pendingCount))") {
                            batch.resume { [weak state] track in await state?.completeMissingLyrics(track: track) }
                        }
                        .buttonStyle(.borderless)
                    } else if batch.failedCount > 0 {
                        Button("重试失败(\(batch.failedCount))") {
                            batch.retryFailures { [weak state] track in await state?.completeMissingLyrics(track: track) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if batch.isRunning {
                    ProgressView(value: Double(batch.completed), total: Double(max(1, batch.total)))
                    if let title = batch.currentTitle {
                        Text(title).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption)
    }
}

struct TranslationBatchButton: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var browser: PlaylistBrowserModel
    @State private var pending: Request?
    @State private var showsConfirmation = false

    private struct Request {
        let title: String
        let tracks: [Track]
    }

    var body: some View {
        Menu("批量翻译", systemImage: "character.bubble") {
            let queue = browser.queueItems.map(\.track)
            Button("提前翻译接下来 2 首") { offer("接下来 2 首", Array(queue.prefix(2))) }.disabled(queue.isEmpty)
            Button("翻译播放队列") { offer(browser.queueTitle, queue) }.disabled(queue.isEmpty)
            Button("翻译所选歌单") {
                offer(browser.picker.playlists.first { $0.id == browser.selectedID }?.name ?? "所选歌单",
                      browser.tracks.map(\.track))
            }.disabled(browser.selectedID == PlaylistBrowserModel.queueID || browser.selectedTracksAreLoading || browser.tracks.isEmpty)
        }
        .disabled(!state.canStartTranslationBatch)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .confirmationDialog(pending?.title ?? "批量翻译", isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button("开始翻译") {
                if let pending { state.translateBatch(title: pending.title, tracks: pending.tracks) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(pending?.tracks.count ?? 0) 首。会先复用当前模型与译风的缓存，只为缺少完整译文的歌曲发请求。")
        }
    }

    private func offer(_ title: String, _ tracks: [Track]) {
        pending = .init(title: title, tracks: TranslationSessionController.uniqueBatchTracks(tracks))
        showsConfirmation = true
    }
}

struct TranslationBatchStatus: View {
    @ObservedObject var state: PlaybackState

    var body: some View {
        if let batch = state.translationBatchProgress {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(batch.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text("\(batch.finished)/\(batch.total)").monospacedDigit()
                    if batch.running { Button("停止") { state.cancelTranslationBatch() }.buttonStyle(.borderless) }
                    else if batch.cancelled { Text("已停止").foregroundStyle(.secondary) }
                }
                if batch.running {
                    ProgressView(value: Double(batch.finished), total: Double(batch.total))
                    Text(batch.currentTrack).lineLimit(1)
                }
                Text("新译 \(batch.translated) · 缓存 \(batch.cached) · 缺词 \(batch.missingLyrics) · 失败 \(batch.failed)")
                    .foregroundStyle(.secondary)
                if let error = batch.lastError {
                    Text(error).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }.font(.caption)
        }
    }
}

/// Queue rows are hidden locally and marked for a single skip when they become current.
private struct V3QueueSkipButton: View {
    @ObservedObject var browser: PlaylistBrowserModel
    let item: SpotifyPlaylistTrack
    let hovered: Bool
    var body: some View {
        if browser.supportsQueueEdits {
            Button { browser.skipQueuedTrack(item) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("跳过这首").accessibilityLabel("跳过这首")
            .disabled(TrackIdentity.spotifyRequestTrackID(item.track.spotifyId ?? item.track.spotifyURL?.absoluteString) == nil)
            .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
        }
    }
}

/// Shared by playlist, liked-song and catalog search rows. Never used for queue rows.
struct V3QueueInsertButton: View {
    @ObservedObject var browser: PlaylistBrowserModel
    let track: Track
    let hovered: Bool
    @State private var sending = false
    @State private var inserted = false
    @State private var error: String?
    var body: some View {
        if browser.supportsQueueEdits {
            HStack(spacing: 4) {
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button {
                    sending = true
                    error = nil
                    Task {
                        defer { sending = false }
                        do { try await browser.enqueue(track); inserted = true }
                        catch is CancellationError { return }
                        catch SpotifyCatalogError.forbidden { error = "需要 Spotify Premium" }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Image(systemName: inserted ? "checkmark" : "text.line.first.and.arrowtriangle.forward")
                }
                .buttonStyle(.plain).disabled(sending || inserted).help("插入播放")
                .opacity(hovered || sending || inserted || error != nil ? 1 : 0)
            }
            .task(id: inserted) {
                guard inserted else { return }
                try? await Task.sleep(for: .milliseconds(1500))
                if !Task.isCancelled { inserted = false }
            }
        }
    }
}

/// The running whole-song translation, step by step: which step it is on,
/// how many lines are written, how long it has taken, and a way to stop it.
struct TranslationLiveCard: View {
    @ObservedObject var state: PlaybackState
    var accent: Color? = nil

    static let steps = ["准备", "已发送", "思考", "写译文", "校验"]

    static func stepIndex(_ stage: AITranslationLiveStage) -> Int {
        switch stage {
        case .preparing: return 0
        case .sent: return 1
        case .thinking: return 2
        case .writing: return 3
        case .checking: return 4
        }
    }

    static func headline(_ stage: AITranslationLiveStage) -> String {
        switch stage {
        case .preparing: return "正在打开翻译对话"
        case .sent: return "已发送，等模型回应"
        case .thinking: return "模型在理解整首歌"
        case .writing(let done, let total): return "正在写译文 · \(done)/\(total) 行"
        case .checking: return "逐行核对并保存"
        }
    }

    /// 0…1 while lines are written; nil while the step has no measure.
    static func fraction(_ stage: AITranslationLiveStage) -> Double? {
        if case .writing(let done, let total) = stage, total > 0 { return Double(done) / Double(total) }
        if case .checking = stage { return 1 }
        return nil
    }

    var body: some View {
        let stage = state.translationLiveStage
        let tint = accent ?? .accentColor
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.headline(stage))
                    .font(.system(size: 12.5, weight: .semibold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let started = state.translationStartedAt {
                    TimelineView(.v3Every(1)) { context in
                        Text(Self.elapsed(context.date.timeIntervalSince(started)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button("取消") { state.cancelTranslation() }
                    .buttonStyle(.borderless).font(.system(size: 11.5))
            }
            if let fraction = Self.fraction(stage) {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(tint)
                    .animation(.easeOut(duration: 0.25), value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear).tint(tint)
            }
            HStack(spacing: 0) {
                ForEach(Self.steps.indices, id: \.self) { index in
                    let current = Self.stepIndex(stage)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(index < current ? tint : index == current ? tint.opacity(0.9) : Color.primary.opacity(0.18))
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(tint.opacity(index == current ? 0.45 : 0), lineWidth: 3).scaleEffect(1.7))
                        Text(Self.steps[index])
                            .font(.system(size: 10.5, weight: index == current ? .semibold : .regular))
                            .foregroundStyle(index <= current ? Color.primary : Color.secondary)
                    }
                    if index < Self.steps.count - 1 { Spacer(minLength: 2) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("第 \(Self.stepIndex(stage) + 1) 步，共 \(Self.steps.count) 步：\(Self.headline(stage))")
            if !state.translationProgressMessage.isEmpty {
                Text(state.translationProgressMessage)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.25), lineWidth: 0.75))
        .animation(.easeOut(duration: 0.2), value: Self.stepIndex(stage))
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return value < 60 ? "\(value) 秒" : String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// A small ring on the 译文 tool while a translation runs, so it can be
/// followed with the panel closed.
struct TranslationToolbarRing: View {
    @ObservedObject var state: PlaybackState
    var accent: Color? = nil

    // No endless spin: the toolbar stays idle on the main thread while a
    // request runs; the arc moves only when a step or line count changes.
    var body: some View {
        if case .loading = state.translationState {
            let fraction = TranslationLiveCard.fraction(state.translationLiveStage)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction.map { max(0.06, $0) }
                          ?? 0.08 * Double(TranslationLiveCard.stepIndex(state.translationLiveStage) + 1))
                    .stroke(accent ?? .accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            }
            .frame(width: 11, height: 11)
            .help(TranslationLiveCard.headline(state.translationLiveStage))
            .accessibilityLabel("翻译进行中：\(TranslationLiveCard.headline(state.translationLiveStage))")
        }
    }
}
