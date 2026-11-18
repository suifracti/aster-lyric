import Foundation

public struct LRCMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    public var source: String?
    public var language: String?
    public var locked: Bool

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, duration: TimeInterval? = nil, source: String? = nil, language: String? = nil, locked: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.source = source
        self.language = language
        self.locked = locked
    }
}

public struct LRCImportResult: Equatable, Sendable {
    public let metadata: LRCMetadata
    public let lines: [LyricsEditorLineDraft]
    public let isSynchronized: Bool
    public let warnings: [String]

    public init(metadata: LRCMetadata, lines: [LyricsEditorLineDraft], isSynchronized: Bool, warnings: [String] = []) {
        self.metadata = metadata
        self.lines = lines
        self.isSynchronized = isSynchronized
        self.warnings = warnings
    }

    public func document(identity: TrackIdentity, track: Track, source: LyricsSource = .manualImport) -> LyricsDocument {
        let timedRows = Set(lines.indices.filter { lines[$0].startTime != nil })
        return LyricsDocument(
            identity: identity,
            title: metadata.title ?? track.title,
            artist: metadata.artist ?? track.artist,
            album: metadata.album ?? track.album,
            duration: metadata.duration ?? track.duration,
            lines: lines.map { $0.asLyricLine() },
            isSynchronized: isSynchronized,
            source: source,
            confidence: 1,
            providerSourceID: "manualImport",
            language: metadata.language,
            explicitlyTimedLineIndices: isSynchronized || timedRows.isEmpty ? nil : timedRows
        )
    }
}

public enum LRCImportError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case malformedTimestamp(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "LRC 文件没有歌词正文"
        case .malformedTimestamp(let value): return "LRC 时间标签无效：\(value)"
        }
    }
}

public enum LRCImportParser {
    private static let timestampExpression = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#)

    public static func parse(_ content: String) throws -> LRCImportResult {
        var metadata = LRCMetadata()
        var lines: [LyricsEditorLineDraft] = []
        var warnings: [String] = []

        let rawLines = content.components(separatedBy: .newlines)
        for (rawIndex, raw) in rawLines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !lines.isEmpty, rawIndex < rawLines.count - 1 {
                    lines.append(LyricsEditorLineDraft(originalText: ""))
                }
                continue
            }
            if let tag = metadataTag(in: line) {
                switch tag.key {
                case "ti": metadata.title = tag.value
                case "ar": metadata.artist = tag.value
                case "al": metadata.album = tag.value
                case "length": metadata.duration = parseLength(tag.value)
                case "source": metadata.source = tag.value
                case "language": metadata.language = tag.value
                case "locked": metadata.locked = tag.value == "true" || tag.value == "1"
                default: break
                }
                continue
            }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = timestampExpression.matches(in: line, range: range)
            let text = timestampExpression.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if matches.isEmpty {
                lines.append(LyricsEditorLineDraft(originalText: line))
                continue
            }
            for match in matches {
                guard let timestamp = timestamp(from: match, in: line) else {
                    warnings.append("跳过无效时间标签")
                    continue
                }
                lines.append(LyricsEditorLineDraft(originalText: text, startTime: timestamp))
            }
        }

        guard !lines.isEmpty, lines.contains(where: { !$0.originalText.isEmpty }) else { throw LRCImportError.empty }
        let nonBlank = lines.filter { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isSynchronized = nonBlank.allSatisfy { $0.startTime != nil } && nonBlank.contains(where: { $0.startTime != nil })
        if isSynchronized {
            // Blank separators in a formatted file have no playback timestamp.
            lines.removeAll { $0.startTime == nil }
            lines.sort { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        }
        return LRCImportResult(metadata: metadata, lines: lines, isSynchronized: isSynchronized, warnings: warnings)
    }

    private static func metadataTag(in line: String) -> (key: String, value: String)? {
        guard line.first == "[", let colon = line.firstIndex(of: ":"), let end = line.firstIndex(of: "]"), colon < end else { return nil }
        let key = String(line[line.index(after: line.startIndex)..<colon]).lowercased()
        let value = String(line[line.index(after: colon)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if key == "length" || key == "ti" || key == "ar" || key == "al" || key == "source" || key == "language" || key == "locked" { return (key, value) }
        return nil
    }

    private static func timestamp(from match: NSTextCheckingResult, in line: String) -> TimeInterval? {
        guard let minutes = Range(match.range(at: 1), in: line).flatMap({ Double(line[$0]) }),
              let seconds = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) }) else { return nil }
        var fraction = 0.0
        if let range = Range(match.range(at: 3), in: line) {
            let text = String(line[range])
            fraction = (Double(text) ?? 0) / pow(10, Double(text.count))
        }
        return minutes * 60 + seconds + fraction
    }

    private static func parseLength(_ value: String) -> TimeInterval? {
        let pieces = value.split(separator: ":")
        guard pieces.count == 2, let minutes = Double(pieces[0]), let seconds = Double(pieces[1]),
              minutes >= 0, seconds >= 0 else { return nil }
        let duration = minutes * 60 + seconds
        return duration.isFinite && duration < Double(Int.max) / 1000 ? duration : nil
    }
}

