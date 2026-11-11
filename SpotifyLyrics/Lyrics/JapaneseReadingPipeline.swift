import Foundation

/// Where a per-token reading came from.
public enum JapaneseReadingSource: String, Codable, Sendable, Equatable {
    case providerOfficial
    case userCorrection
    case mecabIPADIC
    case literalPreserved
    case unknown
    case mixed
}

/// One morphology token emitted by the local Japanese analyzer.
public struct JapaneseMorphologyToken: Equatable, Sendable {
    public let originalText: String
    public let readingKatakana: String?
    public let lemma: String?
    public let partOfSpeech: String?
    public let conjugationType: String?
    public let conjugationForm: String?

    public init(
        originalText: String,
        readingKatakana: String?,
        lemma: String?,
        partOfSpeech: String?,
        conjugationType: String? = nil,
        conjugationForm: String? = nil
    ) {
        self.originalText = originalText
        self.readingKatakana = readingKatakana
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.conjugationType = conjugationType
        self.conjugationForm = conjugationForm
    }
}

public enum JapaneseMorphologyError: Error, LocalizedError, Sendable, Equatable {
    case executableUnavailable
    case processFailed(String)
    case timedOut
    case malformedOutput

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "MeCab executable unavailable"
        case .processFailed(let message):
            return "MeCab failed: \(message)"
        case .timedOut:
            return "MeCab timed out"
        case .malformedOutput:
            return "MeCab returned malformed output"
        }
    }
}

/// Abstraction around morphology so the reading pipeline can be tested with
/// deterministic fixtures without making SwiftUI or alignment depend on a
/// concrete process implementation.
public protocol JapaneseMorphologyEngine: Sendable {
    func tokenize(_ text: String) throws -> [JapaneseMorphologyToken]
}

/// Optional capability used only for morphology patterns known to be
/// ambiguous in the best IPADIC path. Most lyric lines still execute one
/// analysis; callers request alternatives only when a context rule can rank
/// them deterministically.
public protocol JapaneseNBestMorphologyEngine: JapaneseMorphologyEngine {
    func tokenizations(_ text: String, maximumCount: Int) throws -> [[JapaneseMorphologyToken]]
}

/// Real local Japanese morphology/dictionary reader.
///
/// The app invokes the installed MeCab binary with its configured IPADIC
/// dictionary. It does not depend on a project-root resource at runtime. If
/// MeCab cannot resolve a Han token, the pipeline returns `unknown` instead of
/// falling back to a single-character or Chinese reading.
public struct JapaneseMeCabEngine: JapaneseNBestMorphologyEngine, Sendable {
    public let executableURL: URL?
    public let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 2.0) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func tokenize(_ text: String) throws -> [JapaneseMorphologyToken] {
        guard !text.isEmpty else { return [] }
        let output = try run(text: text, arguments: ["-Ochasen"])
        let parsedTokens = Self.parseOchaSen(output)
        guard !parsedTokens.isEmpty else {
            throw JapaneseMorphologyError.malformedOutput
        }
        return Self.restoreIgnoredGaps(parsedTokens, in: text)
    }

    public func tokenizations(
        _ text: String,
        maximumCount: Int
    ) throws -> [[JapaneseMorphologyToken]] {
        guard !text.isEmpty else { return [] }
        let count = max(1, min(12, maximumCount))
        let output = try run(text: text, arguments: ["-N", String(count), "-Ochasen"])
        let candidates = Self.parseOchaSenCandidates(output)
            .map { Self.restoreIgnoredGaps($0, in: text) }
            .filter { $0.map(\.originalText).joined() == text }
        guard !candidates.isEmpty else {
            throw JapaneseMorphologyError.malformedOutput
        }
        return candidates
    }

    /// Output of earlier successful runs, for this app run only. MeCab's
    /// answer depends only on the executable, its arguments and the text, and
    /// the same lyric line arrives once per candidate, query and document.
    /// Failures are not kept, so a missing or slow MeCab is tried again.
    private final class OutputCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func value(for key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: String, for key: String) {
            lock.lock(); defer { lock.unlock() }
            // Lyric lines are short; dropping everything is enough of a bound.
            if values.count >= 20_000 { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }

    private static let outputCache = OutputCache()

    private func run(text: String, arguments: [String]) throws -> String {
        guard let executableURL = executableURL ?? Self.resolveExecutable() else {
            throw JapaneseMorphologyError.executableUnavailable
        }
        let cacheKey = ([executableURL.path] + arguments + [text]).joined(separator: "\u{1F}")
        if let cached = Self.outputCache.value(for: cacheKey) { return cached }
        let output = try launch(executableURL, text: text, arguments: arguments)
        Self.outputCache.store(output, for: cacheKey)
        return output
    }

    private func launch(_ executableURL: URL, text: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw JapaneseMorphologyError.processFailed(error.localizedDescription)
        }

        guard let data = (text + "\n").data(using: .utf8) else {
            process.terminate()
            throw JapaneseMorphologyError.processFailed("input is not UTF-8")
        }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw JapaneseMorphologyError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.001)
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "status \(process.terminationStatus)"
            throw JapaneseMorphologyError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let textOutput = String(data: outputData, encoding: .utf8) else {
            throw JapaneseMorphologyError.malformedOutput
        }
        return textOutput
    }

    public static func resolveExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["SPOTIFYLYRICS_MECAB_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/mecab",
            "/usr/local/bin/mecab",
            "/usr/bin/mecab"
        ])

        let fileManager = FileManager.default
        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Parses MeCab's stable `-Ochasen` tabular output.
    public static func parseOchaSen(_ output: String) -> [JapaneseMorphologyToken] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line != "EOS" else { return nil }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 4 else { return nil }

            func optionalColumn(_ index: Int) -> String? {
                guard columns.indices.contains(index) else { return nil }
                let value = columns[index]
                return value.isEmpty || value == "*" ? nil : value
            }

            return JapaneseMorphologyToken(
                originalText: columns[0],
                readingKatakana: optionalColumn(1),
                lemma: optionalColumn(2),
                partOfSpeech: optionalColumn(3),
                conjugationType: optionalColumn(4),
                conjugationForm: optionalColumn(5)
            )
        }
    }

    public static func parseOchaSenCandidates(_ output: String) -> [[JapaneseMorphologyToken]] {
        var candidates: [[JapaneseMorphologyToken]] = []
        var current: [String] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "EOS" {
                let parsed = parseOchaSen(current.joined(separator: "\n"))
                if !parsed.isEmpty { candidates.append(parsed) }
                current.removeAll(keepingCapacity: true)
            } else if !line.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty {
            let parsed = parseOchaSen(current.joined(separator: "\n"))
            if !parsed.isEmpty { candidates.append(parsed) }
        }
        return candidates
    }

    /// MeCab ignores some whitespace while tokenizing. Reinsert those spans so
    /// the reading result can prove that every original character survived.
    private static func restoreIgnoredGaps(
        _ tokens: [JapaneseMorphologyToken],
        in originalText: String
    ) -> [JapaneseMorphologyToken] {
        var result: [JapaneseMorphologyToken] = []
        var cursor = originalText.startIndex

        for token in tokens {
            guard !token.originalText.isEmpty,
                  let range = originalText.range(of: token.originalText, range: cursor..<originalText.endIndex) else {
                return tokens
            }
            if range.lowerBound > cursor {
                let gap = String(originalText[cursor..<range.lowerBound])
                result.append(JapaneseMorphologyToken(
                    originalText: gap,
                    readingKatakana: gap,
                    lemma: gap,
                    partOfSpeech: "記号-空白"
                ))
            }
            result.append(token)
            cursor = range.upperBound
        }

        if cursor < originalText.endIndex {
            let gap = String(originalText[cursor..<originalText.endIndex])
            result.append(JapaneseMorphologyToken(
                originalText: gap,
                readingKatakana: gap,
                lemma: gap,
                partOfSpeech: "記号-空白"
            ))
        }
        return result
    }
}

