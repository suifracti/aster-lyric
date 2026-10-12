import Combine
import Foundation

/// A read-only line projection shared by every maintained surface. It is
/// intentionally independent of the source LyricsDocument: the original
/// text and legacy kana/romaji columns are never mutated in persistence.
public struct ReadingProjection: Equatable, Sendable {
    public let lyricsVersionID: UUID?
    public let sourceContentHash: String?
    public let readingVersionID: UUID?
    public let representationID: String?
    public let sourceKind: ReadingVersionSourceKind?
    public let lines: [ReadingLineResult]
    public let isNoSelection: Bool

    public static let empty = ReadingProjection(
        lyricsVersionID: nil,
        sourceContentHash: nil,
        readingVersionID: nil,
        representationID: nil,
        sourceKind: nil,
        lines: [],
        isNoSelection: false
    )

    public init(
        lyricsVersionID: UUID?,
        sourceContentHash: String?,
        readingVersionID: UUID?,
        representationID: String?,
        sourceKind: ReadingVersionSourceKind? = nil,
        lines: [ReadingLineResult],
        isNoSelection: Bool
    ) {
        self.lyricsVersionID = lyricsVersionID
        self.sourceContentHash = sourceContentHash
        self.readingVersionID = readingVersionID
        self.representationID = representationID
        self.sourceKind = sourceKind
        self.lines = lines.sorted { $0.lineIndex < $1.lineIndex }
        self.isNoSelection = isNoSelection
    }

    public func applying(to base: [LyricLine], scriptConversion: ScriptConversionID = .none) -> [LyricLine] {
        guard !base.isEmpty else { return base }
        let byIndex = isNoSelection
            ? [:]
            : Dictionary(uniqueKeysWithValues: lines.map { ($0.lineIndex, $0) })
        return base.enumerated().map { index, source in
            var line = source
            if isNoSelection {
                // "No reading version" is a session projection choice, not a
                // destructive edit. Clear only the copied auxiliary layers so
                // legacy/provider kana and romaji cannot leak through while
                // the persisted lyric line remains untouched.
                line.kanaText = nil
                line.romajiText = nil
                line.rubyTokens = nil
                line.readingRepresentationID = nil
            } else if let reading = byIndex[index], reading.originalText == source.originalText {
                switch representationID.flatMap(ReadingRepresentationID.init(rawValue:)) {
                case .kana:
                    line = ReadingRubyCorrection.project(
                        reading,
                        onto: line,
                        preferStoredReadingText: sourceKind == .manualEdit
                    )
                    line.readingRepresentationID = ReadingRepresentationID.kana.rawValue
                case .romaji:
                    line.romajiText = reading.readingText
                    line.readingRepresentationID = ReadingRepresentationID.romaji.rawValue
                case .pinyinToneMarks, .pinyinToneNumbers, .pinyinPlain:
                    line.romajiText = reading.readingText
                    line.readingRepresentationID = representationID
                    let tokens = reading.tokens.map {
                        LyricRubyToken(id: $0.id, surface: $0.surface, ruby: $0.reading)
                    }
                    if tokens.map(\.surface).joined() == line.originalText {
                        line.rubyTokens = tokens
                    }
                case nil:
                    break
                }
            }
            if let converted = convertedText(source.originalText, using: scriptConversion), converted != source.originalText {
                line.readingSurfaceText = converted
                if let spans = source.timedSpans {
                    line.timedSpans = ReadingScriptConverter.convertSpans(
                        spans,
                        originalText: source.originalText,
                        convertedText: converted,
                        using: scriptConversion
                    )
                }
            } else {
                line.readingSurfaceText = nil
            }
            return line
        }
    }

    private func convertedText(_ text: String, using conversion: ScriptConversionID) -> String? {
        guard conversion != .none else { return nil }
        return ReadingScriptConverter.convert(text, using: conversion)
    }
}

/// Main-actor coordinator for the one shared reading projection. It owns one
/// cancellable generation task, not a timer or a second lyrics session.
@MainActor
public final class ReadingSessionController: ObservableObject {
    @Published public private(set) var projection: ReadingProjection = .empty {
        didSet { projectionRevision &+= 1 }
    }
    private var projectionRevision: UInt64 = 0
    @Published public private(set) var availableVersions: [StoredReadingVersion] = []
    @Published public private(set) var selectedVersion: StoredReadingVersion?
    @Published public private(set) var isGenerating = false
    @Published public private(set) var message = ""

