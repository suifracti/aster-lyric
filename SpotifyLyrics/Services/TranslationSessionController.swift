import Combine
import Foundation
import AppKit

public enum TranslationSessionState: Equatable, Sendable {
    case idle
    case unavailable
    case loading
    case loaded(UUID)
    case candidateReady(UUID)
    case failed(String)

    public var userFacingMessage: String {
        switch self {
        case .idle: return ""
        case .unavailable: return "未配置 AI 翻译"
        case .loading: return "正在翻译整首歌词…"
        case .loaded: return ""
        case .candidateReady: return "有新的翻译候选待采用"
        case .failed(let message): return "翻译失败：\(message)"
        }
    }
}

/// The one shared translation state source for V3, lyrics focus and retained
/// auxiliary windows. It merges identical in-flight requests and commits only
/// complete, source-hash-validated versions.
@MainActor
public final class TranslationSessionController: ObservableObject {
    @Published public private(set) var state: TranslationSessionState = .idle
    @Published public private(set) var selectedVersion: StoredTranslationVersion?
    @Published public private(set) var availableVersions: [StoredTranslationVersion] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var progressMessage = ""
    /// Distinguishes an explicit session-level “无翻译版本” choice from a
    /// hidden translation layer or a context that has not loaded yet.
    @Published public private(set) var isNoSelection = false
    @Published public private(set) var pendingCandidate: StoredTranslationVersion?

    private let repository: any TranslationRepository
    private let acceptanceBudget: TranslationAcceptanceRequestBudget?
    private var engine: (any TranslationEngine)?
    private var requestTask: Task<Void, Never>?
    private var context: TranslationContext?
    private var inFlightKey: RequestKey?
    private var manualSelection: [SourceKey: UUID] = [:]
    private var manualNoSelection: Set<SourceKey> = []
    private let selectionDefaults: UserDefaults?
    private var requestGeneration: UInt64 = 0
    private var terminationObserver: NSObjectProtocol?

    private func observeTermination() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private struct SourceLineKey: Hashable, Sendable {
        let id: UUID
        let text: String
    }
    private struct SourceKey: Hashable, Sendable {
        let identity: TrackIdentity
        let versionID: UUID
        let sourceHash: String
        let targetLanguage: String
        let lines: [SourceLineKey]
    }
    private struct RequestKey: Hashable, Sendable {
        let source: SourceKey
        let rules: AITranslationConfigurationIdentity
        let sourceLanguage: String
    }

    private struct TranslationContext: Equatable, Sendable {
        let identity: TrackIdentity
        let lyricsVersionID: UUID
        let sourceContentHash: String
        let document: LyricsDocument
        let configuration: AITranslationConfiguration

        var key: SourceKey {
            SourceKey(identity: identity, versionID: lyricsVersionID, sourceHash: sourceContentHash,
                targetLanguage: configuration.targetLanguage,
                lines: document.lines.map { SourceLineKey(id: $0.id, text: $0.originalText) })
        }
        var requestKey: RequestKey {
            RequestKey(source: key, rules: configuration.requestIdentity, sourceLanguage: aiContext.sourceLanguage)
        }
        var aiContext: AITranslationContext {
            let profile = TranslationSessionController.decodeProfile(configuration.profileSnapshot)
            let language = document.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AITranslationContext(title: document.title ?? "", artist: document.artist ?? "",
                album: document.album ?? "", sourceLanguage: language.isEmpty ? "und" : language, targetLanguage: configuration.targetLanguage,
                style: configuration.style, lines: document.lines.enumerated().map { index, line in
                    AITranslationSourceLine(index: index, original: line.originalText, kana: line.kanaText,
                        romaji: line.romajiText, lineID: line.id, timestamp: line.timestamp)
                }, styleSummary: profile?.styleSummary ?? "", styleExamples: profile?.examples ?? [])
        }
    }

    public init(
        repository: any TranslationRepository,
        service: (any AITranslationService)? = OpenAICompatibleTranslationService(),
        selectionDefaults: UserDefaults? = nil,
        acceptanceBudget: TranslationAcceptanceRequestBudget? = .processBudget
    ) {
        self.repository = repository
        self.acceptanceBudget = acceptanceBudget
        self.selectionDefaults = selectionDefaults
        self.engine = service.map { TranslationEngineRegistry.wrapping($0) }
        observeTermination()
    }

