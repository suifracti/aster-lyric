import Foundation

/// The encoding detected for a plain-text lyric import.  `plainText` is used
/// for pasted text, while the BOM cases are kept separate so the preview can
/// explain exactly what was read from disk.
public enum TextLyricsEncoding: String, Equatable, Sendable {
    case plainText
    case utf8
    case utf8BOM
    case utf16LittleEndian
    case utf16BigEndian
}

public enum TextLyricsWarningKind: String, Equatable, Sendable {
    case sectionMarker
    case timestampLabel
    case advertisement
    case credits
}

public struct TextLyricsImportWarning: Equatable, Sendable {
    public let kind: TextLyricsWarningKind
    public let lineIndex: Int
    public let text: String

    public init(kind: TextLyricsWarningKind, lineIndex: Int, text: String) {
        self.kind = kind
        self.lineIndex = lineIndex
        self.text = text
    }
}

public enum TextLyricsImportError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedEncoding
    case empty

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "无法识别 TXT 文件编码"
        case .empty:
            return "歌词文本为空，未创建歌词版本"
        }
    }
}

public struct TextLyricsImportResult: Equatable, Sendable {
    public let encoding: TextLyricsEncoding
    public let lines: [String]
    public let warnings: [TextLyricsImportWarning]

    public init(
        encoding: TextLyricsEncoding,
        lines: [String],
        warnings: [TextLyricsImportWarning]
    ) {
        self.encoding = encoding
        self.lines = lines
        self.warnings = warnings
    }

    public var normalizedText: String {
        lines.joined(separator: "\n")
    }

    public func document(
        identity: TrackIdentity,
        track: Track,
        source: LyricsSource = .manualImport
    ) -> LyricsDocument {
        LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            lines: lines.map { line in
                LyricLine(timestamp: 0, originalText: line)
            },
            isSynchronized: false,
            source: source,
            confidence: 1,
            providerSourceID: nil,
            spotifyTrackID: identity.spotifyTrackID,
            isrc: identity.isrc
        )
    }
}

/// Deterministic plain-text import shared by file and clipboard flows.
///
/// This parser deliberately does not attempt to remove web-site material or
/// rewrite lyric text.  It only normalizes line endings, trims line edges and
/// collapses excessive blank rows; suspicious rows are surfaced as warnings
/// for the editor preview to let the user decide.
public enum TextLyricsImportParser {
    public static func parse(_ data: Data) throws -> TextLyricsImportResult {
        let decoded = try decode(data)
        return try makeResult(text: decoded.text, encoding: decoded.encoding)
    }

