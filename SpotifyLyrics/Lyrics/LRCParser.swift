import Foundation

public enum LRCParser {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    )

    public static func parse(
        _ content: String,
        identity: TrackIdentity,
        source: LyricsSource
    ) -> LyricsDocument? {
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval?
        var parsedLines: [LyricLine] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let tag = metadataTag(in: line) {
                switch tag.key {
                case "ti": title = tag.value
                case "ar": artist = tag.value
                case "al": album = tag.value
                case "length": duration = parseLength(tag.value)
                default: break
                }
            }

            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = timestampExpression.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }

            let text = timestampExpression.stringByReplacingMatches(
                in: line,
                range: fullRange,
                withTemplate: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let timestamp = timestamp(from: match, in: line) else { continue }
                parsedLines.append(
                    LyricLine(timestamp: timestamp, originalText: text)
                )
            }
        }

        guard !parsedLines.isEmpty else { return nil }
        parsedLines.sort { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timestamp < rhs.timestamp
        }

        return LyricsDocument(
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lines: parsedLines,
            source: source,
            confidence: 1
        )
    }

    private static func metadataTag(in line: String) -> (key: String, value: String)? {
        guard line.first == "[", let closing = line.firstIndex(of: ":"), let end = line.firstIndex(of: "]"), closing < end else {
            return nil
        }
        let keyStart = line.index(after: line.startIndex)
        let key = String(line[keyStart..<closing]).lowercased()
        let valueStart = line.index(after: closing)
        let value = String(line[valueStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private static func timestamp(from match: NSTextCheckingResult, in line: String) -> TimeInterval? {
        guard match.numberOfRanges >= 4,
              let minuteRange = Range(match.range(at: 1), in: line),
              let secondRange = Range(match.range(at: 2), in: line),
              let minute = Double(line[minuteRange]),
              let seconds = Double(line[secondRange]) else {
            return nil
        }

        var fraction = 0.0
        if let fractionRange = Range(match.range(at: 3), in: line) {
            let fractionText = String(line[fractionRange])
            let denominator = pow(10.0, Double(fractionText.count))
            fraction = (Double(fractionText) ?? 0) / denominator
        }
        return minute * 60 + seconds + fraction
    }

    private static func parseLength(_ value: String) -> TimeInterval? {
        let pieces = value.split(separator: ":")
        guard pieces.count == 2,
              let minutes = Double(pieces[0]),
              let seconds = Double(pieces[1]) else {
            return nil
        }
        return minutes * 60 + seconds
    }

    fileprivate static func timedTextLines(in content: String) -> [(timestamp: TimeInterval, text: String)] {
        var result: [(timestamp: TimeInterval, text: String)] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = timestampExpression.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }
            let text = timestampExpression.stringByReplacingMatches(
                in: line,
                range: fullRange,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for match in matches {
                guard let timestamp = timestamp(from: match, in: line) else { continue }
                result.append((timestamp, text))
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }
}

public enum TimedLyricsCompanionLayer: Sendable {
    case translation
    case romaji
}

/// Attaches independently timed translation or romanization lines without
/// replacing the provider's original lyric text. Companion feeds frequently
/// differ from the primary LRC by a few hundredths of a second, so exact
/// timestamp dictionaries are too brittle.
public enum TimedLyricsCompanionMerger {
    public static func merge(
        _ content: String?,
        into lines: [LyricLine],
        layer: TimedLyricsCompanionLayer,
        tolerance: TimeInterval = 0.35
    ) -> [LyricLine] {
        guard let content, !content.isEmpty, tolerance >= 0 else { return lines }
        let companions = LRCParser.timedTextLines(in: content)
        guard !companions.isEmpty else { return lines }

        var consumed = Set<Int>()
        return lines.map { source in
            var bestIndex: Int?
            var bestDistance = TimeInterval.greatestFiniteMagnitude
            for index in companions.indices where !consumed.contains(index) {
                let distance = abs(companions[index].timestamp - source.timestamp)
                guard distance <= tolerance else { continue }
                if distance < bestDistance {
                    bestIndex = index
                    bestDistance = distance
                }
            }
            guard let bestIndex else { return source }
            consumed.insert(bestIndex)
            var merged = source
            switch layer {
            case .translation:
                merged.translationText = companions[bestIndex].text
            case .romaji:
                merged.romajiText = companions[bestIndex].text
            }
            return merged
        }
    }
}

/// Attaches untimed companion text by row order only when both feeds are plain
/// text and have exactly the same number of non-empty rows.
public enum PlainLyricsCompanionMerger {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"\[\d+:\d+(?:[\.:]\d+)?\]|\[\d+,\d+(?:,\d+)?\]"#
    )

    public static func merge(
        _ content: String?,
        original: String,
        into lines: [LyricLine],
        layer: TimedLyricsCompanionLayer
    ) -> [LyricLine] {
        guard let content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !containsTimestamp(in: original),
              !containsTimestamp(in: content),
              lines.allSatisfy({ $0.timestamp == 0 && $0.endTime == nil && !$0.hasTimedSpans }) else {
            return lines
        }

        let companions = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, companions.count == lines.count else { return lines }

        let originalRows = original.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard originalRows == lines.map(\.originalText) else { return lines }
        var mergedLines = lines
        for (index, text) in companions.enumerated() {
            switch layer {
            case .translation:
                mergedLines[index].translationText = text
            case .romaji:
                mergedLines[index].romajiText = text
            }
        }
        return mergedLines
    }

    private static func containsTimestamp(in content: String) -> Bool {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return timestampExpression.firstMatch(in: content, range: range) != nil
    }
}