/// A confirmed reading for one morphology token.
public struct JapaneseReadingToken: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: Int
    public let originalText: String
    public let lemma: String?
    public let kana: String?
    public let romaji: String?
    public let source: JapaneseReadingSource
    public let confidence: Double
    public let partOfSpeech: String?
    public let startOffset: Int
    public let endOffset: Int

    public var isUnknown: Bool { source == .unknown || kana == nil }

    public init(
        id: Int,
        originalText: String,
        lemma: String?,
        kana: String?,
        romaji: String?,
        source: JapaneseReadingSource,
        confidence: Double,
        partOfSpeech: String? = nil,
        startOffset: Int = 0,
        endOffset: Int = 0
    ) {
        self.id = id
        self.originalText = originalText
        self.lemma = lemma
        self.kana = kana
        self.romaji = romaji
        self.source = source
        self.confidence = confidence
        self.partOfSpeech = partOfSpeech
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

public struct JapaneseReadingResult: Equatable, Sendable {
    public let originalText: String
    public let tokens: [JapaneseReadingToken]
    public let kanaText: String?
    public let romajiText: String?
    public let source: JapaneseReadingSource
    public let confidence: Double
    /// True only when each reading token is safe to project onto the original
    /// surface. A provider can still supply a useful line-level kana string
    /// when its token boundaries cannot be proven, but that result must not be
    /// rendered as one giant ruby annotation above the whole lyric line.
    public let isTokenAligned: Bool

    public var containsUnknown: Bool {
        tokens.contains(where: \.isUnknown)
    }

    /// Only fully resolved readings may be handed to a future alignment gate.
    /// The current alignment feature remains experimental and does not consume
    /// this value automatically; this property prevents accidental use of a
    /// partial/guessed reading if that path is revisited.
    public var isSafeForAlignment: Bool {
        !containsUnknown && confidence >= 0.90
    }

    public init(
        originalText: String,
        tokens: [JapaneseReadingToken],
        kanaText: String?,
        romajiText: String?,
        source: JapaneseReadingSource,
        confidence: Double,
        isTokenAligned: Bool = true
    ) {
        self.originalText = originalText
        self.tokens = tokens
        self.kanaText = kanaText
        self.romajiText = romajiText
        self.source = source
        self.confidence = confidence
        self.isTokenAligned = isTokenAligned
    }
}

/// A shared, timing-neutral reading projection for the main and desktop surfaces.
/// Partial confirmed annotations remain visible without inventing unknown readings.
struct JapaneseRubyPresentation {
    let originalText: String
    let kanaText: String?
    let romajiText: String?
    let rubyTokens: [LyricRubyToken]?

    init(originalText: String, reading: JapaneseReadingResult?, preferredRubyTokens: [LyricRubyToken]? = nil,
         kanaText: String? = nil, romajiText: String? = nil) {
        self.originalText = originalText
        self.kanaText = kanaText ?? reading?.kanaText
        self.romajiText = romajiText ?? reading?.romajiText
        if let preferredRubyTokens, !preferredRubyTokens.isEmpty,
           preferredRubyTokens.map(\.surface).joined() == originalText {
            rubyTokens = preferredRubyTokens
        } else if let reading, reading.isTokenAligned, reading.originalText == originalText {
            let tokens = reading.tokens.flatMap { JapaneseReadingPipeline.rubyTokens(for: $0) }
            rubyTokens = tokens.map(\.surface).joined() == originalText ? tokens : nil
        } else {
            rubyTokens = nil
        }
    }

    /// Legacy enrichment tokens carry no authority: a freshly resolved contextual
    /// reading must replace them. Only a selected kana version overrides it.
    init(line: LyricLine, reading: JapaneseReadingResult?, storedRubyIsAuthoritative: Bool) {
        let original = line.readingSurfaceText ?? line.originalText
        let stored = line.kanaText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = stored.flatMap { $0.isEmpty ? nil : JapaneseRomanizer.displayKana($0) }
        let resolved = Self(originalText: original, reading: reading,
            preferredRubyTokens: storedRubyIsAuthoritative ? line.rubyTokens : nil,
            kanaText: kana, romajiText: line.romajiText)
        if !resolved.hasRuby, kana == nil, !storedRubyIsAuthoritative {
            self = Self(originalText: original, reading: reading, preferredRubyTokens: line.rubyTokens,
                        kanaText: kana, romajiText: line.romajiText)
        } else {
            self = resolved
        }
    }

    var hasRuby: Bool {
        rubyTokens?.contains { token in
            if let ruby = token.ruby, !ruby.isEmpty { return true }
            return token.surface.unicodeScalars.contains { (0x30A1...0x30FA).contains($0.value) }
        } ?? false
    }

    func timedLayout(spans: [TimedTextSpan], fontSize: CGFloat, weight: CGFloat, showsRuby: Bool = true, design: String = "rounded") -> TimedRubyLayout? {
        guard !spans.isEmpty else { return nil }
        let tokens = showsRuby ? rubyTokens : nil
        return TimedTextComposer.computeTimedRubyLayout(
            originalText: originalText, spans: spans,
            rubyTokens: tokens ?? [LyricRubyToken(id: 0, surface: originalText, ruby: nil)],
            fontSize: fontSize, weight: weight, design: design
        )
    }
}

/// Morphology-first Japanese reading pipeline.
public enum JapaneseReadingPipeline {
    public static func analyze(
        originalText: String,
        providerKana: String? = nil
    ) -> JapaneseReadingResult {
        analyzeInternal(
            originalText: originalText,
            providerKana: providerKana,
            engine: JapaneseMeCabEngine(),
            contextual: false
        )
    }

    public static func analyze(
        originalText: String,
        providerKana: String? = nil,
        engine: any JapaneseMorphologyEngine
    ) -> JapaneseReadingResult {
        analyzeInternal(
            originalText: originalText,
            providerKana: providerKana,
            engine: engine,
            contextual: false
        )
    }

    /// Context v2 keeps the same local morphology baseline, then applies a
    /// small deterministic phrase resolver before ruby tokens are built.
    /// This deliberately remains local and inspectable; AI suggestions are
    /// handled by the explicit correction workflow, not during playback.
    public static func analyzeContextually(
        originalText: String,
        providerKana: String? = nil,
        engine: any JapaneseMorphologyEngine = JapaneseMeCabEngine()
    ) -> JapaneseReadingResult {
        analyzeInternal(
            originalText: originalText,
            providerKana: providerKana,
            engine: engine,
            contextual: true
        )
    }

    private static func analyzeInternal(
        originalText: String,
        providerKana: String?,
        engine: any JapaneseMorphologyEngine,
        contextual: Bool
    ) -> JapaneseReadingResult {
        let provider = providerKana?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider, !provider.isEmpty, isValidProviderKana(provider) {
            let kana = JapaneseRomanizer.toHiraganaPreservingLatin(provider)
            if let morphology = try? engine.tokenize(originalText),
               morphology.map(\.originalText).joined() == originalText,
               let projectedKana = projectProviderKana(kana, onto: morphology) {
                var offset = 0
                let tokens = morphology.enumerated().map { index, token in
                    let start = offset
                    offset += token.originalText.count
                    let tokenKana = projectedKana[index]
                    return JapaneseReadingToken(
                        id: index,
                        originalText: token.originalText,
                        lemma: token.lemma,
                        kana: tokenKana,
                        romaji: JapaneseRomanizer.romanizeConfirmedKana(tokenKana),
                        source: .providerOfficial,
                        confidence: 1.0,
                        partOfSpeech: token.partOfSpeech,
                        startOffset: start,
                        endOffset: offset
                    )
                }
                return JapaneseReadingResult(
                    originalText: originalText,
                    tokens: tokens,
                    kanaText: kana,
                    romajiText: JapaneseRomanizer.romanizeConfirmedKana(kana),
                    source: .providerOfficial,
                    confidence: 1.0
                )
            }

            // Keep the authoritative line layer even when the local analyzer
            // cannot prove a token-by-token projection. Callers must treat
            // this one-token result as a line reading, not as per-token ruby.
            let token = JapaneseReadingToken(
                id: 0,
                originalText: originalText,
                lemma: nil,
                kana: kana,
                romaji: JapaneseRomanizer.romanizeConfirmedKana(kana),
                source: .providerOfficial,
                confidence: 1.0,
                startOffset: 0,
                endOffset: originalText.count
            )
            return JapaneseReadingResult(
                originalText: originalText,
                tokens: [token],
                kanaText: kana,
                romajiText: token.romaji,
                source: .providerOfficial,
                confidence: 1.0,
                isTokenAligned: false
            )
        }

        guard !originalText.isEmpty else {
            return JapaneseReadingResult(
                originalText: originalText,
                tokens: [],
                kanaText: nil,
                romajiText: nil,
                source: .unknown,
                confidence: 0
            )
        }

        let rawMorphology: [JapaneseMorphologyToken]
        do {
            rawMorphology = try engine.tokenize(originalText)
        } catch {
            // Literal-only text is safe to preserve even when MeCab is absent;
            // kana containing ambiguous particles is not.
            if Self.isSafeLiteralOnly(originalText) {
                return Self.literalResult(originalText)
            }
            return Self.unknownResult(originalText)
        }

        guard !rawMorphology.isEmpty,
              rawMorphology.map(\.originalText).joined() == originalText else {
            return Self.unknownResult(originalText)
        }

        let repeatedNormalized = normalizeRepeatedSuffixReadings(rawMorphology)
        let morphology: [JapaneseMorphologyToken]
        if contextual {
            let ranked = rankContextualCandidate(
                originalText: originalText,
                baseline: repeatedNormalized,
                engine: engine
            )
            morphology = applyContextualPhraseReadings(ranked)
        } else {
            morphology = repeatedNormalized
        }

        var offset = 0
        let tokens = morphology.enumerated().map { index, token in
            let start = offset
            offset += token.originalText.count
            return Self.readingToken(from: token, id: index, startOffset: start)
        }
        let kanaText = tokens.allSatisfy { $0.kana != nil }
            ? tokens.compactMap(\.kana).joined()
            : nil
        let romajiText = tokens.allSatisfy { $0.romaji != nil }
            ? Self.buildRomajiText(from: tokens)
            : nil
        let source = Self.aggregateSource(tokens)
        let confidence = tokens.map(\.confidence).min() ?? 0

        return JapaneseReadingResult(
            originalText: originalText,
            tokens: tokens,
            kanaText: kanaText,
            romajiText: romajiText,
            source: source,
            confidence: confidence
        )
    }

    /// Projects an authoritative provider line reading onto local morphology
    /// tokens only when the boundaries can be proven from the provider text.
    /// A local dictionary reading is used as an anchor, never as a replacement
    /// for provider kana. If an ambiguous span cannot be bounded, the caller
    /// keeps the line-level reading and the UI can fail closed for ruby.
    private static func projectProviderKana(
        _ providerKana: String,
        onto morphology: [JapaneseMorphologyToken]
    ) -> [String]? {
        guard !morphology.isEmpty else { return nil }
        let characters = Array(JapaneseRomanizer.toHiraganaPreservingLatin(providerKana))
        var cursor = 0
        var projected: [String] = []

        for index in morphology.indices {
            let token = morphology[index]
            let isWhitespace = token.originalText.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }

            if isWhitespace {
                let expected = Array(token.originalText)
                if prefix(expected, in: characters, at: cursor) {
                    projected.append(String(expected))
                    cursor += expected.count
                } else {
                    // Some providers normalize lyric spacing away. Keep the
                    // surface token for ruby grouping without consuming a
                    // character that is not present in the provider layer.
                    projected.append(token.originalText)
                }
                continue
            }

            if !containsHan(token.originalText) {
                let expected = Array(JapaneseRomanizer.toHiraganaPreservingLatin(token.originalText))
                guard !expected.isEmpty else { return nil }

                if prefix(expected, in: characters, at: cursor) {
                    projected.append(String(characters[cursor..<(cursor + expected.count)]))
                    cursor += expected.count
                    continue
                }

                // Allow pronunciation variants (へ/え, は/わ, を/お) strictly when
                // the token is identified as a particle by morphology.
                if let variants = particlePronunciationVariants(for: token) {
                    var matched = false
                    for variant in variants {
                        let variantChars = Array(variant)
                        if prefix(variantChars, in: characters, at: cursor) {
                            projected.append(String(characters[cursor..<(cursor + variantChars.count)]))
                            cursor += variantChars.count
                            matched = true
                            break
                        }
                    }
                    if matched {
                        continue
                    }
                }

                return nil
            }

            let localAnchor = token.readingKatakana
                .map(JapaneseRomanizer.toHiraganaPreservingLatin)
                .map(Array.init) ?? []
            if !localAnchor.isEmpty,
               prefix(localAnchor, in: characters, at: cursor) {
                projected.append(String(characters[cursor..<(cursor + localAnchor.count)]))
                cursor += localAnchor.count
                continue
            }

            if let nextAnchor = nextProviderAnchor(
                after: index,
                morphology: morphology,
                providerCharacters: characters,
                from: cursor
            ) {
                guard nextAnchor > cursor else { return nil }
                projected.append(String(characters[cursor..<nextAnchor]))
                cursor = nextAnchor
                continue
            }

            guard index == morphology.index(before: morphology.endIndex),
                  cursor < characters.count else {
                return nil
            }
            projected.append(String(characters[cursor...]))
            cursor = characters.count
        }

        guard cursor == characters.count,
              projected.count == morphology.count,
              projected.allSatisfy({ !$0.isEmpty && !containsHan($0) }) else {
            return nil
        }
        return projected
    }

    private static func nextProviderAnchor(
        after index: Int,
        morphology: [JapaneseMorphologyToken],
        providerCharacters: [Character],
        from cursor: Int
    ) -> Int? {
        guard index + 1 < morphology.count else { return nil }
        for nextIndex in (index + 1)..<morphology.count {
            let token = morphology[nextIndex]
            let anchor: [Character]
            if !containsHan(token.originalText) {
                anchor = Array(JapaneseRomanizer.toHiraganaPreservingLatin(token.originalText))
            } else if let raw = token.readingKatakana, raw != "*", !raw.isEmpty {
                anchor = Array(JapaneseRomanizer.toHiraganaPreservingLatin(raw))
            } else {
                continue
            }
            guard !anchor.isEmpty else { continue }
            if let position = providerCharacters[cursor...].firstRange(of: anchor)?.lowerBound {
                return position
            }
        }
        return nil
    }

    private static func isParticleToken(_ token: JapaneseMorphologyToken) -> Bool {
        guard let pos = token.partOfSpeech else { return false }
        return pos.hasPrefix("助詞") || pos.contains("助詞") || pos == "particle"
    }

    private static func particlePronunciationVariants(for token: JapaneseMorphologyToken) -> [String]? {
        guard isParticleToken(token) else { return nil }
        let hiragana = JapaneseRomanizer.toHiraganaPreservingLatin(token.originalText)
        switch hiragana {
        case "へ": return ["へ", "え"]
        case "は": return ["は", "わ"]
        case "を": return ["を", "お"]
        default: return [hiragana]
        }
    }

    private static func prefix(
        _ expected: [Character],
        in actual: [Character],
        at offset: Int
    ) -> Bool {
        guard offset >= 0, offset + expected.count <= actual.count else { return false }
        return Array(actual[offset..<(offset + expected.count)]) == expected
    }

    /// Provider kana is authoritative only when it is actually Japanese
    /// reading text. A provider occasionally returns romaji in a kana field;
    /// accepting that value would put Latin text into ruby and make the third
    /// display mode look like a false reading. Fail closed and let local
    /// morphology decide instead.
    private static func isValidProviderKana(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { scalar in
            (0x3040...0x30FF).contains(scalar.value)
        }) else {
            return false
        }

        return scalars.allSatisfy { scalar in
            let value = scalar.value
            let isJapaneseKana = (0x3040...0x30FF).contains(value)
            let isIterationMark = value == 0x3005
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let isPunctuation = CharacterSet.punctuationCharacters.contains(scalar)
            let isSymbol = CharacterSet.symbols.contains(scalar)
            return isJapaneseKana || isIterationMark || isWhitespace || isPunctuation || isSymbol
        }
    }

    private static func readingToken(
        from token: JapaneseMorphologyToken,
        id: Int,
        startOffset: Int
    ) -> JapaneseReadingToken {
        let start = startOffset
        let end = startOffset + token.originalText.count

        if isSafeLiteralToken(token.originalText) {
            return JapaneseReadingToken(
                id: id,
                originalText: token.originalText,
                lemma: token.lemma,
                kana: token.originalText,
                romaji: token.originalText,
                source: .literalPreserved,
                confidence: 1.0,
                partOfSpeech: token.partOfSpeech,
                startOffset: start,
                endOffset: end
            )
        }

        guard let rawReading = token.readingKatakana,
              rawReading != "*",
              !rawReading.isEmpty else {
            return unknownToken(from: token, id: id, start: start, end: end)
        }

        let kana = JapaneseRomanizer.toHiraganaPreservingLatin(rawReading)
        // MeCab emits the original surface for unresolved extended Han
        // characters. That is not a reading and must fail closed.
        guard !containsHan(kana) else {
            return unknownToken(from: token, id: id, start: start, end: end)
        }

        let lyricKana = applyParticleReading(
            kana,
            surface: token.originalText,
            partOfSpeech: token.partOfSpeech
        )
        let properNoun = token.partOfSpeech?.contains("固有名詞") == true
        let confidence = properNoun ? 0.72 : 0.96
        return JapaneseReadingToken(
            id: id,
            originalText: token.originalText,
            lemma: token.lemma,
            kana: lyricKana,
            romaji: JapaneseRomanizer.romanizeConfirmedKana(lyricKana),
            source: .mecabIPADIC,
            confidence: confidence,
            partOfSpeech: token.partOfSpeech,
            startOffset: start,
            endOffset: end
        )
    }

    private static func unknownToken(
        from token: JapaneseMorphologyToken,
        id: Int,
        start: Int,
        end: Int
    ) -> JapaneseReadingToken {
        JapaneseReadingToken(
            id: id,
            originalText: token.originalText,
            lemma: token.lemma,
            kana: nil,
            romaji: nil,
            source: .unknown,
            confidence: 0,
            partOfSpeech: token.partOfSpeech,
            startOffset: start,
            endOffset: end
        )
    }

    private static func applyParticleReading(
        _ kana: String,
        surface: String,
        partOfSpeech: String?
    ) -> String {
        guard partOfSpeech?.hasPrefix("助詞") == true else { return kana }
        switch surface {
        case "は": return "わ"
        case "へ": return "え"
        case "を": return "お"
        default: return kana
        }
    }

    /// IPADIC may reinterpret the second and later glyph in an unseparated
    /// repeated-kanji lyric as a suffix noun (for example 手手手手 becomes
    /// テ・シュ・シュ・シュ). Inherit the lexical head reading only for that
    /// narrow morphology pattern; ordinary compounds and separated tokens
    /// keep their dictionary readings.
    private static func normalizeRepeatedSuffixReadings(
        _ tokens: [JapaneseMorphologyToken]
    ) -> [JapaneseMorphologyToken] {
        guard tokens.count > 1 else { return tokens }
        var normalized = tokens

        for index in tokens.indices.dropFirst() {
            let token = tokens[index]
            guard token.originalText.count == 1,
                  containsHan(token.originalText),
                  token.partOfSpeech?.contains("接尾") == true,
                  tokens[index - 1].originalText == token.originalText else {
                continue
            }

            var headIndex = index - 1
            while headIndex > tokens.startIndex,
                  tokens[headIndex - 1].originalText == token.originalText {
                headIndex -= 1
            }

            let head = tokens[headIndex]
            guard head.partOfSpeech?.contains("接尾") != true,
                  let headReading = head.readingKatakana,
                  !headReading.isEmpty,
                  headReading != "*",
                  head.lemma != nil,
                  head.lemma == token.lemma else {
                continue
            }

            normalized[index] = JapaneseMorphologyToken(
                originalText: token.originalText,
                readingKatakana: headReading,
                lemma: token.lemma,
                partOfSpeech: token.partOfSpeech,
                conjugationType: token.conjugationType,
                conjugationForm: token.conjugationForm
            )
        }

        return normalized
    }

    private struct ContextualPhraseRule {
        let surfaces: [String]
        let replacementReadings: [Int: String]
    }

    /// Phrase rules correct morphology ambiguity while preserving token
    /// boundaries, so ruby remains attached only to the corresponding Han
    /// span. Add rules here only when the surrounding phrase is unambiguous.
    private static let contextualPhraseRules: [ContextualPhraseRule] = [
        // IPADIC splits this established compound into an unrelated 既 reading and unknown 読.
        ContextualPhraseRule(surfaces: ["既", "読"], replacementReadings: [0: "キ", 1: "ドク"]),
        ContextualPhraseRule(
            surfaces: ["満", "を", "持", "し", "て"],
            replacementReadings: [0: "マン"]
        ),
        // IPADIC contains only the Sino-Japanese noun reading ホウコウ for
        // this spelling in this context. Keep the visible okurigana in its
        // own token and replace only the Han stem.
        ContextualPhraseRule(
            surfaces: ["彷徨", "って"],
            replacementReadings: [0: "サマヨ"]
        )
    ]

    private struct ContextualCandidateRule {
        let surfaces: [String]
        let expectedReadings: [Int: String]
    }

    /// These rules do not invent a reading. They select an alternative that
    /// MeCab already returned for a semantically fixed compound family.
    private static let contextualCandidateRules: [ContextualCandidateRule] = [
        ContextualCandidateRule(surfaces: ["過去", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["現在", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["未来", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["基本", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["連用", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["終止", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["命令", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["仮定", "形"], expectedReadings: [1: "ケイ"]),
        ContextualCandidateRule(surfaces: ["未然", "形"], expectedReadings: [1: "ケイ"])
    ]

    private static func rankContextualCandidate(
        originalText: String,
        baseline: [JapaneseMorphologyToken],
        engine: any JapaneseMorphologyEngine
    ) -> [JapaneseMorphologyToken] {
        let matchingRules = contextualCandidateRules.filter { rule in
            containsSurfaceSequence(rule.surfaces, in: baseline)
        }
        guard !matchingRules.isEmpty,
              let nBestEngine = engine as? any JapaneseNBestMorphologyEngine,
              let candidates = try? nBestEngine.tokenizations(originalText, maximumCount: 8) else {
            return baseline
        }

        for rule in matchingRules {
            guard let baselineStart = surfaceSequenceStart(rule.surfaces, in: baseline) else {
                continue
            }
            for candidate in candidates {
                guard let start = surfaceSequenceStart(rule.surfaces, in: candidate) else { continue }
                let matches = rule.expectedReadings.allSatisfy { relativeIndex, expected in
                    let index = start + relativeIndex
                    return candidate.indices.contains(index)
                        && candidate[index].readingKatakana == expected
                }
                if matches {
                    // Keep the best-path tokenization for the rest of the
                    // lyric line. N-best is consulted only to resolve the
                    // reading of the explicitly matched ambiguous token.
                    var resolved = baseline
                    for (relativeIndex, _) in rule.expectedReadings {
                        let baselineIndex = baselineStart + relativeIndex
                        let candidateIndex = start + relativeIndex
                        let source = resolved[baselineIndex]
                        resolved[baselineIndex] = JapaneseMorphologyToken(
                            originalText: source.originalText,
                            readingKatakana: candidate[candidateIndex].readingKatakana,
                            lemma: source.lemma,
                            partOfSpeech: source.partOfSpeech,
                            conjugationType: source.conjugationType,
                            conjugationForm: source.conjugationForm
                        )
                    }
                    return resolved
                }
            }
        }
        return baseline
    }

    private static func containsSurfaceSequence(
        _ surfaces: [String],
        in tokens: [JapaneseMorphologyToken]
    ) -> Bool {
        surfaceSequenceStart(surfaces, in: tokens) != nil
    }

    private static func surfaceSequenceStart(
        _ surfaces: [String],
        in tokens: [JapaneseMorphologyToken]
    ) -> Int? {
        guard !surfaces.isEmpty, tokens.count >= surfaces.count else { return nil }
        for start in 0...(tokens.count - surfaces.count) {
            let end = start + surfaces.count
            if tokens[start..<end].map(\.originalText) == surfaces {
                return start
            }
        }
        return nil
    }

    private static func applyContextualPhraseReadings(
        _ tokens: [JapaneseMorphologyToken]
    ) -> [JapaneseMorphologyToken] {
        guard !tokens.isEmpty else { return tokens }
        var resolved = tokens

        for rule in contextualPhraseRules where tokens.count >= rule.surfaces.count {
            for start in 0...(tokens.count - rule.surfaces.count) {
                let end = start + rule.surfaces.count
                let actual = tokens[start..<end].map(\.originalText)
                guard actual == rule.surfaces else { continue }

                for (relativeIndex, reading) in rule.replacementReadings {
                    let index = start + relativeIndex
                    let token = resolved[index]
                    resolved[index] = JapaneseMorphologyToken(
                        originalText: token.originalText,
                        readingKatakana: reading,
                        lemma: token.lemma,
                        partOfSpeech: contextualPartOfSpeech(token.partOfSpeech),
                        conjugationType: token.conjugationType,
                        conjugationForm: token.conjugationForm
                    )
                }
            }
        }
        return resolved
    }

    private static func contextualPartOfSpeech(_ value: String?) -> String? {
        guard let value, value.contains("固有名詞") else { return value }
        return "名詞-一般"
    }

    static func buildRomajiText(from tokens: [JapaneseReadingToken]) -> String {
        var result = ""
        var previous: JapaneseReadingToken?

        for token in tokens {
            guard let piece = token.romaji else { continue }
            let whitespace = token.originalText.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
            let punctuation = token.partOfSpeech?.hasPrefix("記号") == true
                || token.originalText.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.contains($0)
                }

            if result.isEmpty || whitespace || punctuation {
                result += piece
            } else if let previous {
                if isWhitespace(previous.originalText) {
                    result += piece
                } else if shouldJoin(previous, token) || isOpeningPunctuation(previous.originalText) {
                    result += piece
                } else {
                    result += " " + piece
                }
            } else {
                result += piece
            }
            previous = token
        }
        return result
    }

    private static func shouldJoin(_ previous: JapaneseReadingToken, _ current: JapaneseReadingToken) -> Bool {
        guard !isWhitespace(previous.originalText), !isWhitespace(current.originalText) else { return false }
        if previous.source == .literalPreserved,
           current.source == .literalPreserved,
           isLatinOrDigit(previous.originalText),
           isLatinOrDigit(current.originalText) {
            return true
        }
        let previousPOS = previous.partOfSpeech ?? ""
        let currentPOS = current.partOfSpeech ?? ""
        if previousPOS.contains("動詞") && (currentPOS.contains("動詞") || currentPOS.contains("助動詞") || currentPOS.contains("接続助詞")) {
            return true
        }
        if previousPOS.contains("形容詞") && currentPOS.contains("助動詞") {
            return true
        }
        if previousPOS.contains("接続助詞") && currentPOS.contains("動詞-非自立") {
            return true
        }
        return false
    }

    private static func aggregateSource(_ tokens: [JapaneseReadingToken]) -> JapaneseReadingSource {
        let sources = Set(tokens.map(\.source))
        if sources.count == 1 { return sources.first ?? .unknown }
        return .mixed
    }

    private static func unknownResult(_ originalText: String) -> JapaneseReadingResult {
        let token = JapaneseReadingToken(
            id: 0,
            originalText: originalText,
            lemma: nil,
            kana: nil,
            romaji: nil,
            source: .unknown,
            confidence: 0,
            startOffset: 0,
            endOffset: originalText.count
        )
        return JapaneseReadingResult(
            originalText: originalText,
            tokens: [token],
            kanaText: nil,
            romajiText: nil,
            source: .unknown,
            confidence: 0
        )
    }

    private static func literalResult(_ originalText: String) -> JapaneseReadingResult {
        let token = JapaneseReadingToken(
            id: 0,
            originalText: originalText,
            lemma: originalText,
            kana: JapaneseRomanizer.toHiraganaPreservingLatin(originalText),
            romaji: JapaneseRomanizer.romanizeConfirmedKana(originalText),
            source: .literalPreserved,
            confidence: 1.0,
            startOffset: 0,
            endOffset: originalText.count
        )
        return JapaneseReadingResult(
            originalText: originalText,
            tokens: [token],
            kanaText: token.kana,
            romajiText: token.romaji,
            source: .literalPreserved,
            confidence: 1.0
        )
    }

    private static func isSafeLiteralOnly(_ text: String) -> Bool {
        guard !containsHan(text) else { return false }
        // Without morphology we cannot safely disambiguate lyric particles.
        return !text.contains("は") && !text.contains("へ") && !text.contains("を")
    }

    private static func isSafeLiteralToken(_ text: String) -> Bool {
        guard !containsHan(text) else { return false }
        let hasKana = text.unicodeScalars.contains { isKana($0) }
        if hasKana { return false }
        return true
    }

    private static func isLatinOrDigit(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (0x30...0x39).contains(value)
                || (0x41...0x5A).contains(value)
                || (0x61...0x7A).contains(value)
                || (0xFF10...0xFF19).contains(value)
                || (0xFF21...0xFF3A).contains(value)
                || (0xFF41...0xFF5A).contains(value)
        }
    }

    private static func isWhitespace(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isOpeningPunctuation(_ text: String) -> Bool {
        ["「", "『", "（", "(", "[", "【", "〈", "《"].contains(text)
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value)
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0x20000...0x2FA1F).contains(value)
        }
    }
}

public extension JapaneseReadingPipeline {
    /// Builds ruby display tokens without duplicating okurigana.
    ///
    /// The confirmed full kana/romaji layers remain untouched. This is only a
    /// presentation mapping: kana that already exists in the original surface
    /// stays in the base text, while ruby is assigned to the Han span before
    /// that kana. When the mapping is ambiguous, the builder falls back to a
    /// word-level ruby token rather than inventing a reading.
    static func rubyTokens(
        for readingToken: JapaneseReadingToken,
        engine: (any JapaneseMorphologyEngine)? = nil
    ) -> [LyricRubyToken] {
        JapaneseRubyTokenBuilder.build(
            readingToken,
            engine: engine ?? JapaneseMeCabEngine()
        )
    }
}

/// Deterministic surface/kana alignment for display-only ruby tokens.
fileprivate enum JapaneseRubyTokenBuilder {
    private enum SurfaceKind: Equatable {
        case han
        case kana
        case plain
    }

    private struct SurfaceRun: Equatable {
        let text: String
        let kind: SurfaceKind
    }

    private struct Match {
        let start: Int
        let end: Int
    }

    static func build(
        _ readingToken: JapaneseReadingToken,
        engine: any JapaneseMorphologyEngine
    ) -> [LyricRubyToken] {
        let surface = readingToken.originalText
        guard !surface.isEmpty,
              let kana = readingToken.kana,
              !kana.isEmpty,
              containsHan(surface) else {
            return [baseToken(for: readingToken, segment: 0)]
        }

        let runs = surfaceRuns(surface)
        let readingCharacters = Array(JapaneseRomanizer.toHiraganaPreservingLatin(kana))
        let anchorRuns = runs.enumerated().filter { $0.element.kind == .kana }

        // Iteration marks are not Han characters. If a dictionary can resolve
        // the repeated base character independently, show only that reading
        // above the actual Han character and leave 々 in the base line.
        if anchorRuns.isEmpty,
           let iterationIndex = runs.firstIndex(where: { containsIterationMark($0.text) }),
           let hanIndex = runs[..<iterationIndex].lastIndex(where: { $0.kind == .han }),
           let singleReading = singleSurfaceReading(runs[hanIndex].text, engine: engine),
           readingCharacters.starts(with: Array(singleReading)) {
            var kanaSurfaceByRun: [Int: String] = [:]
            for (index, run) in runs.enumerated() where run.kind != .han {
                kanaSurfaceByRun[index] = run.text
            }
            let remainingReading = String(readingCharacters.dropFirst(singleReading.count))
            if !remainingReading.isEmpty {
                // `日々` is represented as `日:ひ` + `々:び`. The iteration
                // mark has no independent ruby annotation, but it still
                // needs its replacement kana in the kana-primary mode.
                kanaSurfaceByRun[iterationIndex] = remainingReading
            }
            kanaSurfaceByRun[hanIndex] = singleReading
            return makeTokens(
                runs: runs,
                rubyByRun: [hanIndex: singleReading],
                kanaSurfaceByRun: kanaSurfaceByRun,
                readingToken: readingToken
            )
        }

        guard !anchorRuns.isEmpty else {
            return [wordToken(for: readingToken, ruby: kana)]
        }

        guard let matches = matchAnchors(
            anchorRuns.map { normalizedCharacters($0.element.text) },
            in: readingCharacters
        ) else {
            return [wordToken(for: readingToken, ruby: kana)]
        }

        var rubyByRun: [Int: String] = [:]
        var previousReadingEnd = 0
        var previousAnchorRunIndex: Int?

        for (anchorOffset, anchor) in anchorRuns.enumerated() {
            let match = matches[anchorOffset]
            let readingPart = String(readingCharacters[previousReadingEnd..<match.start])
            let rangeStart = (previousAnchorRunIndex.map { $0 + 1 } ?? 0)
            let rangeEnd = anchor.offset
            let hanRuns = runs[rangeStart..<rangeEnd].enumerated().compactMap { offset, run in
                run.kind == .han ? rangeStart + offset : nil
            }

            if !readingPart.isEmpty {
                guard hanRuns.count == 1 else {
                    return [wordToken(for: readingToken, ruby: kana)]
                }
                rubyByRun[hanRuns[0]] = readingPart
            }

            previousReadingEnd = match.end
            previousAnchorRunIndex = anchor.offset
        }

        let trailingReading = String(readingCharacters[previousReadingEnd...])
        let trailingStart = (previousAnchorRunIndex.map { $0 + 1 } ?? 0)
        let trailingHanRuns = runs[trailingStart...].enumerated().compactMap { offset, run in
            run.kind == .han ? trailingStart + offset : nil
        }
        if !trailingReading.isEmpty {
            guard trailingHanRuns.count == 1 else {
                return [wordToken(for: readingToken, ruby: kana)]
            }
            rubyByRun[trailingHanRuns[0]] = trailingReading
        }

        guard rubyByRun.count == runs.filter({ $0.kind == .han }).count else {
            return [wordToken(for: readingToken, ruby: kana)]
        }

        return makeTokens(
            runs: runs,
            rubyByRun: rubyByRun,
            readingToken: readingToken
        )
    }

    private static func makeTokens(
        runs: [SurfaceRun],
        rubyByRun: [Int: String],
        kanaSurfaceByRun: [Int: String] = [:],
        readingToken: JapaneseReadingToken
    ) -> [LyricRubyToken] {
        runs.enumerated().map { index, run in
            let ruby = rubyByRun[index]
            let kanaSurface = kanaSurfaceByRun[index]
                ?? ruby
                ?? (run.kind == .han
                    ? nil
                    : run.kind == .kana
                        ? JapaneseRomanizer.displayKana(run.text)
                        : run.text)
            return LyricRubyToken(
                id: readingToken.id * 10_000 + index,
                surface: run.text,
                ruby: ruby,
                kanaSurface: kanaSurface,
                romaji: ruby.map(JapaneseRomanizer.romanizeConfirmedKana),
                confidence: readingToken.confidence
            )
        }
    }

    private static func baseToken(
        for readingToken: JapaneseReadingToken,
        segment: Int
    ) -> LyricRubyToken {
        LyricRubyToken(
            id: readingToken.id * 10_000 + segment,
            surface: readingToken.originalText,
            ruby: nil,
            kanaSurface: containsKatakana(readingToken.originalText)
                ? JapaneseRomanizer.displayKana(readingToken.kana ?? readingToken.originalText)
                : nil,
            romaji: nil,
            confidence: readingToken.confidence
        )
    }

    private static func wordToken(
        for readingToken: JapaneseReadingToken,
        ruby: String
    ) -> LyricRubyToken {
        LyricRubyToken(
            id: readingToken.id * 10_000,
            surface: readingToken.originalText,
            ruby: containsHan(readingToken.originalText) ? ruby : nil,
            kanaSurface: containsHan(readingToken.originalText) ? ruby : nil,
            romaji: JapaneseRomanizer.romanizeConfirmedKana(ruby),
            confidence: readingToken.confidence
        )
    }

    private static func surfaceRuns(_ surface: String) -> [SurfaceRun] {
        var runs: [SurfaceRun] = []
        for character in surface {
            let kind: SurfaceKind
            if isHan(character) {
                kind = .han
            } else if isKana(character) {
                kind = .kana
            } else {
                kind = .plain
            }

            if let last = runs.last, last.kind == kind {
                runs[runs.count - 1] = SurfaceRun(
                    text: last.text + String(character),
                    kind: kind
                )
            } else {
                runs.append(SurfaceRun(text: String(character), kind: kind))
            }
        }
        return runs
    }

    private static func matchAnchors(
        _ anchors: [[Character]],
        in reading: [Character]
    ) -> [Match]? {
        func occurrences(_ pattern: [Character], from start: Int) -> [Match] {
            guard !pattern.isEmpty, start <= reading.count - pattern.count else { return [] }
            return (start...(reading.count - pattern.count)).compactMap { index in
                Array(reading[index..<(index + pattern.count)]) == pattern
                    ? Match(start: index, end: index + pattern.count)
                    : nil
            }
        }

        func search(_ anchorIndex: Int, from readingStart: Int) -> [Match]? {
            guard anchorIndex < anchors.count else { return [] }
            for match in occurrences(anchors[anchorIndex], from: readingStart) {
                if let rest = search(anchorIndex + 1, from: match.end) {
                    return [match] + rest
                }
            }
            return nil
        }

        return search(0, from: 0)
    }

    private static func singleSurfaceReading(
        _ surface: String,
        engine: any JapaneseMorphologyEngine
    ) -> String? {
        guard let token = (try? engine.tokenize(surface))?.first,
              token.originalText == surface,
              let raw = token.readingKatakana,
              raw != "*",
              !raw.isEmpty else {
            return nil
        }
        let kana = JapaneseRomanizer.toHiraganaPreservingLatin(raw)
        return containsHan(kana) ? nil : kana
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        Array(JapaneseRomanizer.toHiraganaPreservingLatin(text))
    }

    fileprivate static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0x20000...0x2FA1F).contains(value)
        }
    }

    private static func isHan(_ character: Character) -> Bool {
        containsHan(String(character))
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
        }
    }

    private static func containsKatakana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x30A1...0x30FA).contains(scalar.value)
        }
    }

    private static func containsIterationMark(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0x3005 }
    }
}

public extension LyricRubyToken {
    /// Compatibility initializer for callers that still need one word-level
    /// token. The main lyrics renderer uses `JapaneseReadingPipeline.rubyTokens`
    /// so okurigana can be split into separate base-text tokens.
    init(readingToken: JapaneseReadingToken) {
        self.init(
            id: readingToken.id,
            surface: readingToken.originalText,
            ruby: JapaneseRubyTokenBuilder.containsHan(readingToken.originalText)
                ? readingToken.kana
                : nil,
            kanaSurface: JapaneseRubyTokenBuilder.containsHan(readingToken.originalText)
                ? readingToken.kana
                : nil,
            romaji: readingToken.romaji,
            confidence: readingToken.confidence
        )
    }
}
