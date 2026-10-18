import SwiftUI
import AppKit

/// Compact, in-place operations for the currently playing TrackIdentity.
/// Every command is forwarded to the existing PlaybackState/session methods;
/// this view owns no repository, search task, timer, or playback command.
struct CurrentSongOperationsView: View {
    @ObservedObject var state: PlaybackState
    var versionShortcutOnly = false
    var iconOnly = false
    var onVersionPickerPresentationChange: (Bool) -> Void = { _ in }
    var onOpenEditor: (() -> Void)? = nil
    @ObservedObject private var autoAlign = AutomaticAlignmentJobController.shared
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.openWindow) private var openWindow

    @State private var notice = ""
    @State private var showDeleteTranslationConfirmation = false
    @State private var showDeleteReadingConfirmation = false
    @State private var showAIReadingConfirmation = false
    @State private var pendingReadingDeletionID: UUID?
    @State private var showCandidatePreview = false
    @State private var showReadingEditor = false
    @State private var showLyricsVersionPicker = false
    @State private var lyricsVersions: [StoredEditableLyricsVersion] = []
    @State private var isLoadingLyricsVersions = false
    @State private var lyricsVersionMessage = ""
    @State private var adoptingLyricsVersionID: UUID?

    private var snapshot: CurrentSongOperationSnapshot {
        CurrentSongOperationSnapshot(
            title: state.currentTrack.title,
            artist: state.currentTrack.artist,
            lyricsState: CurrentSongLyricsState(loadState: state.liveLyricsState),
            lyricsSource: state.liveLyricsSource,
            lyricsVersionID: state.liveLyricsVersionID,
            isSynchronized: state.liveLyricsAreSynchronized,
            isLyricsNoSelection: state.isLyricsSelectionEmpty,
            hasTranslationSelection: !state.isTranslationSelectionEmpty,
            translationVersionCount: state.translationVersions.count
        )
    }

    var body: some View {
        Group {
            if versionShortcutOnly {
                Button { openLyricsVersionPicker() } label: {
                    if iconOnly {
                        Image(systemName: "text.badge.checkmark")
                            .foregroundStyle(.white.opacity(0.92))
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                            .accessibilityLabel("歌词版本")
                    } else {
                        Label("歌词版本", systemImage: "text.badge.checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                            .help("歌词版本")
                    }
                }
                .contextMenu {
                    Button("复制整首原文", systemImage: "doc.on.doc") {
                        LyricsCopyText.copy(LyricsCopyText.format(state.liveLyrics))
                    }
                    .disabled(state.liveLyrics.isEmpty)
                }
                .accessibilityIdentifier("lyrics.versionShortcut")
            } else {
                operationsPanel
            }
        }
        .onChange(of: state.currentTrackIdentity) { _, _ in
            showLyricsVersionPicker = false
            showAIReadingConfirmation = false
            adoptingLyricsVersionID = nil
        }
        .onChange(of: state.isShowingSearchPreview) { _, previewing in
            if previewing { showLyricsVersionPicker = false }
        }
        .onChange(of: state.liveLyricsVersionID) { _, _ in
            showAIReadingConfirmation = false
        }
        .onChange(of: showLyricsVersionPicker) { _, presented in
            onVersionPickerPresentationChange(presented)
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "删除当前翻译版本？",
            isPresented: $showDeleteTranslationConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除翻译", role: .destructive) { state.deleteSelectedTranslation() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会删除原文、读音或歌词版本。")
        }
        .confirmationDialog(
            "删除当前读音版本？",
            isPresented: $showDeleteReadingConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除读音版本", role: .destructive) {
                if let versionID = pendingReadingDeletionID {
                    state.deleteReading(versionID: versionID)
                }
                pendingReadingDeletionID = nil
            }
            Button("取消", role: .cancel) {
                pendingReadingDeletionID = nil
            }
        } message: {
            Text("不会删除原文、歌词版本、翻译或时间轴。锁定版本仍不可删除。")
        }
        .confirmationDialog(
            "生成 AI 辅助读音候选？",
            isPresented: $showAIReadingConfirmation,
            titleVisibility: .visible
        ) {
            Button("生成候选（可能收费）") {
                guard aiReadingUnavailableReason == nil else { return }
                state.requestAIReadingCandidate()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("使用当前兼容 API 的模型「\(settings.aiTranslationConfiguration.model)」，可能产生费用；生成结果须手动采用，不会自动重试。")
        }
        .sheet(isPresented: $showCandidatePreview) {
            if let candidate = state.translationSessionPendingCandidate {
                TranslationCandidatePreviewView(
                    candidate: candidate,
                    evidence: TranslationCandidatePreviewEvidence.build(
                        sourceLines: state.liveLyrics,
                        translations: candidate.lines.map {
                            IndexedTranslationPreview(lineIndex: $0.lineIndex, text: $0.translatedText)
                        },
                        isSynchronized: state.liveLyricsAreSynchronized
                    ),
                    onAdopt: {
                        state.adoptTranslation(versionID: candidate.record.id)
                        showCandidatePreview = false
                    }
                )
            }
        }
        .sheet(isPresented: $showReadingEditor) {
            if let version = state.selectedReadingVersion {
                ReadingVersionEditorView(state: state, version: version)
            }
        }
        .sheet(isPresented: $showLyricsVersionPicker) {
            LyricsVersionPickerView(
                lines: state.liveLyrics,
                originalLines: state.originalLiveLyrics,
                isSynchronized: state.liveLyricsAreSynchronized,
                title: state.currentTrack.title,
                trackStableKey: state.currentTrackIdentity?.stableKey,
                artistDisplay: state.currentTrack.artist,
                language: state.liveLyricsLanguage,
                userEntries: settings.readingUserDictionary.load(),
                versions: lyricsVersions,
                currentVersionID: state.liveLyricsVersionID,
                isLoading: isLoadingLyricsVersions,
                message: lyricsVersionMessage,
                adoptingVersionID: adoptingLyricsVersionID,
                onAdopt: adoptLyricsVersion,
                candidates: state.liveLyricsCandidates,
                isSearching: state.isSearchingAdditionalLyricsVersions,
                searchMessage: state.additionalLyricsVersionsMessage,
                onAdoptCandidate: { candidate in
                    guard !state.isShowingSearchPreview else {
                        return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("请先返回当前播放歌曲再采用"))
                    }
                    return try await state.adoptLyricsCandidate(candidate)
                },
                onConfirmLocked: { try await state.confirmPendingManualLyricsAdoption() },
                onCancelLocked: { state.cancelPendingManualLyricsAdoption() },
                onCandidateAdopted: loadLyricsVersions,
                canEdit: state.canOpenLyricsEditor,
                onEdit: {
                    showLyricsVersionPicker = false
                    openEditor()
                },
                onSearch: {
                    state.searchAdditionalLyricsVersions()
                }
            )
            .modifier(SystemAppearanceSheetModifier())
        }
    }

    private var operationsPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                lyricsSection
                versionStatusSection
                Divider()
                languageSection
                Divider()
                readingSection
                if !state.liveLyrics.isEmpty {
                    Divider()
                    translationSection
                }
                if showsAutomaticAlignmentSection {
                    Divider()
                    automaticAlignmentSection
                }
                if hasAlignmentAction {
                    Divider()
                    alignmentSection
                }
                if !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .frame(width: 360, alignment: .leading)
        .frame(maxHeight: 560, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前歌曲")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(snapshot.title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(snapshot.artist)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Read-only status only — settings owns the single mode control.
            HStack(spacing: 6) {
                Text("歌词来源：\(settings.lyricsSourceMode.shortTitle)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                if settings.lyricsSourceMode.isExperimental {
                    Text("实验")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }
            .accessibilityIdentifier("currentSong.lyricsSourceMode.readonly")
            .accessibilityElement(children: .combine)
        }
    }

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("歌词版本", systemImage: "text.quote")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Spacer()
                Text(snapshot.lyricsStatusLabel)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(snapshot.isLyricsNoSelection ? .orange : .secondary)
            }
            if let source = state.liveLyricsSource {
                Text("来源：\(source.displayName)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                primaryLyricsButton
                Menu {
                    Button("重新搜索歌词", systemImage: "arrow.clockwise") {
                        state.retryLyrics()
                    }
                    if state.canCreateManualLyrics {
                        Divider()
                        importCreateMenu
                    }
                    Divider()
                    Button("本次播放不使用", systemImage: "minus.circle") {
                        state.selectNoLyricsVersion()
                    }
                    .disabled(state.isLyricsSelectionEmpty)
                    Divider()
                    Button("在 YouTube 查找 MV", systemImage: "play.rectangle") {
                        guard let searchURLSnapshot = youtubeMVSearchURL else { return }
                        openYouTubeMVSearch(searchURLSnapshot)
                    }
                    .disabled(youtubeMVSearchURL == nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .help("歌词版本操作")
            }
            if state.canOpenLyricsEditor {
                HStack(spacing: 12) {
                    Button("选择歌词版本", systemImage: "checklist") {
                        openLyricsVersionPicker()
                    }
                    Button("查看版本历史", systemImage: "clock.arrow.circlepath") {
                        openEditor()
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The current-song popover keeps the status vocabulary visible without
    /// pretending that every status is present on the current record.
    private var versionStatusSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("版本状态", systemImage: "tag")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Spacer()
                Text(snapshot.isLyricsNoSelection ? "本次播放不使用" : "当前使用")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(snapshot.isLyricsNoSelection ? .orange : .secondary)
            }
            HStack(spacing: 6) {
                statusChip(snapshot.isLyricsNoSelection ? "本次播放不使用" : "当前使用")
                if let source = state.liveLyricsSource {
                    if source == .neteaseExperimental || source == .qqExperimental {
                        statusChip("实验")
                    }
                    if source == .manualImport || source == .manualCreate || source == .manualEdit || source == .automaticAlignment {
                        statusChip("非默认")
                    }
                }
                statusChip(state.liveLyricsAreSynchronized ? "已排轴" : "未排轴")
            }
            Menu("状态说明", systemImage: "info.circle") {
                Text("当前使用：本次 Session 正在显示的版本")
                Text("推荐：Provider 或本地仓库建议的版本")
                Text("非默认：用户导入、创建、编辑或排轴版本")
                Text("已归档：保留记录但不再作为默认候选")
                Text("实验：实验 Provider 或实验呈现")
                Text("锁定：不会被网络或 AI 自动覆盖")
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }

    private func statusChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }

    @ViewBuilder
    private var primaryLyricsButton: some View {
        switch snapshot.primaryLyricsAction {
        case .edit:
            Button("编辑当前版本", systemImage: "pencil") { openEditor() }
                .buttonStyle(.borderedProminent)
        case .chooseVersion:
            Button("选择歌词版本", systemImage: "checklist") { openLyricsVersionPicker() }
                .buttonStyle(.bordered)
        case .importOrCreate:
            Menu("导入或创建", systemImage: "square.and.arrow.down") {
                importCreateMenu
            }
            .menuStyle(.borderedButton)
        case .none:
            Button("重新搜索歌词", systemImage: "magnifyingglass") { state.retryLyrics() }
                .buttonStyle(.bordered)
                .disabled(!state.hasLiveTrack)
        }
    }

    @ViewBuilder
    private var importCreateMenu: some View {
        Button("粘贴歌词", systemImage: "doc.on.clipboard") {
            if state.prepareManualLyricsFromClipboard() { showEditorWindow() }
        }
        Button("导入 TXT", systemImage: "doc.text") {
            if state.prepareManualLyricsFromTXT() { showEditorWindow() }
        }
        Button("导入 LRC", systemImage: "clock") {
            if state.prepareManualLyricsFromLRC() { showEditorWindow() }
        }
        Button("创建空白歌词", systemImage: "plus.square") {
            if state.prepareBlankLyricsEditor() { showEditorWindow() }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("显示层")
                .font(.system(size: 12, weight: .medium, design: .rounded))
            Toggle("显示翻译", isOn: displayBinding(\.showTranslation))
            Toggle("显示假名", isOn: kanaBinding)
            Toggle("显示罗马音", isOn: displayBinding(\.showRomaji))
            if settings.displayPreferences.showKana {
                Picker("假名模式", selection: displayBinding(\.kanaDisplayMode)) {
                    Text("汉字上方注音").tag(KanaDisplayMode.inlineRuby)
                    Text("独立假名行").tag(KanaDisplayMode.independentLine)
                    Text("假名替换").tag(KanaDisplayMode.kanaReplacement)
                }
                .pickerStyle(.menu)
            }
            Text("隐藏翻译只改变显示层；无翻译版本会改变当前选择。")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 翻译为实验功能；采用前请预览并核对译文。")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
            HStack {
                Label("翻译版本", systemImage: "character.book.closed")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Spacer()
                Text(snapshot.translationStatusLabel)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(state.isTranslationSelectionEmpty ? .orange : .secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Picker("引擎", selection: Binding(
                    get: { TranslationEngineCatalog.topLevelID(for: settings.aiTranslationConfiguration.engineID) },
                    set: { settings.selectTranslationProvider($0) }
                )) {
                    ForEach(TranslationEngineCatalog.selectable, id: \.stableID) { engine in
                        Text(engine.displayName).tag(engine.stableID)
                    }
                }
                Picker("提示词", selection: configurationStringBinding(\.promptPresetID)) {
                    ForEach(TranslationPromptPresetCatalog.all, id: \.id) { preset in
                        Text(preset.displayName).tag(preset.id.rawValue)
                    }
                }
                Text("模型：\(settings.aiTranslationConfiguration.model.isEmpty ? "手动输入" : settings.aiTranslationConfiguration.model)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                if !state.translationProgressMessage.isEmpty {
                    Label(state.translationProgressMessage, systemImage: translationStatusIcon)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(translationStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let candidate = state.translationSessionPendingCandidate {
                HStack(spacing: 8) {
                    Label("新候选待采用", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                    Spacer()
                    Button("预览") { showCandidatePreview = true }
                    Button("采用") { state.adoptTranslation(versionID: candidate.record.id) }
                }
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            Menu {
                Button("无翻译版本") { state.selectNoTranslationVersion() }
                    .disabled(state.isTranslationSelectionEmpty)
                if !state.translationVersions.isEmpty { Divider() }
                ForEach(state.translationVersions, id: \.record.id) { version in
                    Button {
                        state.selectTranslation(versionID: version.record.id)
                    } label: {
                        Text(versionTitle(version))
                    }
                }
                Divider()
                Button("翻译整首歌词") { state.translateCurrentLyrics() }
                Button("重新翻译") { state.retranslateCurrentLyrics() }
                if case .loading = state.translationState {
                    Button("取消翻译") { state.cancelTranslation() }
                }
                Button("恢复推荐") { state.restoreRecommendedTranslation() }
                if let candidate = state.translationSessionPendingCandidate {
                    Button("预览候选") { showCandidatePreview = true }
                    Button("采用候选") { state.adoptTranslation(versionID: candidate.record.id) }
                    Button("归档候选") { state.archiveTranslation(versionID: candidate.record.id) }
                }
                if state.selectedTranslation?.record.isLocked == false {
                    Divider()
                    Button("锁定当前翻译") { state.lockSelectedTranslation() }
                    Button("删除当前翻译", role: .destructive) {
                        showDeleteTranslationConfirmation = true
                    }
                    Button("归档当前翻译") {
                        if let id = state.selectedTranslation?.record.id { state.archiveTranslation(versionID: id) }
                    }
                }
            } label: {
                Label("选择翻译版本", systemImage: "chevron.up.chevron.down")
            }
            .menuStyle(.borderedButton)
        }
    }

    private var readingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("读音版本", systemImage: "character.book.closed")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Spacer()
                if state.selectedReadingVersion?.record.isLocked == true {
                    Text("锁定")
                        .foregroundStyle(.green)
                } else if state.selectedReadingVersion != nil {
                    Text("当前使用")
                        .foregroundStyle(.secondary)
                } else {
                    Text("无")
                        .foregroundStyle(.orange)
                }
            }
            if let version = state.selectedReadingVersion {
                Text(readingVersionTitle(version))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Menu("选择版本", systemImage: "chevron.up.chevron.down") {
                        Button("无读音版本") { state.selectNoReadingVersion() }
                        Divider()
                        ForEach(state.readingVersions, id: \.record.id) { candidate in
                            Button(readingVersionTitle(candidate)) {
                                state.selectReadingVersion(versionID: candidate.record.id)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    Button("编辑") { showReadingEditor = true }
                        .buttonStyle(.borderless)
                    if !version.record.isLocked {
                        Button("锁定") { state.lockSelectedReading() }
                            .buttonStyle(.borderless)
                    }
                    Menu {
                        Button("无读音版本") { state.selectNoReadingVersion() }
                            .disabled(state.selectedReadingVersion == nil)
                        Button("恢复推荐") { state.restoreRecommendedReading() }
                        Divider()
                        Button("重新生成假名") { state.generateCurrentReading(representationID: .kana) }
                            .disabled(state.isReadingGenerating)
                        Button("重新生成罗马音") { state.generateCurrentReading(representationID: .romaji) }
                            .disabled(state.isReadingGenerating)
                        Button("生成拼音") { state.generateCurrentReading(representationID: .pinyinToneMarks) }
                            .disabled(state.isReadingGenerating)
                        if !version.record.isLocked {
                            Divider()
                            Button("归档") { state.archiveReading(versionID: version.record.id) }
                            Button("删除", role: .destructive) {
                                pendingReadingDeletionID = version.record.id
                                showDeleteReadingConfirmation = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                }
            } else {
                HStack(spacing: 8) {
                    Button("选择无") { state.selectNoReadingVersion() }
                        .buttonStyle(.borderless)
                    if !state.readingVersions.isEmpty {
                        Menu("选择版本") {
                            ForEach(state.readingVersions, id: \.record.id) { candidate in
                                Button(readingVersionTitle(candidate)) {
                                    state.selectReadingVersion(versionID: candidate.record.id)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    Button("生成假名") { state.generateCurrentReading(representationID: .kana) }
                        .buttonStyle(.borderless)
                        .disabled(state.isReadingGenerating)
                    Button("生成拼音") { state.generateCurrentReading(representationID: .pinyinToneMarks) }
                        .buttonStyle(.borderless)
                        .disabled(state.isReadingGenerating)
                }
            }
            if state.isReadingGenerating {
                ProgressView("生成读音…")
                    .controlSize(.small)
            } else if !state.readingMessage.isEmpty {
                Text(state.readingMessage)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Button("AI 辅助读音候选…", systemImage: "sparkles") {
                showAIReadingConfirmation = true
            }
            .buttonStyle(.borderless)
            .disabled(aiReadingUnavailableReason != nil)
            if let reason = aiReadingUnavailableReason {
                Text(reason)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("仅处理日语不确定读音 · 使用所选 AI 引擎 · 确认后生成")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("读音版本独立保存；不修改原文、时间轴或翻译。")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var aiReadingUnavailableReason: String? {
        guard settings.readingPreferences.aiAssistedCandidate else {
            return "在右上角 AI 面板开启读音优化后，可在此明确生成。"
        }
        guard AIReadingCandidateService.supports(engineID: settings.aiTranslationConfiguration.engineID) else {
            return "请选择兼容 API、GPT / ChatGPT 或 Gemini CLI 来优化读音。"
        }
        guard settings.aiTranslationConfiguration.isConfigured else {
            return "请先在 AI 设置中配置所选引擎与模型。"
        }
        guard state.hasLiveTrack, !state.isMockPreviewMode, !state.isShowingSearchPreview,
              state.liveLyricsDocumentMatchesCurrentTrack, state.readingSession.hasSource else {
            return "加载当前播放歌曲的已保存歌词后可生成，预览歌词不调用 AI。"
        }
        guard (ReadingEngineID(rawValue: settings.readingPreferences.japaneseEngineID) ?? .japaneseContextual) == .japaneseContextual else {
            return "AI 候选需要本地上下文读音引擎。"
        }
        guard LyricsLanguageGate.allowsJapaneseReadings(
            language: state.liveLyricsLanguage,
            text: state.liveLyrics.map(\.originalText).joined(separator: "\n")
        ) else {
            return "AI 候选仅用于日语读音。请先确认歌词语言，或使用本地生成与人工编辑。"
        }
        if state.isReadingGenerating { return "读音正在生成，请等待本次完成。" }
        return nil
    }

    /// Product zero-operation status — visible when switch on or a job is active.
    private var showsAutomaticAlignmentSection: Bool {
        if settings.automaticAlignmentEnabled { return true }
        switch autoAlign.state {
        case .idle, .canceled:
            return false
        default:
            return !autoAlign.statusMessage.isEmpty
        }
    }

    private var hasAlignmentAction: Bool {
        switch state.liveLyricsState {
        case .alignmentQueued, .alignmentRunning, .alignmentPreview:
            return true
        default:
            break
        }
#if DEBUG
        if state.showsListeningAssistControls { return true }
#endif
        return false
    }

    @ViewBuilder
    private var automaticAlignmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("自动时间轴", systemImage: "timeline.selection")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Spacer()
                Text(autoAlignStatusLabel)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(autoAlignStatusColor)
                    .accessibilityIdentifier("autoAlign.status")
            }
            if let userFacingStatus = autoAlign.userFacingStatus {
                Text(userFacingStatus.recoveryHint)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !autoAlign.statusMessage.isEmpty {
                Text(autoAlign.statusMessage)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if settings.automaticAlignmentEnabled {
                Text("播放未排轴歌曲时会在后台尝试生成时间轴。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if autoAlignJobIsActive {
                    Button("停止本次") {
                        autoAlign.cancelCurrentJob(userInitiated: true)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("autoAlign.stop")
                }
                if settings.automaticAlignmentEnabled,
                   !state.liveLyricsAreSynchronized,
                   state.hasLiveTrack {
                    Button("重新尝试") {
                        autoAlign.retry()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("autoAlign.retry")
                }
#if DEBUG
                if state.showsListeningAssistControls || state.canStartListeningAssist {
                    Button("打开排轴工作台") {
                        state.presentListeningAssistExplanation()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("autoAlign.openWorkbench")
                }
#endif
            }
        }
    }

    private var autoAlignJobIsActive: Bool {
        switch autoAlign.state {
        case .capturing, .paused, .aligning, .evaluating, .waitingForPlayback, .accumulating, .deferred:
            return true
        default:
            return false
        }
    }

    private var autoAlignStatusLabel: String {
        if let userFacingStatus = autoAlign.userFacingStatus {
            return userFacingStatus.title
        }
        switch autoAlign.state {
        case .idle: return settings.automaticAlignmentEnabled ? "就绪" : "关闭"
        case .waitingForPlayback: return "等待播放"
        case .capturing, .aligning, .evaluating: return "正在生成时间轴"
        case .paused: return "已暂停"
        case .accumulating: return "已保存部分进度"
        case .completed: return "已完成"
        case .failed: return "本次无法可靠完成"
        case .canceled: return "已停止"
        case .deferred:
            if autoAlign.statusMessage.contains("引擎") {
                return "引擎尚未准备好"
            }
            return "等待继续播放"
        }
    }

    private var autoAlignStatusColor: Color {
        switch autoAlign.state {
        case .completed: return .green
        case .failed, .canceled: return .orange
        case .capturing, .aligning, .evaluating: return .primary
        default: return .secondary
        }
    }

    private func readingVersionTitle(_ version: StoredReadingVersion) -> String {
        var labels: [String] = []
        if version.record.isLocked { labels.append("锁定") }
        if state.selectedReadingVersion?.record.id == version.record.id { labels.append("当前") }
        if version.record.isArchived { labels.append("已归档") }
        if version.record.isManuallyEdited { labels.append("人工") }
        if version.record.warningMetadata.contains(.aiCandidateOnly) { labels.append("AI 候选") }
        let suffix = labels.isEmpty ? "" : " · " + labels.joined(separator: "/")
        let representation = ReadingRepresentationID(rawValue: version.record.representationID)?.displayName ?? "读音"
        return "\(representation)\(suffix) · \(version.record.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder
    private var alignmentSection: some View {
        switch state.liveLyricsState {
        case .alignmentQueued:
            VStack(alignment: .leading, spacing: 8) {
                Text("实验排轴：选择本地音频可独立于播放来源生成预览，确认后保存。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack {
                    Label("待排轴", systemImage: "waveform")
                    Spacer()
                    Button("选择本地音频") { state.alignCurrentLyricsWithLocalAudio() }
                }
#if DEBUG
                listeningAssistControls
#endif
            }
        case .alignmentRunning:
            HStack {
                Label("正在排轴", systemImage: "waveform")
                Spacer()
                Button("取消") { state.cancelAlignmentPreview() }
            }
        case .alignmentPreview:
            HStack {
                Label("排轴预览", systemImage: "waveform.path.ecg")
                Spacer()
                Button("确认") { state.confirmAlignmentPreview(saveLocal: true) }
                Button("放弃") { state.cancelAlignmentPreview() }
            }
        default:
#if DEBUG
            if state.showsListeningAssistControls {
                VStack(alignment: .leading, spacing: 8) {
                    Label("边听边排轴", systemImage: "ear")
                    listeningAssistControls
                }
            } else {
                EmptyView()
            }
#else
            EmptyView()
#endif
        }
    }

#if DEBUG
    /// Product-facing Assist controls (no S1/S2/S3A / DP / confidence jargon).
    @ViewBuilder
    private var listeningAssistControls: some View {
        switch state.assistPhase {
        case .idle, .cancelled:
            if state.canStartListeningAssist {
                Button("边听边排轴") {
                    state.presentListeningAssistExplanation()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("assist.listening.start")
            }
        case .explaining:
            Text(state.assistStatusMessage.isEmpty
                 ? "请在说明中选择开始或取消"
                 : state.assistStatusMessage)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("打开说明") {
                    state.isAssistExplainSheetPresented = true
                }
                .buttonStyle(.bordered)
                Button("取消") {
                    state.cancelListeningAssist()
                }
                .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("assist.listening.explaining")
        case .capturing, .merging:
            Text(state.assistStatusMessage.isEmpty
                 ? "正在分析当前歌曲…"
                 : state.assistStatusMessage)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("取消边听边排") {
                state.cancelListeningAssist()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("assist.listening.cancel")
        case .ready:
            Text(state.assistStatusMessage.isEmpty
                 ? "已生成时间建议（尚未保存）"
                 : state.assistStatusMessage)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("打开编辑草稿") {
                    state.openListeningAssistEditorWithDraft()
                    openEditor()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("assist.listening.openEditor")
                if state.canStartListeningAssist {
                    Button("重新开始") {
                        state.presentListeningAssistExplanation()
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .failed:
            Text(state.assistStatusMessage.isEmpty
                 ? "未能完成边听边排轴"
                 : state.assistStatusMessage)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if state.canStartListeningAssist {
                Button("重试边听边排轴") {
                    state.presentListeningAssistExplanation()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("assist.listening.retry")
            }
        }
    }
#endif

    private func showEditorWindow() {
        if let onOpenEditor { onOpenEditor() }
        else { openWindow(id: "lyrics-editor") }
    }

    private func openEditor() {
        state.prepareLyricsEditor()
        showEditorWindow()
    }

    private func openLyricsVersionPicker() {
        lyricsVersions = []
        showLyricsVersionPicker = true
        loadLyricsVersions()
    }

    private func loadLyricsVersions() {
        lyricsVersionMessage = ""
        isLoadingLyricsVersions = true
        let identity = state.currentTrackIdentity
        Task { @MainActor in
            do {
                let versions = try await state.loadCurrentLyricsVersions()
                guard state.currentTrackIdentity == identity else { return }
                lyricsVersions = versions
                if versions.isEmpty {
                    lyricsVersionMessage = "没有已保存的歌词版本"
                }
            } catch {
                guard state.currentTrackIdentity == identity else { return }
                lyricsVersionMessage = "版本读取失败：\(error.localizedDescription)"
            }
            isLoadingLyricsVersions = false
        }
    }

    private func adoptLyricsVersion(versionID: UUID) {
        guard adoptingLyricsVersionID == nil else { return }
        adoptingLyricsVersionID = versionID
        lyricsVersionMessage = "正在采用歌词版本…"

        let identity = state.currentTrackIdentity
        Task { @MainActor in
            do {
                let adopted = try await state.adoptCurrentLyricsVersion(versionID: versionID)
                guard state.currentTrackIdentity == identity else { return }
                if adopted {
                    lyricsVersions = try await state.loadCurrentLyricsVersions()
                    guard state.currentTrackIdentity == identity else { return }
                    lyricsVersionMessage = "已采用所选歌词版本"
                } else {
                    lyricsVersionMessage = "当前歌曲已变化，版本未采用"
                }
            } catch {
                guard state.currentTrackIdentity == identity else { return }
                lyricsVersionMessage = "版本采用失败：\(error.localizedDescription)"
            }
            adoptingLyricsVersionID = nil
        }
    }

    private func versionTitle(_ version: StoredTranslationVersion) -> String {
        let model = version.record.translationSourceTitle
        if version.record.isDraft { return "候选 · \(model)" }
        if version.record.isArchived { return "已归档 · \(model)" }
        return version.record.isLocked ? "🔒 \(model)" : model
    }

    private var translationStatusIcon: String {
        if case .failed = state.translationState { return "exclamationmark.triangle" }
        if case .candidateReady = state.translationState { return "checkmark.circle" }
        return "arrow.triangle.2.circlepath"
    }

    private var translationStatusColor: Color {
        if case .failed = state.translationState { return .orange }
        if case .candidateReady = state.translationState { return .green }
        return .secondary
    }

    private func configurationStringBinding(_ keyPath: WritableKeyPath<AITranslationConfiguration, String>) -> Binding<String> {
        Binding(
            get: { settings.aiTranslationConfiguration[keyPath: keyPath] },
            set: { value in
                var next = settings.aiTranslationConfiguration
                next[keyPath: keyPath] = value
                settings.aiTranslationConfiguration = next
            }
        )
    }

    private func displayBinding<Value>(_ keyPath: WritableKeyPath<DisplayPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { settings.displayPreferences[keyPath: keyPath] },
            set: { value in
                var next = settings.displayPreferences
                next[keyPath: keyPath] = value
                settings.displayPreferences = next
            }
        )
    }

    private var kanaBinding: Binding<Bool> {
        Binding(
            get: { settings.displayPreferences.showKana },
            set: { value in
                var next = settings.displayPreferences
                next.showKana = value
                settings.displayPreferences = next
            }
        )
    }

    private var youtubeMVSearchURL: URL? {
        guard state.liveTrackIdentity != nil else { return nil }

        let artist = state.currentTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = state.currentTrack.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/results"
        components.queryItems = [
            URLQueryItem(
                name: "search_query",
                value: "\(artist) \(title) official music video"
            )
        ]
        return components.url
    }

    private func openYouTubeMVSearch(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

private struct TranslationCandidatePreviewView: View {
    let candidate: StoredTranslationVersion
    let evidence: [TranslationCandidatePreviewLineEvidence]
    let onAdopt: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("翻译候选预览").font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack(spacing: 8) {
                Label(candidate.record.translationSourceTitle, systemImage: "character.book.closed")
                Text("·")
                Text(candidate.record.targetLanguage)
                Text("·")
                Text(evidence.first?.hasTiming == true ? "保留时间轴" : "纯文本行序")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("逐行对照原文与候选译文；确认前不会替换当前翻译。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(evidence, id: \.lineIndex) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(previewTimeLabel(line))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.originalText.isEmpty ? "（空白原文）" : line.originalText)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary)
                                Text(line.translatedText.isEmpty ? "（空白译文）" : line.translatedText)
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("采用此翻译", action: onAdopt)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 620, height: 620)
    }

    private func previewTimeLabel(_ line: TranslationCandidatePreviewLineEvidence) -> String {
        guard let timestamp = line.timestamp else { return "#\(line.lineIndex + 1)" }
        let seconds = max(0, Int(timestamp.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// A sheet can follow macOS even when the listening canvas is always dark.
private struct SystemAppearanceSheetModifier: ViewModifier {
    @State private var scheme = Self.colorScheme(for: NSApp.effectiveAppearance)

    static func colorScheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    func body(content: Content) -> some View {
        content
            // Reset styles inherited from the dark listening toolbar as well
            // as the scheme; hierarchical secondary text otherwise stays white.
            .foregroundStyle(Color.primary)
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
            .presentationBackground(scheme == .dark
                ? Color(red: 0.13, green: 0.14, blue: 0.15)
                : Color(red: 0.94, green: 0.95, blue: 0.96))
            .onReceive(NSApp.publisher(for: \.effectiveAppearance).receive(on: RunLoop.main)) { appearance in
                let next = Self.colorScheme(for: appearance)
                if scheme != next { scheme = next }
            }
    }
}

private struct LyricsVersionPickerView: View {
    let lines: [LyricLine]
    let originalLines: [LyricLine]
    let isSynchronized: Bool
    let title: String
    let trackStableKey: String?
    let artistDisplay: String?
    let language: String?
    let userEntries: [ReadingDictionaryEntry]
    let versions: [StoredEditableLyricsVersion]
    let currentVersionID: UUID?
    let isLoading: Bool
    let message: String
    let adoptingVersionID: UUID?
    let onAdopt: (UUID) -> Void
    let candidates: [LyricsCandidate]
    let isSearching: Bool
    let searchMessage: String
    let onAdoptCandidate: (LyricsCandidate) async throws -> LyricsPersistenceSaveResult
    let onConfirmLocked: () async throws -> LyricsPersistenceSaveResult?
    let onCancelLocked: () -> Void
    let onCandidateAdopted: () -> Void
    let canEdit: Bool
    let onEdit: () -> Void
    let onSearch: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCopy = false
    @State private var selectedID: String?
    @State private var showSourceTranslation = false
    @State private var isSavingCandidate = false
    @State private var isLockConfirmationPresented = false
    @State private var conflictingLockedVersionIDs: [UUID] = []
    @State private var failureMessage: String?

    private var selectedVersion: StoredEditableLyricsVersion? {
        versions.first { selectedID == "saved:\($0.record.id)" }
    }
    private var selectedCandidate: LyricsCandidate? {
        candidates.first { selectedID == "candidate:\($0.id)" }
    }
    private var isBusy: Bool { isSavingCandidate || adoptingVersionID != nil }
    private var previewLines: [LyricLine]? { selectedVersion?.document.lines ?? selectedCandidate?.lines }
    private var previewSynchronized: Bool { selectedVersion?.document.isSynchronized ?? selectedCandidate?.isSynchronized ?? false }
    private var previewSource: String {
        if let version = selectedVersion { return DatabaseSourceIdentifier.displayName(for: version.record.source) }
        return selectedCandidate?.source.displayName ?? "所选版本"
    }
    private var previewTranslationLineCount: Int {
        previewLines?.filter { hasText($0.translationText) }.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("歌词版本").font(.title3.weight(.semibold))
                    Text([title, artistDisplay].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isBusy)
            }
            Text("选择版本可预览对比，点击采用后才会切换。原版本会保留。")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已保存 · \(versions.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if isLoading { ProgressView("正在读取…").controlSize(.small) }
                        else if versions.isEmpty { Text("没有已保存版本").font(.caption).foregroundStyle(.secondary) }
                        ForEach(versions, id: \.record.id) { version in savedRow(version) }
                        Divider().padding(.vertical, 5)
                        HStack {
                            Text("搜索候选 · \(candidates.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if isSearching { ProgressView().controlSize(.small) }
                        }
                        ForEach(candidates) { candidate in candidateRow(candidate) }
                        if !searchMessage.isEmpty {
                            Text(searchMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else if candidates.isEmpty {
                            Text("点击“查找更多”获取候选版本。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.trailing, 3)
                }
                .frame(width: 240)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let previewLines {
                        HStack {
                            if previewTranslationLineCount > 0 {
                                Toggle("显示词源译文", isOn: $showSourceTranslation)
                                    .toggleStyle(.checkbox)
                                Text("词源译文 \(previewTranslationLineCount)/\(previewLines.count) 行")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Label("此版本没有词源译文", systemImage: "text.bubble")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        HStack(alignment: .top, spacing: 12) {
                            lyricColumn("当前使用", lines: originalLines, synchronized: isSynchronized, showTranslation: false)
                            Divider()
                            lyricColumn(previewSource, lines: previewLines, synchronized: previewSynchronized,
                                        showTranslation: showSourceTranslation)
                        }
                        if let candidate = selectedCandidate {
                            Text("\(candidate.title) · \(candidate.artist)").font(.caption).foregroundStyle(.secondary)
                            if let notice = candidate.arrangementNotice {
                                Text(notice).font(.caption).foregroundStyle(.orange)
                            }
                            DisclosureGroup("来源与匹配详情") {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(candidate.source.displayName) · \(candidate.queryMethodLabel) · \(candidate.timelineLabel)")
                                    ForEach(Array(candidate.matchExplanation.enumerated()), id: \.offset) { _, explanation in Text(explanation) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Spacer()
                            if selectedVersion?.record.id == currentVersionID, selectedVersion != nil {
                                Label("当前版本", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            } else {
                                Button(isBusy ? "正在采用…" : "采用此版本") {
                                    if let version = selectedVersion { onAdopt(version.record.id) }
                                    else { adoptCandidate(confirmingLocks: false) }
                                }
                                .buttonStyle(.borderedProminent).disabled(isBusy)
                            }
                        }
                    } else {
                        ContentUnavailableView("选择一个版本", systemImage: "text.bubble",
                            description: Text("左侧选择已保存版本或搜索候选，在这里与当前歌词对比。"))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxHeight: .infinity)

            if let failureMessage {
                Text(failureMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 10) {
                Button("编辑当前", systemImage: "square.and.pencil", action: onEdit).disabled(!canEdit || isBusy)
                    .help("保留原版，编辑后另存人工版本")
                Button("复制当前歌词", systemImage: "doc.on.doc") { showCopy = true }.disabled(lines.isEmpty || isBusy)
                Spacer(minLength: 0)
                Button(isSearching ? "正在查找…" : "查找更多", systemImage: "magnifyingglass") {
                    selectedID = nil
                    failureMessage = nil
                    onSearch()
                }.disabled(isBusy || isSearching)
            }.controlSize(.small)
        }
        .padding(20)
        .frame(width: 920, height: 650)
        .interactiveDismissDisabled(isBusy)
        .onAppear { if let currentVersionID { selectedID = "saved:\(currentVersionID)" } }
        .onChange(of: selectedID) { _, _ in
            failureMessage = nil
            showSourceTranslation = false
            onCancelLocked()
            conflictingLockedVersionIDs = []
        }
        .onDisappear { onCancelLocked() }
        .sheet(isPresented: $showCopy) {
            LyricsCopyView(lines: lines, title: title, trackStableKey: trackStableKey,
                           artistDisplay: artistDisplay, language: language, userEntries: userEntries)
        }
        .confirmationDialog("歌词版本已锁定", isPresented: $isLockConfirmationPresented, titleVisibility: .visible) {
            Button("仍采用此版本", role: .destructive) { adoptCandidate(confirmingLocks: true) }
            Button("取消", role: .cancel) { onCancelLocked(); conflictingLockedVersionIDs = [] }
        } message: {
            Text("当前歌曲有 \(conflictingLockedVersionIDs.count) 个锁定歌词版本。继续会采用此候选，并保留原版本及锁定标记。")
        }
    }

    private func savedRow(_ version: StoredEditableLyricsVersion) -> some View {
        let key = "saved:\(version.record.id)"
        let source = DatabaseSourceIdentifier.displayName(for: version.record.source)
        let provenance = DatabaseSourceIdentifier.provenanceDescription(source: version.record.source,
            parentVersionID: version.record.parentVersionID) { id in
                guard let parent = versions.first(where: { $0.record.id == id })?.record else { return nil }
                return (parent.source, parent.parentVersionID)
            }
        return Button { selectedID = key } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    LibraryVersionLabel(kind: "lyrics", id: version.record.id, originalTitle: source)
                    Spacer(minLength: 3)
                    if version.record.id == currentVersionID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    if version.record.isLocked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                }
                Text("\(version.record.isSynced ? "已同步" : "纯文本") · \(version.record.isManuallyEdited ? "人工编辑" : "来源版本")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(version.record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                Text("来源：\(provenance)").font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(provenance)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == key ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(isBusy)
    }

    private func candidateRow(_ candidate: LyricsCandidate) -> some View {
        let key = "candidate:\(candidate.id)"
        return Button { selectedID = key } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.source.displayName).font(.callout.weight(.medium))
                Text(candidate.title).font(.caption).lineLimit(2)
                Text("\(candidate.artist) · \(candidate.isSynchronized ? "已同步" : "纯文本")")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == key ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(isBusy)
    }

    private func lyricColumn(_ heading: String, lines: [LyricLine], synchronized: Bool, showTranslation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline).lineLimit(1)
            Text("\(lines.count) 行 · \(synchronized ? "已同步" : "纯文本")").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(synchronized ? timeLabel(line.timestamp) : "#\(index + 1)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Text(line.originalText.isEmpty ? "（空白原文）" : line.originalText)
                                .font(.callout).textSelection(.enabled)
                            if showTranslation, hasText(line.translationText), let translation = line.translationText {
                                Text(translation)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if lines.isEmpty { Text("暂无当前歌词").font(.callout).foregroundStyle(.secondary) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func timeLabel(_ timestamp: TimeInterval) -> String {
        let seconds = max(0, Int(timestamp.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func hasText(_ text: String?) -> Bool {
        !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func adoptCandidate(confirmingLocks: Bool) {
        guard !isBusy, let candidate = selectedCandidate else { return }
        isSavingCandidate = true
        failureMessage = nil
        Task { @MainActor in
            defer { isSavingCandidate = false }
            do {
                let result = try await (confirmingLocks ? onConfirmLocked() : onAdoptCandidate(candidate))
                guard let result else { failureMessage = "候选已失效，请重新查找。"; return }
                switch result.disposition {
                case .inserted, .duplicate:
                    guard let versionID = result.versionID else { failureMessage = "歌词未能保存，请重试。"; return }
                    onCancelLocked()
                    selectedID = "saved:\(versionID)"
                    onCandidateAdopted()
                case .lockedConflict:
                    conflictingLockedVersionIDs = result.conflictingLockedVersionIDs
                    isLockConfirmationPresented = true
                case .skippedLocked:
                    failureMessage = "歌词仍受锁定保护，未采用。"
                case .rejected(let reason):
                    failureMessage = reason
                }
            } catch { failureMessage = "歌词未能保存：\(error.localizedDescription)" }
        }
    }
}


/// Formats the selected saved/displayed layers without touching their content,
/// timing, versions, or the playback position.
enum LyricsCopyText {
    static func resolvingReadings(_ lines: [LyricLine], trackStableKey: String?, artistDisplay: String?,
                                  language: String?, userEntries: [ReadingDictionaryEntry]) -> [LyricLine] {
        lines.map { source in
            guard !Task.isCancelled else { return source }
            let surface = source.readingSurfaceText ?? source.originalText
            guard LyricsLanguageGate.allowsJapaneseReadings(language: language, text: surface) else { return source }
            func hasText(_ text: String?) -> Bool { !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            var line = source
            if hasText(source.kanaText) {
                // Confirmed provider/manual kana outranks local morphology.
                if !hasText(source.romajiText), let kana = source.kanaText {
                    line.romajiText = JapaneseRomanizer.romanizeConfirmedKana(kana)
                }
            } else if let reading = V3JapaneseReadingCache.reading(for: surface, userEntries: userEntries,
                                                                  trackStableKey: trackStableKey, artistDisplay: artistDisplay) {
                line.kanaText = reading.kanaText
                if !hasText(source.romajiText) { line.romajiText = reading.romajiText }
            }
            return line
        }
    }

    static func format(_ lines: [LyricLine], original: Bool = true, kana: Bool = false,
                       romaji: Bool = false, translation: Bool = false, selectedIndices: Set<Int>? = nil) -> String {
        lines.enumerated().compactMap { index, line -> String? in
            if let selectedIndices, !selectedIndices.contains(index) { return nil }
            let layers: [String?] = [original ? line.originalText : nil,
                                    kana ? line.kanaText : nil,
                                    romaji ? line.romajiText : nil,
                                    translation ? line.translationText : nil]
            let text = layers.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }.joined(separator: original && !kana && !romaji && !translation ? "\n" : "\n\n")
    }

    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct LyricsCopyView: View {
    let lines: [LyricLine]
    let title: String
    let trackStableKey: String?
    let artistDisplay: String?
    let language: String?
    let userEntries: [ReadingDictionaryEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var original = true
    @State private var kana = false
    @State private var romaji = false
    @State private var translation = false
    @State private var copied = false
    @State private var resolvedLines: [LyricLine]?
    @State private var isResolving = true
    @State private var showPassages: Bool
    @State private var selectedIndices: Set<Int>

    init(lines: [LyricLine], title: String, trackStableKey: String? = nil, artistDisplay: String? = nil,
         language: String? = nil, userEntries: [ReadingDictionaryEntry] = [], initialSelectedIndex: Int? = nil) {
        self.lines = lines
        self.title = title
        self.trackStableKey = trackStableKey
        self.artistDisplay = artistDisplay
        self.language = language
        self.userEntries = userEntries
        _showPassages = State(initialValue: initialSelectedIndex != nil)
        _selectedIndices = State(initialValue: initialSelectedIndex.map { lines.indices.contains($0) ? Set([$0]) : [] } ?? Set(lines.indices))
    }

    private var copyLines: [LyricLine] { resolvedLines ?? lines }

    private var text: String {
        LyricsCopyText.format(copyLines, original: original, kana: kana, romaji: romaji, translation: translation, selectedIndices: selectedIndices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("复制歌词").font(.title3.bold())
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack(spacing: 18) {
                Toggle("原文", isOn: $original)
                Toggle("假名", isOn: $kana).disabled(!copyLines.contains { $0.kanaText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
                Toggle("罗马音", isOn: $romaji).disabled(!copyLines.contains { $0.romajiText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
                Toggle("翻译", isOn: $translation).disabled(!copyLines.contains { $0.translationText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
            }
            .toggleStyle(.checkbox)
            if isResolving {
                ProgressView("正在准备可复制的读音…").controlSize(.small)
            }
            HStack {
                Button(showPassages ? "收起段落选择" : "选择段落") { showPassages.toggle() }
                Text("已选 \(selectedIndices.count)/\(copyLines.count) 行").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("全选") { selectedIndices = Set(copyLines.indices) }
                Button("清空") { selectedIndices = [] }
            }
            if showPassages {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(copyLines.enumerated()), id: \.offset) { index, line in
                            Toggle(isOn: Binding(
                                get: { selectedIndices.contains(index) },
                                set: { selected in
                                    if selected { selectedIndices.insert(index) } else { selectedIndices.remove(index) }
                                }
                            )) {
                                Text(line.originalText).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 140)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                Text(text.isEmpty ? "请选择要复制的内容" : text)
                    .font(.system(size: 16))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("选中文字后按 ⌘C，或复制所选段落。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已复制" : (selectedIndices.count == copyLines.count ? "复制全部" : "复制所选"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                    LyricsCopyText.copy(text)
                    copied = true
                }
                .disabled(text.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 600, height: 560)
        .onChange(of: text) { _, _ in copied = false }
        .task {
            let sourceLines = lines
            let entries = userEntries
            let scope = trackStableKey
            let artist = artistDisplay
            let sourceLanguage = language
            let preparation = Task.detached(priority: .userInitiated) {
                LyricsCopyText.resolvingReadings(sourceLines, trackStableKey: scope, artistDisplay: artist,
                                                language: sourceLanguage, userEntries: entries)
            }
            let prepared = await withTaskCancellationHandler(operation: { await preparation.value }, onCancel: { preparation.cancel() })
            guard !Task.isCancelled else { return }
            resolvedLines = prepared
            isResolving = false
        }
    }
}
