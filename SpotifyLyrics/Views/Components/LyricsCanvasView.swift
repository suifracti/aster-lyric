import SwiftUI

private struct LyricsCandidateBrightCoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var lyricsCandidateBrightCover: Bool {
        get { self[LyricsCandidateBrightCoverKey.self] }
        set { self[LyricsCandidateBrightCoverKey.self] = newValue }
    }
}

struct LyricsCanvasView: View {
    @ObservedObject var state: PlaybackState
    var onSearch: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var lastScrolledLineIndex: Int?
    @State private var isAlignmentDetailsPresented = false
    @State private var manualLyricsSearchQuery = ""
    @State private var candidateToPreview: LyricsCandidate?

    var body: some View {
        Group {
            if !state.isShowingSearchPreview && state.liveTrackIsMarkedInstrumental {
                VStack(spacing: 12) {
                    Image(systemName: "music.note").font(.largeTitle)
                    Text("已标记为纯音乐").font(.headline)
                    Text("仅影响当前显示；已保存的歌词与译文仍保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("撤销纯音乐标记") { state.clearCurrentInstrumentalMark() }
                        .buttonStyle(.bordered)
                }
            } else {
            switch LyricsStatePresentation.active {
            case .systemV1:
                systemStateContent
            case .contentFirstV1:
                contentFirstStateContent
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(state.lyricsSessionRevision)
        .environment(\.lyricAgentPresentationMap, LyricAgentPresentationMap(lines: state.lyrics))
        .sheet(isPresented: $isAlignmentDetailsPresented) {
            if let report = state.lyricsState.alignmentReport {
                AlignmentPreviewView(report: report)
            }
        }
        // AssistExplainSheet is hosted once on MainLyricsWindowView so default
        // appleMusicImmersiveV3 (which does not embed LyricsCanvasView) can present it.
    }

    /// The archived renderer remains available as a rollback target. It uses
    /// the same state and commands; only the presentation of non-document
    /// states differs.
    @ViewBuilder
    private var systemStateContent: some View {
        if state.isShowingSearchPreview {
            if !state.lyrics.isEmpty {
                lyricsScroll
            } else {
                LyricsStateContentFirstView(state: state, onSearch: onSearch)
            }
        } else {
        switch state.lyricsState {
        case .loaded(_), .mockPreview:
            lyricsScroll
        case .alignmentQueued:
            VStack(spacing: 10) {
                lyricsScroll
                statusView(
                    icon: "timeline.selection",
                    message: "待对齐时间轴",
                    detail: state.songSearchSelectionMessage.isEmpty
                        ? "已获取歌词正文；原文/假名/罗马音独立保存。当前无可靠时间轴，不会伪造同步高亮。"
                        : state.songSearchSelectionMessage
                ) {
                    VStack(spacing: 8) {
                        Button("自动排轴") { state.alignCurrentLyricsWithLocalAudio() }
                            .buttonStyle(.borderedProminent)
                            .tint(LyricsDesignTokens.accent)
#if DEBUG
                        // Entry still available on classic LyricsCanvas layouts;
                        // explain sheet is hosted on MainLyricsWindowView only.
                        if state.canStartListeningAssist {
                            Button("边听边排轴") { state.presentListeningAssistExplanation() }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("assist.listening.start.canvas")
                        }
                        if state.assistPhase == .capturing || state.assistPhase == .merging {
                            Text(state.assistStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("取消边听边排") { state.cancelListeningAssist() }
                                .buttonStyle(.bordered)
                        }
                        if state.assistPhase == .ready {
                            Button("打开编辑草稿") {
                                state.openListeningAssistEditorWithDraft()
                                openWindow(id: "lyrics-editor")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if state.assistPhase == .explaining {
                            Button("取消") { state.cancelListeningAssist() }
                                .buttonStyle(.bordered)
                        }
#endif
                        retryButton
                    }
                }
                .frame(maxHeight: 180)
            }
        case .alignmentRunning(_, _, let progress):
            VStack(spacing: 10) {
                lyricsScroll
                statusView(
                    icon: "waveform",
                    message: "正在自动排轴… \(Int(progress * 100))%",
                    detail: state.songSearchSelectionMessage.isEmpty ? "识别音频并与已知歌词逐行对齐" : state.songSearchSelectionMessage
                ) {
                    Button("取消") { state.cancelAlignmentPreview() }
                        .buttonStyle(.bordered)
                }
                .frame(maxHeight: 140)
            }
        case .alignmentPreview(_, _, _, let report):
            VStack(spacing: 10) {
                lyricsScroll
                statusView(
                    icon: "checkmark.circle",
                    message: String(format: "排轴预览 · 置信度 %.0f%%", report.overallConfidence * 100),
                    detail: "低置信/未匹配 \(report.lowConfidenceCount) 行已标出。确认前不会覆盖保存；可试听 seek。"
                ) {
                    HStack(spacing: 8) {
                        Button("确认并保存") { state.confirmAlignmentPreview(saveLocal: true) }
                            .buttonStyle(.borderedProminent)
                            .tint(LyricsDesignTokens.accent)
                        Button("逐行证据") { isAlignmentDetailsPresented = true }
                            .buttonStyle(.bordered)
                        Button("放弃") { state.cancelAlignmentPreview() }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxHeight: 160)
            }
        case .loading where state.isAutomaticSearchDisabledForDisplayedSession:
            statusView(icon: "text.quote", message: "正在加载已保存歌词…", detail: "切歌后自动搜索已关闭。")
        case .loading:
            statusView(icon: "magnifyingglass", message: "正在自动补全歌词…", detail: "Local → AMLL → LRCLIB → 网易云/QQ（实验）查询中")
        case .noLyrics:
            statusView(icon: "text.magnifyingglass", message: "来源未提供歌词", detail: "这不代表已确认纯音乐。可以继续搜索或手动添加歌词。") {
                VStack(spacing: 8) {
                    retryButton
                    manualLyricsQueryEntry
                    Button("导入本地音频 · ASR 草稿") { state.importLocalAudioForASR() }
                        .buttonStyle(.bordered)
                    ManualLyricsActionsView(state: state)
                }
            }
        case .noMatch:
            statusView(
                icon: "magnifyingglass",
                message: "自动补全未找到歌词",
                detail: "多别名与在线源均无正文（noTextSource）。可选：重试自动补全，或导入本地音频生成 ASR 草稿。"
            ) {
                VStack(spacing: 8) {
                    retryButton
                    manualLyricsQueryEntry
                    Button("导入本地音频 · ASR 草稿") { state.importLocalAudioForASR() }
                        .buttonStyle(.bordered)
                    ManualLyricsActionsView(state: state)
                }
            }
        case .noSelection:
            statusView(
                icon: "rectangle.slash",
                message: "未选择歌词版本",
                detail: "当前歌曲仍在播放；可重新搜索或从主窗口选择歌词版本。"
            ) {
                VStack(spacing: 8) {
                    retryButton
                    ManualLyricsActionsView(state: state)
                }
            }
        case .failed(_, let failure):
            statusView(icon: "exclamationmark.triangle", message: "自动补全失败", detail: failure.userFacingMessage) {
                VStack(spacing: 8) {
                    retryButton
                    manualLyricsQueryEntry
                    ManualLyricsActionsView(state: state)
                }
            }
        case .candidates(_, let candidates):
            candidateList(candidates)
        case .idle where state.isAutomaticSearchDisabledForDisplayedSession:
            statusView(
                icon: "magnifyingglass",
                message: "切歌后自动搜索已关闭",
                detail: state.lyricsSession.persistenceStatusMessage.map { "读取已保存歌词失败：\($0)" }
                    ?? "已保存版本仍会自动加载；可用顶部“搜索歌曲”入口手动查找。"
            ) {
                if let onSearch {
                    Button("手动搜索歌词", action: onSearch)
                        .buttonStyle(.borderedProminent)
                        .tint(LyricsDesignTokens.accent)
                }
            }
        case .idle:
            statusView(icon: "music.note", message: "等待 Spotify 歌曲", detail: "连接后将自动补全当前歌曲歌词")
        }
        }
    }

    @ViewBuilder
    private var contentFirstStateContent: some View {
        if !state.lyrics.isEmpty {
            systemStateContent
        } else {
            LyricsStateContentFirstView(state: state, onSearch: onSearch)
        }
    }

    private var retryButton: some View {
        Button("自动补全歌词") {
            state.autoCompleteLyrics()
        }
        .buttonStyle(.bordered)
        .tint(LyricsDesignTokens.accent)
    }

    private var manualLyricsQueryEntry: some View {
        HStack(spacing: 6) {
            TextField("标题或艺人搜索词", text: $manualLyricsSearchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
            Button("搜索") {
                let query = manualLyricsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return }
                state.retryLyrics(queryOverride: query)
            }
            .buttonStyle(.bordered)
            .disabled(manualLyricsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("手动修改歌词搜索词")
    }

    private var lyricsScroll: some View {
        let seekDocumentTrack = state.displayedTrack
        let seekDocumentIdentity = TrackIdentity(track: seekDocumentTrack)
        let seekDocumentRevision = state.lyricsSessionRevision
        let seekDocumentSource: PlaybackState.LyricsSeekDocumentSource = state.isShowingSearchPreview ? .searchPreview : .live
        let seekLines = state.lyrics
        let seekIsSynchronized = state.lyricsAreSynchronized
        return VStack(alignment: .leading, spacing: 6) {
            lyricsScopeControls
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        LazyVStack(
                            alignment: .leading,
                            spacing: LyricsDesignTokens.lyricRowSpacing(
                                for: geometry.size.width,
                                visibleLayerCount: visibleLayerCount
                            )
                        ) {
                            ForEach(Array(seekLines.enumerated()), id: \.element.id) { index, line in
                                if let seekTimestamp = LyricsTimeline.validSeekTimestamp(
                                    for: line,
                                    isSynchronized: seekIsSynchronized,
                                    duration: seekDocumentTrack.duration
                                ) {
                                    Button {
                                        state.seekFromDisplayedLyrics(
                                            to: seekTimestamp,
                                            documentIdentity: seekDocumentIdentity,
                                            documentRevision: seekDocumentRevision,
                                            documentSource: seekDocumentSource,
                                            source: "lyric-line"
                                        )
                                    } label: {
                                        lyricLineView(
                                            line: line,
                                            index: index,
                                            availableWidth: geometry.size.width
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .accessibilityLabel(line.originalText)
                                    .accessibilityHint("跳转到歌词时间")
                                    .accessibilityIdentifier("lyrics-line-\(line.id.uuidString)")
                                } else {
                                    lyricLineView(
                                        line: line,
                                        index: index,
                                        availableWidth: geometry.size.width
                                    )
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .frame(
                            width: min(
                                720,
                                max(520, geometry.size.width - (LyricsDesignTokens.canvasHorizontalPadding * 2 + 16))
                            ),
                            alignment: .leading
                        )
                        .animation(
                            LyricsTransitionPolicy.animation(reduceMotion: reduceMotion),
                            value: visibleLayerCount
                        )
                        .animation(
                            LyricsTransitionPolicy.animation(reduceMotion: reduceMotion),
                            value: state.lyricsAreSynchronized
                        )

                        Spacer(minLength: 0)
                    }
                    .frame(
                        minWidth: max(0, geometry.size.width - LyricsDesignTokens.canvasHorizontalPadding * 2),
                        minHeight: 320,
                        alignment: .center
                    )
                    .padding(.horizontal, LyricsDesignTokens.canvasHorizontalPadding)
                    .padding(.vertical, LyricsDesignTokens.canvasVerticalPadding)
                    }
                    .scrollIndicators(.hidden)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.13),
                                .init(color: .black, location: 0.87),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .accessibilityElement(children: .contain)
                    .onAppear {
                        lastScrolledLineIndex = nil
                        scrollToCurrentLine(using: proxy, animated: false)
                    }
                    .onChange(of: state.currentLineIndex) { _, _ in
                        scrollToCurrentLine(using: proxy, animated: true)
                    }
                    .onChange(of: state.lyricsSessionRevision) { _, _ in
                        lastScrolledLineIndex = nil
                        scrollToCurrentLine(using: proxy, animated: false)
                    }
                    .onChange(of: state.preferences) { _, _ in
                        scrollToCurrentLine(using: proxy, animated: true, force: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lyricsScopeControls: some View {
        if state.isShowingSearchPreview {
            searchPreviewReadOnlyCue
        } else {
            translationControls
        }
    }

    private var searchPreviewReadOnlyCue: some View {
        HStack(spacing: 8) {
            Label("搜索预览 · 只读", systemImage: "eye")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(LyricsDesignTokens.accent.opacity(0.12), in: Capsule())

            Text(state.displayedTrack.title.isEmpty ? "候选歌词" : state.displayedTrack.title)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LyricsDesignTokens.canvasHorizontalPadding)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lyrics.search-preview.read-only")
    }

    private var translationControls: some View {
        HStack(spacing: 8) {
            Menu("歌词版本") {
                Button("无歌词版本") { state.selectNoLyricsVersion() }
                    .disabled(state.isLyricsSelectionEmpty)
                Text(state.isLyricsSelectionEmpty ? "当前会话未选择版本" : "当前会话使用已采用版本")
            }
            .menuStyle(.borderlessButton)
            Image(systemName: "character.bubble")
                .foregroundStyle(LyricsDesignTokens.mutedText)
            if state.translationState == .loading {
                ProgressView().controlSize(.small)
                Text("正在翻译整首歌词…")
            } else if !state.translationState.userFacingMessage.isEmpty {
                Text(state.translationState.userFacingMessage)
            } else if state.isTranslationSelectionEmpty {
                Text("未选择翻译版本（显示开关独立）")
            } else if state.selectedTranslation != nil {
                Text("已加载翻译")
            } else {
                Text("暂无翻译")
            }
            Spacer()
            if state.selectedTranslation == nil {
                Button("翻译") { state.translateCurrentLyrics() }
                    .buttonStyle(.bordered)
            } else {
                Button("重新翻译") { state.retranslateCurrentLyrics() }
                    .buttonStyle(.bordered)
            }
            Menu("翻译版本") {
                Button("无翻译版本") { state.selectNoTranslationVersion() }
                    .disabled(state.isTranslationSelectionEmpty)
                if !state.translationVersions.isEmpty { Divider() }
                ForEach(state.translationVersions, id: \.record.id) { version in
                    Button {
                        state.selectTranslation(versionID: version.record.id)
                    } label: {
                        Text("\(version.record.model.isEmpty ? version.record.sourceKind.rawValue : version.record.model) · \(version.record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                if state.selectedTranslation?.record.isLocked == false {
                    Divider()
                    Button("锁定当前版本") { state.lockSelectedTranslation() }
                    Button("删除当前版本", role: .destructive) { state.deleteSelectedTranslation() }
                }
            }
            .menuStyle(.borderlessButton)
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(LyricsDesignTokens.mutedText)
        .padding(.horizontal, LyricsDesignTokens.canvasHorizontalPadding)
        .padding(.top, 8)
    }

    private func statusView<Accessory: View>(
        icon: String,
        message: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(LyricsDesignTokens.mutedText)

            Text(message)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.primaryText)

            Text(detail)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)
                .multilineTextAlignment(.center)

            accessory()
        }
        .padding(28)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 6)
        .accessibilityElement(children: .combine)
    }

    private func candidateList(_ candidates: [LyricsCandidate]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("选择歌词版本")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.primaryText)

                Text("找到这些版本。请先核对歌曲和歌手，预览后采用；之后仍可随时切换。")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)

                ForEach(candidates) { candidate in
                    Button {
                        candidateToPreview = candidate
                    } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                }
                ManualLyricsActionsView(state: state)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, LyricsDesignTokens.canvasHorizontalPadding)
            .padding(.vertical, LyricsDesignTokens.canvasVerticalPadding)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $candidateToPreview) { candidate in
            LyricsCandidatePreviewSheet(
                candidate: candidate,
                onAdopt: { try await state.adoptLyricsCandidate(candidate) },
                onConfirmLocked: { try await state.confirmPendingManualLyricsAdoption() },
                onCancelLocked: { state.cancelPendingManualLyricsAdoption() }
            )
        }
    }

    private func candidateRow(_ candidate: LyricsCandidate) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                if let notice = candidate.arrangementNotice {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Text("\(candidate.artist) · \(candidate.album)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(candidate.source.displayName)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
                Text("预览")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
    }

    private func distance(from index: Int) -> Int {
        LyricsTimeline.presentationDistance(
            index: index,
            currentIndex: state.currentLineIndex,
            isSynchronized: state.lyricsAreSynchronized
        )
    }

    @ViewBuilder
    private func lyricLineView(
        line: LyricLine,
        index: Int,
        availableWidth: CGFloat
    ) -> some View {
        LyricLineView(
            line: line,
            isActive: state.currentLineIndex == index,
            distance: distance(from: index),
            isSynchronized: state.lyricsAreSynchronized,
            preferences: state.preferences,
            availableWidth: availableWidth,
            visibleLayerCount: visibleLayerCount,
            language: state.isShowingSearchPreview ? nil : state.liveLyricsLanguage
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .id(line.id)
    }

    private func scrollToCurrentLine(
        using proxy: ScrollViewProxy,
        animated: Bool,
        force: Bool = false
    ) {
        guard let currentIndex = state.currentLineIndex,
              state.lyrics.indices.contains(currentIndex),
              force || lastScrolledLineIndex != currentIndex else { return }

        let action = {
            proxy.scrollTo(state.lyrics[currentIndex].id, anchor: .center)
            // Mark it only after asking the proxy to locate the row. If the
            // first request happens while LazyVStack is still materializing,
            // a later clock tick can retry the same target.
            lastScrolledLineIndex = currentIndex
        }

        if animated {
            LyricsTransitionPolicy.perform(reduceMotion: reduceMotion, action)
        } else {
            action()
        }
    }

    private var visibleLayerCount: Int {
        [
            state.preferences.showOriginal,
            state.preferences.kanaDisplayMode != .hidden,
            state.preferences.showRomaji,
            state.preferences.showTranslation
        ]
        .filter { $0 }
        .count
    }
}

/// Content-first rendering for all non-document lyric states.  This is a
/// presentation surface only: PlaybackState remains the owner of actions and
/// the shared lyric session remains the owner of candidates. No timer or
/// preview session is created here.
struct LyricsStateContentFirstView: View {
    @Environment(\.lyricsCandidateBrightCover) private var brightCover
    @V3ContentPlaybackState var state: PlaybackState
    var compact = false
    var lyricsFocus = false
    var compactLabel: String? = nil
    var onSearch: (() -> Void)? = nil

    @State private var candidateToPreview: LyricsCandidate?
    @State private var manualLyricsSearchQuery = ""
    @State private var diagnosticExpanded = false
    @State private var manualSearchExpanded = false

    var body: some View {
        Group {
            if state.isShowingSearchPreview {
                searchPreviewContent
            } else if case .candidates(_, let candidates) = state.lyricsState {
                candidateContent(candidates)
            } else {
                statusContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $candidateToPreview) { candidate in
            if !state.isShowingSearchPreview {
                LyricsCandidatePreviewSheet(
                    candidate: candidate,
                    onAdopt: { try await state.adoptLyricsCandidate(candidate) },
                    onConfirmLocked: { try await state.confirmPendingManualLyricsAdoption() },
                    onCancelLocked: { state.cancelPendingManualLyricsAdoption() }
                )
            }
        }
        .onChange(of: state.isShowingSearchPreview) { _, showingPreview in
            if showingPreview { candidateToPreview = nil }
        }
    }

    // Preview feedback never builds a live operation or adoption sheet.
    private var searchPreviewContent: some View {
        ScrollView {
            VStack(spacing: compact ? 12 : 16) {
                Label("搜索预览 · 只读", systemImage: "eye")
                    .foregroundStyle(LyricsDesignTokens.accent)
                Text(state.displayedTrack.title)
                    .font(.headline)
                Text(stateTitle)
                    .font(.title3)
                Text(stateDetail)
                    .foregroundStyle(LyricsDesignTokens.mutedText)
                    .multilineTextAlignment(.center)
                if case .candidates(_, let candidates) = state.lyricsState {
                    ForEach(candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title)
                            Text("\(candidate.artist) · \(candidate.source.displayName)")
                                .font(.caption)
                                .foregroundStyle(LyricsDesignTokens.mutedText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("返回当前播放") { state.clearSearchPreview() }
                    .buttonStyle(.bordered)
            }
            .padding(compact ? 18 : LyricsDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("lyrics.search-preview.read-only.empty")
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: stateIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72)).frame(width: 24)
                VStack(alignment: .leading, spacing: 7) {
                    Text(stateTitle)
                        .font(.system(size: compact ? 17 : 20, weight: .semibold))
                        .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Text(conciseDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                primaryAction
                if offersRecovery {
                    Button("搜索其他版本") { manualSearchExpanded.toggle() }
                        .buttonStyle(.borderless).font(.system(size: 12))
                    Menu {
                        if state.canCreateManualLyrics {
                            ManualLyricsActionsView(state: state, compact: true, compactLabel: "导入或创建")
                        }
                        Button("确认这首是纯音乐…", systemImage: "music.note") {
                            state.markCurrentTrackAsInstrumental()
                        }
                        Button("本次不显示歌词", systemImage: "rectangle.slash") {
                            state.selectNoLyricsVersion()
                        }
                        Button("导入本地音频 · ASR 草稿", systemImage: "waveform") {
                            state.importLocalAudioForASR()
                        }
                    } label: { Image(systemName: "ellipsis").accessibilityLabel("更多歌词操作") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if manualSearchExpanded && offersRecovery { manualLyricsQueryEntry }
            if case .failed = state.lyricsState {
                DisclosureGroup("来源详情", isExpanded: $diagnosticExpanded) {
                    Text(stateDetail)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.76))
            }
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: compact ? 420 : 510, alignment: .leading)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .padding(.horizontal, compact ? 16 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.currentTrackIdentity) { _, _ in
            diagnosticExpanded = false; manualSearchExpanded = false
        }
    }

    private var offersRecovery: Bool {
        switch state.lyricsState {
        case .noLyrics, .noMatch, .failed: return true
        default: return false
        }
    }
    private var conciseDetail: String {
        guard case .failed(_, let failure) = state.lyricsState else { return stateDetail }
        switch failure {
        case .lyricsBodyUnavailable:
            return "找到了发行记录，但这项来源还没有可用正文。可继续播放并查找其他来源；这不表示歌曲是纯音乐。"
        case .serverError, .timedOut, .networkUnavailable, .rateLimited:
            return "部分歌词来源暂时不可用。可以继续听歌，稍后重试；失败请求不会被当作歌曲没有歌词。"
        default:
            return "当前结果还不足以安全显示正确歌词。查看来源详情或搜索其他版本；已保存的版本不会被删除。"
        }
    }
    @ViewBuilder
    private var primaryAction: some View {
        switch state.lyricsState {
        case .noLyrics, .noMatch, .failed:
            Button("重试查找") { state.retryLyrics() }
                .buttonStyle(.borderedProminent).tint(LyricsDesignTokens.accent)
        case .noSelection:
            if let onSearch { Button("查找歌词", action: onSearch).buttonStyle(.borderedProminent) }
        case .idle where state.isAutomaticSearchDisabledForDisplayedSession:
            if let onSearch { Button("手动搜索", action: onSearch).buttonStyle(.borderedProminent) }
        case .idle where state.providerStatus != .ready:
            Button("重试连接") { state.reconnectSpotify() }.buttonStyle(.borderedProminent)
        default: EmptyView()
        }
    }

    private var stateIcon: String {
        switch state.lyricsState {
        case .loading:
            return "magnifyingglass"
        case .noLyrics:
            return "text.quote"
        case .noSelection:
            return "rectangle.slash"
        case .noMatch:
            return "magnifyingglass"
        case .failed:
            return "exclamationmark.triangle"
        case .idle:
            return providerIcon
        case .loaded:
            return "text.quote"
        default:
            return "music.note"
        }
    }

    private var providerIcon: String {
        switch state.providerStatus {
        case .connecting:
            return "antenna.radiowaves.left.and.right"
        case .permissionDenied:
            return "lock.fill"
        case .notInstalled, .notRunning, .noTrack, .unavailable:
            return "music.note"
        case .mockPreview, .ready:
            return "music.note"
        }
    }

    private var manualLyricsQueryEntry: some View {
        HStack(spacing: 6) {
            TextField("标题或艺人搜索词", text: $manualLyricsSearchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: compact ? 170 : 220)
            Button("搜索") {
                let query = manualLyricsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return }
                state.retryLyrics(queryOverride: query)
            }
            .buttonStyle(.bordered)
            .disabled(manualLyricsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("手动修改歌词搜索词")
    }

    private var stateTitle: String {
        switch state.lyricsState {
        case .loading where state.isAutomaticSearchDisabledForDisplayedSession:
            return "正在加载已保存歌词"
        case .loading:
            return "正在搜索歌词"
        case .noLyrics:
            return "当前来源暂无正文"
        case .noMatch:
            return "暂未找到可靠版本"
        case .noSelection:
            return "暂不使用歌词"
        case .failed(_, let failure):
            return failure.userFacingTitle
        case .idle where state.isAutomaticSearchDisabledForDisplayedSession:
            return "切歌后自动搜索已关闭"
        case .idle:
            switch state.providerStatus {
            case .connecting:
                return "正在识别当前歌曲"
            case .permissionDenied:
                return "需要连接 Spotify"
            case .notInstalled:
                return "找不到 Spotify"
            case .notRunning:
                return "Spotify 尚未运行"
            case .noTrack, .ready:
                return "等待播放歌曲"
            case .unavailable:
                return "暂时无法读取当前歌曲"
            case .mockPreview:
                return "等待预览内容"
            }
        case .loaded:
            return "暂无歌词"
        default:
            return "歌词"
        }
    }

    private var stateDetail: String {
        switch state.lyricsState {
        case .loading where state.isAutomaticSearchDisabledForDisplayedSession:
            if let error = state.lyricsSession.persistenceStatusMessage {
                return "读取已保存歌词失败：\(error)"
            }
            return "切歌自动搜索已关闭；仍会恢复本地已保存版本。需要查找时可手动搜索。"
        case .loading:
            return "正在为当前歌曲查找可用歌词。"
        case .noLyrics:
            return "当前歌曲还没有可用的歌词正文。"
        case .noMatch:
            return "没有找到足够可靠的歌词版本，可以重新搜索或导入本地内容。"
        case .noSelection:
            return "本次播放不显示歌词；已有版本没有被删除。"
        case .failed(_, let failure):
            return friendlyFailureDetail(failure)
        case .idle where state.isAutomaticSearchDisabledForDisplayedSession:
            if let error = state.lyricsSession.persistenceStatusMessage {
                return "读取已保存歌词失败：\(error)"
            }
            return "已保存版本仍会自动加载；此设置只关闭切歌后自动搜索。可手动搜索当前歌曲。"
        case .idle:
            switch state.providerStatus {
            case .connecting:
                return "连接成功后会自动搜索歌词。"
            case .permissionDenied:
                return "请允许 Lyric Island 读取 Spotify Desktop 的当前播放。"
            case .notInstalled:
                return "安装 Spotify Desktop 后即可同步当前歌曲。"
            case .notRunning:
                return "打开 Spotify Desktop 后即可同步当前歌曲。"
            case .noTrack, .ready:
                return "开始播放歌曲后会自动搜索歌词。"
            case .unavailable(let message):
                return message.isEmpty ? "稍后重试连接 Spotify。" : "暂时无法读取当前歌曲，请稍后重试。"
            case .mockPreview:
                return "当前没有可用于预览的歌词内容。"
            }
        case .loaded:
            return "当前歌曲没有可显示的歌词行。"
        default:
            return ""
        }
    }

    private func friendlyFailureDetail(_ failure: LyricsFailure) -> String {
        failure.recoveryMessage
    }

    private func candidateContent(_ candidates: [LyricsCandidate]) -> some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: LyricsDesignTokens.Spacing.sm) {
                Spacer(minLength: compact ? 8 : 20)
                Text("核对歌词版本")
                    .font(.system(size: compact ? 20 : 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.primaryText)
                Text("这些结果仍有身份或编曲差异，未自动替你采用。选择一次会保存，后续可继续复用。")
                    .font(.system(size: compact ? 12 : 14, design: .rounded))
                    .foregroundStyle(brightCover ? Color.white.opacity(0.9) : LyricsDesignTokens.mutedText)
                    .shadow(color: .black.opacity(brightCover ? 0.85 : 0), radius: 3, y: 1)

                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }

                if state.isShowingSearchPreview {
                    Label("预览中不会更改当前播放歌曲歌词版本", systemImage: "eye")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(brightCover ? Color.white.opacity(0.9) : LyricsDesignTokens.mutedText)
                        .shadow(color: .black.opacity(brightCover ? 0.85 : 0), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                } else {
                    Button("不使用任何歌词版本") {
                        state.selectNoLyricsVersion()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(brightCover ? Color.white.opacity(0.9) : LyricsDesignTokens.mutedText)
                    .shadow(color: .black.opacity(brightCover ? 0.85 : 0), radius: 3, y: 1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }

                if state.canCreateManualLyrics {
                    ManualLyricsActionsView(
                        state: state,
                        compact: true,
                        compactLabel: "导入或创建"
                    )
                    .foregroundColor(brightCover ? Color.white.opacity(0.9) : nil)
                    .shadow(color: .black.opacity(brightCover ? 0.85 : 0), radius: 3, y: 1)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                Spacer(minLength: compact ? 8 : 20)
            }
            .padding(.horizontal, compact ? 18 : LyricsDesignTokens.Spacing.xl)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func candidateRow(_ candidate: LyricsCandidate) -> some View {
        Button {
            candidateToPreview = candidate
        } label: {
            HStack(spacing: LyricsDesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(candidate.title)
                            .font(.system(size: compact ? 13 : 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(LyricsDesignTokens.primaryText)
                            .lineLimit(1)
                    }
                    Text("\(candidate.artist) · \(candidate.album.isEmpty ? "未知专辑" : candidate.album)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(LyricsDesignTokens.mutedText)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(candidate.source.displayName)
                        Text(languageLabel(candidate.language))
                        Text(candidate.timelineLabel)
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText.opacity(0.9))
                    if let notice = candidate.arrangementNotice {
                        Text(notice)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if candidate.matchExplanation.contains(where: {
                        $0.hasPrefix("extraFeaturedArtist ")
                            || $0.hasPrefix("missingFeaturedArtist ")
                            || $0.hasPrefix("featuredNameUnverified ")
                    }) {
                        Text("合作歌手信息待确认")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(LyricsDesignTokens.accent)
                    Text("预览")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(LyricsDesignTokens.primaryText.opacity(0.78))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )

        }
        .buttonStyle(.plain)
        .accessibilityLabel("歌词候选：\(candidate.title)，\(candidate.artist)")
        .accessibilityHint("预览后选择此版本")
    }

    private func languageLabel(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "语言未知" }
        switch language.lowercased() {
        case "ja", "jp", "jpn", "japanese": return "日语"
        case "zh", "zh-hans", "zh-cn", "chi", "chinese": return "中文"
        case "en", "eng", "english": return "英语"
        case "ko", "kor", "korean": return "韩语"
        default: return language
        }
    }
}

private struct LyricsCandidatePreviewSheet: View {
    let candidate: LyricsCandidate
    let onAdopt: () async throws -> LyricsPersistenceSaveResult
    let onConfirmLocked: () async throws -> LyricsPersistenceSaveResult?
    let onCancelLocked: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var isLockConfirmationPresented = false
    @State private var conflictingLockedVersionIDs: [UUID] = []
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title)
                        .font(.title2.weight(.semibold))
                    Text("\(candidate.artist) · \(candidate.source.displayName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(candidate.isSynchronized ? "含时间轴" : "纯文本")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("候选预览")
                .font(.headline)
            DisclosureGroup("来源与匹配详情") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(candidate.source.displayName) · \(candidate.queryMethodLabel) · \(candidate.timelineLabel)")
                    Text("匹配评分 \(Int(candidate.displayedConfidence * 100))，仅供核对，不代表录音身份已确认。")
                    ForEach(Array(candidate.matchExplanation.enumerated()), id: \.offset) { _, explanation in
                        Text(explanation)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(candidate.lines.enumerated()), id: \.element.id) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(candidate.isSynchronized ? previewTimeLabel(line.timestamp) : "#\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.originalText.isEmpty ? "（空白原文）" : line.originalText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let translation = line.translationText, !translation.isEmpty {
                                    Text(translation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(minHeight: 300)

            HStack {
                Spacer()
                Button("取消") {
                    onCancelLocked()
                    dismiss()
                }
                .disabled(isSaving)
                Button(isSaving ? "正在保存…" : "采用此版本") {
                    performAdoption(confirmingLocks: false)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
            if let failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(width: 620, height: 600)
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            "歌词版本已锁定",
            isPresented: $isLockConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("仍采用此版本", role: .destructive) {
                performAdoption(confirmingLocks: true)
            }
            Button("取消", role: .cancel) {
                onCancelLocked()
                conflictingLockedVersionIDs = []
            }
        } message: {
            Text("当前歌曲有 \(conflictingLockedVersionIDs.count) 个锁定歌词版本。继续会将此候选设为当前，并保留原版本的锁定标记。")
        }
    }

    private func performAdoption(confirmingLocks: Bool) {
        guard !isSaving else { return }
        isSaving = true
        failureMessage = nil
        Task { @MainActor in
            do {
                let result: LyricsPersistenceSaveResult?
                if confirmingLocks {
                    result = try await onConfirmLocked()
                } else {
                    result = try await onAdopt()
                }
                guard let result else {
                    failureMessage = "候选已失效，请重新搜索后再采用。"
                    isSaving = false
                    return
                }
                switch result.disposition {
                case .inserted, .duplicate:
                    guard result.versionID != nil else {
                        failureMessage = "歌词没有返回持久版本身份，未显示采用成功。"
                        break
                    }
                    onCancelLocked()
                    dismiss()
                case .lockedConflict:
                    conflictingLockedVersionIDs = result.conflictingLockedVersionIDs
                    isLockConfirmationPresented = true
                case .skippedLocked:
                    failureMessage = "歌词仍受锁定保护，未采用。"
                case .rejected(let message):
                    failureMessage = message
                }
            } catch {
                failureMessage = "歌词未能保存：\(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func previewTimeLabel(_ timestamp: TimeInterval) -> String {
        let seconds = max(0, Int(timestamp.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
