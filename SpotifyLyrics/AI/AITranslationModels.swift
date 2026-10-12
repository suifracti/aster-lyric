import Combine
import Foundation

public enum AITranslationSourceKind: String, CaseIterable, Codable, Sendable {
    case ai
    case providerEmbedded
    case manualImport
    case manualEdit
    case legacyImported
}

/// Stable identifiers for the translation engines.  These are presentation
/// and routing identifiers only; the translation session remains the single
/// owner of in-flight work and selected versions.
public enum TranslationEngineID: String, CaseIterable, Codable, Sendable {
    case openAICompatible = "translationEngine.openAICompatible.v1"
    case appleSystem = "translationEngine.appleSystem.v1"
    case codexChatGPT = "translationEngine.codexChatGPT.v1"
    case grokBuild = "translationEngine.grokBuild.v1"
    case geminiCLI = "translationEngine.geminiCLI.v1"
    case antigravityCLI = "translationEngine.antigravityCLI.v1"
    case deepSeekAPI = "translationEngine.deepSeekAPI.v1"
}

public enum TranslationEngineAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case requiresConfiguration
    case requiresSystemSupport
}

public enum TranslationFallbackStrategy: String, CaseIterable, Codable, Sendable {
    case none
    case ask
    case automaticSystem

    public var title: String {
        switch self {
        case .none: return "不自动切换"
        case .ask: return "失败后询问"
        case .automaticSystem: return "自动尝试系统翻译"
        }
    }
}

public enum TranslationWorkflowID: String, CaseIterable, Codable, Sendable {
    case classicV1 = "translationWorkflow.classicV1"
    case contextualV2 = "translationWorkflow.contextualV2"
}

public struct TranslationEngineMetadata: Equatable, Sendable {
    public let stableID: String
    public let displayName: String
    public let availability: TranslationEngineAvailability
    public let requiresAPIKey: Bool
    public let supportsModelDirectory: Bool

    public init(
        stableID: String,
        displayName: String,
        availability: TranslationEngineAvailability,
        requiresAPIKey: Bool,
        supportsModelDirectory: Bool
    ) {
        self.stableID = stableID
        self.displayName = displayName
        self.availability = availability
        self.requiresAPIKey = requiresAPIKey
        self.supportsModelDirectory = supportsModelDirectory
    }
}

public enum TranslationEngineCatalog {
    public static let all: [TranslationEngineMetadata] = [
        TranslationEngineMetadata(
            stableID: TranslationEngineID.openAICompatible.rawValue,
            displayName: "OpenAI-compatible API",
            availability: .requiresConfiguration,
            requiresAPIKey: true,
            supportsModelDirectory: true
        ),
        TranslationEngineMetadata(
            stableID: TranslationEngineID.appleSystem.rawValue,
            displayName: "Apple 系统翻译",
            availability: .requiresSystemSupport,
            requiresAPIKey: false,
            supportsModelDirectory: false
        ),
        TranslationEngineMetadata(
            stableID: TranslationEngineID.codexChatGPT.rawValue,
            displayName: "Codex / ChatGPT 登录",
            availability: .available,
            requiresAPIKey: false,
            supportsModelDirectory: false
        ),
        TranslationEngineMetadata(
            stableID: TranslationEngineID.grokBuild.rawValue,
            displayName: "Grok Build CLI",
            availability: .requiresConfiguration,
            requiresAPIKey: false,
            supportsModelDirectory: false
        ),
        TranslationEngineMetadata(
            stableID: TranslationEngineID.geminiCLI.rawValue,
            displayName: "Gemini CLI",
            availability: .unavailable,
            requiresAPIKey: false,
            supportsModelDirectory: false
        ),
        TranslationEngineMetadata(
            stableID: TranslationEngineID.antigravityCLI.rawValue,
            displayName: "Gemini（Antigravity CLI）",
            availability: .unavailable,
            requiresAPIKey: false,
            supportsModelDirectory: false
        ),
        TranslationEngineMetadata(
            stableID: TranslationEngineID.deepSeekAPI.rawValue,
            displayName: "DeepSeek API",
            availability: .requiresConfiguration,
            requiresAPIKey: true,
            supportsModelDirectory: false
        )
    ]

