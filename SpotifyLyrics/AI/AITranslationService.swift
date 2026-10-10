import Foundation
import AppKit
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Translation)
import Translation
#endif

public protocol AITranslationService: Sendable {
    func translate(
        context: AITranslationContext,
        sourceContentHash: String,
        configuration: AITranslationConfiguration
    ) async throws -> AITranslationDraft

    func testConnection(configuration: AITranslationConfiguration) async throws
}

public protocol TranslationEngine: AITranslationService {
    var metadata: TranslationEngineMetadata { get }
}

private struct LegacyTranslationEngineAdapter: TranslationEngine {
    let service: any AITranslationService

    var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(
            stableID: TranslationEngineID.openAICompatible.rawValue,
            displayName: "兼容旧翻译服务",
            availability: .available,
            requiresAPIKey: true,
            supportsModelDirectory: false
        )
    }

    func translate(
        context: AITranslationContext,
        sourceContentHash: String,
        configuration: AITranslationConfiguration
    ) async throws -> AITranslationDraft {
        try await service.translate(context: context, sourceContentHash: sourceContentHash, configuration: configuration)
    }

    func testConnection(configuration: AITranslationConfiguration) async throws {
        try await service.testConnection(configuration: configuration)
    }
}

public struct OpenAICompatibleTranslationService: TranslationEngine, Sendable {
    private let client: OpenAICompatibleClient
    private let keyStore: any AITranslationAPIKeyStore
    private let promptBuilder: AITranslationPromptBuilder

    public init(
        client: OpenAICompatibleClient = OpenAICompatibleClient(),
        keyStore: any AITranslationAPIKeyStore = KeychainAITranslationAPIKeyStore(),
        promptBuilder: AITranslationPromptBuilder = AITranslationPromptBuilder()
    ) {
        self.client = client
        self.keyStore = keyStore
        self.promptBuilder = promptBuilder
    }

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(
            stableID: TranslationEngineID.openAICompatible.rawValue,
            displayName: "OpenAI-compatible API",
            availability: .requiresConfiguration,
            requiresAPIKey: true,
            supportsModelDirectory: true
        )
    }

    public func translate(
        context: AITranslationContext,
        sourceContentHash: String,
        configuration: AITranslationConfiguration
    ) async throws -> AITranslationDraft {
        guard configuration.isConfigured else { throw AITranslationError.notConfigured }
        guard let key = keyStore.read(), !key.isEmpty else { throw AITranslationError.missingAPIKey }
        let prompt = try promptBuilder.build(context: context, configuration: configuration)
        let result = try await client.complete(
            prompt: prompt,
            configuration: configuration,
            apiKey: key,
            inputLineCount: context.lines.count
        )
        do {
            let parsed = try AITranslationResponseParser.parse(
                result.content,
                expectedLineCount: context.lines.count
            )
            let validated = try AITranslationResponseParser.validate(
                parsed,
                against: context.lines.map(\.original)
            )
            return AITranslationDraft(
                lines: validated,
                targetLanguage: configuration.targetLanguage,
                model: configuration.model,
                baseURLHost: AITranslationEndpoint(baseURL: configuration.baseURL).hostForLogging,
                promptHash: prompt.promptHash,
                sourceContentHash: sourceContentHash,
                engineID: TranslationEngineID.openAICompatible.rawValue,
                promptPresetID: configuration.promptPresetID,
                profileID: configuration.profileID,
                profileSnapshot: configuration.profileSnapshot,
                temperature: configuration.temperature,
                workflowID: configuration.workflowID,
                fallbackStrategy: configuration.fallbackStrategy,
                isDraft: true
            )
        } catch let error as AITranslationResponseError {
            throw AITranslationError.invalidResponse(String(describing: error))
        }
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        guard configuration.isConfigured else { throw AITranslationError.notConfigured }
        guard let key = keyStore.read(), !key.isEmpty else { throw AITranslationError.missingAPIKey }
        _ = try await client.testConnection(configuration: configuration, apiKey: key)
    }
}