public struct LRCImportMatchReport: Equatable, Sendable {
    public let titleMatches: Bool
    public let artistMatches: Bool
    public let durationMatches: Bool
    public var isMismatchWarning: Bool { !titleMatches || !artistMatches || !durationMatches }
}

public enum LRCImportMatcher {
    public static func compare(metadata: LRCMetadata, track: Track, durationTolerance: TimeInterval = 5) -> LRCImportMatchReport {
        func normalize(_ value: String?) -> String { (value ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).replacingOccurrences(of: " ", with: "").lowercased() }
        let titleMatches = metadata.title.map { normalize($0) == normalize(track.title) } ?? true
        let artistMatches = metadata.artist.map { normalize($0).contains(normalize(track.artist)) || normalize(track.artist).contains(normalize($0)) } ?? true
        let durationMatches = metadata.duration.map { abs($0 - track.duration) <= durationTolerance } ?? true
        return LRCImportMatchReport(titleMatches: titleMatches, artistMatches: artistMatches, durationMatches: durationMatches)
    }
}

public enum LRCExporter {
    public static func original(document: LyricsDocument, source: String, locked: Bool) -> String {
        var metadata = [("source", source), ("locked", locked ? "true" : "false")]
        if let language = document.language, !language.isEmpty { metadata.append(("language", language)) }
        return export(document: document, text: document.lines.map(\.originalText), metadata: metadata)
    }

    public static func translation(document: LyricsDocument, translations: [String], targetLanguage: String, source: String, locked: Bool) -> String {
        export(document: document, text: translations, metadata: [
            ("language", targetLanguage), ("source", source), ("locked", locked ? "true" : "false")
        ])
    }

    private static func export(document: LyricsDocument, text: [String], metadata: [(String, String)]) -> String {
        var output: [String] = []
        if let title = document.title { output.append("[ti:\(title)]") }
        if let artist = document.artist { output.append("[ar:\(artist)]") }
        if let album = document.album { output.append("[al:\(album)]") }
        if let duration = document.duration { output.append("[length:\(formatLength(duration))]") }
        for (key, value) in metadata { output.append("[\(key):\(value)]") }
        for index in document.lines.indices {
            let body = text.indices.contains(index) ? text[index] : ""
            if document.lineHasExplicitTiming(index) {
                let timestamp = document.lines[index].timestamp
                output.append("[\(formatTimestamp(timestamp))]\(body)")
            } else {
                output.append(body)
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func formatTimestamp(_ value: TimeInterval) -> String {
        let safe = max(0, value)
        let minutes = Int(safe / 60)
        let seconds = safe - Double(minutes * 60)
        return String(format: "%02d:%06.3f", minutes, seconds)
    }

    private static func formatLength(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