    /// Presentation groups never replace the persisted backend identity.
    public static var selectable: [TranslationEngineMetadata] {
        let entries: [(TranslationEngineID,String)] = [(.codexChatGPT,"GPT"),(.grokBuild,"Grok"),
            (.openAICompatible,"API"),(.appleSystem,"苹果翻译")]
        return entries.compactMap { id,name in
            guard let old=metadata(for:id.rawValue) else { return nil }
            return .init(stableID:old.stableID,displayName:name,availability:old.availability,
                requiresAPIKey:old.requiresAPIKey,supportsModelDirectory:old.supportsModelDirectory)
        }
    }

    public static func topLevelID(for backend:String) -> String {
        switch TranslationEngineID(rawValue:backend) {
        case .deepSeekAPI:return TranslationEngineID.openAICompatible.rawValue
        default:return backend
        }
    }

    public static func metadata(for stableID: String) -> TranslationEngineMetadata? {
        all.first { $0.stableID == stableID }
    }
}

public enum TranslationPromptPresetID: String, CaseIterable, Codable, Sendable {
    case naturalSong = "translationPrompt.naturalSong.v1"
    case literalFaithful = "translationPrompt.literalFaithful.v1"
    case poeticFlow = "translationPrompt.poeticFlow.v1"
    case contextAware = "translationPrompt.contextAware.v1"
    case custom = "translationPrompt.custom.v1"

    public var displayName: String {
        switch self {
        case .naturalSong: return "自然歌曲"
        case .literalFaithful: return "忠实直译"
        case .poeticFlow: return "诗意流畅"
        case .contextAware: return "上下文优先"
        case .custom: return "自定义"
        }
    }
}

public struct TranslationPromptPresetMetadata: Equatable, Sendable {
    public let id: TranslationPromptPresetID
    public let displayName: String
    public let detail: String

    public init(id: TranslationPromptPresetID, displayName: String, detail: String) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

/// A style example is recorded only from a user-confirmed manual translation.
/// It is local preference data, not a provider response and not a credential.
public struct TranslationStyleExample: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let original: String
    public let translation: String
    public let sourceKind: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        original: String,
        translation: String,
        sourceKind: String = AITranslationSourceKind.manualEdit.rawValue,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.original = original
        self.translation = translation
        self.sourceKind = sourceKind
        self.createdAt = createdAt
    }
}

public enum TranslationPromptPresetCatalog {
    public static let all: [TranslationPromptPresetMetadata] = [
        .init(id: .naturalSong, displayName: "自然歌曲", detail: "保留歌曲语气与意象，优先自然中文"),
        .init(id: .literalFaithful, displayName: "忠实直译", detail: "尽量贴近原句结构，不补写未提供的信息"),
        .init(id: .poeticFlow, displayName: "诗意流畅", detail: "在不改变含义的前提下保持诗性与节奏"),
        .init(id: .contextAware, displayName: "上下文优先", detail: "结合整首歌词统一主语、语气和重复副歌"),
        .init(id: .custom, displayName: "自定义", detail: "使用自定义系统提示词")
    ]

    public static var defaultPreset: TranslationPromptPresetMetadata {
        all[0]
    }
}

