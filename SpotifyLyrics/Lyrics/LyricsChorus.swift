import Foundation

/// Where the chorus is, from the lyrics alone: a run of at least two lines
/// that comes back later in the song (with at least ten characters between
/// them) is treated as chorus, every time it occurs. No audio, no login.
/// Only for timed lyrics; the result is cached per document.
enum LyricsChorus {
    struct Span: Equatable, Sendable {
        let lines: ClosedRange<Int>
        let start: TimeInterval
        let end: TimeInterval
    }

    @MainActor private static var cache: (key: Int, spans: [Span])?

    @MainActor static func spans(lines: [LyricLine], duration: TimeInterval) -> [Span] {
        var hasher = Hasher()
        hasher.combine(duration)
        for line in lines { hasher.combine(line.id) }
        let key = hasher.finalize()
        if let cache, cache.key == key { return cache.spans }
        let result = compute(lines: lines, duration: duration)
        cache = (key, result)
        return result
    }

    @MainActor static func contains(_ index: Int?, lines: [LyricLine], duration: TimeInterval) -> Bool {
        guard let index else { return false }
        return spans(lines: lines, duration: duration).contains { $0.lines.contains(index) }
    }

    /// True for the first line of a chorus (the moment it begins).
    @MainActor static func starts(at index: Int?, lines: [LyricLine], duration: TimeInterval) -> Bool {
        guard let index else { return false }
        return spans(lines: lines, duration: duration).contains { $0.lines.lowerBound == index }
    }

    static func compute(lines: [LyricLine], duration: TimeInterval) -> [Span] {
        let count = lines.count
        guard count >= 4 else { return [] }
        let keys: [String] = lines.map { line in
            let key = TrackTextNormalizer.normalize(line.originalText).unicodeScalars
                .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            let text = String(String.UnicodeScalarView(key))
            return text.count >= 2 ? text : ""
        }
        var marked = Array(repeating: false, count: count)
        for i in 0..<count where !keys[i].isEmpty {
            for j in (i + 1)..<count where keys[j] == keys[i] {
                // Only from the start of a matching run.
                if i > 0, j > 0, !keys[i - 1].isEmpty, keys[i - 1] == keys[j - 1] { continue }
                var length = 0, characters = 0
                while i + length < j, j + length < count, !keys[i + length].isEmpty, keys[i + length] == keys[j + length] {
                    characters += keys[i + length].count
                    length += 1
                }
                guard length >= 2, characters >= 10 else { continue }
                for k in 0..<length { marked[i + k] = true; marked[j + k] = true }
            }
        }
        var spans: [Span] = []
        var index = 0
        while index < count {
            guard marked[index] else { index += 1; continue }
            let first = index
            while index + 1 < count, marked[index + 1] { index += 1 }
            let last = index
            let start = lines[first].timestamp
            let end = last + 1 < count ? lines[last + 1].timestamp
                : (lines[last].endTime ?? min(duration > 0 ? duration : lines[last].timestamp + 4, lines[last].timestamp + 6))
            if end > start { spans.append(Span(lines: first...last, start: start, end: end)) }
            index += 1
        }
        return spans
    }
}