    private let repository: any ReadingRepository
    private let settings: AppSettingsStore
    private let aiCandidateService: AIReadingCandidateService
    private var loadTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var sourceLyricsVersionID: UUID?
    private var sourceContentHash: String?
    private var sourceLines: [ReadingInputLine] = []
    private var sourceLanguage: String?
    private var sourceTrackStableKey: String?
    private var sourceArtistDisplay: String?
    private var noSelectionSource: (UUID, String)?

    public init(
        repository: any ReadingRepository,
        settings: AppSettingsStore,
        aiCandidateService: AIReadingCandidateService = AIReadingCandidateService()
    ) {
        self.repository = repository
        self.settings = settings
        self.aiCandidateService = aiCandidateService
    }

    deinit {
        loadTask?.cancel()
        generationTask?.cancel()
    }

    public var currentRevision: UInt64 { projectionRevision }
    public var hasSource: Bool { sourceLyricsVersionID != nil && sourceContentHash != nil }
    public var preferredRepresentation: ReadingRepresentationID { settings.readingPreferences.japaneseRepresentation }

    public func synchronize(
        lyricsVersionID: UUID?,
        sourceContentHash: String?,
        lines: [LyricLine],
        language: String?,
        trackStableKey: String? = nil,
        artistDisplay: String? = nil
    ) {
        let nextLines = lines.enumerated().map { ReadingInputLine(lineIndex: $0.offset, originalText: $0.element.originalText) }
        let changed = sourceLyricsVersionID != lyricsVersionID
            || self.sourceContentHash != sourceContentHash
            || sourceLines != nextLines
            || sourceLanguage != language
            || sourceTrackStableKey != trackStableKey
            || sourceArtistDisplay != artistDisplay
        guard changed || !hasSource else { return }

        revision &+= 1
        let token = revision
        loadTask?.cancel()
        generationTask?.cancel()
        isGenerating = false
        sourceLyricsVersionID = lyricsVersionID
        self.sourceContentHash = sourceContentHash
        sourceLines = nextLines
        sourceLanguage = language
        sourceTrackStableKey = trackStableKey
        sourceArtistDisplay = artistDisplay
        availableVersions = []
        selectedVersion = nil
        projection = .empty
        message = ""

        guard let lyricsVersionID, let sourceContentHash, !nextLines.isEmpty else { return }
        if noSelectionSource?.0 != lyricsVersionID || noSelectionSource?.1 != sourceContentHash {
            noSelectionSource = nil
        }
        guard noSelectionSource == nil else { return }
        loadTask = Task { [weak self, repository] in
            do {
                let versions = try await repository.loadReadingVersions(
                    lyricsVersionID: lyricsVersionID,
                    representationID: nil,
                    sourceContentHash: sourceContentHash
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.revision == token,
                          self.sourceLyricsVersionID == lyricsVersionID,
                          self.sourceContentHash == sourceContentHash,
                          self.noSelectionSource == nil else { return }
                    self.availableVersions = versions.filter(\.isComplete)
                    self.selectedVersion = self.chooseVersion(from: self.availableVersions)
                    self.rebuildProjection()
                    if self.selectedVersion == nil,
                       self.settings.readingPreferences.automaticGeneration,
                       self.noSelectionSource == nil {
                        self.generateCurrentReading()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.revision == token else { return }
                    self.message = "读音版本暂不可用"
                }
            }
        }
    }

    public func clear() {
        revision &+= 1
        loadTask?.cancel()
        generationTask?.cancel()
        isGenerating = false
        sourceLyricsVersionID = nil
        sourceContentHash = nil
        sourceLines = []
        sourceLanguage = nil
        sourceTrackStableKey = nil
        sourceArtistDisplay = nil
        noSelectionSource = nil
        availableVersions = []
        selectedVersion = nil
        projection = .empty
        message = ""
    }

    public func reload() {
        guard let id = sourceLyricsVersionID, let hash = sourceContentHash else { return }
        let lines = sourceLines.map { LyricLine(timestamp: 0, originalText: $0.originalText) }
        let language = sourceLanguage
        let trackStableKey = sourceTrackStableKey
        let artistDisplay = sourceArtistDisplay
        sourceLyricsVersionID = nil
        synchronize(
            lyricsVersionID: id,
            sourceContentHash: hash,
            lines: lines,
            language: language,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay
        )
    }

    public func selectNone() {
        guard let id = sourceLyricsVersionID, let hash = sourceContentHash else { return }
        revision &+= 1
        loadTask?.cancel()
        generationTask?.cancel()
        isGenerating = false
        noSelectionSource = (id, hash)
        selectedVersion = nil
        projection = ReadingProjection(
            lyricsVersionID: id,
            sourceContentHash: hash,
            readingVersionID: nil,
            representationID: nil,
            lines: [],
            isNoSelection: true
        )
        message = "本次播放不使用读音版本"
    }

    public func select(versionID: UUID) {
        guard let version = availableVersions.first(where: { $0.record.id == versionID }), !version.record.isArchived else { return }
        revision &+= 1
        let token = revision
        noSelectionSource = nil
        selectedVersion = version
        rebuildProjection()
        persistAdoption(versionID: versionID, token: token)
    }

    public func restoreRecommended() {
        revision &+= 1
        let token = revision
        noSelectionSource = nil
        selectedVersion = chooseVersion(from: availableVersions)
        rebuildProjection()
        if let versionID = selectedVersion?.record.id {
            persistAdoption(versionID: versionID, token: token)
        }
    }

    public func generateCurrentReading(representationID: ReadingRepresentationID? = nil) {
        guard let lyricsVersionID = sourceLyricsVersionID,
              let sourceContentHash,
              !sourceLines.isEmpty else {
            message = "当前没有可生成读音的歌词版本"
            return
        }
        let representation = representationID ?? (isChineseSource ? settings.readingPreferences.pinyinRepresentation : settings.readingPreferences.japaneseRepresentation)
        let engineID: ReadingEngineID
        if representation == .pinyinToneMarks || representation == .pinyinToneNumbers || representation == .pinyinPlain {
            engineID = .chinesePinyin
        } else {
            engineID = ReadingEngineID(rawValue: settings.readingPreferences.japaneseEngineID) ?? .japaneseContextual
        }
        revision &+= 1
        let token = revision
        generationTask?.cancel()
        isGenerating = true
        message = settings.readingPreferences.aiAssistedCandidate
            ? "正在生成本地上下文读音（AI 候选仅在明确调用时使用）…"
            : "正在生成读音…"
        let request = ReadingGenerationRequest(
            lyricsVersionID: lyricsVersionID,
            sourceContentHash: sourceContentHash,
            lines: sourceLines,
            languageHint: sourceLanguage,
            trackStableKey: sourceTrackStableKey,
            artistDisplay: sourceArtistDisplay,
            nearbyContext: sourceLines.map(\.originalText),
            representationID: representation
        )
        let engine = ReadingEngineRegistry.make(
            engineID,
            userEntries: settings.readingUserDictionary.load()
        )
        let uncertaintyPolicy = settings.readingPreferences.uncertaintyPolicy
        let aiEnabled = settings.readingPreferences.aiAssistedCandidate
        let aiConfiguration = settings.aiTranslationConfiguration
        generationTask = Task { [weak self, repository] in
            do {
                let localResult = try await engine.generate(request)
                let result: ReadingGenerationResult
                if aiEnabled,
                   engineID == .japaneseContextual {
                    // AI is an explicit, candidate-only refinement. If the
                    // optional request fails, the deterministic local result
                    // remains usable and can still be saved for confirmation.
                    result = (try? await self?.aiCandidateService.refine(
                        result: localResult,
                        request: request,
                        configuration: aiConfiguration
                    )) ?? localResult
                } else {
                    result = localResult
                }
                guard !Task.isCancelled else { return }
                guard result.lines.count == request.lines.count,
                      result.lines.map(\.lineIndex) == Array(request.lines.indices),
                      result.lines.enumerated().allSatisfy({ $0.element.originalText == request.lines[$0.offset].originalText }) else {
                    throw ReadingRepositoryError.invalidLines("生成结果与原文行不一致")
                }
                let requiresConfirmation = self?.requiresConfirmation(
                    result: result,
                    policy: uncertaintyPolicy
                ) ?? true
                let now = Date()
                let record = ReadingVersionRecord(
                    id: UUID(),
                    lyricsVersionID: lyricsVersionID,
                    sourceContentHash: sourceContentHash,
                    engineID: result.engineID.rawValue,
                    representationID: result.representationID.rawValue,
                    language: result.language,
                    createdAt: now,
                    updatedAt: now,
                    isMachineGenerated: true,
                    isManuallyEdited: false,
                    isCurrent: false,
                    isLocked: false,
                    isArchived: false,
                    parentVersionID: nil,
                    confidence: result.confidence,
                    warningMetadata: result.warnings,
                    contextHash: result.contextHash
                )
                let stored = try await repository.saveReadingVersion(ReadingVersionSaveRequest(record: record, lines: result.lines))
                guard !Task.isCancelled,
                      let self,
                      self.revision == token,
                      self.sourceLyricsVersionID == lyricsVersionID,
                      self.sourceContentHash == sourceContentHash else { return }
                if !requiresConfirmation {
                    try await repository.adoptReadingVersion(versionID: stored.record.id)
                }
                guard !Task.isCancelled,
                      self.revision == token,
                      self.sourceLyricsVersionID == lyricsVersionID,
                      self.sourceContentHash == sourceContentHash else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.revision == token,
                          self.sourceLyricsVersionID == lyricsVersionID,
                          self.sourceContentHash == sourceContentHash else { return }
                    self.isGenerating = false
                    self.noSelectionSource = nil
                    self.availableVersions.insert(stored, at: 0)
                    if !requiresConfirmation {
                        self.selectedVersion = stored
                    }
                    self.rebuildProjection()
                    self.message = requiresConfirmation
                        ? "读音候选已保存，请确认后采用"
                        : "读音已保存为新的本地版本"
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.revision == token else { return }
                    self.isGenerating = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.revision == token else { return }
                    self.isGenerating = false
                    self.message = "读音生成失败：\(error.localizedDescription)"
                }
            }
        }
    }

