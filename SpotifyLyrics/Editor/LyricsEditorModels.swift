import Foundation

public enum LyricsEditorError: Error, Equatable, Sendable, LocalizedError {
    case invalidLine
    case invalidSplitOffset
    case cannotDeleteLastLine
    case nothingToUndo
    case nothingToRedo
    case noChanges
    case staleSession
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLine: return "找不到歌词行"
        case .invalidSplitOffset: return "拆分位置无效"
        case .cannotDeleteLastLine: return "至少需要保留一行歌词"
        case .nothingToUndo: return "没有可撤销的编辑"
        case .nothingToRedo: return "没有可重做的编辑"
        case .noChanges: return "没有需要保存的修改"
        case .staleSession: return "歌词在编辑期间已经变化，请重新打开编辑器"
        case .invalidDocument(let message): return message
        }
    }
}

public struct LyricsEditorLineDraft: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var originalText: String
    public var translationText: String?
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var kanaText: String?
    public var romajiText: String?
    public var rubyTokens: [LyricRubyToken]?
    /// Projection metadata retained while opening an existing timed version.
    public var performerID: String?
    public var timedSpans: [TimedTextSpan]?
    public var readingRepresentationID: String?
    public var readingSurfaceText: String?

    public init(
        id: UUID = UUID(),
        originalText: String,
        translationText: String? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        kanaText: String? = nil,
        romajiText: String? = nil,
        rubyTokens: [LyricRubyToken]? = nil,
        performerID: String? = nil,
        timedSpans: [TimedTextSpan]? = nil,
        readingRepresentationID: String? = nil,
        readingSurfaceText: String? = nil
    ) {
        self.id = id
        self.originalText = originalText
        self.translationText = translationText
        self.startTime = startTime
        self.endTime = endTime
        self.kanaText = kanaText
        self.romajiText = romajiText
        self.rubyTokens = rubyTokens
        self.performerID = performerID
        self.timedSpans = timedSpans
        self.readingRepresentationID = readingRepresentationID
        self.readingSurfaceText = readingSurfaceText
    }

    public init(line: LyricLine, startTimeIsMeaningful: Bool = true) {
        self.init(
            id: line.id,
            originalText: line.originalText,
            translationText: line.translationText,
            // LyricLine keeps a zero placeholder for plain-text rows for
            // compatibility with the playback renderer. The editor must not
            // turn that placeholder into a real timestamp.
            startTime: startTimeIsMeaningful && line.timestamp.isFinite ? line.timestamp : nil,
            endTime: line.endTime,
            kanaText: line.kanaText,
            romajiText: line.romajiText,
            rubyTokens: line.rubyTokens,
            performerID: line.performerID,
            timedSpans: line.timedSpans,
            readingRepresentationID: line.readingRepresentationID,
            readingSurfaceText: line.readingSurfaceText
        )
    }

    public func asLyricLine() -> LyricLine {
        LyricLine(
            id: id,
            timestamp: startTime ?? 0,
            originalText: originalText,
            endTime: endTime,
            translationText: translationText,
            romajiText: romajiText,
            kanaText: kanaText,
            rubyTokens: rubyTokens,
            performerID: performerID,
            timedSpans: timedSpans,
            readingRepresentationID: readingRepresentationID,
            readingSurfaceText: readingSurfaceText
        )
    }
}

public struct LyricsTimingLossSummary: Equatable, Sendable {
    public let lostSpanCount: Int
    public let affectedLineCount: Int
    public let lostPerformerMetadataLineCount: Int

    public init(lostSpanCount: Int, affectedLineCount: Int, lostPerformerMetadataLineCount: Int = 0) {
        self.lostSpanCount = lostSpanCount
        self.affectedLineCount = affectedLineCount
        self.lostPerformerMetadataLineCount = lostPerformerMetadataLineCount
    }

    public var requiresConfirmation: Bool {
        lostSpanCount > 0 || lostPerformerMetadataLineCount > 0
    }

    public var confirmationMessage: String {
        var details: [String] = []
        if lostSpanCount > 0 {
            details.append("将失去 \(lostSpanCount) 个逐字时间片段，涉及 \(affectedLineCount) 行")
        }
        if lostPerformerMetadataLineCount > 0 {
            details.append("将失去 \(lostPerformerMetadataLineCount) 行的演唱者标记")
        }
        return details.joined(separator: "；") + "。确认后只保存仍与原文和行时间兼容的逐字数据；取消不会写入数据库。"
    }
}

