import Foundation

public enum LyricsRecoveryState: String, Codable, Sendable, Equatable {
    case idle
    case planning
    case queryingProviders
    case matching
    case enrichingLayers
    case alignmentQueued
    case saving
    case loaded
    case candidates
    case noMatchExhausted
    case failed
}

public enum LyricsRecoveryOption: String, Codable, Sendable, CaseIterable {
    case autoComplete
    case pasteOrImport
    case openWebDiscovery
    case manualCreate
    case retry
}

public struct LyricsRecoveryPlan: Equatable, Sendable {
    public let state: LyricsRecoveryState
    public let options: [LyricsRecoveryOption]
    public let webSearchQueries: [String]
    public let queryVariants: [LyricsQueryVariant]

    public init(
        state: LyricsRecoveryState,
        options: [LyricsRecoveryOption],
        webSearchQueries: [String],
        queryVariants: [LyricsQueryVariant] = []
    ) {
        self.state = state
        self.options = options
        self.webSearchQueries = webSearchQueries
        self.queryVariants = queryVariants
    }
}

public enum LyricsRecoveryPlanner {
    /// Builds fallback surface after provider variants are exhausted.
    /// Product default remains one-tap auto-complete; paste/import is advanced only.
    public static func plan(
        metadata: TrackMetadata,
        exhaustedVariants: [LyricsQueryVariant]
    ) -> LyricsRecoveryPlan {
        var queries: [String] = []
        func push(_ title: String, _ artist: String?) {
            if let artist, !artist.isEmpty {
                queries.append("\(title) \(artist)")
            } else {
                queries.append(title)
            }
        }

        push(metadata.track.title, metadata.track.artist)
        if let romaji = metadata.aliases(for: .title, kind: .romaji).first {
            push(romaji.value, metadata.aliases(for: .artist, kind: .romaji).first?.value ?? metadata.track.artist)
        } else if let gen = JapaneseRomanizer.romanizeIfMostlyKana(metadata.track.title) {
            push(gen, JapaneseRomanizer.romanizeIfMostlyKana(metadata.track.artist) ?? metadata.track.artist)
        }
        for en in metadata.aliases(for: .title, kind: .officialEnglish) {
            push(en.value, metadata.track.artist)
        }
        for v in exhaustedVariants.prefix(4) {
            push(v.titleQuery, v.artistQuery)
        }

        // de-dupe by normalize
        var seen = Set<String>()
        queries = queries.filter {
            // Both scripts are worth asking for; only exact repeats are dropped.
            let k = TrackTextNormalizer.normalize($0, foldsChineseScript: false)
            if k.isEmpty || seen.contains(k) { return false }
            seen.insert(k)
            return true
        }

        return LyricsRecoveryPlan(
            state: .noMatchExhausted,
            options: [
                .autoComplete,
                .retry,
                .openWebDiscovery,
                .pasteOrImport,
                .manualCreate
            ],
            webSearchQueries: queries,
            queryVariants: exhaustedVariants
        )
    }
}

// MARK: - Layered lyric text (product principle)

public enum LyricsLayerLock: String, Codable, Sendable {
    case unlocked
    case locked
}

public struct LyricsTextLayers: Equatable, Sendable {
    public var originalText: String
    public var kanaText: String?
    public var romajiText: String?
    public var translationText: String?

    public var originalLock: LyricsLayerLock
    public var kanaLock: LyricsLayerLock
    public var romajiLock: LyricsLayerLock
    public var translationLock: LyricsLayerLock

    public init(
        originalText: String,
        kanaText: String? = nil,
        romajiText: String? = nil,
        translationText: String? = nil,
        originalLock: LyricsLayerLock = .unlocked,
        kanaLock: LyricsLayerLock = .unlocked,
        romajiLock: LyricsLayerLock = .unlocked,
        translationLock: LyricsLayerLock = .unlocked
    ) {
        self.originalText = originalText
        self.kanaText = kanaText
        self.romajiText = romajiText
        self.translationText = translationText
        self.originalLock = originalLock
        self.kanaLock = kanaLock
        self.romajiLock = romajiLock
        self.translationLock = translationLock
    }

    /// Apply automatic enrichments without overwriting locked layers.
    public mutating func applyAutomatic(
        kana: String?,
        romaji: String?,
        translation: String? = nil
    ) {
        if kanaLock == .unlocked, let kana, !kana.isEmpty {
            kanaText = kana
        }
        if romajiLock == .unlocked, let romaji, !romaji.isEmpty {
            romajiText = romaji
        }
        if translationLock == .unlocked, let translation, !translation.isEmpty {
            translationText = translation
        }
    }
}

public enum LyricsLayerEnricher {
    /// Fills kana/romaji for lines when missing. Never mutates originalText.
    public static func enrich(lines: [LyricLine]) -> [LyricLine] {
        lines.map { line in
            var layers = LyricsTextLayers(
                originalText: line.originalText,
                kanaText: line.kanaText,
                romajiText: line.romajiText,
                translationText: line.translationText
            )
            let hasJapaneseScript = line.originalText.unicodeScalars.contains { scalar in
                let value = scalar.value
                return (0x3040...0x30FF).contains(value)
                    || (0x3400...0x4DBF).contains(value)
                    || (0x4E00...0x9FFF).contains(value)
                    || (0xF900...0xFAFF).contains(value)
                    || (0x20000...0x2FA1F).contains(value)
            }
            let suppliedKana = layers.kanaText
            let reading: JapaneseReadingResult? = (hasJapaneseScript || suppliedKana != nil)
                ? JapaneseReadingPipeline.analyze(
                    originalText: line.originalText,
                    providerKana: suppliedKana
                )
                : nil
            // Do not turn ordinary English/Latin lyric lines into a duplicate
            // "romaji" layer. A provider-supplied kana layer is authoritative
            // only after the reading pipeline accepts it; malformed values are
            // cleared so they cannot reach independent/ruby/replacement UI.
            if suppliedKana != nil,
               reading?.source != .providerOfficial,
               layers.kanaLock == .unlocked {
                layers.kanaText = nil
            }
            let kana = layers.kanaText ?? reading?.kanaText
            let romaji = layers.romajiText ?? reading?.romajiText
            let generatedRubyTokens: [LyricRubyToken]? = {
                guard let reading, reading.isTokenAligned else { return nil }
                return reading.tokens.flatMap { JapaneseReadingPipeline.rubyTokens(for: $0) }
            }()
            let rubyTokens = line.rubyTokens ?? generatedRubyTokens
            layers.applyAutomatic(kana: kana, romaji: romaji)
            return LyricLine(
                id: line.id,
                timestamp: line.timestamp,
                originalText: layers.originalText,
                endTime: line.endTime,
                translationText: layers.translationText,
                romajiText: layers.romajiText,
                kanaText: layers.kanaText,
                rubyTokens: rubyTokens,
                performerID: line.performerID,
                timedSpans: line.timedSpans,
                readingRepresentationID: line.readingRepresentationID,
                readingSurfaceText: line.readingSurfaceText
            )
        }
    }
}