    public func adopt(versionID: UUID) {
        guard let version = availableVersions.first(where: { $0.record.id == versionID }) else { return }
        revision &+= 1
        let token = revision
        loadTask?.cancel()
        isGenerating = false
        noSelectionSource = nil
        selectedVersion = version
        rebuildProjection()
        persistAdoption(versionID: versionID, token: token)
    }

    public func lockSelected() {
        guard let version = selectedVersion else { return }
        Task { [weak self, repository] in
            do {
                try await repository.markReadingLocked(versionID: version.record.id, locked: true)
                await MainActor.run { [weak self] in self?.reload() }
            } catch {
                await MainActor.run { [weak self] in self?.message = "读音版本未能锁定" }
            }
        }
    }

    public func archive(versionID: UUID) {
        Task { [weak self, repository] in
            do {
                try await repository.archiveReadingVersion(versionID: versionID, archived: true)
                await MainActor.run { [weak self] in self?.reload() }
            } catch {
                await MainActor.run { [weak self] in self?.message = "读音版本未能归档" }
            }
        }
    }

    public func delete(versionID: UUID) {
        Task { [weak self, repository] in
            do {
                try await repository.deleteReadingVersion(versionID: versionID)
                await MainActor.run { [weak self] in self?.reload() }
            } catch {
                await MainActor.run { [weak self] in self?.message = "读音版本未能删除；锁定版本不会被删除" }
            }
        }
    }