    public init(
        repository: any TranslationRepository,
        engine: (any TranslationEngine)?,
        selectionDefaults: UserDefaults? = nil,
        acceptanceBudget: TranslationAcceptanceRequestBudget? = .processBudget
    ) {
        self.repository = repository
        self.acceptanceBudget = acceptanceBudget
        self.selectionDefaults = selectionDefaults
        self.engine = engine
        observeTermination()
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        requestTask?.cancel()
    }

    public var isTranslating: Bool {
        if case .loading = state { return true }
        return false
    }

    public func synchronize(
        document: LyricsDocument?,
        lyricsVersionID: UUID?,
        sourceContentHash: String?,
        configuration: AITranslationConfiguration
    ) {
        guard let document, !document.lines.isEmpty, let lyricsVersionID else {
            resetForMissingLyrics()
            return
        }
        let hash = sourceContentHash ?? LyricsPersistenceMapper.sourceContentHash(document: document)
        let next = TranslationContext(
            identity: document.identity,
            lyricsVersionID: lyricsVersionID,
            sourceContentHash: hash,
            document: document,
            configuration: configuration
        )
        // Language/profile edits change request context, not the adopted lyric source.
        let sameLyricsSource = context.map {
            $0.identity == next.identity && $0.lyricsVersionID == next.lyricsVersionID
                && $0.sourceContentHash == next.sourceContentHash
        } ?? false
        if let previous = context, previous.key == next.key {
            // A session refresh may carry newly enriched display layers. Keep
            // the selected version but update the document used for projection.
            context = next
            // Manual selection is tied to the source, while work/candidates are
            // tied to the complete provider/model/rule snapshot.
            let configurationBoundaryChanged = previous.requestKey != next.requestKey ||
                previous.configuration.autoTranslateNewLyrics != next.configuration.autoTranslateNewLyrics ||
                previous.configuration.isConfigured != next.configuration.isConfigured
            if configurationBoundaryChanged {
                // Editing settings cancels obsolete work, but is not a paid
                // update command. Preserve adopted results while looking up cache.
                let enabledNow = !previous.configuration.autoTranslateNewLyrics && next.configuration.autoTranslateNewLyrics
                cancel()
                pendingCandidate = nil
                state = selectedVersion.map { .loaded($0.record.id) } ?? .idle
                loadExistingOrAutoTranslate(next, allowAutomaticRequest: enabledNow)
            }
            return
        }
        requestTask?.cancel()
        requestTask = nil
        inFlightKey = nil
        requestGeneration &+= 1
        context = next
        restorePersistedSelection(next.key)
        selectedVersion = nil
        availableVersions = []
        pendingCandidate = nil
        errorMessage = nil
        progressMessage = ""
        isNoSelection = manualNoSelection.contains(next.key)
        state = .idle
        loadExistingOrAutoTranslate(next, allowAutomaticRequest: !sameLyricsSource)
    }

    public func cancel() {
        requestTask?.cancel()
        requestTask = nil
        inFlightKey = nil
        requestGeneration &+= 1
        state = .idle
        errorMessage = nil
        progressMessage = ""
    }

    public func setEngine(_ engine: any TranslationEngine) {
        self.engine = engine
    }

    /// Re-reads the selected/source-matched versions after another session
    /// (for example the lyrics editor) has committed a new version.
    public func reloadCurrentContext() {
        guard let context else { return }
        loadExistingOrAutoTranslate(context)
    }

    public func resetForMissingLyrics() {
        requestTask?.cancel()
        requestTask = nil
        inFlightKey = nil
        requestGeneration &+= 1
        context = nil
        selectedVersion = nil
        availableVersions = []
        errorMessage = nil
        progressMessage = ""
        isNoSelection = false
        pendingCandidate = nil
        state = .idle
    }

    public func translateCurrentLyrics() {
        guard let context else { return }
        startTranslation(context, forceNewVersion: false, explicitRequest: true)
    }

    public func retranslateCurrentLyrics() {
        guard let context else { return }
        startTranslation(context, forceNewVersion: true, explicitRequest: true)
    }

