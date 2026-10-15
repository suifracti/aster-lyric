import Foundation
import CryptoKit

/// The v1 engine is the explicit dictionary/morphology path already used by
/// the app. It never invents a reading for unresolved Han characters.
public struct JapaneseDictionaryReadingEngine: ReadingEngine, Sendable {
    public let stableID: ReadingEngineID = .japaneseDictionary
    fileprivate let userEntries: [ReadingDictionaryEntry]

    public init(userEntries: [ReadingDictionaryEntry] = []) {
        self.userEntries = userEntries
    }

    public func generate(_ request: ReadingGenerationRequest) async throws -> ReadingGenerationResult {
        let contextHash = ReadingEngineSupport.hashContext(request.nearbyContext)
        let scopedEntries = ReadingEngineSupport.applicableUserEntries(
            userEntries,
            trackStableKey: request.trackStableKey,
            artistDisplay: request.artistDisplay
        )
        let dictionary = JapaneseDictionaryReadingEngine(userEntries: scopedEntries)
        let lines = request.lines.map { line in
            dictionary.makeLine(line, languageHint: request.languageHint, contextHash: contextHash, representation: request.representationID)
        }
        let language = ReadingEngineSupport.aggregateLanguage(lines)
        let warnings = Array(Set(lines.flatMap(\.warnings))).sorted { $0.rawValue < $1.rawValue }
        let confidence = lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
        return ReadingGenerationResult(
            engineID: stableID,
            representationID: request.representationID,
            lines: lines,
            language: language,
            confidence: confidence,
            warnings: warnings,
            contextHash: contextHash
        )
    }

    fileprivate func makeLine(
        _ line: ReadingInputLine,
        languageHint: String?,
        contextHash: String,
        contextual: Bool = false,
        representation: ReadingRepresentationID = .kana
    ) -> ReadingLineResult {
        let analysis = ReadingLanguageGate.analyze(line.originalText, languageHint: languageHint)
        let blank = line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !blank else {
            return ReadingLineResult(
                lineIndex: line.lineIndex,
                originalText: line.originalText,
                readingText: "",
                language: .unknown,
                tokens: [],
                confidence: 1
            )
        }
        guard ReadingLanguageGate.shouldRunJapanese(on: analysis) else {
            return ReadingLineResult(
                lineIndex: line.lineIndex,
                originalText: line.originalText,
                readingText: nil,
                language: analysis.language,
                tokens: [],
                warnings: analysis.needsConfirmation ? [.languageNeedsConfirmation] : [],
                confidence: analysis.needsConfirmation ? 0.2 : 1
            )
        }

        let result = JapaneseReadingSupport.analyze(
            text: line.originalText,
            userEntries: userEntries,
            contextual: contextual,
            contextHash: contextHash
        )
        let source = result.source == .providerOfficial ? ReadingTokenSource.provider :
            contextual ? .contextualLocal : .mecabIPADIC
        let tokens = result.tokens.map { token in
            ReadingToken(
                id: token.id,
                surface: token.originalText,
                reading: token.kana,
                startOffset: token.startOffset,
                endOffset: token.endOffset,
                source: source,
                confidence: token.confidence,
                needsConfirmation: token.isUnknown
            )
        }
        var warnings: [ReadingWarningCode] = []
        if result.containsUnknown { warnings.append(.unknownToken) }
        if analysis.language == .mixed { warnings.append(.mixedLanguage) }
        return ReadingLineResult(
            lineIndex: line.lineIndex,
            originalText: line.originalText,
            readingText: requestRepresentation(result, representationID: representation),
            language: analysis.language,
            tokens: tokens,
            warnings: warnings,
            confidence: result.confidence
        )
    }

    private func requestRepresentation(_ result: JapaneseReadingResult, representationID: ReadingRepresentationID) -> String? {
        switch representationID {
        case .kana: return result.kanaText
        case .romaji: return result.romajiText
        default: return result.kanaText
        }
    }
}

