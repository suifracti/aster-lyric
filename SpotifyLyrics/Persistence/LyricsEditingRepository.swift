import Foundation

public struct StoredEditableLyricsVersion: Equatable, Sendable {
    public let record: DatabaseLyricsVersionRecord
    public let lines: [DatabaseLyricLineRecord]
    public let document: LyricsDocument
    public let lockedReadingLayers: [DatabaseReadingLayerRecord]

    public init(
        record: DatabaseLyricsVersionRecord,
        lines: [DatabaseLyricLineRecord],
        document: LyricsDocument,
        lockedReadingLayers: [DatabaseReadingLayerRecord] = []
    ) {
        self.record = record
        self.lines = lines
        self.document = document
        self.lockedReadingLayers = lockedReadingLayers
    }

    /// Canonical identity of the stored source rows. Unlike
    /// `record.contentHash`, this excludes provider/deduplication metadata and
    /// any translation, timing, or reading projection applied to `document`.
    public var sourceContentHash: String {
        LyricsSourceContentHasher.hash(
            isSynchronized: record.isSynced,
            lines: lines
        )
    }
}

public struct LyricsReadingLayerDraft: Equatable, Sendable {
    public let lineIndex: Int
    public let kanaText: String?
    public let romajiText: String?
    public let source: String
    public let isLocked: Bool

    public init(lineIndex: Int, kanaText: String?, romajiText: String?, source: String = "manualEdit", isLocked: Bool) {
        self.lineIndex = lineIndex
        self.kanaText = kanaText
        self.romajiText = romajiText
        self.source = source
        self.isLocked = isLocked
    }
}

public struct ManualTranslationEdit: Equatable, Sendable {
    public let targetLanguage: String
    public let model: String
    public let baseURLHost: String
    public let promptHash: String
    public let lines: [String]
    public let parentVersionID: UUID?
    public let isLocked: Bool

    public init(
        targetLanguage: String,
        model: String = "",
        baseURLHost: String = "",
        promptHash: String = "",
        lines: [String],
        parentVersionID: UUID? = nil,
        isLocked: Bool = false
    ) {
        self.targetLanguage = targetLanguage
        self.model = model
        self.baseURLHost = baseURLHost
        self.promptHash = promptHash
        self.lines = lines
        self.parentVersionID = parentVersionID
        self.isLocked = isLocked
    }
}

public struct LyricsEditSaveRequest: Equatable, Sendable {
    public let track: Track
    public let identity: TrackIdentity
    public let sourceVersionID: UUID
    public let sourceContentHash: String
    public let document: LyricsDocument
    public let createLyricsVersion: Bool
    public let lockLyricsVersion: Bool
    public let preserveCurrentLyricsSelection: Bool
    public let targetSource: LyricsSource
    /// True only after the editor/library UI has shown the concrete timing
    /// loss and the user chose to continue with the compatible remainder.
    public let confirmedTimingLoss: Bool
    /// A fresh manual/import source has no provider version to compare against.
    /// Existing editor saves keep this false and remain compare-and-save
    /// operations against `sourceVersionID`.
    public let isNewSource: Bool
    public let translation: ManualTranslationEdit?
    public let readingLayers: [LyricsReadingLayerDraft]

    public init(
        track: Track,
        identity: TrackIdentity,
        sourceVersionID: UUID,
        sourceContentHash: String,
        document: LyricsDocument,
        createLyricsVersion: Bool,
        lockLyricsVersion: Bool = false,
        preserveCurrentLyricsSelection: Bool = false,
        targetSource: LyricsSource = .manualEdit,
        confirmedTimingLoss: Bool = false,
        isNewSource: Bool = false,
        translation: ManualTranslationEdit? = nil,
        readingLayers: [LyricsReadingLayerDraft] = []
    ) {
        self.track = track
        self.identity = identity
        self.sourceVersionID = sourceVersionID
        self.sourceContentHash = sourceContentHash
        self.document = document
        self.createLyricsVersion = createLyricsVersion
        self.lockLyricsVersion = lockLyricsVersion
        self.preserveCurrentLyricsSelection = preserveCurrentLyricsSelection
        self.targetSource = targetSource
        self.confirmedTimingLoss = confirmedTimingLoss
        self.isNewSource = isNewSource
        self.translation = translation
        self.readingLayers = readingLayers
    }
}

public struct LyricsEditSaveResult: Equatable, Sendable {
    public let lyricsVersion: StoredEditableLyricsVersion?
    public let translationVersion: StoredTranslationVersion?

    public init(lyricsVersion: StoredEditableLyricsVersion?, translationVersion: StoredTranslationVersion?) {
        self.lyricsVersion = lyricsVersion
        self.translationVersion = translationVersion
    }
}

