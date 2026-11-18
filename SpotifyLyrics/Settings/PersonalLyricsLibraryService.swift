import Foundation
import AppKit
import Combine

struct LastOpenedLyricsRecord: Codable, Equatable {
    static let defaultsKey = "library.lastOpenedLyricsRecord.v1"
    let trackKey: String
    let title: String
    let artist: String
    var passage: LibraryPassageTarget? = nil
    var edition: String? = nil

    var readingID: String { "\(trackKey).\(String(describing: passage?.source))" }

    var readingDetail: String {
        let row = passage?.readingPosition.flatMap { $0.topLineIndex ?? $0.lineIndex }
        return [artist, edition ?? passage?.source.label, row.map { "第 \($0 + 1) 行" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum RecentLyricsReadings {
    static let defaultsKey = "library.recentReadings.v1"

    static func records(from data: Data, legacy: LastOpenedLyricsRecord?) -> [LastOpenedLyricsRecord] {
        if let stored = try? JSONDecoder().decode([LastOpenedLyricsRecord].self, from: data), !stored.isEmpty {
            return stored
        }
        if let legacy, legacy.passage != nil { return [legacy] }
        return []
    }

    static func note(_ record: LastOpenedLyricsRecord, in defaults: UserDefaults, legacy: LastOpenedLyricsRecord?) {
        let current = records(from: defaults.data(forKey: defaultsKey) ?? Data(), legacy: legacy)
        let next = Array(([record] + current.filter { $0.readingID != record.readingID }).prefix(5))
        if current != next || defaults.data(forKey: defaultsKey) == nil,
           let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

@MainActor
public final class PersonalLyricsLibraryService: ObservableObject {
    @Published public private(set) var entries: [PersonalLyricsLibraryEntry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var statusMessage: String = ""
    private var searchQuery = ""
    private var loadedSearchQuery: String?
    private var loadedPassages: [String: LibraryPassageHit] = [:]

    @Published public var selectedTrackDetail: PersonalLyricsLibraryTrackDetail?
    @Published private var currentTrackDetail: PersonalLyricsLibraryTrackDetail?
    private var currentTrackStableKey: String?
    private var currentTrackRequestID = UUID()
    private var detailRequestID = UUID()
    private var listTask: Task<Void, Never>?
    @Published private(set) var selectedTrackIssue: String?
    private var requestedTrackStableKey: String?
    @Published public var importPreview: PersonalLibraryImportPreview?
    @Published public var pendingImportPackage: PersonalLyricsLibraryPackage?
    @Published public var showImportPreviewSheet = false

    @Published public var dataImportPreview: PersonalDataImportPreview?
    @Published public var pendingDataPackage: PersonalDataPackage?
    @Published public var showDataImportPreviewSheet = false
    @Published private(set) var personalDataNotice: String?

    @Published public private(set) var syncFolderURL: URL?
    @Published public private(set) var isSyncing = false

    @Published public var revisionDraft: LibraryLyricsRevisionDraft?
    @Published public var translationRevisionDraft: LibraryTranslationRevisionDraft?
    @Published public var readingRevisionDraft: LibraryReadingRevisionDraft?
    @Published public var timingRevisionDraft: LibraryTimingRevisionDraft?
    @Published public private(set) var revisionError: String?
    @Published public private(set) var revisionBusy = false

    struct VersionLabelDraft: Identifiable {
        let kind: String
        let versionID: UUID
        let originalTitle: String
        let title: String
        let note: String
        var id: String { "\(kind).\(versionID.uuidString)" }
        static func key(_ kind: String, _ id: UUID) -> String { "personalLibrary.versionLabel.\(kind).\(id.uuidString)" }
        var storageKey: String { Self.key(kind, versionID) }
        static func stored(kind: String, versionID: UUID, originalTitle: String) -> Self {
            let key = key(kind, versionID)
            return Self(kind: kind, versionID: versionID, originalTitle: originalTitle,
                        title: UserDefaults.lyricsQ.string(forKey: key + ".title") ?? "",
                        note: UserDefaults.lyricsQ.string(forKey: key + ".note") ?? "")
        }
    }
    struct TranslationDeletion: Identifiable {
        let version: PersonalTranslationVersionItem
        let trackStableKey: String
        var id: UUID { version.id }
    }
    @Published var versionLabelDraft: VersionLabelDraft?
    @Published var translationDeletionCandidate: TranslationDeletion?
    @Published var comparison: LibraryCompareRequest?

    func presentComparison(_ source: LibraryPassageSource, detail: PersonalLyricsLibraryTrackDetail, reading: LibraryPassageTarget? = nil) {
        comparison = makeComparison(source, detail: detail, reading: reading)
    }

    func playingComparison(identity: TrackIdentity, lyricsID: UUID, selected: UUID?,
                           versions: [StoredTranslationVersion]) async throws -> LibraryCompareRequest? {
        let matching = versions.filter { $0.record.lyricsVersionID == lyricsID }
        guard matching.count > 1,
              let detail = try await repository.loadPersonalLibraryTrackDetail(stableKey: identity.stableKey),
              detail.lyricsVersions.contains(where: { $0.id == lyricsID }) else { return nil }
        let base = matching.first(where: { $0.record.id == selected }) ?? matching.first(where: { !$0.isDraft }) ?? matching[0]
        let allowed = matching.filter { $0.isComplete && !$0.isArchived && (!$0.isDraft || !$0.record.isLocked) }.map { $0.record.id }
        let playing = LibraryCompareRequest.Playing(identity: identity, lyricsID: lyricsID, selectedID: selected, adoptable: Set(allowed))
        return makeComparison(.translation(base.record.id), detail: detail, playing: playing,
                              available: Dictionary(uniqueKeysWithValues: matching.map { ($0.record.id, $0) }))
    }

    private func makeComparison(_ source: LibraryPassageSource, detail: PersonalLyricsLibraryTrackDetail,
                                playing: LibraryCompareRequest.Playing? = nil,
                                available: [UUID: StoredTranslationVersion]? = nil,
                                reading: LibraryPassageTarget? = nil) -> LibraryCompareRequest? {
        let choices: [LibraryCompareVersion], selected: UUID
        switch source {
        case let .original(id):
            selected = id
            choices = detail.lyricsVersions.map {
                .init(id: $0.id, title: versionTitle("lyrics", $0.id, DatabaseSourceIdentifier.displayName(for: $0.source)),
                      updatedAt: $0.updatedAt, isCurrent: $0.isCurrent, parentID: $0.parentVersionID)
            }
        case let .translation(id):
            selected = id
            choices = detail.translationVersions.compactMap { item in
                let stored = available?[item.id]
                if available != nil && stored == nil { return nil }
                let name = stored?.record.translationSourceTitle ?? AITranslationSourceKind(rawValue: item.sourceKind)?.displayName ?? "译文"
                let current = playing.map { $0.selectedID == item.id } ?? item.isCurrent
                return .init(id: item.id, title: versionTitle("translation", item.id, name), updatedAt: item.updatedAt,
                             isCurrent: current, parentID: item.parentVersionID, translation: item)
            }
        default: return nil
        }
        return .init(entry: detail.entry, baseID: selected, versions: choices, playing: playing, reading: reading)
    }

    func compare(trackKey: String, base: LibraryCompareVersion, with reference: LibraryCompareVersion) async throws -> LibraryVersionComparison {
        guard let pair = try await repository.readPassagePair(trackKey: trackKey, base: base.source,
                                                              reference: reference.source) else {
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        try Task.checkCancellation()
        let translations = base.translation != nil
        return await Task.detached(priority: .userInitiated) {
            LibraryVersionComparison(base: pair.0, reference: pair.1, translations: translations)
        }.value
    }

    struct VersionPreview: Identifiable {
        let id = UUID()
        let title: String
        let text: String
        var passage: LibraryPassageTarget? = nil
    }
    @Published var versionPreview: VersionPreview?
    func previewTimingVersion(lyricsID: UUID, entry: PersonalLyricsLibraryEntry, timingID: UUID) {
        Task {
            do {
                let track = entry.libraryTrack
                try await repository.prepare()
                guard let source = try await repository.loadEditableVersion(versionID: lyricsID, track: track, identity: TrackIdentity(track: track)),
                      let timing = try await repository.loadPersonalLibraryTimingVersion(id: timingID),
                      let draft = LibraryTimingRevisionDraft(track: track, lyricsSource: source, source: timing)
                else { throw LyricsEditingRepositoryError.sourceNotFound }
                let text = draft.lines.map { line in
                    line.spans.map { String(format: "%.2f–%.2f ", $0.startTime, $0.endTime) + $0.source.text }.joined(separator: " ")
                }.joined(separator: "\n")
                versionPreview = VersionPreview(title: entry.title, text: text)
            } catch { statusMessage = "预览失败：" + error.localizedDescription }
        }
    }

    func presentPassage(_ target: LibraryPassageTarget) {
        versionPreview = VersionPreview(title: "", text: "", passage: target)
    }

    func readPassage(_ target: LibraryPassageTarget, recordOpening: Bool = true, includeEditions: Bool = false) async throws -> LibraryPassagePage? {
        let page = try await repository.readLibraryPassage(target, includeEditions: includeEditions)
        try Task.checkCancellation()
        if let page, recordOpening { rememberReading(page, openedFrom: target) }
        return page
    }

    func readingEditionTitle(_ edition: LibraryPassageEdition) -> String {
        guard let id = edition.source.versionID else { return edition.title }
        return versionTitle(edition.kind.rawValue, id, edition.title)
    }

    private func versionTitle(_ kind: String, _ id: UUID, _ fallback: String) -> String {
        let title = defaults.string(forKey: VersionLabelDraft.key(kind, id) + ".title") ?? ""
        return title.isEmpty ? fallback : title
    }

    func rememberReading(_ page: LibraryPassagePage, openedFrom target: LibraryPassageTarget,
                         position: LibraryPassageTarget.ReadingPosition? = nil) {
        guard !page.lines.isEmpty else { return }
        let resolved = LibraryPassageTarget(trackKey: page.entry.trackStableKey, source: page.resolvedSource ?? target.source,
                                            find: target.find, lineIndex: target.lineIndex, savedQuote: target.savedQuote,
                                            readingPosition: position ?? target.readingPosition,
                                            excerptEndLineIndex: target.excerptEndLineIndex)
        let version = resolved.source.versionID.flatMap { id -> String? in
            let kind: String
            switch resolved.source {
            case .original, .attached: kind = "lyrics"
            case .translation: kind = "translation"
            case .reading: kind = "reading"
            case .selected: return nil
            }
            let title = defaults.string(forKey: VersionLabelDraft.key(kind, id) + ".title") ?? ""
            return title.isEmpty ? nil : title
        }
        rememberOpenedRecord(page.entry, passage: resolved, edition: version ?? page.edition)
    }

    public func beginRevision(versionID: UUID, entry: PersonalLyricsLibraryEntry) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let track = Track(title: entry.title, artist: entry.artist, album: entry.album ?? "", duration: entry.duration, isrc: entry.isrc, spotifyId: entry.spotifyTrackID, artworkURL: entry.artworkURL, spotifyURL: entry.spotifyURI.flatMap(URL.init(string:)))
                try await repository.prepare()
                guard let source = try await repository.loadEditableVersion(versionID: versionID, track: track, identity: TrackIdentity(track: track)) else {
                    throw LyricsEditingRepositoryError.sourceNotFound
                }
                revisionDraft = LibraryLyricsRevisionDraft(track: track, source: source)
            } catch {
                statusMessage = "打开编辑失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveRevision(_ draft: LibraryLyricsRevisionDraft, confirmingTimingLoss: Bool = false,
                             applyToPlayback: ((UUID) async throws -> Bool)? = nil) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let result = try await repository.saveManualEdit(
                    draft.saveRequest(confirmingTimingLoss: confirmingTimingLoss)
                )
                guard let version = result.lyricsVersion else { throw LyricsEditingRepositoryError.sourceNotFound }
                _ = try await applyToPlayback?(version.record.id)
                revisionDraft = nil
                refreshTrackDetail(stableKey: draft.source.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    public func beginTranslationRevision(version: PersonalTranslationVersionItem, entry: PersonalLyricsLibraryEntry,
                                         reading: LibraryPassageTarget? = nil) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                translationRevisionDraft = try await translationDraft(for: version, entry: entry,
                    openingLineIndex: reading?.readingLine(for: version.id, trackKey: entry.id))
            } catch {
                statusMessage = "打开译文编辑失败：\(error.localizedDescription)"
            }
        }
    }

    func translationDraft(for version: PersonalTranslationVersionItem, entry: PersonalLyricsLibraryEntry,
                          picking indices: Set<Int> = [], from reference: PersonalTranslationVersionItem? = nil,
                          openingLineIndex: Int? = nil) async throws -> LibraryTranslationRevisionDraft {
        let track = entry.libraryTrack
        try await repository.prepare()
        guard let lyrics = try await repository.loadEditableVersion(versionID: version.lyricsVersionID, track: track,
                                                                    identity: TrackIdentity(track: track)) else {
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        func stored(_ item: PersonalTranslationVersionItem) async throws -> StoredTranslationVersion {
            guard item.lyricsVersionID == lyrics.record.id else { throw LyricsEditingRepositoryError.sourceContentMismatch }
            let versions = try await repository.loadTranslationVersions(lyricsVersionID: item.lyricsVersionID,
                targetLanguage: item.targetLanguage, sourceContentHash: lyrics.sourceContentHash)
            guard let match = versions.first(where: { $0.record.id == item.id }) else { throw TranslationRepositoryError.versionNotFound }
            return match
        }
        var draft = LibraryTranslationRevisionDraft(track: track, lyricsSource: lyrics, source: try await stored(version),
            preferredLanguage: defaults.string(forKey: AppSettingsStore.Key.aiTargetLanguage) ?? "zh-Hans")
        if let reference { try draft.takeLines(indices, from: await stored(reference)) }
        draft.openingLineIndex = openingLineIndex.flatMap { draft.lines.indices.contains($0) ? $0 : nil }
        return draft
    }

    public func saveTranslationRevision(_ draft: LibraryTranslationRevisionDraft, onSaved: ((StoredTranslationVersion) -> Void)? = nil) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let result = try await repository.saveManualEdit(draft.saveRequest())
                guard let version = result.translationVersion else { throw LyricsEditingRepositoryError.sourceNotFound }
                onSaved?(version)
                translationRevisionDraft = nil
                refreshTrackDetail(stableKey: draft.lyricsSource.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    public func beginReadingRevision(version: PersonalReadingVersionItem, entry: PersonalLyricsLibraryEntry) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let track = entry.libraryTrack
                let identity = TrackIdentity(track: track)
                try await repository.prepare()
                guard let lyricsSource = try await repository.loadEditableVersion(
                    versionID: version.lyricsVersionID, track: track, identity: identity
                ) else { throw LyricsEditingRepositoryError.sourceNotFound }
                let versions = try await repository.loadReadingVersions(
                    lyricsVersionID: version.lyricsVersionID,
                    representationID: version.representationID,
                    sourceContentHash: lyricsSource.sourceContentHash
                )
                guard let source = versions.first(where: { $0.record.id == version.id }) else {
                    throw ReadingRepositoryError.versionNotFound
                }
                readingRevisionDraft = LibraryReadingRevisionDraft(
                    track: track, lyricsSource: lyricsSource, source: source
                )
            } catch {
                statusMessage = "打开读音编辑失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveReadingRevision(_ draft: LibraryReadingRevisionDraft) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                _ = try await repository.saveReadingVersion(draft.saveRequest())
                readingRevisionDraft = nil
                refreshTrackDetail(stableKey: draft.lyricsSource.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    public func beginTimingRevision(version: PersonalTimingVersionItem, entry: PersonalLyricsLibraryEntry) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                let track = entry.libraryTrack
                let identity = TrackIdentity(track: track)
                try await repository.prepare()
                guard let lyricsSource = try await repository.loadEditableVersion(
                    versionID: version.lyricsVersionID, track: track, identity: identity
                ), let source = try await repository.loadPersonalLibraryTimingVersion(id: version.id),
                   source.lyricsVersionID == lyricsSource.record.id,
                   source.sourceContentHash == lyricsSource.sourceContentHash,
                   let draft = LibraryTimingRevisionDraft(track: track, lyricsSource: lyricsSource, source: source) else {
                    throw LyricsEditingRepositoryError.sourceNotFound
                }
                timingRevisionDraft = draft
            } catch {
                statusMessage = "打开逐字时间编辑失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveTimingRevision(_ draft: LibraryTimingRevisionDraft) {
        guard !revisionBusy else { return }
        revisionBusy = true
        revisionError = nil
        Task {
            defer { revisionBusy = false }
            do {
                _ = try await repository.savePersonalLibraryTimingRevision(draft.saveRequest())
                timingRevisionDraft = nil
                refreshTrackDetail(stableKey: draft.lyricsSource.record.trackStableKey)
                refresh()
            } catch { revisionError = error.localizedDescription }
        }
    }

    private let repository: SQLiteLyricsRepository
    private let defaults: UserDefaults
    private var pendingSync: (folder: URL, revision: Data)?

    public init(
        repository: SQLiteLyricsRepository = SQLiteLyricsRepository(),
        defaults: UserDefaults = .lyricsQ
    ) {
        self.repository = repository
        self.defaults = defaults
        self.syncFolderURL = PersonalDataSyncStore.restoreFolderReference(defaults: defaults)
    }

    func searchPassages(matching query: String) async throws -> [LibraryPassageHit] {
        try await repository.searchLibraryPassages(query)
    }

    func bookSources(matching query: String) async throws -> [LibraryPassageHit] {
        if !query.isEmpty { return try await searchPassages(matching: query).filter { $0.entry.lyricsVersionCount > 0 } }
        let entries = try await repository.loadPersonalLibraryEntries()
        return entries.filter { $0.lyricsVersionCount > 0 }
            .map { LibraryPassageHit(entry: $0, source: nil, excerpt: nil, matchesMetadata: true) }
    }

    func fileDestinations(preferredRecording: String?) async throws
        -> (records: [DatabaseTrackRecord], preferred: DatabaseTrackRecord?) {
        try await repository.localRecordingChoices(preferredRecording: preferredRecording)
    }

    func fileLyrics(_ file: LocalLyricsFile, with track: Track, archiveKey: String? = nil) async throws -> LibraryPassageTarget {
        let target = try await repository.importLyricFile(file, into: track, archiveKey: archiveKey)
        if !entries.isEmpty || selectedTrackDetail != nil {
            refreshTrackDetail(stableKey: target.trackKey)
            refresh()
        }
        return target
    }

    func continueFiledLyricReading(_ target: LibraryPassageTarget, file: LocalLyricsFile,
                                   position: LibraryPassageTarget.ReadingPosition) async throws -> LibraryPassageTarget {
        try await repository.continueFiledLyricReading(target, file: file, position: position)
    }

    func entries(for query: String) -> [PersonalLyricsLibraryEntry] {
        loadedSearchQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) ? entries : []
    }

    func matchingPassage(for trackKey: String, in query: String) -> (target: LibraryPassageTarget, excerpt: String?)? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadedSearchQuery == term, let hit = loadedPassages[trackKey] else { return nil }
        return (hit.readingTarget(for: term), hit.excerpt)
    }

    func search(_ query: String, immediately: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard immediately || searchQuery != trimmed || (loadedSearchQuery != trimmed && !isLoading) else { return }
        searchQuery = trimmed
        refresh(after: immediately || trimmed.isEmpty ? .zero : .milliseconds(180))
    }

    public func refresh() { refresh(after: .zero) }

    private func refresh(after delay: Duration) {
        listTask?.cancel()
        isLoading = true
        statusMessage = "正在加载歌词库..."
        let query = searchQuery
        let repository = repository
        listTask = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                let list: [PersonalLyricsLibraryEntry]
                let hits: [LibraryPassageHit]
                if query.isEmpty {
                    list = try await repository.loadPersonalLibraryEntries(includeMissingLyrics: true)
                    hits = []
                } else {
                    hits = try await repository.searchLibraryPassages(query, includeMissingLyrics: true)
                    list = hits.map(\.entry)
                }
                guard !Task.isCancelled, let self else { return }
                self.loadedSearchQuery = query
                self.loadedPassages = Dictionary(uniqueKeysWithValues: hits.filter { $0.source != nil }.map { ($0.id, $0) })
                self.entries = list
                self.isLoading = false
                self.statusMessage = ""
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoading = false
                self.statusMessage = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    public func selectTrack(stableKey: String, rememberForWorkspace: Bool = true) {
        let requestID = UUID()
        detailRequestID = requestID
        if requestedTrackStableKey != stableKey { selectedTrackDetail = nil }
        requestedTrackStableKey = stableKey
        selectedTrackIssue = nil
        Task {
            do {
                let detail = try await repository.loadPersonalLibraryTrackDetail(stableKey: stableKey)
                guard detailRequestID == requestID else { return }
                selectedTrackDetail = detail
                if detail == nil { selectedTrackIssue = "本机还没有这首歌的档案" }
                if rememberForWorkspace, let entry = detail?.entry { rememberOpenedRecord(entry) }
            } catch {
                guard detailRequestID == requestID else { return }
                selectedTrackIssue = "暂时读不到这首歌的档案"
                statusMessage = "获取歌曲详情失败：\(error.localizedDescription)"
            }
        }
    }

    private func rememberOpenedRecord(_ entry: PersonalLyricsLibraryEntry, passage: LibraryPassageTarget? = nil, edition: String? = nil) {
        let previous = defaults.data(forKey: LastOpenedLyricsRecord.defaultsKey)
            .flatMap { try? JSONDecoder().decode(LastOpenedLyricsRecord.self, from: $0) }
        let resume = passage ?? (previous?.trackKey == entry.trackStableKey ? previous?.passage : nil)
        let record = LastOpenedLyricsRecord(trackKey: entry.trackStableKey, title: entry.title, artist: entry.artist,
                                            passage: resume, edition: edition ?? (resume == nil ? nil : previous?.edition))
        if passage != nil {
            RecentLyricsReadings.note(record, in: defaults, legacy: previous)
        } else if let previous, previous.passage != nil, defaults.data(forKey: RecentLyricsReadings.defaultsKey) == nil {
            RecentLyricsReadings.note(previous, in: defaults, legacy: nil)
        }
        if record != previous, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: LastOpenedLyricsRecord.defaultsKey)
        }
    }

    func selectedDetail(for stableKey: String) -> PersonalLyricsLibraryTrackDetail? {
        requestedTrackStableKey == stableKey ? selectedTrackDetail : nil
    }

    func selectionIssue(for stableKey: String) -> String? {
        requestedTrackStableKey == stableKey ? selectedTrackIssue : nil
    }

    func currentDetail(for stableKey: String) -> PersonalLyricsLibraryTrackDetail? {
        currentTrackStableKey == stableKey ? currentTrackDetail : nil
    }

    func prefetchCurrentTrack(stableKey: String?, force: Bool = false) {
        guard force || currentTrackStableKey != stableKey else { return }
        let changed = currentTrackStableKey != stableKey
        currentTrackStableKey = stableKey
        if changed { currentTrackDetail = nil }
        let requestID = UUID()
        currentTrackRequestID = requestID
        guard let stableKey else { return }
        Task {
            do {
                let detail = try await repository.loadPersonalLibraryTrackDetail(stableKey: stableKey)
                guard currentTrackRequestID == requestID else { return }
                currentTrackDetail = detail
            } catch {
                guard currentTrackRequestID == requestID else { return }
                statusMessage = "获取歌曲详情失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshTrackDetail(stableKey: String) {
        if let requestedTrackStableKey,
           requestedTrackStableKey == stableKey || selectedTrackDetail?.entry.trackStableKey == stableKey {
            selectTrack(stableKey: requestedTrackStableKey, rememberForWorkspace: false)
        }
        if currentTrackStableKey == stableKey || currentTrackDetail?.entry.trackStableKey == stableKey {
            prefetchCurrentTrack(stableKey: currentTrackStableKey, force: true)
        }
    }

    // MARK: - Version Actions

    func adoptBatchCandidate(_ candidate: LyricsCandidate, for entry: PersonalLyricsLibraryEntry) async throws -> LyricsPersistenceSaveResult {
        let result = try await repository.adoptBatchCandidate(candidate, for: entry)
        if result.versionID != nil { refreshTrackDetail(stableKey: entry.trackStableKey) }
        return result
    }

    func isCurrentTrack(stableKey: String, playbackIdentity: TrackIdentity?) async throws -> Bool {
        guard let playbackIdentity else { return false }
        let libraryKey = try await repository.resolveStableKey(stableKey)
        let playbackKey = try await repository.resolveStableKey(playbackIdentity.stableKey)
        return libraryKey == playbackKey
    }

    public func adoptLyricsVersion(versionID: UUID, trackStableKey: String, applyToPlayback: ((UUID) async throws -> Bool)? = nil) {
        Task {
            do {
                try await repository.setPersonalLibraryActiveLyrics(trackStableKey: trackStableKey, lyricsVersionID: versionID)
                _ = try await applyToPlayback?(versionID)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "切换歌词版本失败：\(error.localizedDescription)"
            }
        }
    }

    public func adoptTiming(versionID: UUID, trackStableKey: String,
                            applyToPlayback: ((UUID) async throws -> Bool)? = nil) {
        Task {
            do {
                let lyricsID = try await repository.adoptPersonalLibraryTimingVersion(id: versionID, trackStableKey: trackStableKey)
                try await repository.setPersonalLibraryActiveLyrics(trackStableKey: trackStableKey, lyricsVersionID: lyricsID)
                _ = try await applyToPlayback?(lyricsID)
                refreshTrackDetail(stableKey: trackStableKey)
            } catch { statusMessage = "采用时间轴失败：\(error.localizedDescription)" }
        }
    }

    public func toggleLyricsLock(versionID: UUID, currentLocked: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.toggleLyricsLocked(versionID: versionID, locked: !currentLocked)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "锁定歌词失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    public func adoptTranslation(versionID: UUID, trackStableKey: String) async -> Bool {
        do {
            try await repository.adoptTranslation(versionID: versionID)
            refreshTrackDetail(stableKey: trackStableKey)
            refresh()
            return true
        } catch {
            statusMessage = "采用翻译失败：\(error.localizedDescription)"
            return false
        }
    }

    public func toggleTranslationLock(versionID: UUID, currentLocked: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.markTranslationLocked(versionID: versionID, locked: !currentLocked)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "锁定翻译失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleTranslationArchive(versionID: UUID, currentArchived: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.archiveTranslation(versionID: versionID, archived: !currentArchived)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "归档翻译失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    public func deleteTranslationVersion(versionID: UUID, trackStableKey: String) async -> Bool {
        do {
            try await repository.deleteTranslation(versionID: versionID)
            refreshTrackDetail(stableKey: trackStableKey)
            refresh()
            return true
        } catch {
            statusMessage = "删除译文失败：\(error.localizedDescription)"
            return false
        }
    }

    public func adoptReading(versionID: UUID, trackStableKey: String) {
        Task {
            do {
                try await repository.adoptReadingVersion(versionID: versionID)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "采用读音失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleReadingLock(versionID: UUID, currentLocked: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.markReadingLocked(versionID: versionID, locked: !currentLocked)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "锁定读音失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleReadingArchive(versionID: UUID, currentArchived: Bool, trackStableKey: String) {
        Task {
            do {
                try await repository.archiveReadingVersion(versionID: versionID, archived: !currentArchived)
                refreshTrackDetail(stableKey: trackStableKey)
                refresh()
            } catch {
                self.statusMessage = "归档读音失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export / Import

    public func exportPackage(for stableKey: String) {
        Task {
            do {
                let package = try await repository.exportPersonalLibraryPackage(stableKey: stableKey)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(package)

                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.json]
                savePanel.nameFieldStringValue = "\(package.track.artist) - \(package.track.title).lyricisland.json"
                savePanel.title = "导出歌词资产包"
                savePanel.message = "导出包含歌词、翻译、读音与逐字时间轴的标准数据包"

                if savePanel.runModal() == .OK, let url = savePanel.url {
                    try data.write(to: url, options: .atomic)
                    self.statusMessage = "导出成功：\(url.lastPathComponent)"
                }
            } catch {
                self.statusMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    public func exportPersonalData() {
        Task {
            do {
                let package = try await repository.exportPersonalDataPackage()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(package)

                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.json]
                savePanel.nameFieldStringValue = "LyricIsland-Personal-Data-v1.lyricisland.json"
                savePanel.title = "导出个人数据"
                savePanel.message = "导出所有个人歌词、翻译、读音与逐字时间轴资产"

                if savePanel.runModal() == .OK, let url = savePanel.url {
                    try data.write(to: url, options: .atomic)
                    self.statusMessage = "个人数据导出成功：" + url.lastPathComponent
                }
            } catch {
                self.statusMessage = "个人数据导出失败：" + error.localizedDescription
            }
        }
    }

    public func presentImportDialog() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "选择要导入的歌词资产包"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let package = try decoder.decode(PersonalLyricsLibraryPackage.self, from: data)
                    let preview = try await repository.previewImportPersonalLibraryPackage(package)

                    self.pendingImportPackage = package
                    self.importPreview = preview
                    self.showImportPreviewSheet = true
                } catch {
                    self.statusMessage = "读取歌词包失败：\(error.localizedDescription)"
                }
            }
        }
    }

    public func presentPersonalDataImportDialog() {
        guard !isSyncing else { return }
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "选择个人数据包"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let package = try PersonalDataSyncStore.decode(data)
                    let preview = try await repository.previewImportPersonalDataPackage(package)

                    self.pendingSync = nil
                    self.personalDataNotice = nil
                    self.pendingDataPackage = package
                    self.dataImportPreview = preview
                    self.showDataImportPreviewSheet = true
                } catch {
                    self.personalDataNotice = "读取个人数据包失败：" + error.localizedDescription
                }
            }
        }
    }

    // MARK: - Private Folder Sync

    public func selectSyncFolder() {
        guard !isSyncing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "选择私人同步文件夹"
        panel.message = "Aster · Lyric 将在此文件夹中保存一个个人数据包文件"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PersonalDataSyncStore.saveFolderReference(url, defaults: defaults)
                if pendingSync != nil { discardPersonalDataPreview() }
                syncFolderURL = url.standardizedFileURL
                personalDataNotice = "已选择同步文件夹"
            } catch {
                personalDataNotice = "选择同步文件夹失败：" + error.localizedDescription
            }
        }
    }

    public func cancelSyncFolder() {
        guard !isSyncing else { return }
        PersonalDataSyncStore.clearFolderReference(defaults: defaults)
        syncFolderURL = nil
        if pendingSync != nil { discardPersonalDataPreview() }
        personalDataNotice = "已取消私人同步文件夹"
    }

    public func syncNow() {
        guard !isSyncing, !showDataImportPreviewSheet else { return }
        let selectedFolder = PersonalDataSyncStore.restoreFolderReference(defaults: defaults)
        syncFolderURL = selectedFolder
        guard let folder = selectedFolder else {
            personalDataNotice = "请先选择同步文件夹"
            return
        }

        isSyncing = true
        personalDataNotice = "正在检查同步文件夹…"

        Task {
            defer { self.isSyncing = false }
            do {
                if let remote = try await readSyncFile(in: folder) {
                    let preview = try await repository.previewImportPersonalDataPackage(remote.package)
                    try checkSelectedSyncFolder(folder)
                    if preview.hasConflicts || preview.totalNewAssets > 0 {
                        self.pendingSync = (folder, remote.revision)
                        self.pendingDataPackage = remote.package
                        self.dataImportPreview = preview
                        self.showDataImportPreviewSheet = true
                        self.personalDataNotice = nil
                    } else {
                        self.personalDataNotice = "同步文件没有可导入的新资产"
                    }
                } else {
                    let localPackage = try await repository.exportPersonalDataPackage()
                    try await writeSyncFile(localPackage, in: folder, replacing: nil)
                    self.personalDataNotice = "已将 \(localPackage.tracks.count) 首歌曲写入同步文件夹"
                }
            } catch {
                self.personalDataNotice = "同步检查失败：" + error.localizedDescription
            }
        }
    }

    private func checkSelectedSyncFolder(_ folder: URL) throws {
        guard PersonalDataSyncStore.restoreFolderReference(defaults: defaults) == folder else {
            throw PersonalDataSyncStoreError.folderUnavailable
        }
    }

    private func readSyncFile(in folder: URL) async throws -> PersonalDataSyncStore.Snapshot? {
        try await Task.detached(priority: .userInitiated) {
            try PersonalDataSyncStore.withFolderAccess(folder) { try PersonalDataSyncStore.snapshot(in: folder) }
        }.value
    }

    private func writeSyncFile(_ package: PersonalDataPackage, in folder: URL, replacing revision: Data?) async throws {
        try checkSelectedSyncFolder(folder)
        try await Task.detached(priority: .userInitiated) {
            try PersonalDataSyncStore.withFolderAccess(folder) { try PersonalDataSyncStore.write(package, to: folder, replacing: revision) }
        }.value
    }

    public func confirmImport() {
        guard let package = pendingImportPackage else { return }
        Task {
            do {
                try await repository.importPersonalLibraryPackage(package)
                self.statusMessage = "成功导入「\(package.track.title)」的歌词资产"
                self.pendingImportPackage = nil
                self.importPreview = nil
                self.showImportPreviewSheet = false
                refresh()
            } catch {
                self.statusMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    public func confirmPersonalDataImport() {
        guard !isSyncing, let package = pendingDataPackage else { return }
        let sync = pendingSync
        isSyncing = true
        personalDataNotice = nil
        Task {
            defer { isSyncing = false }
            if let sync {
                do {
                    let observed = try await readSyncFile(in: sync.folder)
                    try checkSelectedSyncFolder(sync.folder)
                    guard observed?.revision == sync.revision else { throw PersonalDataSyncStoreError.packageChanged }
                } catch {
                    discardPersonalDataPreview()
                    personalDataNotice = error.localizedDescription
                    return
                }
            }
            do {
                try await repository.importPersonalDataPackage(package)
            } catch {
                personalDataNotice = "个人数据包导入失败：" + error.localizedDescription
                return
            }
            if let sync {
                do {
                    let mergedPackage = try await repository.exportPersonalDataPackage()
                    try await writeSyncFile(mergedPackage, in: sync.folder, replacing: sync.revision)
                    personalDataNotice = "已导入资产并更新同步文件"
                } catch {
                    personalDataNotice = "已导入本机，未更新同步文件。" + error.localizedDescription
                }
            } else {
                personalDataNotice = "成功导入 \(package.tracks.count) 首歌曲的个人资产"
            }
            discardPersonalDataPreview()
            refresh()
            if let key = requestedTrackStableKey { refreshTrackDetail(stableKey: key) }
            if let key = currentTrackStableKey, key != requestedTrackStableKey { refreshTrackDetail(stableKey: key) }
        }
    }

    public func cancelImport() {
        self.pendingImportPackage = nil
        self.importPreview = nil
        self.showImportPreviewSheet = false
    }

    public func cancelPersonalDataImport() {
        guard !isSyncing else { return }
        discardPersonalDataPreview()
    }

    private func discardPersonalDataPreview() {
        pendingSync = nil
        pendingDataPackage = nil
        dataImportPreview = nil
        showDataImportPreviewSheet = false
    }
}