    /// Explicitly selects no translation for the current lyric context. The
    /// existing versions remain available and are never deleted or modified.
    public func selectNone() {
        guard let context else { return }
        requestTask?.cancel()
        requestTask = nil
        inFlightKey = nil
        requestGeneration &+= 1
        manualNoSelection.insert(context.key)
        persistSelection("none", key: context.key)
        selectedVersion = nil
        pendingCandidate = nil
        isNoSelection = true
        errorMessage = nil
        state = .idle
        progressMessage = ""
    }

    private func preferenceKey(_ key: SourceKey) -> String {
        Self.selectionPreferenceKey(trackStableKey: key.identity.stableKey, versionID: key.versionID, sourceHash: key.sourceHash, targetLanguage: key.targetLanguage)
    }
    public static func selectionPreferenceKey(trackStableKey: String, versionID: UUID, sourceHash: String, targetLanguage: String) -> String {
        "ai.translationSelection.v1." + [trackStableKey, versionID.uuidString, sourceHash, targetLanguage].joined(separator: "|")
    }
    private func persistSelection(_ value: String?, key: SourceKey) {
        selectionDefaults?.set(value, forKey: preferenceKey(key))
        selectionDefaults?.set(value, forKey: "ai.libraryTranslationSelection.v1." + key.identity.stableKey)
    }
    private func restorePersistedSelection(_ key: SourceKey) {
        guard let saved = selectionDefaults?.string(forKey: preferenceKey(key)) else { return }
        if saved == "none" { manualNoSelection.insert(key) }
        else if let id = UUID(uuidString: saved) { manualSelection[key] = id }
    }

    public func restoreRecommended() {
        guard let context else { return }
        manualSelection.removeValue(forKey: context.key)
        manualNoSelection.remove(context.key)
        persistSelection(nil, key: context.key)
        isNoSelection = false
        pendingCandidate = nil
        progressMessage = ""
        loadExistingOrAutoTranslate(context)
    }

    public func select(versionID: UUID) {
        guard let context,
              let version = availableVersions.first(where: { $0.record.id == versionID }),
              version.record.sourceContentHash == context.sourceContentHash,
              (version.record.targetLanguage == context.configuration.targetLanguage || version.isEmbeddedTranslation),
              version.isComplete,
              !version.isDraft,
              !version.isArchived else { return }
        requestTask?.cancel()
        requestTask = nil
        inFlightKey = nil
        manualSelection[context.key] = versionID
        manualNoSelection.remove(context.key)
        persistSelection(versionID.uuidString, key: context.key)
        requestGeneration &+= 1
        isNoSelection = false
        selectedVersion = version
        state = .loaded(version.record.id)
        errorMessage = nil
        progressMessage = ""
    }