public enum LyricsEditingRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case sourceNotFound
    case sourceContentMismatch
    case identityMismatch
    case invalidDocument(String)
    case invalidTimeline(String)
    case invalidTranslation(String)
    case timingLossRequiresConfirmation(LyricsTimingLossSummary)
    case noChanges
    case lockedVersion

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound: return "找不到编辑来源歌词版本"
        case .sourceContentMismatch: return "编辑来源内容已经变化"
        case .identityMismatch: return "编辑内容不属于当前歌曲"
        case .invalidTimeline(let message): return "时间轴校验失败：\(message)"
        case .invalidTranslation(let message): return "翻译校验失败：\(message)"
        case .timingLossRequiresConfirmation(let summary): return summary.confirmationMessage
        case .invalidDocument(let message): return "歌词文档无效：\(message)"
        case .noChanges: return "没有需要保存的编辑"
        case .lockedVersion: return "锁定版本不能被直接覆盖"
        }
    }
}

public protocol LyricsEditingRepository: Sendable, LyricsOffsetScopeResolving {
    func loadEditableVersions(track: Track, identity: TrackIdentity) async throws -> [StoredEditableLyricsVersion]
    func loadEditableVersion(versionID: UUID, track: Track, identity: TrackIdentity) async throws -> StoredEditableLyricsVersion?
    /// Marks an existing lyrics version as the preferred persisted version for
    /// its track without creating, deleting, or rewriting the version.
    func adoptLyricsVersion(trackStableKey: String, lyricsVersionID: UUID) async throws
    /// Translation versions are loaded through the same repository boundary
    /// when the editor switches lyric source versions. The editor must never
    /// reach into SQLite or construct a second translation state source.
    func loadTranslationVersions(
        lyricsVersionID: UUID,
        targetLanguage: String,
        sourceContentHash: String
    ) async throws -> [StoredTranslationVersion]
    func saveManualEdit(_ request: LyricsEditSaveRequest) async throws -> LyricsEditSaveResult
    func markLyricsVersionLocked(versionID: UUID, locked: Bool) async throws
}

/// A library edit is bound to its stored source, independently of Spotify playback.
public struct LibraryLyricsRevisionDraft: Identifiable {
    public let id = UUID()
    public let track: Track
    public let source: StoredEditableLyricsVersion
    public var lines: [LyricsEditorLineDraft]
    private let originalLines: [LyricsEditorLineDraft]

    public init(track: Track, source: StoredEditableLyricsVersion) {
        self.track = track
        self.source = source
        let lines = source.document.lines.enumerated().map {
            LyricsEditorLineDraft(line: $0.element, startTimeIsMeaningful: source.document.lineHasExplicitTiming($0.offset))
        }
        self.lines = lines
        self.originalLines = lines
    }

    public var hasChanges: Bool { lines != originalLines }

    public var timingLossSummary: LyricsTimingLossSummary {
        LyricsTimingCompatibility.loss(from: originalLines, to: lines)
    }

    public func saveRequest(confirmingTimingLoss: Bool = false) throws -> LyricsEditSaveRequest {
        guard hasChanges else { throw LyricsEditingRepositoryError.noChanges }
        let timingLoss = timingLossSummary
        guard !timingLoss.requiresConfirmation || confirmingTimingLoss else {
            throw LyricsEditingRepositoryError.timingLossRequiresConfirmation(timingLoss)
        }
        // Derived text must not silently follow rewritten words into the revision.
        let cleaned = LyricsTimingCompatibility.sanitized(lines, relativeTo: originalLines).map { line -> LyricsEditorLineDraft in
            var line = line
            line.translationText = nil
            if line.startTime == nil || line.endTime.map({ $0 < (line.startTime ?? 0) }) == true {
                line.endTime = nil
            }
            if originalLines.first(where: { $0.id == line.id })?.originalText != line.originalText {
                line.kanaText = nil; line.romajiText = nil; line.rubyTokens = nil
            }
            return line
        }
        let hash = LyricsSourceContentHasher.hash(isSynchronized: source.record.isSynced, lines: source.lines)
        let draft = LyricsEditorDraft(
            identity: source.document.identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: cleaned,
            isSynchronized: source.document.isSynchronized,
            language: source.document.language,
            explicitlyTimedLineIndices: source.document.explicitlyTimedLineIndices,
            sourceVersionID: source.record.id,
            sourceContentHash: hash,
            source: .manualEdit
        )
        guard let document = draft.document() else { throw LyricsEditingRepositoryError.invalidDocument("无法生成歌词版本") }
        let readingLayers = source.lockedReadingLayers.compactMap { sourceLayer -> LyricsReadingLayerDraft? in
            guard source.document.lines.indices.contains(sourceLayer.lineIndex) else { return nil }
            let sourceLineID = source.document.lines[sourceLayer.lineIndex].id
            guard let newIndex = cleaned.firstIndex(where: { $0.id == sourceLineID }),
                  cleaned[newIndex].originalText == source.document.lines[sourceLayer.lineIndex].originalText else {
                return nil
            }
            return LyricsReadingLayerDraft(
                lineIndex: newIndex,
                kanaText: sourceLayer.kanaText,
                romajiText: sourceLayer.romajiText,
                source: sourceLayer.source,
                isLocked: true
            )
        }
        return LyricsEditSaveRequest(
            track: track,
            identity: source.document.identity,
            sourceVersionID: source.record.id,
            sourceContentHash: hash,
            document: document,
            createLyricsVersion: true,
            preserveCurrentLyricsSelection: true,
            confirmedTimingLoss: confirmingTimingLoss,
            readingLayers: readingLayers
        )
    }
}

