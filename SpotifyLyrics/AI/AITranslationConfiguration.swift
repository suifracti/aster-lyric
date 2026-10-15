import Foundation
import CryptoKit

public struct AITranslationConfiguration: Equatable, Sendable {
    public var baseURL: String
    public var model: String
    /// Non-secret Keychain reference. Existing compatible API settings retain "default".
    public var apiCredentialAccount: String
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
    /// Empty preserves the selected model default; never silently substitutes an effort.
    public var codexReasoningEffort: String
    public var grokReasoningEffort: String
    /// Gemini CLI's native level. Keep separate from its model-specific budget.
    public var geminiThinkingLevel: String
    public var geminiThinkingBudget: Int?
    /// Antigravity's native scale; per-model capability metadata remains authoritative.
    public var antigravityEffort: String
    /// model-default, enabled, or disabled; never infer another provider's scale.
    public var deepSeekThinkingMode: String
    public var deepSeekReasoningEffort: String

    public init(
        baseURL: String = "",
        model: String = "",
        apiCredentialAccount: String = "default",
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
        codexReasoningEffort: String = "",
        grokReasoningEffort: String = "",
        geminiThinkingLevel: String = "",
        geminiThinkingBudget: Int? = nil,
        antigravityEffort: String = "",
        deepSeekThinkingMode: String = "model-default",
        deepSeekReasoningEffort: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiCredentialAccount = apiCredentialAccount
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
        self.grokReasoningEffort = grokReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        self.geminiThinkingLevel = geminiThinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.geminiThinkingBudget = geminiThinkingBudget
        self.antigravityEffort = antigravityEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deepSeekThinkingMode = deepSeekThinkingMode
        self.deepSeekReasoningEffort = deepSeekReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        switch TranslationEngineID(rawValue: engineID) {
        case .appleSystem: return true
        case .codexChatGPT, .grokBuild, .geminiCLI, .antigravityCLI, .deepSeekAPI:
            return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openAICompatible, .none: break
        }
        if TranslationEngineID(rawValue: engineID) == .codexChatGPT { return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            grokReasoningEffort: engineID == TranslationEngineID.grokBuild.rawValue ? grokReasoningEffort : "",
            geminiThinkingLevel: engineID == TranslationEngineID.geminiCLI.rawValue ? geminiThinkingLevel : "",
            geminiThinkingBudget: engineID == TranslationEngineID.geminiCLI.rawValue ? geminiThinkingBudget : nil,
            antigravityEffort: engineID == TranslationEngineID.antigravityCLI.rawValue ? antigravityEffort : "",
            deepSeekThinkingMode: engineID == TranslationEngineID.deepSeekAPI.rawValue ? deepSeekThinkingMode : "",
            deepSeekReasoningEffort: engineID == TranslationEngineID.deepSeekAPI.rawValue ? deepSeekReasoningEffort : "")
    }
    public var promptHash: String {
        // JSON array boundaries cannot collide with separators inside user rules.
        var fields = [style, targetLanguage, customSystemPrompt, promptPresetID, profileSnapshot, workflowID]
        switch TranslationEngineID(rawValue: engineID) {
        case .codexChatGPT: fields += ["codex", codexReasoningEffort]
        case .grokBuild: fields += ["grok", grokReasoningEffort]
        case .geminiCLI: fields += ["gemini", geminiThinkingLevel, geminiThinkingBudget.map(String.init) ?? ""]
        case .antigravityCLI: fields += ["antigravity", antigravityEffort]
        case .deepSeekAPI: fields += ["deepseek", deepSeekThinkingMode, deepSeekReasoningEffort]
        case .openAICompatible, .appleSystem, .none: break
        }
        let payload = try! JSONEncoder().encode(fields)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

/// CLI authentication belongs to the existing CLI user, independently of the
/// app's optional private lyrics library. The launcher can name that home
/// without copying credentials or changing the app's data directory.
enum TranslationCLIHost {
    static var homeDirectory: String {
        let configured = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_TRANSLATION_CLI_HOME"] ?? ""
        return configured.hasPrefix("/") ? configured : NSHomeDirectory()
    }
    static var searchDirectories: [String] {
        [homeDirectory + "/.local/bin", homeDirectory + "/.npm-global/bin",
         homeDirectory + "/Library/Application Support/SpotifyLyrics/TranslationCLI/bin",
         "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }
    static var path: String { searchDirectories.joined(separator: ":") }
    static func childEnvironment(from inherited: [String: String]) -> [String: String] {
        var result = inherited
        result["HOME"] = homeDirectory
        result["CFFIXED_USER_HOME"] = nil
        result["SPOTIFYLYRICS_TRANSLATION_CLI_HOME"] = nil
        result["PATH"] = path
        return result
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

extension AITranslationConfiguration {
    public var providerReasoningSetting: String {
        switch TranslationEngineID(rawValue: engineID) {
        case .codexChatGPT: return "effort=" + (codexReasoningEffort.isEmpty ? "model-default" : codexReasoningEffort)
        case .grokBuild: return "reasoning_effort=" + (grokReasoningEffort.isEmpty ? "model-default" : grokReasoningEffort)
        case .geminiCLI:
            if !geminiThinkingLevel.isEmpty { return "thinkingLevel=" + geminiThinkingLevel }
            if let budget = geminiThinkingBudget { return "thinkingBudget=\(budget)" }
            return "model-default"
        case .antigravityCLI: return "effort=" + (antigravityEffort.isEmpty ? "model-default" : antigravityEffort)
        case .deepSeekAPI:
            let mode = deepSeekThinkingMode.isEmpty ? "model-default" : deepSeekThinkingMode
            let effort = deepSeekReasoningEffort.isEmpty ? "model-default" : deepSeekReasoningEffort
            return "thinking=\(mode);reasoning_effort=\(effort)"
        case .openAICompatible, .appleSystem, .none: return ""
        }
    }
}
