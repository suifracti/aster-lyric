import Foundation

/// Some sources print swear words with asterisks (`f**k`, `sh*t`). For
/// singing along the whole word reads better. Only same-length restorations
/// are made, one asterisk for one letter, so word timing (UTF-16 ranges)
/// stays valid. Display only: the stored lyric text is never changed.
/// Word list after Lyricify Lyrics Helper's `Explicit.FixExplicit`.
enum LyricCensorRestorer {
    private struct Rule { let word: String; let prefix: String?; let standalone: Bool }

    private static let rules: [Rule] = [
        Rule(word: "fuck", prefix: "mother", standalone: false),
        Rule(word: "shit", prefix: "bull", standalone: false),
        Rule(word: "bitch", prefix: nil, standalone: false),
        Rule(word: "damn", prefix: nil, standalone: false),
        Rule(word: "dick", prefix: nil, standalone: false),
        Rule(word: "pussy", prefix: nil, standalone: false),
        Rule(word: "ass", prefix: nil, standalone: true),
    ]

    private static let expressions: [(Rule, NSRegularExpression)] = rules.compactMap { rule in
        // First letter as written; every later letter may be an asterisk.
        let tail = rule.word.dropFirst().map { "[\($0)*]" }.joined()
        let prefix = rule.prefix.map { "(?:\($0))?" } ?? ""
        let end = rule.standalone ? "(?=hole|[^A-Za-z*]|$)" : ""
        let pattern = "(?<![A-Za-z*])\(prefix)\(rule.word.first!)\(tail)\(end)"
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (rule, $0) }
    }

    static func restore(_ text: String) -> String {
        guard text.contains("*") else { return text }
        var result = text as NSString
        for (rule, expression) in expressions {
            let matches = expression.matches(in: result as String, range: NSRange(location: 0, length: result.length))
            for match in matches.reversed() {
                let found = result.substring(with: match.range)
                guard found.contains("*") else { continue }
                // Fill the word's own letters from the end of the match.
                var letters = Array(found)
                let word = Array(rule.word)
                let offset = letters.count - word.count
                let upper = found.filter(\.isLetter).allSatisfy(\.isUppercase)
                for index in word.indices where letters[offset + index] == "*" {
                    letters[offset + index] = upper ? Character(word[index].uppercased()) : word[index]
                }
                result = result.replacingCharacters(in: match.range, with: String(letters)) as NSString
            }
        }
        return result as String
    }

    /// Word spans re-read their text at the same UTF-16 ranges.
    static func respan(_ spans: [TimedTextSpan]?, text: String) -> [TimedTextSpan]? {
        guard let spans else { return nil }
        let utf16 = text.utf16
        return spans.map { span in
            guard span.utf16Start >= 0, span.utf16Start + span.utf16Length <= utf16.count,
                  let from = utf16.index(utf16.startIndex, offsetBy: span.utf16Start, limitedBy: utf16.endIndex),
                  let to = utf16.index(from, offsetBy: span.utf16Length, limitedBy: utf16.endIndex),
                  let slice = String(utf16[from..<to]), slice.utf16.count == span.text.utf16.count else { return span }
            return TimedTextSpan(id: span.id, text: slice, trailingWhitespace: span.trailingWhitespace,
                                 startTime: span.startTime, endTime: span.endTime, utf16Start: span.utf16Start,
                                 utf16Length: span.utf16Length, granularity: span.granularity)
        }
    }
}
