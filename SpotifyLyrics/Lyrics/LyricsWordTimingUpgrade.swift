import Foundation

/// Stored line-timed lyrics can be upgraded to word timing (网易 yrc, QQ qrc,
/// 酷狗 krc, AMLL) when a source later offers it for the same song. Lyrimuse
/// showed 逐字 for Lost My Mind while we kept a QQ line-timed version saved
/// before QRC was read; QQ had the QRC all along.
///
/// The upgrade never changes what the listener reads: the new version must
/// carry the same lines at the same moments, only with finer timing. A
/// manual, local, aligned or ASR version is never replaced.
public enum LyricsWordTimingUpgrade {
    /// Sources whose stored line timing came from an online catalogue.
    static let upgradableSources: Set<LyricsSource> = [
        .amll, .lrclib, .neteaseExperimental, .qqExperimental,
        .kuwoExperimental, .kugouExperimental, .linkcore, .petitLyrics,
    ]

    /// Largest start-time difference for a line to count as the same moment.
    static let lineStartTolerance: TimeInterval = 1.0
    /// Share of the held sung lines that must reappear in the upgrade.
    static let requiredCoverage = 0.8

    public static func hasWordTiming(_ document: LyricsDocument) -> Bool {
        let sung = document.lines.filter { !normalized($0.originalText).isEmpty }
        guard !sung.isEmpty else { return false }
        let worded = sung.filter { $0.hasValidTimedSpans(lineStartIsMeaningful: document.isSynchronized) }
        return worded.count * 2 >= sung.count
    }

    /// True for a stored, online, line-timed version without word timing.
    public static func wantsUpgrade(_ held: LyricsDocument) -> Bool {
        held.isSynchronized
            && upgradableSources.contains(held.source)
            && !held.lines.contains(where: { !($0.timedSpans?.isEmpty ?? true) })
            && held.lines.contains(where: { !normalized($0.originalText).isEmpty })
    }

    public static func isCompatible(held: LyricsDocument, upgrade: LyricsDocument) -> Bool {
        addingTiming(from: upgrade, to: held) != nil
    }

    /// Keep the original rows and their timestamps. Only attach spans that can
    /// light the corresponding characters in the listener's chosen text.
    static func addingTiming(from upgrade: LyricsDocument, to held: LyricsDocument) -> LyricsDocument? {
        guard wantsUpgrade(held), upgrade.isSynchronized, held.identity == upgrade.identity else { return nil }
        let lines = matchingRows(from: upgrade, to: held) ?? matchingWords(from: upgrade, to: held)
        return lines.map { held.replacingLines($0, timingVersionID: nil) }
    }

    private static func matchingRows(from upgrade: LyricsDocument, to held: LyricsDocument) -> [LyricLine]? {
        var byText = Dictionary(grouping: upgrade.lines, by: { normalized($0.originalText) })
        var lines = held.lines
        var sung = 0, matched = 0, timed = 0
        for index in lines.indices {
            let original = lines[index]
            let key = normalized(original.originalText)
            guard !key.isEmpty else { continue }
            sung += 1
            guard let candidates = byText[key],
                  let nearest = candidates.indices.min(by: {
                      abs(candidates[$0].timestamp - original.timestamp) < abs(candidates[$1].timestamp - original.timestamp)
                  }), abs(candidates[nearest].timestamp - original.timestamp) <= lineStartTolerance else { continue }
            let donor = candidates[nearest]
            byText[key]?.remove(at: nearest)
            matched += 1
            if let line = addingSpans(from: donor, to: original) {
                lines[index] = line
                timed += 1
            }
        }
        guard Double(matched) >= Double(sung) * requiredCoverage, timed * 2 >= sung else { return nil }
        return lines
    }

    private struct DonorWord {
        let row: Int
        let letters: [Unicode.Scalar]
        let span: TimedTextSpan
    }

    private typealias Letter = (value: Unicode.Scalar, range: Range<String.Index>)

    /// The same recording can break a phrase across different rows. Match
    /// complete saved rows against contiguous donor words in timeline order.
    private static func matchingWords(from upgrade: LyricsDocument, to held: LyricsDocument) -> [LyricLine]? {
        let words = upgrade.lines.enumerated().flatMap { row, line -> [DonorWord] in
            guard line.hasValidTimedSpans(), let spans = line.timedSpans,
                  normalized(spans.map(\.text).joined()) == normalized(line.originalText) else { return [] }
            return spans.compactMap { span in
                let letters = Array(normalized(span.text).unicodeScalars)
                return letters.isEmpty ? nil : DonorWord(row: row, letters: letters, span: span)
            }
        }
        guard !words.isEmpty else { return nil }
        var lines = held.lines
        var nextWord = 0
        var sung = 0
        var timed = 0
        for (index, original) in held.lines.enumerated() {
            let text = original.originalText
            let letters: [Letter] = text.indices.flatMap { start in
                let range = start..<text.index(after: start)
                return normalized(String(text[range])).unicodeScalars.map { (value: $0, range: range) }
            }
            guard !letters.isEmpty else { continue }
            sung += 1
            guard let range = matchingWordRange(letters.map(\.value), at: original.timestamp, in: words, after: nextWord),
                  let projected = projectWords(words[range], onto: original, letters: letters) else { continue }
            nextWord = range.upperBound
            lines[index] = projected
            timed += 1
        }
        // Require timeline-aligned word evidence for at least two thirds of
        // the saved sung rows. Differently worded rows keep their line timing.
        return sung > 0 && timed * 3 >= sung * 2 ? lines : nil
    }