    public func correctRuby(surface: String, reading: String, trackKey: String,
                            lyricsVersionID: UUID, visibleLines: [LyricLine], expectedReadingVersionID: UUID? = nil) async throws {
        guard sourceTrackStableKey == trackKey, sourceLyricsVersionID == lyricsVersionID,
              let hash = sourceContentHash,
              sourceLines.map(\.originalText) == visibleLines.map(\.originalText) else {
            throw ReadingRepositoryError.sourceContentMismatch
        }
        guard selectedVersion?.record.id == expectedReadingVersionID else {
            throw ReadingRepositoryError.invalidLines("读音版本已变化，请重新点击假名后修改")
        }
        let entry = try ReadingRubyCorrection.entry(surface: surface, reading: reading, trackStableKey: trackKey)
        revision &+= 1
        let token = revision
        let pendingGeneration = generationTask
        generationTask = nil
        pendingGeneration?.cancel()
        loadTask?.cancel()
        isGenerating = false
        if let pendingGeneration {
            await pendingGeneration.value
        }
        guard revision == token, sourceLyricsVersionID == lyricsVersionID else {
            throw ReadingRepositoryError.sourceContentMismatch
        }
        let parentID = selectedVersion?.record.id
        let edited = try await Task.detached(priority: .userInitiated) {
            try ReadingRubyCorrection.lines(visibleLines, entry: entry)
        }.value
        guard revision == token, sourceLyricsVersionID == lyricsVersionID else { throw ReadingRepositoryError.sourceContentMismatch }
        let now = Date()
        let record = ReadingVersionRecord(id: UUID(), lyricsVersionID: lyricsVersionID,
            sourceContentHash: hash, engineID: ReadingEngineID.japaneseContextual.rawValue,
            representationID: ReadingRepresentationID.kana.rawValue, sourceKind: .manualEdit,
            language: .japanese, createdAt: now, updatedAt: now, isMachineGenerated: false,
            isManuallyEdited: true, isCurrent: false, isLocked: false, isArchived: false,
            parentVersionID: parentID, confidence: edited.map(\.confidence).min() ?? 0,
            warningMetadata: [], contextHash: ReadingEngineSupport.hashContext([trackKey, surface, entry.reading]))
        let saved = try await repository.saveReadingVersion(ReadingVersionSaveRequest(record: record, lines: edited))
        guard revision == token, sourceLyricsVersionID == lyricsVersionID else { throw ReadingRepositoryError.sourceContentMismatch }
        try await repository.adoptReadingVersion(versionID: saved.record.id)
        // Commit the remembered rule only after the new version was saved and adopted.
        settings.readingUserDictionary.rememberSongCorrection(entry)
        guard revision == token else { return }
        noSelectionSource = nil
        let adopted = StoredReadingVersion(record: saved.record.with(isCurrent: true), lines: saved.lines)
        availableVersions = availableVersions.map { version in
            guard version.record.representationID == saved.record.representationID else { return version }
            return StoredReadingVersion(record: version.record.with(isCurrent: false), lines: version.lines)
        }
        availableVersions.insert(adopted, at: 0)
        selectedVersion = adopted
        rebuildProjection()
        message = "已保存这首歌的人工读音版本"
    }