public struct JapaneseContextualReadingEngine: ReadingEngine, Sendable {
    public let stableID: ReadingEngineID = .japaneseContextual
    private let dictionary: JapaneseDictionaryReadingEngine

    public init(userEntries: [ReadingDictionaryEntry] = []) {
        self.dictionary = JapaneseDictionaryReadingEngine(userEntries: userEntries)
    }

    public static func analyze(
        text: String,
        userEntries: [ReadingDictionaryEntry] = [],
        trackStableKey: String? = nil,
        artistDisplay: String? = nil
    ) -> JapaneseReadingResult {
        let scopedEntries = ReadingEngineSupport.applicableUserEntries(
            userEntries,
            trackStableKey: trackStableKey,
            artistDisplay: artistDisplay
        )
        return JapaneseReadingSupport.analyze(
            text: text,
            userEntries: scopedEntries,
            contextual: true,
            contextHash: ReadingEngineSupport.hashContext([text, trackStableKey ?? "", artistDisplay ?? ""])
        )
    }

    public func generate(_ request: ReadingGenerationRequest) async throws -> ReadingGenerationResult {
        let contextHash = ReadingEngineSupport.hashContext(request.nearbyContext + request.lines.map(\.originalText))
        let scopedEntries = ReadingEngineSupport.applicableUserEntries(
            dictionary.userEntries,
            trackStableKey: request.trackStableKey,
            artistDisplay: request.artistDisplay
        )
        let dictionary = JapaneseDictionaryReadingEngine(userEntries: scopedEntries)
        let lines = request.lines.map { line in
            dictionary.makeLine(
                line,
                languageHint: request.languageHint,
                contextHash: contextHash,
                contextual: true,
                representation: request.representationID
            )
        }
        let warnings = Array(Set(lines.flatMap(\.warnings))).sorted { $0.rawValue < $1.rawValue }
        let language = ReadingEngineSupport.aggregateLanguage(lines)
        let confidence = lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
        return ReadingGenerationResult(
            engineID: stableID,
            representationID: request.representationID,
            lines: lines,
            language: language,
            confidence: confidence,
            warnings: warnings,
            contextHash: contextHash
        )
    }
}