/// A personal translation style is a UserDefaults object, not a translation
/// version and not a second secret store. Its snapshot is copied into a
/// translation version only when an explicit request is saved.
public struct TranslationStyleProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var basePresetID: TranslationPromptPresetID
    public var customInstructions: String
    public var targetLanguage: String
    public var temperatureOverride: Double?
    public var preserveProperNouns: Bool
    public var preserveRepetition: Bool
    public var keepSongTone: Bool
    public var examples: [TranslationStyleExample]
    public var styleSummary: String
    public var summaryVersion: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        basePresetID: TranslationPromptPresetID = .naturalSong,
        customInstructions: String = "",
        targetLanguage: String = "zh-Hans",
        temperatureOverride: Double? = nil,
        preserveProperNouns: Bool = true,
        preserveRepetition: Bool = true,
        keepSongTone: Bool = true,
        examples: [TranslationStyleExample] = [],
        styleSummary: String = "",
        summaryVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.basePresetID = basePresetID
        self.customInstructions = customInstructions
        self.targetLanguage = targetLanguage
        self.temperatureOverride = temperatureOverride.map { min(max($0, 0), 2) }
        self.preserveProperNouns = preserveProperNouns
        self.preserveRepetition = preserveRepetition
        self.keepSongTone = keepSongTone
        self.examples = Array(examples.suffix(24))
        self.styleSummary = styleSummary
        self.summaryVersion = max(1, summaryVersion)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }

    public func with(name: String) -> TranslationStyleProfile {
        var copy = self
        copy.name = name
        copy.updatedAt = Date()
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, basePresetID, customInstructions, targetLanguage
        case temperatureOverride, preserveProperNouns, preserveRepetition, keepSongTone
        case examples, styleSummary, summaryVersion, createdAt, updatedAt, isArchived
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try values.decode(String.self, forKey: .name)
        self.basePresetID = try values.decodeIfPresent(TranslationPromptPresetID.self, forKey: .basePresetID) ?? .naturalSong
        self.customInstructions = try values.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
        self.targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh-Hans"
        self.temperatureOverride = try values.decodeIfPresent(Double.self, forKey: .temperatureOverride)
        self.preserveProperNouns = try values.decodeIfPresent(Bool.self, forKey: .preserveProperNouns) ?? true
        self.preserveRepetition = try values.decodeIfPresent(Bool.self, forKey: .preserveRepetition) ?? true
        self.keepSongTone = try values.decodeIfPresent(Bool.self, forKey: .keepSongTone) ?? true
        self.examples = Array((try values.decodeIfPresent([TranslationStyleExample].self, forKey: .examples) ?? []).suffix(24))
        self.styleSummary = try values.decodeIfPresent(String.self, forKey: .styleSummary) ?? ""
        self.summaryVersion = max(1, try values.decodeIfPresent(Int.self, forKey: .summaryVersion) ?? 1)
        self.createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.createdAt
        self.isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    /// Immutable metadata captured with a translation version. It contains
    /// style choices only; it never contains credentials or lyric contents.
    public var snapshotString: String {
        guard let data = try? JSONEncoder().encode(self) else { return name }
        return String(data: data, encoding: .utf8) ?? name
    }
}