    public func saveManualEdit(_ version: StoredReadingVersion, readingLines: [ReadingLineResult]) async throws {
        guard let lyricsVersionID = sourceLyricsVersionID,
              let sourceHash = sourceContentHash,
              version.record.lyricsVersionID == lyricsVersionID,
              version.record.sourceContentHash == sourceHash else {
            throw ReadingRepositoryError.sourceContentMismatch
        }

        // An explicit edit supersedes an in-flight automatic generation. Wait
        // for its persistence call to leave the repository before saving and
        // adopting the user's child version, so a late auto-adoption cannot
        // replace this selection afterward.
        revision &+= 1
        let token = revision
        let pendingGeneration = generationTask
        generationTask = nil
        pendingGeneration?.cancel()
        loadTask?.cancel()
        isGenerating = false
        if let pendingGeneration {
            await pendingGeneration.value
        }
        guard revision == token,
              sourceLyricsVersionID == lyricsVersionID,
              sourceContentHash == sourceHash else {
            throw ReadingRepositoryError.sourceContentMismatch
        }

        let parentLines = Dictionary(uniqueKeysWithValues: version.lines.map { ($0.lineIndex, $0) })
        let reconciledLines = readingLines.map { line -> ReadingLineResult in
            guard let parent = parentLines[line.lineIndex] else { return line }
            // The editor supplies no positional edit map. An unchanged line
            // keeps its exact saved tokens; any changed whole-line string
            // invalidates that row's tokens rather than guessing which repeated
            // word or grapheme they belong to.
            return line.replacingTokens(line.readingText == parent.readingText ? parent.tokens : [])
        }
        let now = Date()
        let record = ReadingVersionRecord(
            id: UUID(),
            lyricsVersionID: version.record.lyricsVersionID,
            sourceContentHash: version.record.sourceContentHash,
            engineID: version.record.engineID,
            representationID: version.record.representationID,
            sourceKind: .manualEdit,
            language: version.record.language,
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: false,
            isManuallyEdited: true,
            isCurrent: false,
            isLocked: false,
            isArchived: false,
            parentVersionID: version.record.id,
            confidence: 1,
            warningMetadata: [],
            contextHash: version.record.contextHash
        )
        do {
            let saved = try await repository.saveReadingVersion(ReadingVersionSaveRequest(record: record, lines: reconciledLines))
            try await repository.adoptReadingVersion(versionID: saved.record.id)
            guard revision == token,
                  sourceLyricsVersionID == lyricsVersionID,
                  sourceContentHash == sourceHash else { return }
            let adopted = StoredReadingVersion(record: saved.record.with(isCurrent: true), lines: saved.lines)
            availableVersions = availableVersions.map { existing in
                guard existing.record.representationID == adopted.record.representationID else { return existing }
                return StoredReadingVersion(record: existing.record.with(isCurrent: false), lines: existing.lines)
            }
            availableVersions.insert(adopted, at: 0)
            selectedVersion = adopted
            rebuildProjection()
            message = "人工读音已保存"
        } catch {
            if revision == token { message = "人工读音保存失败：\(error.localizedDescription)" }
            throw error
        }
    }