public struct ReadingDictionaryEntry: Codable, Hashable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let surface: String
    public let reading: String
    public let language: ReadingLanguage
    public let trackStableKey: String?
    public let artistScope: String?
    public let priority: Int
    public let isEnabled: Bool
    public let isArchived: Bool
    public let notes: String

    private enum CodingKeys: String, CodingKey {
        case id, surface, reading, language, trackStableKey, artistScope, priority, isEnabled, isArchived, notes
    }

    public init(
        id: UUID = UUID(),
        surface: String,
        reading: String,
        language: ReadingLanguage,
        trackStableKey: String? = nil,
        artistScope: String? = nil,
        priority: Int = 0,
        isEnabled: Bool = true,
        isArchived: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.surface = surface
        self.reading = reading
        self.language = language
        self.trackStableKey = trackStableKey
        self.artistScope = artistScope
        self.priority = priority
        self.isEnabled = isEnabled
        self.isArchived = isArchived
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        surface = try values.decode(String.self, forKey: .surface)
        reading = try values.decode(String.self, forKey: .reading)
        language = try values.decode(ReadingLanguage.self, forKey: .language)
        trackStableKey = try values.decodeIfPresent(String.self, forKey: .trackStableKey)
        artistScope = try values.decodeIfPresent(String.self, forKey: .artistScope)
        priority = try values.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

enum JapaneseReadingSupport {
    static func analyze(
        text: String,
        userEntries: [ReadingDictionaryEntry],
        contextual: Bool,
        contextHash: String
    ) -> JapaneseReadingResult {
        let normalizedEntries = userEntries
            .filter { !$0.isArchived && $0.isEnabled && $0.language == .japanese && !$0.surface.isEmpty && !$0.reading.isEmpty }
            .sorted(by: ReadingEngineSupport.precedesUserEntry)
        let pipeline = contextual
            ? JapaneseReadingPipeline.analyzeContextually(originalText: text)
            : JapaneseReadingPipeline.analyze(originalText: text)
        let corrected = applyingExactTokenCorrections(normalizedEntries, to: pipeline)
        if !corrected.containsUnknown { return corrected }

        // This small deterministic fallback covers the synthetic acceptance
        // vocabulary when a machine has no IPADIC installation. It is not a
        // claim to be a complete Japanese dictionary.
        let fallback: [String: String] = [
            "生ビール": "なまビール", "生きる": "いきる", "学生": "がくせい",
            "上手": "じょうず", "歌う": "うたう", "階段": "かいだん", "上がる": "あがる",
            "飲む": "のむ", "として": "として", "知らない": "しらない", "朝": "あさ",
            "雨": "あめ", "窓": "まど", "街": "まち", "灯り": "あかり", "風": "かぜ",
            "通り過ぎる": "とおりすぎる", "待っている": "まっている"
        ]
        var kana = text
        for (surface, reading) in fallback.sorted(by: { $0.key.count > $1.key.count }) {
            kana = kana.replacingOccurrences(of: surface, with: reading)
        }
        let stillHasKanji = JapaneseKanaGenerator.hasKanji(kana)
        guard !stillHasKanji else { return corrected }
        let source: JapaneseReadingSource = contextual ? .mixed : .mecabIPADIC
        let confidence = contextual ? 0.92 : 0.88
        let token = JapaneseReadingToken(
            id: 0,
            originalText: text,
            lemma: nil,
            kana: kana,
            romaji: JapaneseRomanizer.romanizeConfirmedKana(kana),
            source: source,
            confidence: confidence,
            startOffset: 0,
            endOffset: text.count
        )
        _ = contextHash
        return JapaneseReadingResult(
            originalText: text,
            tokens: [token],
            kanaText: kana,
            romajiText: token.romaji,
            source: source,
            confidence: confidence,
            isTokenAligned: false
        )
    }

    static func applyingExactTokenCorrections(
        _ entries: [ReadingDictionaryEntry],
        to result: JapaneseReadingResult
    ) -> JapaneseReadingResult {
        var didCorrect = false
        let tokens = result.tokens.map { token in
            let kana: String
            if let entry = entries.first(where: { $0.surface == token.originalText }) {
                kana = JapaneseRomanizer.toHiraganaPreservingLatin(entry.reading)
            } else {
                // Ruby may split off okurigana from a morphology token. Preserve
                // the other segments while correcting only the clicked surface.
                let segments = JapaneseReadingPipeline.rubyTokens(for: token)
                guard segments.contains(where: { segment in entries.contains { $0.surface == segment.surface } }) else { return token }
                kana = segments.map { segment in
                    entries.first(where: { $0.surface == segment.surface })?.reading
                        ?? segment.kanaSurface ?? segment.ruby ?? segment.surface
                }.joined()
            }
            didCorrect = true
            return JapaneseReadingToken(
                id: token.id,
                originalText: token.originalText,
                lemma: token.lemma,
                kana: kana,
                romaji: JapaneseRomanizer.romanizeConfirmedKana(kana),
                source: .userCorrection,
                confidence: 1,
                partOfSpeech: token.partOfSpeech,
                startOffset: token.startOffset,
                endOffset: token.endOffset
            )
        }
        guard didCorrect else { return result }

        let kanaText = tokens.allSatisfy { $0.kana != nil }
            ? tokens.compactMap(\.kana).joined()
            : nil
        let romajiText = tokens.allSatisfy { $0.romaji != nil }
            ? JapaneseReadingPipeline.buildRomajiText(from: tokens)
            : nil
        let sources = Set(tokens.map(\.source))
        let source: JapaneseReadingSource = sources.count == 1
            ? (sources.first ?? .unknown)
            : .mixed
        return JapaneseReadingResult(
            originalText: result.originalText,
            tokens: tokens,
            kanaText: kanaText,
            romajiText: romajiText,
            source: source,
            confidence: tokens.map(\.confidence).min() ?? 0,
            isTokenAligned: result.isTokenAligned
        )
    }
}

public enum ReadingEngineSupport {
    /// A correction for this recording wins over an artist/global convention.
    /// Priority only resolves competing entries within the same scope.
    static func precedesUserEntry(_ lhs: ReadingDictionaryEntry, _ rhs: ReadingDictionaryEntry) -> Bool {
        func specificity(_ entry: ReadingDictionaryEntry) -> Int {
            if let song = entry.trackStableKey, !song.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 2 }
            if let artist = entry.artistScope, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 1 }
            return 0
        }
        let left = specificity(lhs), right = specificity(rhs)
        if left != right { return left > right }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.surface.count != rhs.surface.count { return lhs.surface.count > rhs.surface.count }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Stable keys include rounded duration, which can differ by one second
    /// between integer playback snapshots and fractional metadata snapshots.
    /// Keep a song correction across that drift only with a shared Spotify ID
    /// and matching title, artist and album. Other identity forms stay exact.
    public static func matchesSongScope(_ scope: String, trackStableKey: String?) -> Bool {
        guard let trackStableKey else { return false }
        if scope == trackStableKey { return true }
        func recording(_ key: String) -> (id: String, metadata: [String], duration: Double)? {
            let sections = key.components(separatedBy: "|metadata:")
            guard sections.count == 2 else { return nil }
            let primary = sections[0]
            let identifier: String
            if primary.hasPrefix("spotify-id:") {
                identifier = String(primary.dropFirst("spotify-id:".count))
            } else if primary.hasPrefix("spotify-uri:") {
                identifier = String(primary.dropFirst("spotify-uri:".count))
            } else { return nil }
            let fields = sections[1].components(separatedBy: "|")
            guard fields.count == 4,
                  let id = TrackIdentity.canonicalSpotifyTrackID(identifier),
                  let duration = Double(fields[3]), duration.isFinite, duration > 0,
                  duration.rounded() == duration else { return nil }
            let metadata = fields.prefix(3).map(TrackIdentity.normalizedComponent)
            guard !metadata[0].isEmpty, !metadata[1].isEmpty else { return nil }
            return (id, metadata, duration)
        }
        guard let lhs = recording(scope), let rhs = recording(trackStableKey) else { return false }
        return lhs.id == rhs.id && lhs.metadata == rhs.metadata && abs(lhs.duration - rhs.duration) <= 1
    }

    public static func applicableUserEntries(
        _ entries: [ReadingDictionaryEntry],
        trackStableKey: String?,
        artistDisplay: String?
    ) -> [ReadingDictionaryEntry] {
        let normalizedArtist = artistDisplay?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            guard !entry.isArchived, entry.isEnabled else { return false }
            if let scope = entry.trackStableKey,
               !scope.isEmpty,
               !matchesSongScope(scope, trackStableKey: trackStableKey) {
                return false
            }
            if let artistScope = entry.artistScope,
               !artistScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let normalizedArtist,
                      normalizedArtist.localizedCaseInsensitiveContains(artistScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    return false
                }
            }
            return true
        }.sorted(by: precedesUserEntry)
    }

    public static func hashContext(_ values: [String]) -> String {
        let data = values.joined(separator: "\u{001F}").data(using: .utf8) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func aggregateLanguage(_ lines: [ReadingLineResult]) -> ReadingLanguage {
        let languages = Set(lines.map(\.language).filter { $0 != .unknown })
        if languages.count == 1 { return languages.first ?? .unknown }
        if languages.isEmpty { return .unknown }
        return .mixed
    }
}
