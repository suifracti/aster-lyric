import Foundation

/// Deterministic kana → Hepburn romaji (ASCII long vowels as ou/uu).
/// Does not use chat models. Kanji is left unchanged (no unihan Chinese readings).
public enum JapaneseRomanizer {
    public enum Style: String, Sendable {
        /// Hepburn with ASCII long vowels: ou, uu (default).
        case hepburnASCII
    }

    public static func romanize(_ text: String, style: Style = .hepburnASCII) -> String {
        _ = style
        let kana = toHiraganaPreservingLatin(text)
        return romanizeHiragana(kana, capitalize: true)
    }

    /// Romaji for an already confirmed kana layer.
    ///
    /// Unlike `romanize`, this method deliberately keeps lyric text lowercase
    /// and never attempts to interpret kanji. It is the only entry point the
    /// morphology pipeline uses for local/provider-confirmed readings.
    public static func romanizeConfirmedKana(_ text: String) -> String {
        let kana = toHiraganaPreservingLatin(text)
        return romanizeHiragana(kana, capitalize: false)
    }

    /// Returns romaji only when the Japanese portion is mostly kana (safe for titles like あやふや).
    public static func romanizeIfMostlyKana(_ text: String) -> String? {
        let jp = text.unicodeScalars.filter {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
        guard !jp.isEmpty else { return nil }
        let kanaCount = jp.filter { (0x3040...0x30FF).contains($0.value) }.count
        let ratio = Double(kanaCount) / Double(jp.count)
        guard ratio >= 0.8 else { return nil }
        let r = romanize(text)
        let trimmed = r.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func toHiraganaPreservingLatin(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            let v = s.value
            if (0x30A1...0x30FA).contains(v) {
                // Katakana to hiragana
                if let h = UnicodeScalar(v - 0x60) {
                    out.append(h)
                } else {
                    out.append(s)
                }
            } else {
                out.append(s)
            }
        }
        return String(out)
    }

    /// Normalizes a confirmed reading for presentation only.
    ///
    /// Provider and morphology payloads may use katakana even when the lyric
    /// surface is intended for a hiragana ruby annotation.  Keep the stored
    /// source layers untouched and fold only the value rendered in the UI.
    public static func displayKana(_ text: String) -> String {
        toHiraganaPreservingLatin(text)
    }

    private static let table: [String: String] = Dictionary(uniqueKeysWithValues: [
            ("きゃ", "kya"), ("きゅ", "kyu"), ("きょ", "kyo"),
            ("しゃ", "sha"), ("しゅ", "shu"), ("しょ", "sho"),
            ("ちゃ", "cha"), ("ちゅ", "chu"), ("ちょ", "cho"),
            ("にゃ", "nya"), ("にゅ", "nyu"), ("にょ", "nyo"),
            ("ひゃ", "hya"), ("ひゅ", "hyu"), ("ひょ", "hyo"),
            ("みゃ", "mya"), ("みゅ", "myu"), ("みょ", "myo"),
            ("りゃ", "rya"), ("りゅ", "ryu"), ("りょ", "ryo"),
            ("ぎゃ", "gya"), ("ぎゅ", "gyu"), ("ぎょ", "gyo"),
            ("じゃ", "ja"), ("じゅ", "ju"), ("じょ", "jo"),
            ("びゃ", "bya"), ("びゅ", "byu"), ("びょ", "byo"),
            ("ぴゃ", "pya"), ("ぴゅ", "pyu"), ("ぴょ", "pyo"),
            ("ふぁ", "fa"), ("ふぃ", "fi"), ("ふぇ", "fe"), ("ふぉ", "fo"),
            ("てぃ", "ti"), ("でぃ", "di"), ("とぅ", "tu"), ("どぅ", "du"),
            ("うぃ", "wi"), ("うぇ", "we"), ("うぉ", "wo"),
            ("ゔぁ", "va"), ("ゔぃ", "vi"), ("ゔ", "vu"), ("ゔぇ", "ve"), ("ゔぉ", "vo"),
            ("あ", "a"), ("い", "i"), ("う", "u"), ("え", "e"), ("お", "o"),
            ("か", "ka"), ("き", "ki"), ("く", "ku"), ("け", "ke"), ("こ", "ko"),
            ("さ", "sa"), ("し", "shi"), ("す", "su"), ("せ", "se"), ("そ", "so"),
            ("た", "ta"), ("ち", "chi"), ("つ", "tsu"), ("て", "te"), ("と", "to"),
            ("な", "na"), ("に", "ni"), ("ぬ", "nu"), ("ね", "ne"), ("の", "no"),
            ("は", "ha"), ("ひ", "hi"), ("ふ", "fu"), ("へ", "he"), ("ほ", "ho"),
            ("ま", "ma"), ("み", "mi"), ("む", "mu"), ("め", "me"), ("も", "mo"),
            ("や", "ya"), ("ゆ", "yu"), ("よ", "yo"),
            ("ら", "ra"), ("り", "ri"), ("る", "ru"), ("れ", "re"), ("ろ", "ro"),
            ("わ", "wa"), ("ゐ", "wi"), ("ゑ", "we"), ("を", "o"),
            ("ん", "n"),
            ("が", "ga"), ("ぎ", "gi"), ("ぐ", "gu"), ("げ", "ge"), ("ご", "go"),
            ("ざ", "za"), ("じ", "ji"), ("ず", "zu"), ("ぜ", "ze"), ("ぞ", "zo"),
            ("だ", "da"), ("ぢ", "ji"), ("づ", "zu"), ("で", "de"), ("ど", "do"),
            ("ば", "ba"), ("び", "bi"), ("ぶ", "bu"), ("べ", "be"), ("ぼ", "bo"),
            ("ぱ", "pa"), ("ぴ", "pi"), ("ぷ", "pu"), ("ぺ", "pe"), ("ぽ", "po"),
            ("ぁ", "a"), ("ぃ", "i"), ("ぅ", "u"), ("ぇ", "e"), ("ぉ", "o"),
            ("ゃ", "ya"), ("ゅ", "yu"), ("ょ", "yo"), ("っ", ""), // sokuon handled specially
            ("ー", "") // chōonpu handled specially
        ])


    private static func romanizeHiragana(_ text: String, capitalize: Bool) -> String {
        // Longest-match table
        var i = text.startIndex
        var pieces: [String] = []
        while i < text.endIndex {
            let rest = text[i...]
            // sokuon っ
            if rest.hasPrefix("っ") {
                let nextStart = text.index(after: i)
                if nextStart < text.endIndex {
                    // peek next romaji consonant
                    let nextRomaji = peekRomaji(text[nextStart...])
                    if let c = nextRomaji.first, c.isLetter, !"aiueon".contains(c) {
                        pieces.append(String(c))
                    } else {
                        pieces.append("t")
                    }
                } else {
                    // A morphology token may end at っ while the following
                    // consonant is in the next token (e.g. なかっ + た).
                    pieces.append("t")
                }
                i = nextStart
                continue
            }
            // Hepburn disambiguates ん before a vowel or y with an apostrophe.
            // This conversion is based only on the confirmed kana sequence.
            if rest.hasPrefix("ん") {
                let nextStart = text.index(after: i)
                if nextStart < text.endIndex {
                    let nextRomaji = peekRomaji(text[nextStart...])
                    if let first = nextRomaji.first, "aiueoy".contains(first) {
                        pieces.append("n'")
                    } else {
                        pieces.append("n")
                    }
                } else {
                    pieces.append("n")
                }
                i = nextStart
                continue
            }
            // chōonpu ー explicitly repeats the preceding vowel. The kana
            // sequence おう is kept as o + u and therefore remains "ou".
            if rest.hasPrefix("ー") {
                if let last = pieces.last, let v = last.last, "aiueo".contains(v) {
                    pieces.append(String(v))
                }
                i = text.index(after: i)
                continue
            }

            let pair = String(rest.prefix(2))
            let single = String(rest.prefix(1))
            let key = table[pair] != nil ? pair : single
            let matched = table[key] != nil
            if let value = table[key] {
                pieces.append(value)
                i = text.index(i, offsetBy: key.count)
            }
            if !matched {
                // keep non-kana as-is (latin, digits, punctuation)
                pieces.append(String(rest.first!))
                i = text.index(after: i)
            }
        }

        var joined = pieces.joined()
        // Preserve source spacing; the morphology pipeline controls any
        // additional word grouping before it calls this method.
        joined = joined.replacingOccurrences(of: "  ", with: " ")
        guard capitalize else { return joined }

        // Title-style: capitalize first letter of each whitespace-separated token for display aliases
        let tokens = joined.split(separator: " ", omittingEmptySubsequences: true).map { token -> String in
            let t = String(token)
            // If pure romaji word, Capitalize
            if t.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "'" || $0 == "-" }) {
                return t.prefix(1).uppercased() + t.dropFirst()
            }
            return t
        }
        // For single Japanese titles without spaces, keep lowercase hepburn then capitalize first
        if tokens.count == 1, let only = tokens.first {
            let lower = only.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return tokens.joined(separator: " ")
    }

    private static func peekRomaji(_ rest: Substring) -> String {
        if let pair = table[String(rest.prefix(2))], !pair.isEmpty { return pair }
        return table[String(rest.prefix(1))] ?? ""
    }
}
