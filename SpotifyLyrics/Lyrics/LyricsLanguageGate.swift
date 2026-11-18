import Foundation

/// Decides whether Japanese reading layers are appropriate for a lyric
/// document. This is a projection policy only: it never deletes or rewrites
/// stored kana/romaji values.
public enum LyricsLanguageGate {
    /// A conservative language hint for newly materialized documents. Kana is
    /// deterministic evidence of Japanese script; Han-only text remains
    /// unknown because it is also valid Chinese. This hint never rewrites
    /// stored language metadata.
    public static func inferredLanguage(text: String) -> String? {
        if containsKana(text) { return "ja" }
        if containsHan(text) { return "zh" }
        return nil
    }

    /// Unknown language is deliberately conservative. A line with Japanese
    /// kana is sufficient evidence for an unknown/mixed document; Han-only
    /// text is not, because it is indistinguishable from Chinese text.
    public static func allowsJapaneseReadings(language: String?, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let language {
            let normalized = language
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalized.hasPrefix("ja") {
                // Explicit Japanese metadata is authoritative for Kanji, but
                // a Latin-only line still has no Japanese surface to annotate.
                return containsJapaneseSurface(trimmed)
            }
            if normalized.isEmpty || normalized == "und" || normalized == "unknown" {
                return containsKana(trimmed)
            }
            // zh/en/ko and every other explicitly non-Japanese language fail
            // closed, even if a mixed line happens to contain a Kanji glyph.
            return false
        }

        return containsKana(trimmed)
    }

    public static func containsJapaneseSurface(_ text: String) -> Bool {
        containsKana(text) || containsHan(text)
    }

    static func usesPinyin(for line: LyricLine, language: String?) -> Bool {
        if line.readingRepresentationID?.hasPrefix("readingRepresentation.pinyin") == true { return true }
        let text = line.readingSurfaceText ?? line.originalText
        guard containsHan(text), !containsKana(text) else { return false }
        let hint = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return hint.hasPrefix("zh") || hint.isEmpty || hint == "und" || hint == "unknown"
    }

    public static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value)
                || (0x30A0...0x30FF).contains(scalar.value)
        }
    }

    public static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}
