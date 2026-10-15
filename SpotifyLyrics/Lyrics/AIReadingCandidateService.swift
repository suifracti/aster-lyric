import CryptoKit
import Foundation

/// Optional, candidate-only refinement for unresolved Japanese readings.
///
/// This adapter deliberately reuses the Phase 2.5 OpenAI-compatible client and
/// its Keychain store. It is never invoked unless the user explicitly enables
/// AI-assisted disambiguation, and it sends only the ambiguous line/token
/// context needed for a reading candidate. The returned result is marked with
/// `aiCandidateOnly` so the reading session cannot auto-adopt it.
public struct AIReadingCandidateService: Sendable {
    private let client: OpenAICompatibleClient
    private let keyStore: any AITranslationAPIKeyStore
    private let acceptanceBudget: TranslationAcceptanceRequestBudget?

    public init(
        client: OpenAICompatibleClient = OpenAICompatibleClient(),
        keyStore: any AITranslationAPIKeyStore = KeychainAITranslationAPIKeyStore(),
        acceptanceBudget: TranslationAcceptanceRequestBudget? = .processBudget
    ) {
        self.client = client
        self.keyStore = keyStore
        self.acceptanceBudget = acceptanceBudget
    }

    public func refine(
        result: ReadingGenerationResult,
        request: ReadingGenerationRequest,
        configuration: AITranslationConfiguration
    ) async throws -> ReadingGenerationResult {
        guard configuration.engineID == TranslationEngineID.openAICompatible.rawValue else {
            throw AITranslationError.engineUnavailable("AI 读音候选目前仅支持兼容 API；不会转用其他翻译服务")
        }
        guard configuration.isConfigured else { throw AITranslationError.notConfigured }
        _ = try AITranslationEndpoint(baseURL: configuration.baseURL).validatedChatCompletionsURL()

        let ambiguousLines = result.lines.filter { line in
            let warnings = Set(line.warnings)
            return !warnings.isDisjoint(with: [.unknownToken, .ambiguousReading, .languageNeedsConfirmation])
        }
        guard !ambiguousLines.isEmpty else {
            throw AITranslationError.engineUnavailable("没有需要 AI 辅助的不确定读音；本地读音可直接使用")
        }

        let payload: [[String: Any]] = ambiguousLines.map { line in
            let tokens = line.tokens
                .filter { $0.needsConfirmation || $0.reading == nil }
                .map { [
                    "id": $0.id,
                    "surface": $0.surface,
                    "currentReading": $0.reading ?? ""
                ] as [String: Any] }
            return [
                "lineIndex": line.lineIndex,
                "text": line.originalText,
                "tokens": tokens
            ]
        }
        let ambiguousIndices = Set(ambiguousLines.map(\.lineIndex))
        let boundedContext = request.lines
            .filter { line in
                ambiguousIndices.contains(line.lineIndex)
                    || ambiguousIndices.contains(line.lineIndex - 1)
                    || ambiguousIndices.contains(line.lineIndex + 1)
            }
            .map(\.originalText)
        let context: [String: Any] = [
            "language": request.languageHint ?? "ja",
            "representation": request.representationID.rawValue,
            "nearbyLines": boundedContext,
            "ambiguousLines": payload
        ]
        let userData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
        guard let user = String(data: userData, encoding: .utf8) else {
            throw AITranslationError.invalidResponse("无法构造读音候选请求")
        }
        let system = """
        Return ONLY a JSON array. Each item must have lineIndex (integer) and tokens (array). Each token must have id (integer) and reading (string). Return only token IDs supplied by the user. Return hiragana for kana or romaji for romaji. Do not change lyric text, translation, timing, token order, or line indices. These are suggestions only; do not add explanations.
        """
        let promptHash = SHA256.hash(data: Data((system + "\n" + user).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try Task.checkCancellation()
        try acceptanceBudget?.reserve(
            provider: configuration.engineID, trackKey: request.trackStableKey ?? "")
        guard let apiKey = keyStore.read(), !apiKey.isEmpty else {
            throw AITranslationError.notConfigured
        }
        try Task.checkCancellation()
        let response = try await client.complete(
            prompt: AITranslationPrompt(system: system, user: user, promptHash: promptHash),
            configuration: configuration,
            apiKey: apiKey,
            inputLineCount: ambiguousLines.count
        )
        let candidates = try Self.parse(response.content)
        let allowed = Dictionary(uniqueKeysWithValues: ambiguousLines.map { line in
            (line.lineIndex, Set(line.tokens.map(\.id)))
        })
        guard Set(candidates.map(\.lineIndex)).isSubset(of: Set(allowed.keys)),
              candidates.map(\.lineIndex).count == Set(candidates.map(\.lineIndex)).count,
              candidates.allSatisfy({ item in
                  guard let tokenIDs = allowed[item.lineIndex] else { return false }
                  return item.tokens.map(\.id).count == Set(item.tokens.map(\.id)).count
                      && item.tokens.allSatisfy { tokenIDs.contains($0.id) && !$0.reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }) else {
            throw AITranslationError.invalidResponse("读音候选的行或 token 不匹配")
        }

        let byLine = Dictionary(uniqueKeysWithValues: candidates.map { ($0.lineIndex, $0) })
        let lines = result.lines.map { line -> ReadingLineResult in
            guard let candidate = byLine[line.lineIndex] else { return line }
            let byToken = Dictionary(uniqueKeysWithValues: candidate.tokens.map { ($0.id, $0.reading) })
            let tokens = line.tokens.map { token in
                guard let reading = byToken[token.id] else { return token }
                return ReadingToken(
                    id: token.id,
                    surface: token.surface,
                    reading: reading,
                    startOffset: token.startOffset,
                    endOffset: token.endOffset,
                    source: .aiCandidate,
                    confidence: min(token.confidence, 0.75),
                    needsConfirmation: true
                )
            }
            let readingText = Self.render(tokens: tokens, representation: request.representationID)
            return ReadingLineResult(
                lineIndex: line.lineIndex,
                originalText: line.originalText,
                readingText: readingText,
                language: line.language,
                tokens: tokens,
                warnings: Array(Set(line.warnings + [.aiCandidateOnly])).sorted { $0.rawValue < $1.rawValue },
                confidence: min(line.confidence, 0.75)
            )
        }
        return ReadingGenerationResult(
            engineID: result.engineID,
            representationID: result.representationID,
            lines: lines,
            language: result.language,
            confidence: min(result.confidence, 0.75),
            warnings: Array(Set(result.warnings + [.aiCandidateOnly])).sorted { $0.rawValue < $1.rawValue },
            contextHash: result.contextHash + ":aiCandidate"
        )
    }

    private struct Candidate: Decodable, Sendable {
        let lineIndex: Int
        let tokens: [Token]
    }

    private struct Token: Decodable, Sendable {
        let id: Int
        let reading: String
    }

    private static func parse(_ data: Data) throws -> [Candidate] {
        do {
            return try JSONDecoder().decode([Candidate].self, from: data)
        } catch {
            throw AITranslationError.invalidResponse("读音候选不是有效 JSON")
        }
    }

    private static func render(tokens: [ReadingToken], representation: ReadingRepresentationID) -> String? {
        guard !tokens.isEmpty else { return nil }
        var result = ""
        for token in tokens.sorted(by: { $0.startOffset < $1.startOffset }) {
            let reading = token.reading ?? token.surface
            if representation == .romaji {
                result += JapaneseRomanizer.romanizeConfirmedKana(reading)
            } else {
                result += reading
            }
        }
        return result.isEmpty ? nil : result
    }
}
