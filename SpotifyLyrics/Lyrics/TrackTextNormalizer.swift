import Foundation

public enum TrackTextNormalizer {
    public struct FeaturedSplit: Equatable, Sendable {
        public let primary: String
        public let featured: [String]
    }

    /// A Spotify artist display string is not a single comparable name. Keep
    /// the first artist as the primary identity and retain the remaining
    /// names as featured artists. This deliberately uses token equality in
    /// SafeMatcher rather than substring containment.
    public struct ArtistTokens: Equatable, Sendable {
        public let primary: String
        public let featured: [String]

        public var all: [String] { [primary] + featured }

        public init(primary: String, featured: [String]) {
            self.primary = primary
            self.featured = featured
        }
    }

    public static func normalize(_ raw: String) -> String {
        var s = raw
        // Unicode compatibility + canonical composition
        s = s.decomposedStringWithCompatibilityMapping
        s = s.precomposedStringWithCanonicalMapping

        // Fullwidth ASCII / spaces via applyingTransform when available
        if let folded = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) {
            s = folded
        }

        s = s.lowercased()

        let replacements: [(String, String)] = [
            ("・", " "),
            ("·", " "),
            ("•", " "),
            ("〜", "~"),
            ("～", "~"),
            ("─", "-"),
            ("—", "-"),
            ("–", "-"),
            ("‐", "-"),
            ("\u{3000}", " "),
            ("\t", " "),
            ("\n", " "),
            ("\r", " "),
            ("“", "\""),
            ("”", "\""),
            ("‘", "'"),
            ("’", "'"),
            ("「", " "),
            ("」", " "),
            ("『", " "),
            ("』", " "),
            ("（", "("),
            ("）", ")"),
            ("【", " "),
            ("】", " "),
            ("［", "["),
            ("］", "]")
        ]
        for (a, b) in replacements {
            s = s.replacingOccurrences(of: a, with: b)
        }

