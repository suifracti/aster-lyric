import Foundation
import Combine
import CryptoKit

/// Non-secret settings and model-directory state. All mutation occurs on the UI thread.
/// No process, Keychain read or network request happens until explicit refresh.
public final class TranslationModelSettingsStore: ObservableObject {
    public typealias Loader = @Sendable (AITranslationConfiguration) async throws -> [TranslationModelDescriptor]
    @Published public private(set) var models: [TranslationModelDescriptor] = []
    @Published public private(set) var status: TranslationModelDirectoryStatus = .idle
    @Published public private(set) var cachedAt: Date?
    @Published public private(set) var selectionNotice = ""
    private let defaults: UserDefaults
    private let loader: Loader
    private var records: [String: Record]
    private var directories: [String: [TranslationModelDescriptor]]
    private var directoryDates: [String: Date]
    private var activeScope: String = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    static let recordsKey = "ai.providerModels.v1"
    static let directoriesKey = "ai.providerDirectories.v1"

    private struct Record: Codable {
        var model: String
        var baseURL: String
        var temperature: Double
        var apiCredentialAccount: String?
        var codex: String
        var grok: String
        var geminiLevel: String
        var geminiBudget: Int?
        var agy: String
        var deepSeekMode: String
        var deepSeekEffort: String
        init(_ c: AITranslationConfiguration) {
            model=c.model; baseURL=c.baseURL; temperature=c.temperature
            apiCredentialAccount=c.apiCredentialAccount
            codex=c.codexReasoningEffort; grok=c.grokReasoningEffort
            geminiLevel=c.geminiThinkingLevel; geminiBudget=c.geminiThinkingBudget
            agy=c.antigravityEffort; deepSeekMode=c.deepSeekThinkingMode; deepSeekEffort=c.deepSeekReasoningEffort
        }
        func applying(to input: AITranslationConfiguration) -> AITranslationConfiguration {
            var c=input; c.model=model
            switch TranslationEngineID(rawValue:c.engineID) {
            case .codexChatGPT: c.codexReasoningEffort=codex; c.baseURL=""
            case .grokBuild: c.grokReasoningEffort=grok; c.baseURL=""
            case .geminiCLI: c.geminiThinkingLevel=geminiLevel; c.geminiThinkingBudget=geminiBudget; c.baseURL=""
            case .antigravityCLI: c.antigravityEffort=agy; c.baseURL=""
            case .deepSeekAPI: c.baseURL=baseURL; c.temperature=temperature; c.deepSeekThinkingMode=deepSeekMode; c.deepSeekReasoningEffort=deepSeekEffort
            case .openAICompatible: c.baseURL=baseURL; c.temperature=temperature;c.apiCredentialAccount=apiCredentialAccount ?? "default"
            case .appleSystem, .none: c.baseURL=""
            }
            return c
        }
    }

    public init(defaults: UserDefaults, configuration: AITranslationConfiguration,
                loader: Loader? = nil) {
        self.defaults=defaults; self.loader=loader ?? { try await ProviderModelDirectoryLoader().models(configuration:$0) }
        records=defaults.data(forKey:Self.recordsKey).flatMap { try? JSONDecoder().decode([String:Record].self,from:$0) } ?? [:]
        directories=defaults.data(forKey:Self.directoriesKey).flatMap { try? JSONDecoder().decode([String:[TranslationModelDescriptor]].self,from:$0) } ?? [:]
        directoryDates=defaults.data(forKey:"ai.providerDirectoryDates.v1").flatMap { try? JSONDecoder().decode([String:Date].self,from:$0) } ?? [:]
        if records[configuration.engineID] == nil { records[configuration.engineID]=Record(configuration) }
        // Old directories carry no owner. Only migrate when the legacy owner is known.
        if defaults.data(forKey:Self.directoriesKey) == nil,
           configuration.engineID == TranslationEngineID.openAICompatible.rawValue,
           let data=defaults.data(forKey:"ai.modelDirectory.cache"),
           let legacy=try? JSONDecoder().decode([TranslationModelDescriptor].self,from:data) {
            directories[Self.scope(configuration)]=legacy
        }
        remember(restored(configuration))
    }

    public func restored(_ c: AITranslationConfiguration) -> AITranslationConfiguration {
        records[c.engineID]?.applying(to:c) ?? c
    }

    public func selectProvider(from old: AITranslationConfiguration, to engineID:String) -> AITranslationConfiguration {
        remember(old)
        var next=old; next.engineID=engineID
        let neutral=AITranslationConfiguration(engineID:engineID)
        next=(records[engineID] ?? Record(neutral)).applying(to:next)
        remember(next)
        return next
    }

    public func remember(_ c: AITranslationConfiguration) {
        records[c.engineID]=Record(c)
        if [TranslationEngineID.openAICompatible.rawValue,TranslationEngineID.deepSeekAPI.rawValue].contains(c.engineID) {
            records[Self.scope(c)]=Record(c)
            defaults.set(c.engineID,forKey:"ai.lastAPIBackend.v1")
        }
        if let data=try? JSONEncoder().encode(records) { defaults.set(data,forKey:Self.recordsKey) }
        let scope=Self.scope(c)
        guard activeScope != scope else { return }
        generation=UUID(); task?.cancel(); task=nil; activeScope=scope
        cachedAt=directoryDates[scope]; selectionNotice=""
        models=directories[scope] ?? []
        status=directories[scope].map { $0.isEmpty ? .empty : .loaded($0) } ?? .idle
    }

    public var preferredAPIBackend:String {
        defaults.string(forKey:"ai.lastAPIBackend.v1") ?? TranslationEngineID.openAICompatible.rawValue
    }

