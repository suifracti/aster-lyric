import Foundation
import CryptoKit

public struct AITranslationConfiguration: Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var targetLanguage: String
    public var style: String
    public var customSystemPrompt: String
    public var temperature: Double
    public var timeout: TimeInterval
    public var autoTranslateNewLyrics: Bool
    public var engineID: String
    public var promptPresetID: String
    public var profileID: UUID?
    public var profileSnapshot: String
    public var fallbackStrategy: TranslationFallbackStrategy
    public var workflowID: String
    public var codexReasoningEffort: String

    public init(
        baseURL: String = "",
        model: String = "",
        targetLanguage: String = "zh-Hans",
        style: String = "natural_song",
        customSystemPrompt: String = "",
        temperature: Double = 0.2,
        timeout: TimeInterval = 60,
        autoTranslateNewLyrics: Bool = false,
        engineID: String = TranslationEngineID.openAICompatible.rawValue,
        promptPresetID: String = TranslationPromptPresetID.naturalSong.rawValue,
        profileID: UUID? = nil,
        profileSnapshot: String = "",
        fallbackStrategy: TranslationFallbackStrategy = .none,
        workflowID: String = TranslationWorkflowID.contextualV2.rawValue,
        codexReasoningEffort: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.targetLanguage = targetLanguage
        self.style = style
        self.customSystemPrompt = customSystemPrompt
        self.temperature = min(max(temperature, 0), 2)
        self.timeout = min(max(timeout, 5), 600)
        self.autoTranslateNewLyrics = autoTranslateNewLyrics
        self.engineID = engineID
        self.promptPresetID = promptPresetID
        self.profileID = profileID
        self.profileSnapshot = profileSnapshot
        self.fallbackStrategy = fallbackStrategy
        self.workflowID = workflowID
        self.codexReasoningEffort = codexReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        if TranslationEngineID(rawValue: engineID) == .appleSystem {
            return true
        }
        if TranslationEngineID(rawValue: engineID) == .codexChatGPT { return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var providerReasoningSetting: String {
        engineID == TranslationEngineID.codexChatGPT.rawValue
            ? "effort=" + (codexReasoningEffort.isEmpty ? "model-default" : codexReasoningEffort) : ""
    }
    public var providerCacheIdentity: String {
        let usesAPI = TranslationEngineID(rawValue: engineID) == .openAICompatible
        let fields = ["provider-cache-v1", engineID,
            engineID == TranslationEngineID.appleSystem.rawValue ? "" : model,
            usesAPI ? AITranslationEndpoint(baseURL: baseURL).chatCompletionsURL.absoluteString : "",
            usesAPI ? "default" : "", providerReasoningSetting, usesAPI ? String(temperature) : ""]
        return SHA256.hash(data: try! JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
    public var requestIdentity: AITranslationConfigurationIdentity {
        let usesAPI = engineID == TranslationEngineID.openAICompatible.rawValue
        return AITranslationConfigurationIdentity(engineID: engineID, model: model, endpoint: usesAPI ? baseURL : "",
            targetLanguage: targetLanguage, style: style, presetID: promptPresetID, customRules: customSystemPrompt,
            profileID: profileID, profileSnapshot: profileSnapshot, workflowID: workflowID,
            temperature: usesAPI ? temperature : 0, timeout: timeout, fallback: fallbackStrategy.rawValue,
            codexReasoningEffort: engineID == TranslationEngineID.codexChatGPT.rawValue ? codexReasoningEffort : "",
            grokReasoningEffort: "", geminiThinkingLevel: "", geminiThinkingBudget: nil,
            antigravityEffort: "", deepSeekThinkingMode: "", deepSeekReasoningEffort: "")
    }
    public var promptHash: String {
        var fields = [style, targetLanguage, customSystemPrompt, promptPresetID, profileSnapshot, workflowID]
        if engineID == TranslationEngineID.codexChatGPT.rawValue { fields += ["codex", codexReasoningEffort] }
        return SHA256.hash(data: try! JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AITranslationEndpoint: Equatable, Sendable {
    public let baseURL: String

    public init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var chatCompletionsURL: URL {
        // The public property is intentionally convenient for contract tests.
        // Production requests call validatedChatCompletionsURL() first.
        normalizedURL() ?? URL(string: "about:blank")!
    }

    public func validatedChatCompletionsURL() throws -> URL {
        guard let url = normalizedURL(), url.scheme == "http" || url.scheme == "https" else {
            throw AITranslationError.invalidEndpoint
        }
        return url
    }

    public var hostForLogging: String {
        guard let url = URL(string: baseURL), let host = url.host, !host.isEmpty else { return "invalid" }
        return host
    }

    public var modelsURL: URL {
        normalizedModelsURL() ?? URL(string: "about:blank")!
    }

    private func normalizedURL() -> URL? {
        var value = baseURL
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty, let raw = URL(string: value), let scheme = raw.scheme,
              (scheme == "http" || scheme == "https"), raw.host != nil,
              raw.query == nil, raw.fragment == nil else { return nil }

        let lower = value.lowercased()
        if lower.hasSuffix("/chat/completions") {
            return raw
        }
        if lower.hasSuffix("/v1") {
            return URL(string: value + "/chat/completions")
        }
        return URL(string: value + "/v1/chat/completions")
    }

    private func normalizedModelsURL() -> URL? {
        var value = baseURL
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty, let raw = URL(string: value), let scheme = raw.scheme,
              (scheme == "http" || scheme == "https"), raw.host != nil,
              raw.query == nil, raw.fragment == nil else { return nil }
        let lower = value.lowercased()
        if lower.hasSuffix("/chat/completions") {
            let prefix = String(value.dropLast("/chat/completions".count))
            return URL(string: prefix + "/models")
        }
        if lower.hasSuffix("/models") { return raw }
        if lower.hasSuffix("/v1") { return URL(string: value + "/models") }
        return URL(string: value + "/v1/models")
    }
}