    public func project(onto lines: [LyricLine]) -> [LyricLine] {
        projection.applying(to: lines, scriptConversion: settings.readingPreferences.scriptConversion)
    }

    private func persistAdoption(versionID: UUID, token: UInt64) {
        let pendingGeneration = generationTask
        generationTask = nil
        pendingGeneration?.cancel()
        isGenerating = false
        Task { [weak self, repository] in
            do {
                if let pendingGeneration {
                    await pendingGeneration.value
                }
                guard let self, self.revision == token else { return }
                try await repository.adoptReadingVersion(versionID: versionID)
                await MainActor.run { [weak self] in
                    guard let self, self.revision == token else { return }
                    self.message = ""
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.revision == token else { return }
                    self.message = "读音版本未能采用"
                }
            }
        }
    }

    private func requiresConfirmation(
        result: ReadingGenerationResult,
        policy: ReadingUncertaintyPolicy
    ) -> Bool {
        let hardWarnings: Set<ReadingWarningCode> = [
            .languageNeedsConfirmation,
            .unknownToken,
            .ambiguousReading,
            .aiCandidateOnly
        ]
        if !Set(result.warnings).isDisjoint(with: hardWarnings) {
            return true
        }
        if result.lines.contains(where: { !Set($0.warnings).isDisjoint(with: hardWarnings) }) {
            return true
        }
        return policy == .needsConfirmation && result.confidence < 0.9
    }

    private func chooseVersion(from versions: [StoredReadingVersion]) -> StoredReadingVersion? {
        let active = versions.filter { !$0.record.isArchived }
        let preferred = isChineseSource ? settings.readingPreferences.pinyinRepresentationID : settings.readingPreferences.japaneseRepresentationID
        let locked = active.filter(\.record.isLocked)
        let eligible = active.filter { !requiresConfirmation($0) }
        return active.filter { $0.record.isCurrent && $0.record.isManuallyEdited }
            .max(by: { $0.record.updatedAt < $1.record.updatedAt })
            ?? locked.first(where: { $0.record.representationID == preferred })
            ?? eligible.first(where: { $0.record.representationID == preferred && $0.record.isCurrent })
            ?? eligible.first(where: { $0.record.representationID == preferred })
            ?? locked.first
            ?? eligible.first
    }

    private func requiresConfirmation(_ version: StoredReadingVersion) -> Bool {
        let hardWarnings: Set<ReadingWarningCode> = [
            .languageNeedsConfirmation,
            .unknownToken,
            .ambiguousReading,
            .aiCandidateOnly
        ]
        guard Set(version.record.warningMetadata).isDisjoint(with: hardWarnings),
              version.lines.allSatisfy({ Set($0.warnings).isDisjoint(with: hardWarnings) }) else {
            return true
        }
        return settings.readingPreferences.uncertaintyPolicy == .needsConfirmation
            && version.record.confidence < 0.9
    }

    private func rebuildProjection() {
        projection = ReadingProjection(
            lyricsVersionID: sourceLyricsVersionID,
            sourceContentHash: sourceContentHash,
            readingVersionID: selectedVersion?.record.id,
            representationID: selectedVersion?.record.representationID,
            sourceKind: selectedVersion?.record.sourceKind,
            lines: selectedVersion?.lines ?? [],
            isNoSelection: noSelectionSource != nil
        )
    }

    private var isChineseSource: Bool {
        let hint = sourceLanguage?.lowercased() ?? ""
        if hint.contains("zh") || hint.contains("hans") || hint.contains("hant") || hint == "cn" {
            return true
        }
        let allText = sourceLines.map(\.originalText).joined()
        return LyricsLanguageGate.containsHan(allText) && !LyricsLanguageGate.containsKana(allText)
    }
}