    public func savedAPIEndpoints() -> [String] {
        Array(Set(records.filter { $0.key.hasPrefix(TranslationEngineID.openAICompatible.rawValue+":") }
            .map { $0.value.baseURL }.filter { !$0.isEmpty })).sorted()
    }

    /// Explicit endpoint application, never a transient text-field keystroke.
    public func selectAPIEndpoint(from old:AITranslationConfiguration,to endpoint:String) -> AITranslationConfiguration {
        remember(old)
        var next=old;next.baseURL=endpoint.trimmingCharacters(in:.whitespacesAndNewlines)
        let scope=Self.scope(next)
        if let record=records[scope] { next=record.applying(to:next) }
        else {
            next.model="";next.temperature=0.2
            if next.engineID==TranslationEngineID.openAICompatible.rawValue {
                next.apiCredentialAccount="endpoint-"+SHA256.hash(data:Data(next.baseURL.utf8)).map{String(format:"%02x",$0)}.joined()
            } else { next.deepSeekThinkingMode="model-default";next.deepSeekReasoningEffort="" }
        }
        remember(next);return next
    }

    public func selectionKind(model:String) -> String {
        if model.isEmpty { return "尚未选择模型" }
        return models.contains { $0.id==model } ? "已发现模型" : "ID 未在当前目录"
    }

    public func acknowledgeReasoningSelection() { selectionNotice="" }

    public func refresh(_ c: AITranslationConfiguration) {
        remember(c)
        task?.cancel(); generation=UUID()
        let token=generation, scope=activeScope, loader=loader
        status = .loading
        task=Task { @MainActor [weak self] in
            do {
                let models=try await loader(c)
                guard let self, self.generation==token, self.activeScope==scope, !Task.isCancelled else { return }
                self.models=models; self.directories[scope]=models
                let date=Date(); self.directoryDates[scope]=date; self.cachedAt=date
                if let data=try? JSONEncoder().encode(self.directoryDates) { self.defaults.set(data,forKey:"ai.providerDirectoryDates.v1") }
                self.status=models.isEmpty ? .empty : .loaded(models)
                if let data=try? JSONEncoder().encode(self.directories) { self.defaults.set(data,forKey:Self.directoriesKey) }
            } catch {
                guard let self, self.generation==token, self.activeScope==scope, !Task.isCancelled else { return }
                switch error {
                case AITranslationError.unauthorized, AITranslationError.missingAPIKey: self.status = .unauthorized
                case AITranslationError.server(404), AITranslationError.server(405): self.status = .endpointUnsupported
                default: self.status = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    public func cancelRefresh() {
        generation=UUID(); task?.cancel(); task=nil
        status=directories[activeScope].map { $0.isEmpty ? .empty : .loaded($0) } ?? .idle
    }

    public func matchingModels(_ query:String) -> [TranslationModelDescriptor] {
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        return query.isEmpty ? models : models.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    /// Changing the model never silently carries an unsupported or unknown native override.
    public func selectingModel(_ id:String, in input:AITranslationConfiguration) -> AITranslationConfiguration {
        var c=input; c.model=id; selectionNotice=""
        guard id != input.model else { return c }
        let old=TranslationReasoningPolicy.value(input)
        let supported=models.first { $0.id==id }?.reasoningEfforts
        if (!old.isEmpty && !(supported?.contains(old) ?? false)) || (input.geminiThinkingBudget != nil && input.engineID == TranslationEngineID.geminiCLI.rawValue) {
            c=TranslationReasoningPolicy.setting("",in:c)
            selectionNotice="旧推理参数不适用于新模型或尚未核实，已清除；请重新选择。"
        }
        if c.engineID == TranslationEngineID.deepSeekAPI.rawValue, c.deepSeekThinkingMode != "model-default", supported == nil || supported?.isEmpty == true {
            c.deepSeekThinkingMode="model-default";c.deepSeekReasoningEffort=""
            selectionNotice="新模型的 thinking 能力尚未核实，旧参数已清除；请重新选择。"
        }
        return c
    }

    private static func scope(_ c:AITranslationConfiguration) -> String {
        guard [TranslationEngineID.openAICompatible.rawValue,TranslationEngineID.deepSeekAPI.rawValue].contains(c.engineID) else { return c.engineID }
        let endpoint=c.baseURL.trimmingCharacters(in:.whitespacesAndNewlines)
        return c.engineID+":"+SHA256.hash(data:Data(endpoint.utf8)).map { String(format:"%02x",$0) }.joined()
    }
}

/// No cross-provider scale conversion or model-name inference.
public enum TranslationReasoningPolicy {
    public static func value(_ c:AITranslationConfiguration) -> String {
        switch TranslationEngineID(rawValue:c.engineID) {
        case .codexChatGPT:return c.codexReasoningEffort
        case .grokBuild:return c.grokReasoningEffort
        case .geminiCLI:return c.geminiThinkingLevel
        case .antigravityCLI:return c.antigravityEffort
        case .deepSeekAPI:return c.deepSeekReasoningEffort
        default:return ""
        }
    }
    public static func setting(_ value:String,in input:AITranslationConfiguration) -> AITranslationConfiguration {
        var c=input
        switch TranslationEngineID(rawValue:c.engineID) {
        case .codexChatGPT:c.codexReasoningEffort=value
        case .grokBuild:c.grokReasoningEffort=value
        case .geminiCLI:c.geminiThinkingLevel=value;c.geminiThinkingBudget=nil
        case .antigravityCLI:c.antigravityEffort=value
        case .deepSeekAPI:c.deepSeekReasoningEffort=value
        default:break
        }
        return c
    }
}