public final class TranslationProfileStore: ObservableObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "ai.translationProfiles.v1"
    @Published public private(set) var revision: Int = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func list(includeArchived: Bool = false) -> [TranslationStyleProfile] {
        guard let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode([TranslationStyleProfile].self, from: data) else { return [] }
        return profiles
            .filter { includeArchived || !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func create(
        name: String,
        basePresetID: TranslationPromptPresetID = .naturalSong,
        customInstructions: String = "",
        targetLanguage: String = "zh-Hans",
        temperatureOverride: Double? = nil,
        preserveProperNouns: Bool = true,
        preserveRepetition: Bool = true,
        keepSongTone: Bool = true
    ) -> TranslationStyleProfile {
        let profile = TranslationStyleProfile(
            name: name,
            basePresetID: basePresetID,
            customInstructions: customInstructions,
            targetLanguage: targetLanguage,
            temperatureOverride: temperatureOverride,
            preserveProperNouns: preserveProperNouns,
            preserveRepetition: preserveRepetition,
            keepSongTone: keepSongTone
        )
        save(profile)
        return profile
    }

    public func update(_ profile: TranslationStyleProfile) {
        save(profile)
    }

    @discardableResult
    public func copy(_ profile: TranslationStyleProfile, name: String? = nil) -> TranslationStyleProfile {
        let duplicate = TranslationStyleProfile(
            name: name ?? "(profile.name) 副本",
            basePresetID: profile.basePresetID,
            customInstructions: profile.customInstructions,
            targetLanguage: profile.targetLanguage,
            temperatureOverride: profile.temperatureOverride,
            preserveProperNouns: profile.preserveProperNouns,
            preserveRepetition: profile.preserveRepetition,
            keepSongTone: profile.keepSongTone,
            examples: profile.examples,
            styleSummary: profile.styleSummary,
            summaryVersion: profile.summaryVersion
        )
        save(duplicate)
        return duplicate
    }

    public func archive(id: UUID, archived: Bool = true) {
        guard let existing = list(includeArchived: true).first(where: { $0.id == id }) else { return }
        var updated = existing
        updated.isArchived = archived
        updated.updatedAt = Date()
        save(updated)
    }

    public func delete(id: UUID) {
        let remaining = list(includeArchived: true).filter { $0.id != id }
        if let data = try? JSONEncoder().encode(remaining) {
            defaults.set(data, forKey: key)
            revision &+= 1
        }
    }

    /// Adds examples from a completed manual save and rebuilds a deterministic
    /// summary locally. No network or model is involved in this operation.
    public func recordConfirmedExamples(
        profileID: UUID,
        examples incoming: [TranslationStyleExample]
    ) {
        guard let existing = list(includeArchived: true).first(where: { $0.id == profileID }) else { return }
        var updated = existing
        let valid = incoming.filter {
            !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.sourceKind == AITranslationSourceKind.manualEdit.rawValue
        }
        var combined = existing.examples
        for example in valid where !combined.contains(where: {
            $0.original == example.original && $0.translation == example.translation
        }) {
            combined.append(example)
        }
        updated.examples = Array(combined.suffix(24))
        updated.styleSummary = Self.summary(for: updated.examples)
        updated.summaryVersion = max(1, existing.summaryVersion + 1)
        updated.updatedAt = Date()
        save(updated)
    }

    public func regenerateSummary(profileID: UUID) {
        guard let existing = list(includeArchived: true).first(where: { $0.id == profileID }) else { return }
        var updated = existing
        updated.styleSummary = Self.summary(for: updated.examples)
        updated.summaryVersion = max(1, existing.summaryVersion + 1)
        updated.updatedAt = Date()
        save(updated)
    }

    private static func summary(for examples: [TranslationStyleExample]) -> String {
        guard !examples.isEmpty else { return "尚未记录已确认的人工翻译样例。" }
        let repeatedPairs = Dictionary(grouping: examples) { $0.translation.count }
            .max { $0.value.count < $1.value.count }?.key
        if let repeatedPairs {
            return "已确认 \(examples.count) 条人工样例；常见译文长度约 \(repeatedPairs) 字，保持原文重复与语气。"
        }
        return "已确认 \(examples.count) 条人工样例；保持原文重复、专名和歌曲语气。"
    }

    private func save(_ profile: TranslationStyleProfile) {
        var all = list(includeArchived: true).filter { $0.id != profile.id }
        all.append(profile)
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
            revision &+= 1
        }
    }
}

public struct TranslationModelDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let source: String
    public let updatedAt: Date?
    /// nil means unreported, [] means explicitly no adjustable effort. Native values only.
    public let reasoningEfforts: [String]?

    public init(id: String, displayName: String? = nil, source: String = "directory", updatedAt: Date? = nil, reasoningEfforts: [String]? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.source = source
        self.updatedAt = updatedAt
        self.reasoningEfforts = reasoningEfforts
    }
}