        // Collapse punctuation used as separators into space (keep alphanumeric JP)
        let scalars = s.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            if (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) {
                return Character(scalar)
            }
            if scalar == "~" || scalar == "-" || scalar == "'" { return Character(scalar) }
            return " "
        }
        s = String(scalars)

        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func splitFeaturedArtists(_ artist: String) -> FeaturedSplit {
        let tokens = artistTokens(artist)
        return FeaturedSplit(primary: tokens.primary, featured: tokens.featured)
    }

    /// Splits common Spotify artist display forms: feat./ft./featuring,
    /// comma, Japanese comma, 、, &, × and a spaced x. A slash is not a
    /// separator because names such as HUNTR/X are legitimate artist names.
    public static func artistTokens(_ artist: String) -> ArtistTokens {
        let raw = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return ArtistTokens(primary: "", featured: []) }

        let featurePattern = #"\s+(?:feat\.?|ft\.?|featuring|with)\s*"#
        var head = raw
        var featureTail: [String] = []
        if let regex = try? NSRegularExpression(pattern: featurePattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: raw, options: [], range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
           let matchRange = Range(match.range, in: raw) {
            head = String(raw[..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(raw[matchRange.upperBound...])
            featureTail = splitArtistList(tail)
        }

        let headParts = splitArtistList(head)
        let primary = (headParts.first ?? head).trimmingCharacters(in: .whitespacesAndNewlines)
        let featured = Array(headParts.dropFirst()) + featureTail
        return ArtistTokens(
            primary: primary,
            featured: featured.filter { !$0.isEmpty }
        )
    }

    /// A punctuation-insensitive artist key. It intentionally removes spaces
    /// and dots so `MOSAIC.TUNE` and `MOSAIC TUNE` can be compared, while the
    /// original display string remains untouched in TrackMetadata.
    public static func normalizeArtistToken(_ raw: String) -> String {
        let normalized = normalize(raw)
        let scalars = normalized.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    public static func artistTokenSet(_ raw: String) -> Set<String> {
        Set(artistTokens(raw).all.map(normalizeArtistToken).filter { !$0.isEmpty })
    }

    private static func splitArtistList(_ raw: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\s*(?:,|，|、|;|；|&|×|\s+x\s+)\s*"#,
            options: [.caseInsensitive]
        ) else {
            return [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let separated = regex.stringByReplacingMatches(
            in: raw,
            options: [],
            range: range,
            withTemplate: "\u{1F}"
        )
        return separated
            .split(separator: "\u{1F}", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // Only explicit arrangement suffixes count; titles such as “Piano Man” stay intact.
    private static let pianoSuffix = #"\s*(?:[-–—]\s*(?:piano(?:\s+(?:ver\.?|version))?|ピアノ版)|[\(\[（【]\s*(?:piano(?:\s+(?:ver\.?|version))?|ピアノ版)\s*[\)\]）】])\s*$"#

    // Tempo labels are recording traits only when explicitly delimited at the end.
    // Never strip words from titles such as “Speed Up Your Life”.
    private static let spedUpSuffix = #"\s*(?:[-–—]\s*(?:sped|speed)[\s-]+up(?:\s+(?:ver\.?|version))?|[\(\[（【]\s*(?:sped|speed)[\s-]+up(?:\s+(?:ver\.?|version))?\s*[\)\]）】])\s*$"#

    public static func extractVersionTags(fromTitle title: String) -> [VersionTag] {
        let n = normalize(title)
        var tags: [VersionTag] = []
        let rules: [(String, VersionTag)] = [
            ("from the first take", .firstTake),
            ("first take", .firstTake),
            ("remastered", .remaster),
            ("remaster", .remaster),
            ("short version", .shortVersion),
            ("movie version", .movieVersion),
            ("anime version", .animeVersion),
            ("live", .live),
            ("remix", .remix),
            ("acoustic", .acoustic),
            ("instrumental", .instrumental),
            ("off vocal", .instrumental),
            ("karaoke", .karaoke),
            ("radio edit", .radioEdit),
            ("demo", .demo),
            ("cover", .cover),
            ("re-record", .reRecord),
            ("rerecord", .reRecord),
            ("movie", .movieVersion),
            ("anime", .animeVersion),
            ("short", .shortVersion)
        ]
        for (key, tag) in rules where n.contains(key) {
            if !tags.contains(tag) { tags.append(tag) }
        }
        if title.range(of: pianoSuffix, options: [.regularExpression, .caseInsensitive]) != nil {
            tags.append(.piano)
        }
        if title.range(of: spedUpSuffix, options: [.regularExpression, .caseInsensitive]) != nil {
            tags.append(.spedUp)
        }
        // Japanese markers
        if title.contains("ライブ") {
            if !tags.contains(.live) { tags.append(.live) }
        }
        if title.contains("リミックス"), !tags.contains(.remix) { tags.append(.remix) }
        if title.contains("インスト"), !tags.contains(.instrumental) { tags.append(.instrumental) }
        if title.contains("カバー"), !tags.contains(.cover) { tags.append(.cover) }
        if title.contains("リマスター"), !tags.contains(.remaster) { tags.append(.remaster) }
        if title.contains("映画") || title.contains("電影") || title.contains("劇場") || title.contains("剧场"),
           !tags.contains(.movieVersion) {
            tags.append(.movieVersion)
        }
        if title.contains("アニメ"), !tags.contains(.animeVersion) { tags.append(.animeVersion) }
        return tags
    }

    public static func stripVersionMarkers(fromTitle title: String) -> String {
        var s = title
        let patterns = [
            pianoSuffix,
            spedUpSuffix,
            #"\s*[\(\[\{（【].*?(live|remix|acoustic|instrumental|karaoke|radio\s*edit|demo|cover|remaster(?:ed)?|first\s*take|movie|anime|short).*?[\)\]\}）】]\s*"#,
            #"\s*-\s*(live|remix|acoustic|instrumental|remaster(?:ed)?|from\s+the\s+first\s+take).*$"#
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