/// A translation edit stays attached to the exact lyric version it came from.
/// Saving creates a manual child translation; it never rewrites the parent.
public struct LibraryTranslationRevisionDraft: Identifiable {
    public let id = UUID()
    public let track: Track
    public let lyricsSource: StoredEditableLyricsVersion
    public let source: StoredTranslationVersion
    public var lines: [String]
    private let originalLines: [String]

    public init(track: Track, lyricsSource: StoredEditableLyricsVersion, source: StoredTranslationVersion) {
        self.track = track
        self.lyricsSource = lyricsSource
        self.source = source
        let lines = source.lines.sorted { $0.lineIndex < $1.lineIndex }.map(\.translatedText)
        self.lines = lines
        self.originalLines = lines
    }

    public var hasChanges: Bool { lines != originalLines }

    public func saveRequest() throws -> LyricsEditSaveRequest {
        guard hasChanges else { throw LyricsEditingRepositoryError.noChanges }
        guard source.record.lyricsVersionID == lyricsSource.record.id,
              source.record.sourceContentHash == lyricsSource.sourceContentHash else {
            throw LyricsEditingRepositoryError.sourceContentMismatch
        }
        return LyricsEditSaveRequest(
            track: track,
            identity: lyricsSource.document.identity,
            sourceVersionID: lyricsSource.record.id,
            sourceContentHash: lyricsSource.sourceContentHash,
            document: lyricsSource.document,
            createLyricsVersion: false,
            preserveCurrentLyricsSelection: true,
            translation: ManualTranslationEdit(
                targetLanguage: source.record.targetLanguage,
                model: source.record.model,
                baseURLHost: source.record.baseURLHost,
                promptHash: source.record.promptHash,
                lines: lines,
                parentVersionID: source.record.id
            )
        )
    }
}

/// A reading edit creates an unlocked manual child on the same source lyrics.
public struct LibraryReadingRevisionDraft: Identifiable {
    public let id = UUID()
    public let track: Track
    public let lyricsSource: StoredEditableLyricsVersion
    public let source: StoredReadingVersion
    public var lines: [String]
    private let originalLines: [String]

    public init(track: Track, lyricsSource: StoredEditableLyricsVersion, source: StoredReadingVersion) {
        self.track = track
        self.lyricsSource = lyricsSource
        self.source = source
        let lines = source.lines.sorted { $0.lineIndex < $1.lineIndex }.map { $0.readingText ?? "" }
        self.lines = lines
        self.originalLines = lines
    }

    public var hasChanges: Bool { lines != originalLines }

    public func saveRequest() throws -> ReadingVersionSaveRequest {
        guard hasChanges else { throw LyricsEditingRepositoryError.noChanges }
        guard source.record.lyricsVersionID == lyricsSource.record.id,
              source.record.sourceContentHash == lyricsSource.sourceContentHash else {
            throw LyricsEditingRepositoryError.sourceContentMismatch
        }
        let now = Date()
        let record = ReadingVersionRecord(
            id: UUID(),
            lyricsVersionID: source.record.lyricsVersionID,
            sourceContentHash: source.record.sourceContentHash,
            engineID: source.record.engineID,
            representationID: source.record.representationID,
            sourceKind: .manualEdit,
            language: source.record.language,
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: false,
            isManuallyEdited: true,
            isCurrent: false,
            isLocked: false,
            isArchived: false,
            parentVersionID: source.record.id,
            confidence: 1,
            warningMetadata: [],
            contextHash: source.record.contextHash
        )
        return ReadingVersionSaveRequest(
            record: record,
            lines: ReadingManualEdit.lines(from: source.lines, drafts: lines)
        )
    }
}