    static func decode(_ data: Data) throws -> (text: String, encoding: TextLyricsEncoding) {
        let decoded: (String, TextLyricsEncoding)

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw TextLyricsImportError.unsupportedEncoding
            }
            decoded = (text, .utf8BOM)
        } else if data.starts(with: [0xFF, 0xFE]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
                throw TextLyricsImportError.unsupportedEncoding
            }
            decoded = (text, .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else {
                throw TextLyricsImportError.unsupportedEncoding
            }
            decoded = (text, .utf16BigEndian)
        } else if let text = String(data: data, encoding: .utf8) {
            decoded = (text, .utf8)
        } else if let text = String(data: data, encoding: .utf16LittleEndian) {
            decoded = (text, .utf16LittleEndian)
        } else if let text = String(data: data, encoding: .utf16BigEndian) {
            decoded = (text, .utf16BigEndian)
        } else {
            throw TextLyricsImportError.unsupportedEncoding
        }

        return decoded
    }

    public static func parse(_ text: String) throws -> TextLyricsImportResult {
        try makeResult(text: text, encoding: .plainText)
    }

    private static func makeResult(
        text: String,
        encoding: TextLyricsEncoding
    ) throws -> TextLyricsImportResult {
        // Some clipboard managers preserve a BOM even though the data no
        // longer carries an encoding marker. Treat it like the file parser
        // does instead of exposing an invisible character in the first row.
        let textWithoutBOM = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let normalized = textWithoutBOM
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }

        var cleaned: [String] = []
        cleaned.reserveCapacity(lines.count)
        var previousWasBlank = false
        for line in lines {
            let isBlank = line.isEmpty
            if isBlank && previousWasBlank { continue }
            cleaned.append(line)
            previousWasBlank = isBlank
        }

        guard cleaned.contains(where: { !$0.isEmpty }) else {
            throw TextLyricsImportError.empty
        }

        let warnings = cleaned.enumerated().compactMap { index, line in
            warning(for: line, lineIndex: index)
        }
        return TextLyricsImportResult(encoding: encoding, lines: cleaned, warnings: warnings)
    }

    private static func warning(
        for line: String,
        lineIndex: Int
    ) -> TextLyricsImportWarning? {
        let lowercased = line.lowercased()

        let sectionPrefixes = [
            "[verse", "[chorus", "[bridge", "[pre-chorus", "[pre chorus",
            "[intro", "[outro", "[hook", "[refrain"
        ]
        if sectionPrefixes.contains(where: { lowercased.hasPrefix($0) }) && lowercased.hasSuffix("]") {
            return TextLyricsImportWarning(kind: .sectionMarker, lineIndex: lineIndex, text: line)
        }

        if line.range(of: #"^\s*\[\d{1,3}:\d{2}(?:[\.:]\d{1,3})?\]"#, options: .regularExpression) != nil {
            return TextLyricsImportWarning(kind: .timestampLabel, lineIndex: lineIndex, text: line)
        }

        let advertisementWords = [
            "歌词网站广告", "歌词下载", "music.163.com", "酷狗", "网易云",
            "qq音乐", "http://", "https://", "www."
        ]
        if advertisementWords.contains(where: { lowercased.contains($0.lowercased()) }) {
            return TextLyricsImportWarning(kind: .advertisement, lineIndex: lineIndex, text: line)
        }

        if line.range(of: #"^\s*(作词|作曲|编曲|制作人|演唱|词|曲|lyrics\s+by|written\s+by|produced\s+by)\s*[:：]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return TextLyricsImportWarning(kind: .credits, lineIndex: lineIndex, text: line)
        }

        return nil
    }
}

/// The destination of a pasted lyric corpus.  The importer intentionally
/// keeps the original lyric version and the translation layer separate; a
/// paste can therefore never rewrite timestamps or silently replace the
/// source document.
public enum TranslationPasteTarget: String, CaseIterable, Sendable {
    case translation
    case original

    public var title: String {
        switch self {
        case .translation: return "翻译"
        case .original: return "原文"
        }
    }
}

public enum TranslationPasteMatchConfidence: String, Equatable, Sendable {
    case high
    case unconfirmed
    case ambiguous
}

public struct TranslationPasteLineMatch: Equatable, Sendable {
    public let importedIndex: Int
    public let sourceLineIndex: Int
    public let importedTimestamp: TimeInterval?
    public let sourceTimestamp: TimeInterval?
    public let text: String
    public let confidence: TranslationPasteMatchConfidence

    public init(
        importedIndex: Int,
        sourceLineIndex: Int,
        importedTimestamp: TimeInterval?,
        sourceTimestamp: TimeInterval?,
        text: String,
        confidence: TranslationPasteMatchConfidence
    ) {
        self.importedIndex = importedIndex
        self.sourceLineIndex = sourceLineIndex
        self.importedTimestamp = importedTimestamp
        self.sourceTimestamp = sourceTimestamp
        self.text = text
        self.confidence = confidence
    }
}

public struct TranslationPasteImportPreview: Equatable, Sendable {
    public let target: TranslationPasteTarget
    public let sourceLineCount: Int
    public let importedLineCount: Int
    public let sourceWasTimed: Bool
    public let importedWasTimed: Bool
    public let detectedOffset: TimeInterval?
    public let matches: [TranslationPasteLineMatch]
    public let missingSourceLineIndices: [Int]
    public let extraImportedLineIndices: [Int]
    public let ambiguousImportedLineIndices: [Int]