/// Pure compatibility checks shared by editor/library projections and the
/// repository boundary. A payload may be partial across lines; every retained
/// span must still point to the same text and obey the renderer's range order.
public enum LyricsTimingCompatibility {
    public static func compatibleSpans(
        in line: LyricsEditorLineDraft,
        enforceLineEndBoundary: Bool = false
    ) -> [TimedTextSpan] {
        guard let spans = line.timedSpans, !spans.isEmpty else { return [] }
        var accepted: [TimedTextSpan] = []
        var previousUTF16End = 0
        var previousStartTime: TimeInterval?

        for span in spans {
            guard span.utf16Start >= previousUTF16End,
                  span.utf16Length > 0,
                  span.startTime.isFinite,
                  span.endTime.isFinite,
                  span.startTime >= 0,
                  span.endTime >= span.startTime,
                  line.startTime.map({ $0.isFinite && $0 >= 0 && span.startTime >= $0 }) ?? true,
                  !enforceLineEndBoundary || line.endTime.map({ $0.isFinite && $0 >= 0 && span.endTime <= $0 }) == true,
                  previousStartTime.map({ span.startTime >= $0 }) ?? true else {
                continue
            }
            let lyricLine = LyricLine(
                id: line.id,
                timestamp: line.startTime ?? 0,
                originalText: line.originalText,
                endTime: line.endTime,
                timedSpans: [span]
            )
            guard lyricLine.resolvedGraphemeSpans() != nil else { continue }

            accepted.append(span)
            previousUTF16End = span.utf16Start + span.utf16Length
            previousStartTime = span.startTime
        }
        return accepted
    }