/// Apple System Translation is an independent engine. It is never silently
/// selected when the compatible API fails; the session applies the user's
/// explicit fallback strategy before calling this type.
public struct AppleSystemTranslationEngine: TranslationEngine, Sendable {
    public init() {}

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(
            stableID: TranslationEngineID.appleSystem.rawValue,
            displayName: "Apple 系统翻译",
            availability: Self.isRuntimeAvailable ? .available : .requiresSystemSupport,
            requiresAPIKey: false,
            supportsModelDirectory: false
        )
    }

    private static var isRuntimeAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public func translate(
        context: AITranslationContext,
        sourceContentHash: String,
        configuration: AITranslationConfiguration
    ) async throws -> AITranslationDraft {
#if canImport(Translation)
        guard #available(macOS 26.0, *) else {
            throw AITranslationError.engineUnavailable("当前 macOS 不支持 Apple 系统翻译")
        }
        let source = Locale.Language(identifier: context.sourceLanguage)
        let target = Locale.Language(identifier: configuration.targetLanguage)
        let availability = await LanguageAvailability().status(from: source, to: target)
        guard availability != .unsupported else {
            throw AITranslationError.engineUnavailable("Apple 系统翻译不支持当前语言组合")
        }
        let nonBlank = context.lines.filter { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let session = TranslationSession(installedSource: source, target: target)
        // `supported` does not imply that the language assets are installed.
        // Preparing here lets the framework request/download what it needs
        // before the batch call instead of failing as if translation did
        // nothing. The UI exposes this preparation through the shared session.
        try await session.prepareTranslation()
        let responses = try await session.translations(from: nonBlank.map { TranslationSession.Request(sourceText: $0.original) })
        guard responses.count == nonBlank.count else {
            throw AITranslationError.invalidResponse("Apple 系统翻译返回行数不匹配")
        }
        var responseIndex = 0
        let lines = context.lines.map { line -> AITranslationLine in
            guard !line.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return AITranslationLine(index: line.index, translation: "")
            }
            defer { responseIndex += 1 }
            return AITranslationLine(index: line.index, translation: responses[responseIndex].targetText)
        }
        let validated = try AITranslationResponseValidator.validate(lines, against: context.lines.map(\.original))
        return AITranslationDraft(
            lines: validated,
            targetLanguage: configuration.targetLanguage,
            model: "Apple System Translation",
            baseURLHost: "",
            promptHash: "apple-system-translation-v1",
            sourceContentHash: sourceContentHash,
            engineID: TranslationEngineID.appleSystem.rawValue,
            promptPresetID: configuration.promptPresetID,
            profileID: configuration.profileID,
            profileSnapshot: configuration.profileSnapshot,
            temperature: configuration.temperature,
            workflowID: configuration.workflowID,
            fallbackStrategy: configuration.fallbackStrategy,
            isDraft: true
        )
#else
        _ = context; _ = sourceContentHash; _ = configuration
        throw AITranslationError.engineUnavailable("当前构建不包含 Apple 系统翻译")
#endif
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        _ = try await translate(
            context: AITranslationContext(
                title: "", artist: "", album: "", sourceLanguage: "ja",
                targetLanguage: configuration.targetLanguage, style: "",
                lines: [AITranslationSourceLine(index: 0, original: "テスト")]
            ),
            sourceContentHash: "connection-test",
            configuration: configuration
        )
    }
}

/// A thin, managed app-server client. Authentication remains inside Codex:
/// this process only sends protocol messages and opens the returned browser
/// URL. It never reads auth.json, copies OAuth tokens, or stores credentials.
public struct CodexAppServerTranslationService: TranslationEngine, Sendable {
    private let executableCandidates: [String]

