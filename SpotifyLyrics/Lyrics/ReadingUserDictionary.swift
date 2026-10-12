import Foundation

public struct ReadingUserDictionaryStore {
    public static let userDefaultsKey = "reading.userDictionary.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .lyricsQ) {
        self.defaults = defaults
    }

    private static let cacheLock = NSLock()
    private static var cachedData: Data?
    private static var cachedEntries: [ReadingDictionaryEntry] = []
    private static var revision: Int = 0

    public static var currentRevision: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return revision
    }

    public func load() -> [ReadingDictionaryEntry] {
        guard let data = defaults.data(forKey: Self.userDefaultsKey) else { return [] }
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let cachedData = Self.cachedData, cachedData == data {
            return Self.cachedEntries
        }
        guard let entries = try? JSONDecoder().decode([ReadingDictionaryEntry].self, from: data) else { return [] }
        Self.cachedData = data
        Self.cachedEntries = entries
        return entries
    }

    public func save(_ entries: [ReadingDictionaryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        Self.cacheLock.lock()
        Self.cachedData = data
        Self.cachedEntries = entries
        Self.revision += 1
        Self.cacheLock.unlock()
        defaults.set(data, forKey: Self.userDefaultsKey)
    }

    public func upsert(_ entry: ReadingDictionaryEntry) {
        var entries = load()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        save(entries.sorted { $0.priority > $1.priority })
    }

    public func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    public func rememberSongCorrection(_ entry: ReadingDictionaryEntry) {
        guard let scope = entry.trackStableKey, !scope.isEmpty else { return }
        var entries = load()
        entries.removeAll { previous in
            previous.id == entry.id || (
                previous.surface == entry.surface && previous.language == entry.language
                && previous.trackStableKey.map { ReadingEngineSupport.matchesSongScope($0, trackStableKey: scope) } == true
            )
        }
        entries.append(entry)
        save(entries)
    }
}

/// A confirmed song-scoped correction. Original lyrics and earlier versions stay immutable.
public enum ReadingRubyCorrection {
    public static func entry(surface: String, reading: String, trackStableKey: String) throws -> ReadingDictionaryEntry {
        let kana = JapaneseRomanizer.toHiraganaPreservingLatin(reading.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !surface.isEmpty, !trackStableKey.isEmpty, !kana.isEmpty,
              kana.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }) else {
            throw ReadingRepositoryError.invalidLines("请输入假名，例如「からだ」")
        }
        return ReadingDictionaryEntry(surface: surface, reading: kana, language: .japanese,
                                      trackStableKey: trackStableKey, priority: 1000, notes: "点击假名纠音")
    }

    public static func project(
        _ reading: ReadingLineResult,
        onto source: LyricLine,
        preferStoredReadingText: Bool = false
    ) -> LyricLine {
        guard reading.originalText == source.originalText else { return source }
        var line = source
        if !preferStoredReadingText,
           reading.readingText == reading.originalText,
           JapaneseKanaGenerator.hasKanji(reading.originalText) {
            return line // Generated unresolved rows keep their existing safe fallback.
        }
        line.kanaText = reading.readingText
        let consistentTokens = reading.hasConsistentKanaTokenProjection ? reading.tokens : []
        let tokens = consistentTokens.map { token in
            JapaneseReadingToken(id: token.id, originalText: token.surface, lemma: nil,
                kana: token.reading, romaji: token.reading.flatMap(JapaneseRomanizer.romanizeConfirmedKana),
                source: .userCorrection, confidence: token.confidence,
                startOffset: token.startOffset, endOffset: token.endOffset)
        }
        if consistentTokens.contains(where: { $0.source == .userDictionary }),
           tokens.map(\.originalText).joined() == source.originalText, !tokens.isEmpty {
            line.romajiText = JapaneseReadingPipeline.buildRomajiText(from: tokens)
            line.rubyTokens = tokens.flatMap { JapaneseReadingPipeline.rubyTokens(for: $0) }
        } else {
            line.romajiText = reading.readingText.flatMap(JapaneseRomanizer.romanizeConfirmedKana)
            line.rubyTokens = nil
        }
        return line
    }

    public static func lines(_ source: [LyricLine], entry: ReadingDictionaryEntry) throws -> [ReadingLineResult] {
        var found = false
        let lines = try source.enumerated().map { index, line in
            let baseline = JapaneseReadingPipeline.analyze(originalText: line.originalText, providerKana: line.kanaText)
            let corrected = JapaneseReadingSupport.applyingExactTokenCorrections([entry], to: baseline)
            if corrected.tokens != baseline.tokens {
                guard corrected.kanaText != nil, corrected.isTokenAligned else {
                    throw ReadingRepositoryError.invalidLines("这行仍有无法确认的读音，请先编辑整行读音")
                }
                found = true
            }
            return ReadingLineResult(lineIndex: index, originalText: line.originalText, readingText: corrected.kanaText ?? line.kanaText ?? line.originalText,
                language: ReadingLanguageGate.analyze(line.originalText, languageHint: nil).language, tokens: corrected.tokens.map { token in
                    ReadingToken(id: token.id, surface: token.originalText, reading: token.kana,
                        startOffset: token.startOffset, endOffset: token.endOffset,
                        source: token.source == .userCorrection ? .userDictionary : .provider,
                        confidence: token.confidence, needsConfirmation: token.isUnknown)
                }.filter { _ in corrected.isTokenAligned && !corrected.containsUnknown },
                warnings: corrected.containsUnknown ? [.unknownToken] : [], confidence: corrected.confidence)
        }
        guard found else { throw ReadingRepositoryError.invalidLines("无法定位这个词的读音，请尝试编辑整行读音") }
        return lines
    }
}