    private static func matchingWordRange(_ letters: [Unicode.Scalar], at timestamp: TimeInterval,
                                          in words: [DonorWord], after consumed: Int) -> Range<Int>? {
        var best: Range<Int>?
        var distance = TimeInterval.infinity
        for start in words.indices.dropFirst(consumed) {
            let delta = abs(words[start].span.startTime - timestamp)
            guard delta <= lineStartTolerance, delta < distance else { continue }
            var offset = 0
            var end = start
            while end < words.count, end == start || words[end].row - words[end - 1].row <= 1,
                  letters.dropFirst(offset).starts(with: words[end].letters) {
                offset += words[end].letters.count
                end += 1
                if offset == letters.count {
                    best = start..<end
                    distance = delta
                    break
                }
            }
        }
        return best
    }

    private static func projectWords(_ words: ArraySlice<DonorWord>, onto original: LyricLine,
                                     letters: [Letter]) -> LyricLine? {
        let text = original.originalText
        let upperTime = original.endTime ?? .infinity
        var offset = 0
        let spans = words.enumerated().map { id, word in
            let startIndex = letters[offset].range.lowerBound
            offset += word.letters.count
            let endIndex = letters[offset - 1].range.upperBound
            let range = NSRange(startIndex..<endIndex, in: text)
            let start = min(upperTime, max(original.timestamp, word.span.startTime))
            let end = max(start, min(upperTime, word.span.endTime))
            return TimedTextSpan(id: id, text: String(text[startIndex..<endIndex]),
                trailingWhitespace: String(text[endIndex...].prefix(while: \.isWhitespace)), startTime: start, endTime: end,
                utf16Start: range.location, utf16Length: range.length, granularity: word.span.granularity)
        }
        var line = original
        line.timedSpans = spans
        return spans.contains { $0.endTime > $0.startTime } && line.hasValidTimedSpans() ? line : nil
    }

    private static func addingSpans(from donor: LyricLine, to original: LyricLine) -> LyricLine? {
        guard donor.hasValidTimedSpans(), let spans = donor.resolvedGraphemeSpans() else { return nil }
        let text = original.originalText
        let sameText = text.utf8.elementsEqual(donor.originalText.utf8)
        var cursor = text.startIndex
        var donorCursor = donor.originalText.startIndex
        var mapped: [TimedTextSpan] = []
        for span in spans {
            let range: Range<String.Index>
            if sameText {
                range = span.range
            } else if let found = text.range(of: span.text, options: .caseInsensitive, range: cursor..<text.endIndex),
                      normalized(String(text[cursor..<found.lowerBound])) ==
                        normalized(String(donor.originalText[donorCursor..<span.range.lowerBound])) {
                range = found
            } else {
                return nil
            }
            let start = max(span.startTime, original.timestamp)
            let end = min(span.endTime, original.endTime ?? span.endTime)
            guard end >= start else { return nil }
            let offsets = NSRange(range, in: text)
            mapped.append(TimedTextSpan(id: span.id, text: String(text[range]),
                trailingWhitespace: String(text[range.upperBound...].prefix(while: \.isWhitespace)),
                startTime: start, endTime: end, utf16Start: offsets.location, utf16Length: offsets.length,
                granularity: span.granularity))
            cursor = range.upperBound
            donorCursor = span.range.upperBound
        }
        var line = original
        line.timedSpans = mapped
        line.performerID = original.performerID ?? donor.performerID
        line.backgroundText = original.backgroundText ?? donor.backgroundText
        return line.hasValidTimedSpans() ? line : nil
    }

    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }))
    }
}

/// QRC, KRC and YRC give each line a `[start,duration]` header rounded on its
/// own, so the last word can end a few milliseconds after the line (Lost My
/// Mind: 「また世界の底に」 words to 31.396). `hasValidTimedSpans` then rejected
/// the whole song's word timing and it ranked as line timing. The line now
/// covers its words.
enum TimedLineBounds {
    static func covering(spans: [TimedTextSpan], start: TimeInterval, end: TimeInterval?) -> (start: TimeInterval, end: TimeInterval?) {
        guard let first = spans.map(\.startTime).min(), let last = spans.map(\.endTime).max() else { return (start, end) }
        return (min(start, first), end.map { max($0, last) })
    }
}