    public init(executableCandidates: [String] = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex"
    ]) {
        self.executableCandidates = executableCandidates
    }

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(
            stableID: TranslationEngineID.codexChatGPT.rawValue,
            displayName: "Codex / ChatGPT 登录",
            availability: .available,
            requiresAPIKey: false,
            supportsModelDirectory: true
        )
    }

    /// Metadata-only probe: it asks the existing app-server for models without starting a thread or turn.
    public func listModels(timeout: TimeInterval = 20) async throws -> [TranslationModelDescriptor] {
        guard timeout.isFinite, timeout > 0 else {
            throw AITranslationError.invalidResponse("Codex 模型目录超时设置无效")
        }
        let executable = try resolveExecutable()
        return try await Task.detached(priority: .utility) {
            let client = try CodexAppServerClient(executable: executable, requestTimeout: timeout)
            defer { client.stop() }
            try client.initialize()
            try client.requireExistingAuthentication()
            return try client.availableModels()
        }.value
    }

    public func translate(
        context: AITranslationContext,
        sourceContentHash: String,
        configuration: AITranslationConfiguration
    ) async throws -> AITranslationDraft {
        let executable = try resolveExecutable()
        let lines = context.lines
        let prompt = makePrompt(context: context, configuration: configuration)
        let responseText = try await Task.detached(priority: .userInitiated) {
            let client = try CodexAppServerClient(executable: executable)
            defer { client.stop() }
            try client.initialize()
            try client.ensureAuthenticated()
            return try client.translate(
                prompt: prompt,
                model: configuration.model,
                outputSchema: Self.outputSchema()
            )
        }.value

        let responseData = try Self.jsonData(from: responseText)
        let stableLinesData = try Self.unwrapStableLines(from: responseData)
        do {
            let validated = try AITranslationResponseParser.parseStable(stableLinesData, expectedLines: lines)
            return AITranslationDraft(
                lines: validated,
                targetLanguage: configuration.targetLanguage,
                model: configuration.model.isEmpty ? "Codex ChatGPT" : configuration.model,
                baseURLHost: "codex-app-server",
                promptHash: Self.hash(prompt),
                sourceContentHash: sourceContentHash,
                engineID: TranslationEngineID.codexChatGPT.rawValue,
                promptPresetID: configuration.promptPresetID,
                profileID: configuration.profileID,
                profileSnapshot: configuration.profileSnapshot,
                temperature: configuration.temperature,
                workflowID: configuration.workflowID,
                fallbackStrategy: configuration.fallbackStrategy,
                isDraft: true
            )
        } catch let error as AITranslationResponseError {
            throw AITranslationError.codexResponseInvalid(String(describing: error))
        }
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        let executable = try resolveExecutable()
        _ = try await Task.detached(priority: .utility) {
            let client = try CodexAppServerClient(executable: executable)
            defer { client.stop() }
            try client.initialize()
            try client.ensureAuthenticated()
        }.value
    }

    func resolveExecutable() throws -> String {
        if let path = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw AITranslationError.codexNotInstalled
    }

    private func makePrompt(context: AITranslationContext, configuration: AITranslationConfiguration) -> String {
        let payload: [String: Any] = [
            "title": context.title,
            "artist": context.artist,
            "album": context.album,
            "sourceLanguage": context.sourceLanguage,
            "targetLanguage": context.targetLanguage,
            "style": context.style,
            "styleSummary": context.styleSummary,
            "styleExamples": context.styleExamples.map { ["original": $0.original, "translation": $0.translation] },
            "lines": context.lines.map { line in
                var value: [String: Any] = [
                    "lineID": line.lineID.uuidString,
                    "index": line.index,
                    "text": line.original
                ]
                if let timestamp = line.timestamp { value["timestamp"] = timestamp }
                if let kana = line.kana, !kana.isEmpty { value["kana"] = kana }
                if let romaji = line.romaji, !romaji.isEmpty { value["romaji"] = romaji }
                return value
            }
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        Translate the complete song represented by the JSON below into \(configuration.targetLanguage). Use the song context and confirmed manual style examples, but never invent or remove source lines. Return ONLY a JSON object with exactly one key, lines. The value of lines must be an array whose items contain exactly these two keys: lineID (the supplied UUID string) and translation (a single-line string). Return every supplied line exactly once, including blank lines. Blank source lines must have an empty translation. Do not return timestamps, indexes, source text, explanations, markdown fences, or metadata. Timestamps are read-only context and must not be edited.
        JSON:
        \(json)
        """
    }

    private static func outputSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["lines"],
            "properties": [
                "lines": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["lineID", "translation"],
                        "properties": [
                            "lineID": ["type": "string"],
                            "translation": ["type": "string"]
                        ]
                    ]
                ]
            ]
        ]
    }

    private static func jsonData(from text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            body = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            body = trimmed
        }
        guard let data = body.data(using: .utf8) else {
            throw AITranslationError.codexResponseInvalid("响应编码无效")
        }
        return data
    }

    private static func unwrapStableLines(from data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.count == 1,
              object["lines"] is [[String: Any]],
              let lines = object["lines"] else {
            throw AITranslationError.codexResponseInvalid("响应必须是只包含 lines 的 JSON 对象")
        }
        return try JSONSerialization.data(withJSONObject: lines, options: [.sortedKeys])
    }

    private static func hash(_ value: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return String(value.hashValue)
        #endif
    }
}

private final class CodexAppServerClient: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var nextID = 1
    private var timeoutWorkItem: DispatchWorkItem?

    init(executable: String, requestTimeout: TimeInterval? = nil) throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        self.process = process
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdoutPipe.fileHandleForReading
        try process.run()
        if let requestTimeout {
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.process.terminate()
            }
            self.timeoutWorkItem = timeoutWork
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout, execute: timeoutWork)
        }
    }

    func stop() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if process.isRunning { process.terminate() }
        try? input.close()
        try? output.close()
    }

    func initialize() throws {
        _ = try request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "spotifylyrics",
                    "title": "SpotifyLyrics",
                    "version": "0.1.0"
                ]
            ]
        )
        try sendNotification(method: "initialized", params: [:])
    }

    func ensureAuthenticated() throws {
        let accountResult = try request(method: "account/read", params: ["refreshToken": false])
        if let account = accountResult["account"] as? [String: Any], account["type"] as? String == "chatgpt" {
            return
        }
        let login = try request(method: "account/login/start", params: ["type": "chatgpt", "appBrand": "chatgpt"])
        guard let authURL = login["authUrl"] as? String,
              let loginID = login["loginId"] as? String,
              let url = URL(string: authURL) else {
            throw AITranslationError.codexUnavailable("登录地址无效")
        }
        _ = NSWorkspace.shared.open(url)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let message = try readMessage()
            guard message["method"] as? String == "account/login/completed" else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            guard params["loginId"] as? String == loginID || params["loginId"] == nil else { continue }
            if params["success"] as? Bool == true { return }
            throw AITranslationError.codexRequiresLogin
        }
        throw AITranslationError.codexRequiresLogin
    }

    func requireExistingAuthentication() throws {
        let result = try request(method: "account/read", params: ["refreshToken": false])
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            throw AITranslationError.codexRequiresLogin
        }
    }

    func availableModels() throws -> [TranslationModelDescriptor] {
        var models: [TranslationModelDescriptor] = []
        var seen = Set<String>()
        var cursors = Set<String>()
        var cursor: String?
        for _ in 0..<10 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try request(method: "model/list", params: params)
            guard let rows = result["data"] as? [[String: Any]] else {
                throw AITranslationError.invalidResponse("Codex 模型目录缺少 data；无法判定可用模型")
            }
            for row in rows {
                guard let id = (row["model"] as? String ?? row["id"] as? String), !id.isEmpty else {
                    throw AITranslationError.invalidResponse("Codex 模型目录缺少模型 ID")
                }
                if seen.insert(id).inserted {
                    let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]])?
                        .compactMap { $0["reasoningEffort"] as? String }
                    models.append(.init(
                        id: id,
                        displayName: row["displayName"] as? String,
                        source: "codex-model-list",
                        reasoningEfforts: efforts
                    ))
                }
            }
            guard let next = result["nextCursor"] as? String, !next.isEmpty else { return models }
            guard cursors.insert(next).inserted else {
                throw AITranslationError.invalidResponse("Codex 模型目录分页重复")
            }
            cursor = next
        }
        throw AITranslationError.invalidResponse("Codex 模型目录分页超过上限")
    }

    func translate(prompt: String, model: String, outputSchema: [String: Any]) throws -> String {
        var threadParams: [String: Any] = [
            "cwd": FileManager.default.currentDirectoryPath,
            "ephemeral": true,
            "serviceName": "spotifylyrics"
        ]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { threadParams["model"] = model }
        let thread = try request(method: "thread/start", params: threadParams)
        guard let threadID = thread["thread"] as? [String: Any] ?? thread["thread"] as? [String: Any],
              let id = threadID["id"] as? String else {
            throw AITranslationError.codexUnavailable("未返回临时会话 ID")
        }
        var turnParams: [String: Any] = [
            "threadId": id,
            "input": [["type": "text", "text": prompt]],
            "outputSchema": outputSchema,
            "approvalPolicy": "never",
            "cwd": FileManager.default.currentDirectoryPath
        ]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { turnParams["model"] = model }
        let turn = try request(method: "turn/start", params: turnParams)
        let turnID = (turn["turn"] as? [String: Any])?["id"] as? String
        var finalText = ""
        while true {
            let message = try readMessage()
            if message["method"] as? String == "item/completed",
               let params = message["params"] as? [String: Any],
               let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String {
                finalText = text
            }
            guard message["method"] as? String == "turn/completed" else { continue }
            if let expected = turnID,
               let params = message["params"] as? [String: Any],
               let completedTurn = params["turn"] as? [String: Any],
               completedTurn["id"] as? String != expected { continue }
            break
        }
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationError.codexUnavailable("会话未返回翻译内容")
        }
        return finalText
    }

    private func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["id": id, "method": method, "params": params])
        while true {
            let message = try readMessage()
            if let responseID = message["id"] as? Int, responseID == id {
                if let error = message["error"] as? [String: Any] {
                    throw AITranslationError.codexUnavailable(error["message"] as? String ?? method)
                }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try input.write(contentsOf: data + Data([0x0A]))
    }

    private func readMessage() throws -> [String: Any] {
        var data = Data()
        while true {
            guard let chunk = try output.read(upToCount: 1), !chunk.isEmpty else {
                throw AITranslationError.codexUnavailable("本地服务提前退出")
            }
            if chunk[chunk.startIndex] == 0x0A { break }
            data.append(chunk)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AITranslationError.codexUnavailable("收到无法解析的协议消息")
        }
        return object
    }
}

public enum TranslationEngineRegistry {
    public static func make(stableID: String) -> any TranslationEngine {
        switch TranslationEngineID(rawValue:stableID) {
        case .appleSystem:
            return AppleSystemTranslationEngine()
        case .codexChatGPT:
            return CodexAppServerTranslationService()
        case .grokBuild, .geminiCLI, .antigravityCLI, .deepSeekAPI:
            let catalog=TranslationEngineCatalog.metadata(for:stableID)
            let metadata=TranslationEngineMetadata(
                stableID:stableID,
                displayName:catalog?.displayName ?? "未接线的翻译服务",
                availability:.unavailable,
                requiresAPIKey:catalog?.requiresAPIKey ?? false,
                supportsModelDirectory:catalog?.supportsModelDirectory ?? false
            )
            return UnavailableProviderTranslationEngine(metadata:metadata)
        case .openAICompatible, .none:
            return OpenAICompatibleTranslationService()
        }
    }
}

private struct UnavailableProviderTranslationEngine: TranslationEngine, Sendable {
    let metadata:TranslationEngineMetadata
    private static let reason="此 Provider 的翻译执行尚未接线。"

    func translate(context:AITranslationContext,sourceContentHash:String,
                   configuration:AITranslationConfiguration) async throws -> AITranslationDraft {
        throw AITranslationError.engineUnavailable(Self.reason)
    }

    func testConnection(configuration:AITranslationConfiguration) async throws {
        throw AITranslationError.engineUnavailable(Self.reason)
    }
}

extension TranslationEngineRegistry {
    public static func wrapping(_ service: any AITranslationService) -> any TranslationEngine {
        LegacyTranslationEngineAdapter(service: service)
    }
}