    public static func sanitized(
        _ lines: [LyricsEditorLineDraft],
        relativeTo sourceLines: [LyricsEditorLineDraft] = [],
        matchByPositionWhenIDsDiffer: Bool = false
    ) -> [LyricsEditorLineDraft] {
        let sourceByID = Dictionary(sourceLines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return lines.enumerated().map { index, original in
            var line = original
            if line.timedSpans != nil {
                let source = sourceByID[line.id] ?? (matchByPositionWhenIDsDiffer && sourceLines.indices.contains(index) ? sourceLines[index] : nil)
                let endChanged = source.map { $0.endTime != line.endTime } ?? false
                line.timedSpans = compatibleSpans(in: line, enforceLineEndBoundary: endChanged && line.endTime != nil)
            }
            return line
        }
    }

    public static func loss(
        from sourceLines: [LyricsEditorLineDraft],
        to proposedLines: [LyricsEditorLineDraft]
    ) -> LyricsTimingLossSummary {
        let proposedByID = Dictionary(proposedLines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lostSpans = 0
        var affectedLines = 0
        var lostPerformerLines = 0

        for source in sourceLines {
            let sourceSpans = compatibleSpans(in: source)
            guard !sourceSpans.isEmpty else { continue }
            guard let proposed = proposedByID[source.id] else {
                lostSpans += sourceSpans.count
                affectedLines += 1
                if source.performerID != nil { lostPerformerLines += 1 }
                continue
            }

            let endChanged = source.endTime != proposed.endTime
            var remaining = compatibleSpans(in: proposed, enforceLineEndBoundary: endChanged && proposed.endTime != nil)
            var lineLoss = 0
            for span in sourceSpans {
                if let retained = remaining.firstIndex(of: span) {
                    remaining.remove(at: retained)
                } else {
                    lineLoss += 1
                }
            }
            if lineLoss > 0 {
                lostSpans += lineLoss
                affectedLines += 1
            }
            if source.performerID != proposed.performerID {
                lostPerformerLines += 1
            }
        }
        return LyricsTimingLossSummary(
            lostSpanCount: lostSpans,
            affectedLineCount: affectedLines,
            lostPerformerMetadataLineCount: lostPerformerLines
        )
    }

    public static func validatedTimingMap(
        _ map: [Int: (performerID: String?, spans: [TimedTextSpan])],
        for document: LyricsDocument
    ) -> [Int: (performerID: String?, spans: [TimedTextSpan])]? {
        guard !map.isEmpty else { return nil }
        var result: [Int: (performerID: String?, spans: [TimedTextSpan])] = [:]
        for (index, timing) in map {
            guard document.lines.indices.contains(index), !timing.spans.isEmpty else { return nil }
            var line = LyricsEditorLineDraft(
                line: document.lines[index],
                startTimeIsMeaningful: document.lineHasExplicitTiming(index)
            )
            line.performerID = timing.performerID
            line.timedSpans = timing.spans
            guard compatibleSpans(in: line) == timing.spans else { return nil }
            result[index] = timing
        }
        return result.isEmpty ? nil : result
    }

    public static func hasOnlyCompatibleSpans(in document: LyricsDocument) -> Bool {
        for (index, line) in document.lines.enumerated() {
            guard let spans = line.timedSpans, !spans.isEmpty else { continue }
            let draft = LyricsEditorLineDraft(
                line: line,
                startTimeIsMeaningful: document.lineHasExplicitTiming(index)
            )
            guard compatibleSpans(in: draft) == spans else { return false }
        }
        return true
    }
}

/// A value-type editing buffer. Every mutation records a complete line-array
/// snapshot, which keeps undo/redo deterministic when rows are split, merged,
/// reordered, or deleted.
public struct LyricsEditorDraft: Equatable, Sendable {
    public let identity: TrackIdentity?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?
    public let isSynchronized: Bool
    public let language: String?
    public let explicitlyTimedLineIndices: Set<Int>?
    /// Source attachment identity retained in this editor projection. It is
    /// not passed into a new-version save document.
    public let timingVersionID: UUID?
    public let sourceVersionID: UUID
    public let sourceContentHash: String
    public let source: LyricsSource
    public var lines: [LyricsEditorLineDraft]

    private var savedLines: [LyricsEditorLineDraft]
    private var undoStack: [[LyricsEditorLineDraft]] = []
    private var redoStack: [[LyricsEditorLineDraft]] = []

    public init(
        identity: TrackIdentity?,
        title: String?,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        lines: [LyricsEditorLineDraft],
        isSynchronized: Bool = true,
        language: String? = nil,
        explicitlyTimedLineIndices: Set<Int>? = nil,
        timingVersionID: UUID? = nil,
        sourceVersionID: UUID,
        sourceContentHash: String,
        source: LyricsSource
    ) {
        self.identity = identity
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.isSynchronized = isSynchronized
        self.language = language
        self.explicitlyTimedLineIndices = explicitlyTimedLineIndices
        self.timingVersionID = timingVersionID
        self.lines = lines
        self.sourceVersionID = sourceVersionID
        self.sourceContentHash = sourceContentHash
        self.source = source
        self.savedLines = lines
    }

    public init(
        lines: [LyricsEditorLineDraft] = [LyricsEditorLineDraft(originalText: "")]
    ) {
        self.identity = nil
        self.title = nil
        self.artist = nil
        self.album = nil
        self.duration = nil
        self.isSynchronized = true
        self.language = nil
        self.explicitlyTimedLineIndices = nil
        self.timingVersionID = nil
        self.sourceVersionID = UUID()
        self.sourceContentHash = ""
        self.source = .manualCreate
        self.lines = lines
        self.savedLines = lines
    }

    public init(document: LyricsDocument, sourceVersionID: UUID, sourceContentHash: String) {
        self.init(
            identity: document.identity,
            title: document.title,
            artist: document.artist,
            album: document.album,
            duration: document.duration,
            lines: document.lines.enumerated().map { index, line in
                LyricsEditorLineDraft(
                    line: line,
                    startTimeIsMeaningful: document.lineHasExplicitTiming(index)
                )
            },
            isSynchronized: document.isSynchronized,
            language: document.language,
            explicitlyTimedLineIndices: document.explicitlyTimedLineIndices,
            timingVersionID: document.timingVersionID,
            sourceVersionID: sourceVersionID,
            sourceContentHash: sourceContentHash,
            source: document.source
        )
    }

    public var isDirty: Bool { lines != savedLines }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func markSaved() {
        savedLines = lines
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public func document(source: LyricsSource = .manualEdit, isSynchronized: Bool? = nil) -> LyricsDocument? {
        guard let identity else { return nil }
        let validation = LyricsTimelineValidator.validate(lines: lines, duration: duration)
        let synced = isSynchronized ?? validation.isSynchronized
        let timedIndices: Set<Int>? = {
            if synced { return nil }
            let set = Set(lines.indices.filter { lines[$0].startTime != nil })
            if explicitlyTimedLineIndices != nil { return set }
            return set.isEmpty ? nil : set
        }()
        return LyricsDocument(
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lines: lines.map { $0.asLyricLine() },
            isSynchronized: synced,
            source: source,
            confidence: 1,
            providerSourceID: "manualEdit",
            language: language,
            explicitlyTimedLineIndices: timedIndices,
            timingVersionID: nil
        )
    }

    /// Counts for Assist partial-save UX.
    public var timedNonBlankLineCount: Int {
        lines.filter {
            !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.startTime != nil
        }.count
    }

    public var untimedNonBlankLineCount: Int {
        lines.filter {
            !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.startTime == nil
        }.count
    }

    public func nextUntimedLineID(after currentID: UUID?) -> UUID? {
        let nonBlank = lines.filter {
            !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonBlank.isEmpty else { return nil }
        if let currentID, let idx = nonBlank.firstIndex(where: { $0.id == currentID }) {
            for candidate in nonBlank.suffix(from: nonBlank.index(after: idx)) where candidate.startTime == nil {
                return candidate.id
            }
            for candidate in nonBlank where candidate.startTime == nil {
                return candidate.id
            }
            return nil
        }
        return nonBlank.first(where: { $0.startTime == nil })?.id
    }

    public mutating func update(_ lineID: UUID, _ change: (inout LyricsEditorLineDraft) -> Void) throws {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { throw LyricsEditorError.invalidLine }
        recordHistory()
        change(&lines[index])
    }

    public mutating func split(lineID: UUID, at offset: Int) throws {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { throw LyricsEditorError.invalidLine }
        let line = lines[index]
        let characters = Array(line.originalText)
        guard offset > 0, offset < characters.count else { throw LyricsEditorError.invalidSplitOffset }
        recordHistory()
        let left = String(characters[..<offset])
        let right = String(characters[offset...])
        let leftTranslation = splitCompanion(line.translationText, at: offset, preferLeft: true)
        let rightTranslation = splitCompanion(line.translationText, at: offset, preferLeft: false)
        lines[index] = LyricsEditorLineDraft(
            id: line.id,
            originalText: left,
            translationText: leftTranslation,
            startTime: line.startTime,
            endTime: nil,
            kanaText: nil,
            romajiText: nil
        )
        lines.insert(
            LyricsEditorLineDraft(
                originalText: right,
                translationText: rightTranslation,
                startTime: nil,
                endTime: line.endTime
            ),
            at: index + 1
        )
    }

    public mutating func merge(lineID: UUID, with nextID: UUID) throws {
        guard let index = lines.firstIndex(where: { $0.id == lineID }),
              index + 1 < lines.count,
              lines[index + 1].id == nextID else { throw LyricsEditorError.invalidLine }
        let first = lines[index]
        let second = lines[index + 1]
        recordHistory()
        lines[index] = LyricsEditorLineDraft(
            id: first.id,
            originalText: first.originalText + second.originalText,
            translationText: mergeCompanion(first.translationText, second.translationText),
            startTime: first.startTime ?? second.startTime,
            endTime: second.endTime ?? first.endTime,
            kanaText: nil,
            romajiText: nil
        )
        lines.remove(at: index + 1)
    }

    public mutating func insertBlank(after lineID: UUID? = nil) {
        recordHistory()
        let index: Int
        if let lineID, let found = lines.firstIndex(where: { $0.id == lineID }) {
            index = found + 1
        } else {
            index = lines.count
        }
        lines.insert(LyricsEditorLineDraft(originalText: ""), at: index)
    }

    public mutating func delete(lineID: UUID) throws {
        guard lines.count > 1 else { throw LyricsEditorError.cannotDeleteLastLine }
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { throw LyricsEditorError.invalidLine }
        recordHistory()
        lines.remove(at: index)
    }

    public mutating func move(lineID: UUID, offset: Int) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        let target = min(max(0, index + offset), lines.count - 1)
        guard target != index else { return }
        recordHistory()
        let line = lines.remove(at: index)
        lines.insert(line, at: target)
    }

    public mutating func undo() throws {
        guard let previous = undoStack.popLast() else { throw LyricsEditorError.nothingToUndo }
        redoStack.append(lines)
        lines = previous
    }

    public mutating func redo() throws {
        guard let next = redoStack.popLast() else { throw LyricsEditorError.nothingToRedo }
        undoStack.append(lines)
        lines = next
    }

    private mutating func recordHistory() {
        undoStack.append(lines)
        redoStack.removeAll()
    }

    private func splitCompanion(_ value: String?, at offset: Int, preferLeft: Bool) -> String? {
        guard let value, !value.isEmpty else { return value }
        let chars = Array(value)
        let split = min(offset, chars.count)
        if preferLeft { return String(chars[..<split]) }
        return String(chars[split...])
    }

    private func mergeCompanion(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs?.isEmpty == false ? lhs : nil, rhs?.isEmpty == false ? rhs : nil) {
        case let (left?, right?): return left + " " + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }
}