    public init(
        target: TranslationPasteTarget,
        sourceLineCount: Int,
        importedLineCount: Int,
        sourceWasTimed: Bool,
        importedWasTimed: Bool,
        detectedOffset: TimeInterval?,
        matches: [TranslationPasteLineMatch],
        missingSourceLineIndices: [Int],
        extraImportedLineIndices: [Int],
        ambiguousImportedLineIndices: [Int]
    ) {
        self.target = target
        self.sourceLineCount = sourceLineCount
        self.importedLineCount = importedLineCount
        self.sourceWasTimed = sourceWasTimed
        self.importedWasTimed = importedWasTimed
        self.detectedOffset = detectedOffset
        self.matches = matches
        self.missingSourceLineIndices = missingSourceLineIndices
        self.extraImportedLineIndices = extraImportedLineIndices
        self.ambiguousImportedLineIndices = ambiguousImportedLineIndices
    }

    public var canApply: Bool {
        missingSourceLineIndices.isEmpty && extraImportedLineIndices.isEmpty
            && ambiguousImportedLineIndices.isEmpty
            && matches.count == sourceLineCount
            && matches.allSatisfy { $0.confidence == .high }
    }

    public var summary: String {
        var result = "\(target.title)：\(matches.count)/\(sourceLineCount) 行已匹配"
        if let detectedOffset, abs(detectedOffset) >= 0.005 {
            let direction = detectedOffset >= 0 ? "后移" : "提前"
            result += "，检测到整体\(direction) \(String(format: "%.2fs", abs(detectedOffset)))"
        }
        if !missingSourceLineIndices.isEmpty {
            result += "，缺少 \(missingSourceLineIndices.count) 行"
        }
        if !extraImportedLineIndices.isEmpty {
            result += "，多出 \(extraImportedLineIndices.count) 行"
        }
        if !ambiguousImportedLineIndices.isEmpty {
            result += "，\(ambiguousImportedLineIndices.count) 行待确认"
        }
        return result
    }
}

public enum TranslationPasteImportError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case sourceNotTimed
    case cannotApply

    public var errorDescription: String? {
        switch self {
        case .empty: return "没有可导入的非空歌词行"
        case .sourceNotTimed: return "当前歌词没有可用于匹配的时间轴"
        case .cannotApply: return "导入存在缺行、多行或歧义，请先处理预览"
        }
    }
}

/// Preview-first paste alignment for translation/original text.  Timestamped
/// input is matched by a detected constant offset plus a small residual
/// tolerance. Untimed input is only mapped sequentially when the non-blank
/// counts are exactly equal. Both paths are deliberately fail-closed.
public enum TranslationPasteImporter {
    private struct ImportedLine {
        let index: Int
        let text: String
        let timestamp: TimeInterval?
    }

    private static let timestampPattern = #"\[\d{1,3}:\d{2}(?:[\.:]\d{1,3})?\]"#

    public static func preview(
        content: String,
        sourceLines: [LyricsEditorLineDraft],
        sourceIsSynchronized: Bool,
        target: TranslationPasteTarget,
        tolerance: TimeInterval = 0.6
    ) throws -> TranslationPasteImportPreview {
        let imported = try parseImportedLines(content)
        let source = sourceLines.enumerated().compactMap { index, line -> (Int, LyricsEditorLineDraft)? in
            guard !line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (index, line)
        }
        guard !source.isEmpty else { throw TranslationPasteImportError.empty }

        let sourceWasTimed = sourceIsSynchronized && source.allSatisfy { $0.1.startTime?.isFinite == true }
        let importedWasTimed = imported.contains { $0.timestamp != nil }
        guard !imported.isEmpty else { throw TranslationPasteImportError.empty }

        if importedWasTimed {
            guard sourceWasTimed else { throw TranslationPasteImportError.sourceNotTimed }
            return timestampedPreview(
                imported: imported,
                source: source,
                target: target,
                tolerance: max(0.05, tolerance)
            )
        }

        let count = min(imported.count, source.count)
        let exactCount = imported.count == source.count
        let matches = (0..<count).map { ordinal in
            TranslationPasteLineMatch(
                importedIndex: imported[ordinal].index,
                sourceLineIndex: source[ordinal].0,
                importedTimestamp: nil,
                sourceTimestamp: source[ordinal].1.startTime,
                text: imported[ordinal].text,
                confidence: exactCount ? .high : .unconfirmed
            )
        }
        return TranslationPasteImportPreview(
            target: target,
            sourceLineCount: source.count,
            importedLineCount: imported.count,
            sourceWasTimed: sourceWasTimed,
            importedWasTimed: false,
            detectedOffset: nil,
            matches: matches,
            missingSourceLineIndices: source.dropFirst(count).map(\.0),
            extraImportedLineIndices: imported.dropFirst(count).map(\.index),
            ambiguousImportedLineIndices: exactCount ? [] : matches.map(\.importedIndex)
        )
    }