public enum TranslationModelDirectoryStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded([TranslationModelDescriptor])
    case empty
    case unauthorized
    case endpointUnsupported
    case unavailable(String)
    case manualFallback

    public var userFacingTitle: String {
        switch self {
        case .idle: return "尚未读取"
        case .loading: return "正在读取模型"
        case .loaded(let models): return "已缓存 \(models.count) 个模型"
        case .empty: return "服务未返回模型"
        case .unauthorized: return "未授权"
        case .endpointUnsupported: return "服务不提供模型目录"
        case .unavailable: return "目录读取失败"
        case .manualFallback: return "使用手动模型"
        }
    }
}

public enum AITranslationVersionStatus: String, Codable, Sendable {
    case complete
    case incomplete
}

public struct AITranslationLine: Codable, Equatable, Sendable {
    public let index: Int
    public let translation: String
    public let lineID: UUID?

    public init(index: Int, translation: String, lineID: UUID? = nil) {
        self.index = index
        self.translation = translation
        self.lineID = lineID
    }

    private enum CodingKeys: String, CodingKey { case index, translation, lineID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        translation = try values.decode(String.self, forKey: .translation)
        lineID = try values.decodeIfPresent(UUID.self, forKey: .lineID)
    }
}

public struct AITranslationContext: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let style: String
    public let lines: [AITranslationSourceLine]
    public let styleSummary: String
    public let styleExamples: [TranslationStyleExample]
    public let selectedLineIDs: Set<UUID>?

    public init(
        title: String,
        artist: String,
        album: String,
        sourceLanguage: String,
        targetLanguage: String,
        style: String,
        lines: [AITranslationSourceLine],
        styleSummary: String = "",
        styleExamples: [TranslationStyleExample] = [],
        selectedLineIDs: Set<UUID>? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.style = style
        self.lines = lines
        self.styleSummary = styleSummary
        self.styleExamples = Array(styleExamples.suffix(12))
        self.selectedLineIDs = selectedLineIDs
    }
}

public struct AITranslationSourceLine: Equatable, Sendable {
    public let index: Int
    public let lineID: UUID
    public let original: String
    public let kana: String?
    public let romaji: String?
    public let timestamp: TimeInterval?

    public init(
        index: Int,
        original: String,
        kana: String? = nil,
        romaji: String? = nil,
        lineID: UUID = UUID(),
        timestamp: TimeInterval? = nil
    ) {
        self.index = index
        self.lineID = lineID
        self.original = original
        self.kana = kana
        self.romaji = romaji
        self.timestamp = timestamp
    }
}