    /// Explicit adoption remains available for protected/manual contexts.
    /// Unprotected complete results are used automatically by the listening flow.
    public func adoptTranslation(versionID: UUID) {
        guard let context,
              let candidate = availableVersions.first(where: { $0.record.id == versionID }),
              candidate.isComplete,
              candidate.isDraft,
              !candidate.record.isLocked,
              candidate.record.lyricsVersionID == context.lyricsVersionID,
              candidate.record.sourceContentHash == context.sourceContentHash else { return }
        cancel()
        let adoptionGeneration = requestGeneration
        Task { [weak self, repository] in
            do {
                try await repository.adoptTranslation(versionID: versionID)
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key, self.requestGeneration == adoptionGeneration else { return }
                    let adopted = candidate.with(record: candidate.record.with(isDraft: false, isArchived: false))
                    self.availableVersions = self.availableVersions.map { $0.record.id == versionID ? adopted : $0 }
                    self.pendingCandidate = nil
                    self.manualSelection[context.key] = versionID
                    self.manualNoSelection.remove(context.key)
                    self.persistSelection(versionID.uuidString, key: context.key)
                    self.isNoSelection = false
                    self.selectedVersion = adopted
                    self.state = .loaded(versionID)
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func archiveTranslation(versionID: UUID) {
        guard let context,
              let version = availableVersions.first(where: { $0.record.id == versionID }),
              !version.record.isLocked else { return }
        Task { [weak self, repository] in
            do {
                try await repository.archiveTranslation(versionID: versionID, archived: true)
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key else { return }
                    let archived = version.with(record: version.record.with(isArchived: true))
                    self.availableVersions = self.availableVersions.map { $0.record.id == versionID ? archived : $0 }
                    if self.pendingCandidate?.record.id == versionID { self.pendingCandidate = nil }
                    if self.selectedVersion?.record.id == versionID {
                        self.selectedVersion = nil
                        self.state = .idle
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func lockSelected() {
        guard let selectedVersion, let context else { return }
        let id = selectedVersion.record.id
        let generation = requestGeneration
        Task { [weak self] in
            do {
                try await self?.repository.markTranslationLocked(versionID: id, locked: true)
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key, self.requestGeneration == generation else { return }
                    self.persistSelection(id.uuidString, key: context.key)
                    self.reloadKeepingSelection(id: id)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key, self.requestGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func deleteSelected() {
        guard let selectedVersion, !selectedVersion.record.isLocked, let context else { return }
        let id = selectedVersion.record.id
        let generation = requestGeneration
        Task { [weak self] in
            do {
                try await self?.repository.deleteTranslation(versionID: id)
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key, self.requestGeneration == generation else { return }
                    self.selectedVersion = nil
                    self.manualSelection.removeValue(forKey: context.key)
                    self.persistSelection(nil, key: context.key)
                    self.loadExistingOrAutoTranslate(context, allowAutomaticRequest: false)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.context?.key == context.key, self.requestGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Projects the selected version onto the existing LyricLine values. All
    /// original/kana/romaji/timeline fields remain untouched.
    public func project(onto lines: [LyricLine]) -> [LyricLine] {
        if isNoSelection {
            return lines.map { line in
                var cleared = line
                cleared.translationText = nil
                return cleared
            }
        }
        guard let selectedVersion,
              selectedVersion.isComplete,
              selectedVersion.lines.count == lines.count,
              selectedVersion.lines.map(\.lineIndex) == Array(lines.indices) else {
            // Provider Chinese is a comparison option, not an implicit default.
            // Preserve translations attached to explicitly imported/edited lyrics.
            if let context, [LyricsSource.manualEdit, .manualImport, .manualCreate].contains(context.document.source) {
                return lines
            }
            return lines.map { line in
                var cleared = line
                cleared.translationText = nil
                return cleared
            }
        }
        var projected = lines
        for stored in selectedVersion.lines {
            projected[stored.lineIndex].translationText = stored.translatedText
        }
        return projected
    }

    /// Projects only when the selected translation belongs to the requested
    /// live lyric document.  Search previews share this controller, so a
    /// floating window must not accidentally render a preview translation on
    /// the currently playing song.
    public func project(
        onto lines: [LyricLine],
        identity: TrackIdentity,
        lyricsVersionID: UUID?,
        sourceContentHash: String?
    ) -> [LyricLine] {
        guard let context,
              context.identity == identity,
              context.lyricsVersionID == lyricsVersionID,
              context.sourceContentHash == sourceContentHash else {
            return lines
        }
        return project(onto: lines)
    }

    nonisolated private static func completionContext(_ context: TranslationContext) -> TranslationCompletionContext {
        TranslationCompletionContext(identity: context.identity, lyricsVersionID: context.lyricsVersionID,
            sourceContentHash: context.sourceContentHash, originalLines: context.document.lines.map(\.originalText),
            targetLanguage: context.configuration.targetLanguage, providerCacheIdentity: context.configuration.providerCacheIdentity,
            configurationPromptHash: context.configuration.promptHash, engineID: context.configuration.engineID,
            allowsAppleFallback: context.configuration.fallbackStrategy == .automaticSystem)
    }

    private func loadExistingOrAutoTranslate(_ context: TranslationContext, allowAutomaticRequest: Bool = true) {
        requestTask?.cancel()
        requestTask = nil
        inFlightKey = nil
        progressMessage = ""
        requestGeneration &+= 1
        let loadGeneration = requestGeneration
        let key = context.key
        requestTask = Task { [weak self, repository] in
            do {
                if context.document.lines.contains(where: { $0.translationText?.isEmpty == false }) {
                    try await repository.preserveEmbeddedTranslation(lyricsVersionID: context.lyricsVersionID,
                        sourceContentHash: context.sourceContentHash)
                }
                var versions = try await repository.loadTranslationVersions(
                    lyricsVersionID: context.lyricsVersionID,
                    targetLanguage: context.configuration.targetLanguage,
                    sourceContentHash: context.sourceContentHash
                )
                guard !Task.isCancelled, self?.context?.key == key, self?.requestGeneration == loadGeneration else { return }
                // Keep complete old work visible even if the request journal is
                // unreadable. It still fails closed for any new dispatch.
                self?.availableVersions = versions
                self?.selectedVersion = self?.chooseVersion(versions, context: context)
                let durableKey = try AITranslationRequestExecution.key(identity: context.identity, versionID: context.lyricsVersionID,
                    sourceHash: context.sourceContentHash, context: context.aiContext, configuration: context.configuration)
                var previousRequest = try await repository.loadTranslationRequest(key: durableKey)
                guard !Task.isCancelled, self?.context?.key == key, self?.requestGeneration == loadGeneration else { return }
                if let request = previousRequest, request.phase == .received || request.phase == .saved {
                    let saved = try await repository.completeTranslationRequest(key: durableKey, attemptID: request.attemptID,
                        context: Self.completionContext(context))
                    versions.removeAll { $0.record.id == saved.record.id }
                    versions.insert(saved, at: 0)
                    previousRequest = try await repository.loadTranslationRequest(key: durableKey)
                }
                guard !Task.isCancelled else { return }
                let interrupted = previousRequest?.phase == .dispatching
                await MainActor.run { [weak self] in
                    guard let self,
                          self.context?.key == key,
                          self.requestGeneration == loadGeneration else { return }
                    self.availableVersions = versions
                    self.pendingCandidate = versions.first(where: {
                        $0.isComplete && $0.isDraft && !$0.isArchived && self.matchesRequest($0, context: context)
                    })
                    if self.manualNoSelection.contains(key) {
                        self.selectedVersion = nil
                        self.isNoSelection = true
                        self.state = .idle
                        self.errorMessage = nil
                        return
                    }
                    self.isNoSelection = false
                    if let selected = self.chooseVersion(versions, context: context) {
                        self.selectedVersion = selected
                        self.state = .loaded(selected.record.id)
                        self.errorMessage = nil
                        if interrupted { self.progressMessage = "上次翻译已中断，结果未知；保留旧译文，不会自动重发。可主动重试。" }
                    } else if let candidate = self.pendingCandidate, self.canUseAutomatically(context) {
                        self.useExistingCandidateAutomatically(candidate, context: context, generation: loadGeneration)
                    } else if interrupted || previousRequest?.phase == .saved {
                        self.state = .failed("上次请求已发起但没有可恢复的完整结果；不会自动重发，请主动重试")
                        self.errorMessage = self.state.userFacingMessage
                        self.progressMessage = "翻译已中断；原文和已有译文保留"
                    } else if allowAutomaticRequest && self.canUseAutomatically(context) && context.configuration.autoTranslateNewLyrics && context.configuration.isConfigured {
                        self.startTranslation(context, forceNewVersion: false)
                    } else {
                        // Old automatic results remain in history, but cannot be
                        // presented as the selected result of a new request.
                        self.selectedVersion = nil
                        self.state = self.pendingCandidate.map { .candidateReady($0.record.id) } ?? .idle
                        self.errorMessage = nil
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.context?.key == key,
                          self.requestGeneration == loadGeneration else { return }
                    self.state = .failed(error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadExistingOrAutoTranslateIfContextExists() {
        guard let context else { return }
        loadExistingOrAutoTranslate(context)
    }

    private func chooseVersion(
        _ versions: [StoredTranslationVersion],
        context: TranslationContext
    ) -> StoredTranslationVersion? {
        let eligible = versions.filter {
            $0.isComplete &&
            !$0.isDraft &&
            !$0.isArchived &&
            ($0.record.targetLanguage == context.configuration.targetLanguage || $0.isEmbeddedTranslation) &&
            $0.record.sourceContentHash == context.sourceContentHash
        }
        guard !manualNoSelection.contains(context.key) else { return nil }
        if let manualID = manualSelection[context.key],
           let manual = eligible.first(where: { $0.record.id == manualID }) { return manual }
        if let locked = eligible.first(where: { $0.record.isLocked }) { return locked }
        if let edited = eligible.first(where: { $0.record.isManuallyEdited || (!$0.record.isMachineGenerated && !$0.isEmbeddedTranslation) }) { return edited }
        // Adopted history remains usable after a settings change. A mismatch is
        // never labelled a cache hit for a new explicit request.
        return eligible.first(where: { matchesRequest($0, context: context) }) ?? eligible.first(where: { !$0.isEmbeddedTranslation })
    }

    private func matchesRequest(_ version: StoredTranslationVersion, context: TranslationContext) -> Bool {
        let record = version.record
        guard record.lyricsVersionID == context.lyricsVersionID,
              record.sourceContentHash == context.sourceContentHash,
              record.targetLanguage == context.configuration.targetLanguage,
              record.engineID == context.configuration.engineID,
              record.providerExecutionMetadata.reasoningSetting == context.configuration.providerReasoningSetting else { return false }
        if let cacheIdentity = record.providerExecutionMetadata.cacheIdentity {
            guard cacheIdentity == context.configuration.providerCacheIdentity else { return false }
        } else if record.engineID == TranslationEngineID.openAICompatible.rawValue {
            // Historical records contain only a host, not the effective endpoint.
            // Keep them viewable; do not claim a verified current API cache hit.
            return false
        }
        if context.configuration.engineID == TranslationEngineID.appleSystem.rawValue {
            return record.promptHash == "apple-system-translation-v1"
        }
        guard !context.configuration.model.isEmpty,
              record.model == context.configuration.model,
              record.workflowID == context.configuration.workflowID,
              let prompt = try? AITranslationPromptBuilder().build(context: context.aiContext, configuration: context.configuration) else { return false }
        return record.promptHash == prompt.promptHash
    }

    private func canUseAutomatically(_ context: TranslationContext) -> Bool {
        guard !manualNoSelection.contains(context.key),
              manualSelection[context.key] == nil else { return false }
        if let selectedVersion, selectedVersion.record.isLocked || selectedVersion.record.isManuallyEdited || !selectedVersion.record.isMachineGenerated { return false }
        if [LyricsSource.manualEdit, .manualImport, .manualCreate].contains(context.document.source),
           context.document.lines.contains(where: { $0.translationText?.isEmpty == false }) { return false }
        return true
    }

    private func useExistingCandidateAutomatically(_ candidate: StoredTranslationVersion, context: TranslationContext, generation: UInt64) {
        Task { [weak self, repository] in
            do {
                guard let self, self.context?.requestKey == context.requestKey,
                      self.requestGeneration == generation, self.canUseAutomatically(context) else { return }
                try await repository.adoptTranslation(versionID: candidate.record.id)
                guard self.context?.requestKey == context.requestKey,
                      self.requestGeneration == generation, self.canUseAutomatically(context) else { return }
                let accepted = candidate.with(record: candidate.record.with(isDraft: false))
                self.availableVersions = self.availableVersions.map { $0.record.id == accepted.record.id ? accepted : $0 }
                self.selectedVersion = accepted
                self.pendingCandidate = nil
                self.state = .loaded(accepted.record.id)
                self.progressMessage = "已自动复用完整 AI 译文，可随时比较和改选"
            } catch {
                guard let self, self.context?.key == context.key, self.requestGeneration == generation else { return }
                self.state = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func startTranslation(_ context: TranslationContext, forceNewVersion: Bool, explicitRequest: Bool = false) {
        let key = context.key
        if !forceNewVersion, inFlightKey == context.requestKey { return }
        if !forceNewVersion, let selectedVersion,
           selectedVersion.isComplete, !selectedVersion.isDraft, !selectedVersion.isArchived,
           selectedVersion.record.isMachineGenerated, !selectedVersion.record.isManuallyEdited,
           matchesRequest(selectedVersion, context: context) {
            state = .loaded(selectedVersion.record.id)
            errorMessage = nil
            progressMessage = "已复用当前模型与译风的完整翻译缓存"
            return
        }
        if !forceNewVersion,
           let pendingCandidate,
           pendingCandidate.record.lyricsVersionID == context.lyricsVersionID,
           pendingCandidate.record.sourceContentHash == context.sourceContentHash,
           !pendingCandidate.record.isArchived,
           matchesRequest(pendingCandidate, context: context) {
            // Reuse the complete result; explicit regeneration is the only
            // action allowed to create another paid request.
            if canUseAutomatically(context) { useExistingCandidateAutomatically(pendingCandidate, context: context, generation: requestGeneration) }
            return
        }
        requestTask?.cancel()
        requestGeneration &+= 1
        let translationGeneration = requestGeneration
        inFlightKey = context.requestKey
        pendingCandidate = nil
        state = .loading
        errorMessage = nil
        progressMessage = engine?.metadata.stableID == TranslationEngineID.appleSystem.rawValue
            ? "正在检查 Apple 语言支持并准备系统翻译…"
            : (engine?.metadata.stableID == TranslationEngineID.codexChatGPT.rawValue
                ? "正在通过 Codex 会话准备整首歌词翻译…"
                : "正在请求整首歌词翻译…")
        let engine = self.engine
        let acceptanceBudget = self.acceptanceBudget
        requestTask = Task { [weak self, repository] in
            do {
                guard let engine else { throw AITranslationError.notConfigured }
                let aiContext = context.aiContext
                try Task.checkCancellation()
                let durableKey = try AITranslationRequestExecution.key(identity: context.identity, versionID: context.lyricsVersionID,
                    sourceHash: context.sourceContentHash, context: aiContext, configuration: context.configuration)
                let request = try await AITranslationRequestExecution.run(engine: engine, repository: repository, key: durableKey,
                    explicitRetry: explicitRequest, context: aiContext, sourceHash: context.sourceContentHash,
                    configuration: context.configuration, budget: acceptanceBudget, trackKey: context.identity.stableKey)
                guard request.result != nil else { throw AITranslationError.invalidResponse("完整结果缺失") }
                guard !Task.isCancelled, self?.context?.requestKey == context.requestKey,
                      self?.requestGeneration == translationGeneration else { throw AITranslationError.cancelled }
                let automaticallyUse = self?.canUseAutomatically(context) == true
                var saved = try await repository.completeTranslationRequest(key: durableKey, attemptID: request.attemptID,
                    context: Self.completionContext(context))
                guard !Task.isCancelled, self?.context?.requestKey == context.requestKey,
                      self?.requestGeneration == translationGeneration else { return }
                if automaticallyUse && self?.canUseAutomatically(context) == true {
                    try await repository.adoptTranslation(versionID: saved.record.id)
                    saved = saved.with(record: saved.record.with(isDraft: false))
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.context?.key == key,
                          self.requestGeneration == translationGeneration else { return }
                    self.inFlightKey = nil
                    self.availableVersions.insert(saved, at: 0)
                    if automaticallyUse && self.canUseAutomatically(context) {
                        self.pendingCandidate = nil
                        self.selectedVersion = saved
                        self.isNoSelection = false
                        self.state = .loaded(saved.record.id)
                        self.progressMessage = "已自动使用完整 AI 译文，可随时比较和改选"
                    } else {
                        self.pendingCandidate = saved
                        self.state = .candidateReady(saved.record.id)
                        self.progressMessage = "新译文已保留；当前人工、锁定或自选版本不变"
                    }
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.context?.key == key,
                          self.requestGeneration == translationGeneration else { return }
                    self.inFlightKey = nil
                    self.state = .idle
                    self.progressMessage = ""
                }
            } catch let error as AITranslationError {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.context?.key == key,
                          self.requestGeneration == translationGeneration else { return }
                    self.inFlightKey = nil
                    self.state = error == .cancelled ? .idle : .failed(error.localizedDescription)
                    self.errorMessage = error == .cancelled ? nil : error.localizedDescription
                    self.progressMessage = error == .cancelled ? "" : "翻译失败：\(error.localizedDescription)"
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.context?.key == key,
                          self.requestGeneration == translationGeneration else { return }
                    self.inFlightKey = nil
                    self.state = .failed(error.localizedDescription)
                    self.errorMessage = error.localizedDescription
                    self.progressMessage = "翻译失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func reloadKeepingSelection(id: UUID) {
        guard let context else { return }
        manualSelection[context.key] = id
        loadExistingOrAutoTranslate(context)
    }

    nonisolated private static func decodeProfile(_ snapshot: String) -> TranslationStyleProfile? {
        guard let data = snapshot.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TranslationStyleProfile.self, from: data)
    }
}