public struct LibraryTimingSpanDraft: Identifiable, Equatable {
    public let source: TimedTextSpan
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public var id: Int { source.id }

    public init(source: TimedTextSpan) {
        self.source = source
        self.startTime = source.startTime
        self.endTime = source.endTime
    }

    public var updatedSpan: TimedTextSpan {
        TimedTextSpan(
            id: source.id,
            text: source.text,
            trailingWhitespace: source.trailingWhitespace,
            startTime: startTime,
            endTime: endTime,
            utf16Start: source.utf16Start,
            utf16Length: source.utf16Length,
            granularity: source.granularity
        )
    }
}

public struct LibraryTimingLineDraft: Identifiable, Equatable {
    public let lineIndex: Int
    public let originalText: String
    public let performerID: String?
    public var spans: [LibraryTimingSpanDraft]

    public var id: Int { lineIndex }

    public init(lineIndex: Int, originalText: String, performerID: String?, spans: [TimedTextSpan]) {
        self.lineIndex = lineIndex
        self.originalText = originalText
        self.performerID = performerID
        self.spans = spans.map(LibraryTimingSpanDraft.init(source:))
    }

    public var payload: LineTimingPayload {
        LineTimingPayload(lineIndex: lineIndex, performerID: performerID, spans: spans.map(\.updatedSpan))
    }
}

public struct LibraryTimingRevisionSaveRequest: Sendable, Equatable {
    public let track: Track
    public let identity: TrackIdentity
    public let sourceTimingVersionID: UUID
    public let lines: [LineTimingPayload]

    public init(track: Track, identity: TrackIdentity, sourceTimingVersionID: UUID, lines: [LineTimingPayload]) {
        self.track = track
        self.identity = identity
        self.sourceTimingVersionID = sourceTimingVersionID
        self.lines = lines
    }
}

/// Fine timing remains a separate immutable asset on the same lyrics version.
public struct LibraryTimingRevisionDraft: Identifiable {
    public let id = UUID()
    public let track: Track
    public let lyricsSource: StoredEditableLyricsVersion
    public let source: DatabaseLyricsTimingVersionRecord
    public var lines: [LibraryTimingLineDraft]
    private let originalLines: [LibraryTimingLineDraft]

    public init?(track: Track, lyricsSource: StoredEditableLyricsVersion, source: DatabaseLyricsTimingVersionRecord) {
        guard source.lyricsVersionID == lyricsSource.record.id,
              source.sourceContentHash == lyricsSource.sourceContentHash,
              let timingMap = DocumentTimingPayload.decode(source.spansPayload) else { return nil }
        let lines = timingMap.keys.sorted().compactMap { lineIndex -> LibraryTimingLineDraft? in
            guard lyricsSource.document.lines.indices.contains(lineIndex),
                  let timing = timingMap[lineIndex] else { return nil }
            return LibraryTimingLineDraft(
                lineIndex: lineIndex,
                originalText: lyricsSource.document.lines[lineIndex].originalText,
                performerID: timing.performerID,
                spans: timing.spans
            )
        }
        guard !lines.isEmpty,
              lines.count == timingMap.count,
              Self.hasCompatibleSpans(lines, source: lyricsSource) else { return nil }
        self.track = track
        self.lyricsSource = lyricsSource
        self.source = source
        self.lines = lines
        self.originalLines = lines
    }

    public var hasChanges: Bool { lines != originalLines }

    public func saveRequest() throws -> LibraryTimingRevisionSaveRequest {
        guard hasChanges else { throw LyricsEditingRepositoryError.noChanges }
        return LibraryTimingRevisionSaveRequest(
            track: track,
            identity: lyricsSource.document.identity,
            sourceTimingVersionID: source.id,
            lines: lines.map(\.payload)
        )
    }

    private static func hasCompatibleSpans(_ timingLines: [LibraryTimingLineDraft], source: StoredEditableLyricsVersion) -> Bool {
        var documentLines = source.document.lines.map { line -> LyricLine in
            var line = line
            line.timedSpans = nil
            line.performerID = nil
            return line
        }
        for timingLine in timingLines {
            guard documentLines.indices.contains(timingLine.lineIndex) else { return false }
            documentLines[timingLine.lineIndex].timedSpans = timingLine.spans.map(\.updatedSpan)
            documentLines[timingLine.lineIndex].performerID = timingLine.performerID
        }
        return LyricsTimingCompatibility.hasOnlyCompatibleSpans(in: source.document.replacingLines(documentLines))
    }
}