public struct AITranslationTokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int

    public init(inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int,
                reasoningOutputTokens: Int = 0, totalTokens: Int) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct AITranslationDraft: Equatable, Sendable {
    public let lines: [AITranslationLine]
    public let targetLanguage: String
    public let model: String
    public let baseURLHost: String
    public let promptHash: String
    public let sourceContentHash: String
    public let sourceKind: AITranslationSourceKind
    public let isMachineGenerated: Bool
    public let isManuallyEdited: Bool
    public let confidence: Double
    public let engineID: String
    public let promptPresetID: String
    public let profileID: UUID?
    public let profileSnapshot: String
    public let temperature: Double
    public let workflowID: String
    public let fallbackStrategy: TranslationFallbackStrategy
    public let isDraft: Bool
    public let isArchived: Bool
    public let tokenUsage: AITranslationTokenUsage?
    public let providerReasoningSetting: String

    public init(
        lines: [AITranslationLine],
        targetLanguage: String,
        model: String,
        baseURLHost: String,
        promptHash: String,
        sourceContentHash: String,
        sourceKind: AITranslationSourceKind = .ai,
        isMachineGenerated: Bool = true,
        isManuallyEdited: Bool = false,
        confidence: Double = 1,
        engineID: String = TranslationEngineID.openAICompatible.rawValue,
        promptPresetID: String = TranslationPromptPresetID.naturalSong.rawValue,
        profileID: UUID? = nil,
        profileSnapshot: String = "",
        temperature: Double = 0.2,
        workflowID: String = TranslationWorkflowID.contextualV2.rawValue,
        fallbackStrategy: TranslationFallbackStrategy = .none,
        isDraft: Bool = false,
        isArchived: Bool = false,
        tokenUsage: AITranslationTokenUsage? = nil,
        providerReasoningSetting: String = ""
    ) {
        self.lines = lines
        self.targetLanguage = targetLanguage
        self.model = model
        self.baseURLHost = baseURLHost
        self.promptHash = promptHash
        self.sourceContentHash = sourceContentHash
        self.sourceKind = sourceKind
        self.isMachineGenerated = isMachineGenerated
        self.isManuallyEdited = isManuallyEdited
        self.confidence = confidence
        self.engineID = engineID
        self.promptPresetID = promptPresetID
        self.profileID = profileID
        self.profileSnapshot = profileSnapshot
        self.temperature = temperature
        self.workflowID = workflowID
        self.fallbackStrategy = fallbackStrategy
        self.isDraft = isDraft
        self.isArchived = isArchived
        self.tokenUsage = tokenUsage
        self.providerReasoningSetting = providerReasoningSetting
    }

    public func with(isDraft: Bool? = nil, isArchived: Bool? = nil) -> AITranslationDraft {
        AITranslationDraft(
            lines: lines,
            targetLanguage: targetLanguage,
            model: model,
            baseURLHost: baseURLHost,
            promptHash: promptHash,
            sourceContentHash: sourceContentHash,
            sourceKind: sourceKind,
            isMachineGenerated: isMachineGenerated,
            isManuallyEdited: isManuallyEdited,
            confidence: confidence,
            engineID: engineID,
            promptPresetID: promptPresetID,
            profileID: profileID,
            profileSnapshot: profileSnapshot,
            temperature: temperature,
            workflowID: workflowID,
            fallbackStrategy: fallbackStrategy,
            isDraft: isDraft ?? self.isDraft,
            isArchived: isArchived ?? self.isArchived,
            tokenUsage: tokenUsage,
            providerReasoningSetting: providerReasoningSetting
        )
    }
}

public enum AITranslationError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case invalidEndpoint
    case missingAPIKey
    case unauthorized
    case rateLimited
    case timedOut
    case network(String)
    case server(Int)
    case cancelled
    case invalidResponse(String)
    case persistence(String)
    case engineUnavailable(String)
    case codexNotInstalled
    case codexRequiresLogin
    case codexUnavailable(String)
    case codexResponseInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "AI 翻译尚未配置 Base URL 或模型"
        case .invalidEndpoint: return "AI Base URL 无效"
        case .missingAPIKey: return "AI API Key 未填写"
        case .unauthorized: return "AI API 未授权（401）"
        case .rateLimited: return "AI API 请求过于频繁（429）"
        case .timedOut: return "AI 翻译请求超时"
        case .network: return "AI 翻译网络不可用"
        case .server(let status): return "AI 服务错误（HTTP \(status)）"
        case .cancelled: return "AI 翻译已取消"
        case .invalidResponse: return "AI 翻译响应校验失败"
        case .persistence: return "AI 翻译保存失败"
        case .engineUnavailable(let message): return message
        case .codexNotInstalled: return "未找到 ChatGPT/Codex 本地运行时"
        case .codexRequiresLogin: return "请先在浏览器完成 ChatGPT/Codex 登录"
        case .codexUnavailable(let message): return "Codex 本地服务不可用：\(message)"
        case .codexResponseInvalid: return "Codex 返回的歌词翻译无法按稳定行 ID 校验"
        }
    }
}

public struct AITranslationProgress: Equatable, Sendable {
    public let requestID: String
    public let inputLineCount: Int
    public let outputLineCount: Int
    public let elapsed: TimeInterval

    public init(requestID: String, inputLineCount: Int, outputLineCount: Int = 0, elapsed: TimeInterval = 0) {
        self.requestID = requestID
        self.inputLineCount = inputLineCount
        self.outputLineCount = outputLineCount
        self.elapsed = elapsed
    }
}