    public static func apply(
        _ preview: TranslationPasteImportPreview,
        to sourceLines: [LyricsEditorLineDraft]
    ) throws -> [LyricsEditorLineDraft] {
        guard preview.canApply else { throw TranslationPasteImportError.cannotApply }
        var result = sourceLines
        for match in preview.matches {
            guard result.indices.contains(match.sourceLineIndex) else { throw TranslationPasteImportError.cannotApply }
            switch preview.target {
            case .translation:
                result[match.sourceLineIndex].translationText = match.text
            case .original:
                result[match.sourceLineIndex].originalText = match.text
            }
        }
        return result
    }

    private static func parseImportedLines(_ content: String) throws -> [ImportedLine] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationPasteImportError.empty
        }
        let isTimestamped = normalized.range(of: timestampPattern, options: .regularExpression) != nil
        if isTimestamped {
            let parsed = try LRCImportParser.parse(normalized)
            return parsed.lines.enumerated().compactMap { index, line in
                guard !line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ImportedLine(index: index, text: line.originalText, timestamp: line.startTime)
            }
        }
        return normalized.components(separatedBy: "\n").enumerated().compactMap { index, raw in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ImportedLine(index: index, text: text, timestamp: nil)
        }
    }

    private static func timestampedPreview(
        imported: [ImportedLine],
        source: [(Int, LyricsEditorLineDraft)],
        target: TranslationPasteTarget,
        tolerance: TimeInterval
    ) -> TranslationPasteImportPreview {
        let pairCount = min(imported.count, source.count)
        let diffs = (0..<pairCount).compactMap { ordinal -> TimeInterval? in
            guard let importedTime = imported[ordinal].timestamp,
                  let sourceTime = source[ordinal].1.startTime,
                  importedTime.isFinite, sourceTime.isFinite else { return nil }
            return importedTime - sourceTime
        }
        let offset = median(diffs)
        var used = Set<Int>()
        var matches: [TranslationPasteLineMatch] = []
        var ambiguous: [Int] = []
        for item in imported {
            guard let importedTime = item.timestamp else {
                ambiguous.append(item.index)
                continue
            }
            let candidates = source.enumerated().compactMap { sourceOrdinal, entry -> Int? in
                guard !used.contains(sourceOrdinal), let sourceTime = entry.1.startTime else { return nil }
                let residual = importedTime - (sourceTime + (offset ?? 0))
                return abs(residual) <= tolerance ? sourceOrdinal : nil
            }
            guard candidates.count == 1, let sourceOrdinal = candidates.first else {
                ambiguous.append(item.index)
                continue
            }
            used.insert(sourceOrdinal)
            matches.append(TranslationPasteLineMatch(
                importedIndex: item.index,
                sourceLineIndex: source[sourceOrdinal].0,
                importedTimestamp: importedTime,
                sourceTimestamp: source[sourceOrdinal].1.startTime,
                text: item.text,
                confidence: .high
            ))
        }
        let missing = source.enumerated().compactMap { ordinal, entry in
            used.contains(ordinal) ? nil : entry.0
        }
        let extra = imported.map(\.index).filter { importedIndex in
            !matches.contains(where: { $0.importedIndex == importedIndex })
                && !ambiguous.contains(importedIndex)
        }
        return TranslationPasteImportPreview(
            target: target,
            sourceLineCount: source.count,
            importedLineCount: imported.count,
            sourceWasTimed: true,
            importedWasTimed: true,
            detectedOffset: offset,
            matches: matches.sorted { $0.importedIndex < $1.importedIndex },
            missingSourceLineIndices: missing,
            extraImportedLineIndices: extra,
            ambiguousImportedLineIndices: ambiguous
        )
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
