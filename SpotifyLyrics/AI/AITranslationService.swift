import Foundation
import CoreFoundation
import Darwin
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

/// A small durable envelope around an engine invocation, not a transport retry.
/// The conservative boundary precedes engine entry: an engine can fail locally
/// after this point, but we cannot safely infer that a server did not receive it.
enum AITranslationRequestExecution {
    static func key(identity: TrackIdentity, versionID: UUID, sourceHash: String,
                    context: AITranslationContext, configuration: AITranslationConfiguration) throws -> String {
        // UI UUIDs are regenerated when lyric_lines are reloaded. Persistent row
        // identity is the immutable version + ordered originals, never that UUID
        // or a legacy prompt's transient display/timing payload. The rules hash
        // covers the effective style/profile and this provider's reasoning.
        let fields = ["translation-request-v1", identity.stableKey, versionID.uuidString, sourceHash,
                      configuration.targetLanguage, configuration.providerCacheIdentity,
                      configuration.promptHash] + context.lines.map(\.original)
        return SHA256.hash(data: try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ draft: AITranslationDraft, context: AITranslationContext,
                         sourceHash: String, configuration: AITranslationConfiguration) throws {
        guard draft.sourceContentHash == sourceHash, draft.targetLanguage == configuration.targetLanguage,
              (draft.engineID == configuration.engineID ||
                (configuration.engineID == TranslationEngineID.openAICompatible.rawValue && configuration.fallbackStrategy == .automaticSystem && draft.engineID == TranslationEngineID.appleSystem.rawValue)) else { throw TranslationRepositoryError.sourceContentMismatch }
        _ = try AITranslationResponseValidator.validate(draft.lines, against: context.lines.map(\.original))
    }

    static func run(engine: any TranslationEngine, repository: any TranslationRepository, key: String,
                    explicitRetry: Bool, context: AITranslationContext, sourceHash: String,
                    configuration: AITranslationConfiguration, budget: TranslationAcceptanceRequestBudget?,
                    trackKey: String) async throws -> StoredTranslationRequest {
        guard configuration.isConfigured else { throw AITranslationError.notConfigured }
        try Task.checkCancellation()
        var request = try await repository.beginTranslationRequest(key: key, explicitRetry: explicitRetry)
        try Task.checkCancellation()
        try budget?.reserve(provider: configuration.engineID, trackKey: trackKey)
        request.phase = .dispatching; request.updatedAt = Date()
        try await repository.updateTranslationRequest(request)
        try Task.checkCancellation()
        let result: AITranslationDraft
        do {
            result = try await CodexRPCDiagnostic.$currentAttemptID.withValue(request.attemptID) {
                try await engine.translate(context: context, sourceContentHash: sourceHash, configuration: configuration)
            }
        } catch {
            guard configuration.fallbackStrategy == .automaticSystem,
                  engine.metadata.stableID == TranslationEngineID.openAICompatible.rawValue else { throw error }
            result = try await AppleSystemTranslationEngine().translate(context: context, sourceContentHash: sourceHash, configuration: configuration)
        }
        try Task.checkCancellation()
        try validate(result, context: context, sourceHash: sourceHash, configuration: configuration)
        request.phase = .received; request.result = result; request.updatedAt = Date()
        try await repository.updateTranslationRequest(request)
        return request
    }
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

/// Runs the user's existing Codex app-server configuration. Authentication stays
/// inside the installed CLI; this service never reads or logs credential values.
public struct CodexAppServerTranslationService: TranslationEngine, Sendable {
    public static let executablePaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/usr/local/bin/codex", "/opt/homebrew/bin/codex"
    ]
    private let executableCandidates: [String]
    private let transport: any CodexTranslationTransport

    public init(executableCandidates: [String] = Self.executablePaths) {
        self.executableCandidates = executableCandidates
        self.transport = CodexAppServerTransport()
    }

    // Internal dependency seam: production registry never supplies a transport.
    init(executableCandidates: [String], transport: any CodexTranslationTransport) {
        self.executableCandidates = executableCandidates
        self.transport = transport
    }

    public func resolveExecutable() throws -> String {
        guard let path = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AITranslationError.codexNotInstalled
        }
        return path
    }

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(stableID: TranslationEngineID.codexChatGPT.rawValue,
            displayName: "Codex / ChatGPT 登录", availability: (try? resolveExecutable()) == nil ? .unavailable : .available,
            requiresAPIKey: false, supportsModelDirectory: true)
    }

    /// Metadata-only probe: it asks the existing app-server for models without starting a thread or turn.
    public func listModels(timeout: TimeInterval = 20) async throws -> [TranslationModelDescriptor] {
        guard timeout.isFinite, timeout > 0 else {
            throw AITranslationError.invalidResponse("Codex 模型目录超时设置无效")
        }
        let executable = try resolveExecutable()
        return try await Task.detached(priority: .utility) {
            let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-model-directory-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: cwd) }
            let client = try CodexAppServerClient(executable: executable, cwd: cwd, timeout: timeout)
            defer { client.stop() }
            try client.initialize()
            try client.ensureAuthenticated()
            return try client.availableModels()
        }.value
    }

    public func translate(context: AITranslationContext, sourceContentHash: String,
                          configuration: AITranslationConfiguration) async throws -> AITranslationDraft {
        try Task.checkCancellation()
        let executable = try resolveExecutable()
        let prompt = try AITranslationPromptBuilder().build(context: context, configuration: configuration)
        guard let wireRequest = prompt.codexWireRequest else {
            throw AITranslationError.codexResponseInvalid("GPT 请求传输身份缺失")
        }
        let result = try await transport.run(executable: executable, prompt: prompt,
            model: configuration.model, reasoningEffort: configuration.codexReasoningEffort,
            timeout: configuration.timeout, outputSchema: Self.outputSchema(request: wireRequest))
        try Task.checkCancellation()
        guard !result.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITranslationError.codexResponseInvalid("未返回实际模型 ID")
        }
        do {
            let validated = try AITranslationResponseParser.parseCodex(
                Data(result.text.utf8), request: wireRequest)
            let effort = result.reasoningEffort ?? configuration.codexReasoningEffort
            let reasoningSetting = effort.isEmpty ? "effort=model-default" : "effort=" + effort
            return AITranslationDraft(lines: validated, targetLanguage: configuration.targetLanguage,
                model: result.model, baseURLHost: "codex-app-server", promptHash: prompt.promptHash,
                sourceContentHash: sourceContentHash, engineID: TranslationEngineID.codexChatGPT.rawValue,
                promptPresetID: configuration.promptPresetID, profileID: configuration.profileID,
                profileSnapshot: configuration.profileSnapshot, temperature: 0,
                workflowID: configuration.workflowID, fallbackStrategy: .none, isDraft: true,
                codexReasoningEffort: result.reasoningEffort ?? "", tokenUsage: result.tokenUsage,
                providerReasoningSetting: reasoningSetting)
        } catch let error as AITranslationError { throw error }
        catch { throw AITranslationError.codexResponseInvalid("JSON 或稳定行 ID 校验失败") }
    }

    /// Shared explicit generation transport, also used by reading candidates.
    func complete(prompt: AITranslationPrompt, configuration: AITranslationConfiguration,
                  outputSchema: [String: Any]) async throws -> Data {
        guard configuration.isConfigured else { throw AITranslationError.notConfigured }
        try Task.checkCancellation()
        let result = try await transport.run(executable: resolveExecutable(), prompt: prompt,
            model: configuration.model, reasoningEffort: configuration.codexReasoningEffort,
            timeout: configuration.timeout, outputSchema: outputSchema)
        try Task.checkCancellation()
        guard !result.model.isEmpty else { throw AITranslationError.codexResponseInvalid("未返回实际模型") }
        return Data(result.text.utf8)
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        _ = try resolveExecutable()
        guard !configuration.model.isEmpty else { throw AITranslationError.notConfigured }
        // Local binary/config presence only. This deliberately sends no model request.
    }

    static func outputSchema(request: CodexTranslationWireRequest) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "required": ["requestID", "lines"], "properties": [
            "requestID": ["type": "string", "enum": [request.requestID.uuidString]],
            "lines": ["type": "array", "items": ["type": "object", "additionalProperties": false,
                "required": ["lineID", "translation"], "properties": [
                    "lineID": ["type": "string"], "translation": ["type": "string"]]]]]]
    }
}

struct CodexTranslationResult: Sendable {
    let text: String
    let model: String
    let reasoningEffort: String?
    let tokenUsage: AITranslationTokenUsage?
    let supportedReasoningEfforts: [String]
    init(text: String, model: String, reasoningEffort: String? = nil, tokenUsage: AITranslationTokenUsage? = nil, supportedReasoningEfforts: [String] = []) {
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.text = text; self.model = model; self.reasoningEffort = reasoningEffort; self.tokenUsage = tokenUsage
    }
}

protocol CodexTranslationTransport: Sendable {
    func run(executable: String, prompt: AITranslationPrompt, model: String, reasoningEffort: String,
             timeout: TimeInterval, outputSchema: [String: Any]) async throws -> CodexTranslationResult
}

/// Existing acceptance transport; registry activation remains a separate App step.
/// CLI manages its normal configuration and existing authentication. Empty cwd,
/// read-only tool policy and event rejection are not proof of zero tool capability.
struct CodexAppServerTransport: CodexTranslationTransport {
    var diagnosticSink: CodexRPCDiagnostic.Sink = { try CodexRPCDiagnostic.log($0) }
    func run(executable: String, prompt: AITranslationPrompt, model: String, reasoningEffort: String,
             timeout: TimeInterval, outputSchema: [String: Any]) async throws -> CodexTranslationResult {
        let owner = CodexProcessOwner()
        let attemptID = CodexRPCDiagnostic.currentAttemptID
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                let job = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-translation-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: job) }
                let client = try CodexAppServerClient(executable: executable, cwd: job, timeout: timeout,
                    diagnosticSink: diagnosticSink, attemptID: attemptID)
                owner.install(client)
                defer { client.stop() }
                try client.initialize()
                try client.ensureAuthenticated()
                return try client.translate(prompt: prompt, model: model, reasoningEffort: reasoningEffort, outputSchema: outputSchema)
            }.value
        }, onCancel: { owner.cancel() })
    }
}

/// Only locally generated metadata. No payloads, IDs from the server, account
/// objects, error messages or stderr may enter this record.
struct CodexRPCDiagnostic: Codable, Sendable {
    @TaskLocal static var currentAttemptID: UUID?
    typealias Sink = @Sendable (CodexRPCDiagnostic) throws -> Void
    let traceID: UUID
    let attemptID: UUID?
    let pid: Int32
    let elapsedMilliseconds: Int
    let phase: String
    let event: String
    let method: String?
    let requestID: Int?
    let exitStatus: Int32?
    static func log(_ record: Self) throws {
        let data = try JSONEncoder().encode(record)
        if let text = String(data: data, encoding: .utf8) { LyricsE2ELog.log("CODEX_RPC " + text) }
    }
}

private final class CodexProcessOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var client: CodexAppServerClient?
    private var cancelled = false
    func install(_ value: CodexAppServerClient) {
        lock.lock(); client = value; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { value.abort(.cancelled) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = client; lock.unlock()
        value?.abort(.cancelled)
    }
}

final class CodexAppServerClient: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let cwd: URL
    private let condition = NSCondition()
    private var buffer = Data()
    private var bytesReceived = 0
    private var eof = false
    private var failure: AITranslationError?
    private var nextID = 1
    private var watchdog: DispatchWorkItem?
    private let deadline: Date
    private let diagnosticSink: CodexRPCDiagnostic.Sink
    private let diagnosticLock = NSLock()
    private let traceID = UUID()
    private let attemptID: UUID?
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var phase = "launch"
    private var activeMethod: String?
    private var activeRequestID: Int?
    private static let frameLimit = 1_048_576
    private static let totalLimit = 4_194_304

    init(executable: String, cwd: URL, timeout: TimeInterval,
         diagnosticSink: @escaping CodexRPCDiagnostic.Sink = { try CodexRPCDiagnostic.log($0) },
         attemptID: UUID? = nil) throws {
        self.diagnosticSink = diagnosticSink
        self.attemptID = attemptID
        self.cwd = cwd
        self.deadline = Date().addingTimeInterval(max(0.05, min(timeout, 600)))
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe
        // Do not record arbitrary tool stderr, which can contain sensitive data.
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://",
            "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\""]
        process.currentDirectoryURL = cwd
        // No inherited API keys, tokens, workspace paths or custom shell config.
        var environment = ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()]
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            environment["CODEX_HOME"] = codexHome
        }
        process.environment = environment
        do { try process.run() }
        catch { diagnose("launch_failed"); throw error }
        diagnose("process_started")
        // Child exit must become a typed error rather than SIGPIPE in the App.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.readabilityHandler = { [weak self] handle in
            // Foundation's read(upToCount:) fills the requested size on this
            // macOS, deadlocking short JSONL frames. POSIX read returns available bytes.
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count >= 0 { self?.receive(Data(bytes.prefix(count))) }
            else if errno != EINTR { self?.abort(.codexUnavailable("输出读取失败")) }
        }
        let work = DispatchWorkItem { [weak self] in self?.abort(.timedOut) }
        watchdog = work
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.05, min(timeout, 600)), execute: work)
    }

    private func diagnose(_ event: String, method: String? = nil, requestID: Int? = nil,
                          newPhase: String? = nil, exitStatus: Int32? = nil) {
        diagnosticLock.lock()
        if let newPhase { phase = newPhase; activeMethod = method; activeRequestID = requestID }
        let record = CodexRPCDiagnostic(traceID: traceID, attemptID: attemptID, pid: process.processIdentifier,
            elapsedMilliseconds: Int(max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000),
            phase: phase, event: event, method: method ?? activeMethod,
            requestID: requestID ?? activeRequestID, exitStatus: exitStatus)
        diagnosticLock.unlock()
        // A failed recorder is never a translation failure.
        try? diagnosticSink(record)
    }

    private func receive(_ chunk: Data) {
        condition.lock()
        if chunk.isEmpty { eof = true } else {
            bytesReceived += chunk.count; buffer.append(chunk)
            if bytesReceived > Self.totalLimit || buffer.count > Self.frameLimit * 2 {
                failure = .codexResponseInvalid("协议输出超出大小限制")
            }
        }
        let exceeded = failure != nil
        condition.broadcast(); condition.unlock()
        if exceeded { terminateOwnedProcess() }
    }

    func abort(_ error: AITranslationError) {
        condition.lock()
        let firstFailure = failure == nil
        if firstFailure { failure = error }
        condition.broadcast(); condition.unlock()
        if firstFailure {
            let reason: String
            switch error {
            case .timedOut: reason = "timeout"
            case .cancelled: reason = "cancelled"
            case .codexToolRequestRejected: reason = "tool_rejected"
            default: reason = "transport_failure"
            }
            diagnose(reason)
        }
        terminateOwnedProcess()
    }

    private func terminateOwnedProcess() {
        guard process.isRunning else { return }
        process.terminate()
        // Reap even a peer that ignores SIGTERM. This PID belongs to this Process.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [process] in
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    func stop() {
        watchdog?.cancel()
        output.readabilityHandler = nil
        terminateOwnedProcess()
        process.waitUntilExit()
        diagnose(process.terminationReason == .uncaughtSignal ? "process_signal_exit" : "process_exit",
                 exitStatus: process.terminationStatus)
        try? input.close(); try? output.close()
    }

    private func recordRecovery(stage: String, fields: [String: Any]) throws {
#if DEBUG
        guard DebugAcceptanceDataIsolation.isRequested,
              ProcessInfo.processInfo.environment["SPOTIFYLYRICS_ACCEPTANCE_TRANSLATION_GRANT"] == "6119898076",
              let attemptID else { throw AITranslationError.codexUnavailable("缺少隔离恢复身份") }
        let file = DebugAcceptanceDataIsolation.configuration.root.appendingPathComponent("logs/codex-recovery-" + attemptID.uuidString + "-" + stage + ".json")
        DebugAcceptanceDataIsolation.requireStorage(file)
        guard !FileManager.default.fileExists(atPath: file.path) else { throw AITranslationError.codexUnavailable("恢复记录已存在，拒绝覆盖") }
        var record = fields
        record["attemptID"] = attemptID.uuidString
        record["grant"] = "6119898076"
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
#endif
    }

    func initialize() throws {
        _ = try request(method: "initialize", params: ["clientInfo": [
            "name": "spotifylyrics", "title": "SpotifyLyrics", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized", "params": [:]])
    }

    func ensureAuthenticated() throws {
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

    func availableReasoningEfforts(model: String) throws -> [String] {
        var cursor: String?
        // Bound pagination; never infer support from a hard-coded model name.
        for _ in 0..<10 {
            var params: [String: Any] = ["limit": 100, "includeHidden": true]
            if let cursor { params["cursor"] = cursor }
            let result = try request(method: "model/list", params: params)
            for entry in result["data"] as? [[String: Any]] ?? [] {
                if entry["model"] as? String == model || entry["id"] as? String == model {
                    return (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                        .compactMap { $0["reasoningEffort"] as? String }
                }
            }
            guard let next = result["nextCursor"] as? String, !next.isEmpty, next != cursor else { return [] }
            cursor = next
        }
        throw AITranslationError.codexUnavailable("模型目录分页超过上限；未发送翻译请求")
    }

    func translate(prompt: AITranslationPrompt, model: String, reasoningEffort: String = "", outputSchema: [String: Any]) throws -> CodexTranslationResult {
        let requestedEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        var available: [String] = []
        if !requestedEffort.isEmpty {
            available = try availableReasoningEfforts(model: model)
            guard available.contains(requestedEffort) else {
                throw AITranslationError.codexUnsupportedReasoningEffort(requested: requestedEffort, available: available)
            }
        }
        var recoverable = false
#if DEBUG
        recoverable = DebugAcceptanceDataIsolation.isRequested && ProcessInfo.processInfo.environment["SPOTIFYLYRICS_ACCEPTANCE_TRANSLATION_GRANT"] == "6119898076"
#endif
        var params: [String: Any] = ["cwd": cwd.path, "ephemeral": !recoverable,
            "serviceName": "spotifylyrics", "approvalPolicy": "never", "sandbox": "read-only",
            // Pinned 0.160.0 exposes failed built-in calls only in raw events.
            // This observes calls and stops the owned process; it is not an
            // atomic veto or a claim that built-in tool declarations are absent.
            "experimentalRawEvents": true, "allowProviderModelFallback": false,
            "environments": [], "dynamicTools": [], "runtimeWorkspaceRoots": [],
            "config": ["project_doc_max_bytes": 0, "web_search": "disabled",
                "features.shell_tool": false, "features.unified_exec": false,
                "features.code_mode_host": false, "agents.enabled": false,
                "features.shell_snapshot": false, "features.apps": false, "features.hooks": false,
                "features.plugins": false, "features.multi_agent": false, "features.memories": false]]
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { params["model"] = model }
        if !requestedEffort.isEmpty {
            var config = params["config"] as! [String: Any]
            config["model_reasoning_effort"] = requestedEffort
            params["config"] = config
        }
        let result = try request(method: "thread/start", params: params)
        guard let thread = result["thread"] as? [String: Any], let threadID = thread["id"] as? String,
              let actualModel = result["model"] as? String, !actualModel.isEmpty else {
            throw AITranslationError.codexResponseInvalid("未返回会话或实际模型 ID")
        }
        guard model.isEmpty || actualModel == model else {
            throw AITranslationError.codexUnavailable("所选模型与实际会话模型不一致；未发送翻译请求")
        }
        let selectedEffort = result["reasoningEffort"] as? String
        guard requestedEffort.isEmpty || selectedEffort == requestedEffort else {
            throw AITranslationError.codexUnavailable("会话未保留指定推理强度；未发送翻译请求")
        }
        if recoverable {
            guard thread["ephemeral"] as? Bool == false else {
                throw AITranslationError.codexUnavailable("会话未确认持久化；未发送翻译请求")
            }
            var fields: [String: Any] = ["threadID": threadID, "model": actualModel,
                "reasoningEffort": selectedEffort ?? "", "promptHash": prompt.promptHash,
                "outputSchema": outputSchema, "promptUser": prompt.user]
            if let wire = prompt.codexWireRequest {
                fields["wireRequestID"] = wire.requestID.uuidString
                fields["sourceLines"] = wire.sourceLines.map { ["index": $0.index, "lineID": $0.lineID.uuidString, "original": $0.original] as [String: Any] }
            }
            try recordRecovery(stage: "thread", fields: fields)
        }
        var turnParams: [String: Any] = ["threadId": threadID,
            "input": [["type": "text", "text": prompt.system + "\nJSON:\n" + prompt.user]],
            "outputSchema": outputSchema, "approvalPolicy": "never", "cwd": cwd.path,
            "environments": [], "sandboxPolicy": ["type": "readOnly", "networkAccess": false]]
        // Pin the model actually selected by thread/start instead of a generic label.
        turnParams["model"] = actualModel
        if !requestedEffort.isEmpty { turnParams["effort"] = requestedEffort }
        let turn = try request(method: "turn/start", params: turnParams)
        guard let turnObject = turn["turn"] as? [String: Any], let turnID = turnObject["id"] as? String else {
            throw AITranslationError.codexResponseInvalid("未返回 turn ID")
        }
        if recoverable { try recordRecovery(stage: "turn", fields: ["threadID": threadID, "turnID": turnID, "model": actualModel, "reasoningEffort": selectedEffort ?? ""]) }
        diagnose("waiting_for_completion", newPhase: "turn_events")
        var text: String?
        var tokenUsage: AITranslationTokenUsage?
        while true {
            let message = try readMessage()
            guard let event = message["params"] as? [String: Any], event["threadId"] as? String == threadID else { continue }
            if message["method"] as? String == "model/rerouted", event["turnId"] as? String == turnID {
                abort(.codexUnavailable("翻译被重定向到其他模型；本次已停止"))
                throw AITranslationError.codexUnavailable("翻译被重定向到其他模型；本次已停止")
            }
            if message["method"] as? String == "thread/tokenUsage/updated", event["turnId"] as? String == turnID,
               let usage = event["tokenUsage"] as? [String: Any], let last = usage["last"] as? [String: Any] {
                tokenUsage = Self.parseTokenUsage(last)
            }
            if message["method"] as? String == "item/completed", event["turnId"] as? String == turnID,
               let item = event["item"] as? [String: Any], item["type"] as? String == "agentMessage" {
                // Only a final answer, not a commentary item, can be a result.
                if item["phase"] == nil || item["phase"] as? String == "final_answer" { text = item["text"] as? String }
            }
            if message["method"] as? String == "turn/completed",
               let completed = event["turn"] as? [String: Any], completed["id"] as? String == turnID {
                diagnose("turn_completed")
                guard completed["status"] as? String == "completed" else {
                    if completed["status"] as? String == "interrupted" { throw AITranslationError.cancelled }
                    if let error = completed["error"] as? [String: Any] { throw Self.protocolError(error) }
                    throw AITranslationError.codexUnavailable("翻译会话失败")
                }
                guard let text, !text.isEmpty else { throw AITranslationError.codexResponseInvalid("完成事件缺少最终译文") }
                diagnose("result_received")
                return CodexTranslationResult(text: text, model: actualModel, reasoningEffort: selectedEffort, tokenUsage: tokenUsage, supportedReasoningEfforts: available)
            }
        }
    }

    private static func parseTokenUsage(_ value: [String: Any]) -> AITranslationTokenUsage? {
        func count(_ key: String) -> Int? {
            guard let number = value[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue < Double(Int.max) else { return nil }
            return number.intValue
        }
        guard let input = count("inputTokens"), let cached = count("cachedInputTokens"),
              let output = count("outputTokens"), let reasoning = count("reasoningOutputTokens"),
              let total = count("totalTokens") else { return nil }
        return AITranslationTokenUsage(inputTokens: input, cachedInputTokens: cached,
            outputTokens: output, reasoningOutputTokens: reasoning, totalTokens: total)
    }

    private static func protocolError(_ error: [String: Any]) -> AITranslationError {
        let info = (error["data"] as? [String: Any])?["codexErrorInfo"] ?? error["codexErrorInfo"]
        if info as? String == "usageLimitExceeded" { return .codexQuotaExceeded }
        if info as? String == "rateLimitExceeded" { return .rateLimited }
        if info as? String == "unauthorized" { return .unauthorized }
        // Do not reflect arbitrary server error text into saved logs/UI.
        return .codexUnavailable("协议请求失败")
    }

    private func request(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID; nextID += 1
        diagnose("rpc_write_started", method: method, requestID: id, newPhase: method)
        try send(["id": id, "method": method, "params": params])
        diagnose("rpc_written", method: method, requestID: id)
        while true {
            let message = try readMessage()
            if message["id"] as? Int == id {
                diagnose("rpc_response", method: method, requestID: id)
                if let error = message["error"] as? [String: Any] {
                    diagnose("rpc_error", method: method, requestID: id)
                    throw Self.protocolError(error)
                }
                guard let result = message["result"] as? [String: Any] else { throw AITranslationError.codexResponseInvalid("协议响应缺少 result") }
                return result
            }
            diagnose("unmatched_message_ignored")
        }
    }

    private func send(_ object: [String: Any]) throws {
        condition.lock(); let error = failure; condition.unlock()
        if let error { throw error }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= Self.frameLimit else { throw AITranslationError.codexResponseInvalid("请求超出大小限制") }
        do { try input.write(contentsOf: data + Data([0x0A])) }
        catch {
            condition.lock(); let error = failure; condition.unlock()
            throw error ?? AITranslationError.codexUnavailable("进程输入写入失败")
        }
    }

    private func readMessage() throws -> [String: Any] {
        condition.lock()
        while true {
            if let failure { condition.unlock(); throw failure }
            if let end = buffer.firstIndex(of: 0x0A) {
                let data = Data(buffer[..<end]); buffer.removeSubrange(...end); condition.unlock()
                guard data.count <= Self.frameLimit else { throw AITranslationError.codexResponseInvalid("协议单条消息过大") }
                let object: [String: Any]
                do {
                    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw AITranslationError.codexResponseInvalid("协议格式错误")
                    }
                    object = value
                } catch { throw AITranslationError.codexResponseInvalid("协议格式错误") }
                if Self.containsToolActivity(object) {
                    // Stop rather than feed a tool error into another model turn.
                    // Latch failure first so buffered/late final text cannot win.
                    abort(.codexToolRequestRejected)
                    throw AITranslationError.codexToolRequestRejected
                }
                if let method = object["method"] as? String {
                    let known = ["thread/started", "turn/started", "item/started", "item/completed", "turn/completed", "thread/tokenUsage/updated", "model/rerouted"]
                    diagnose("notification", method: known.contains(method) ? method : "other")
                }
                return object
            }
            if buffer.count > Self.frameLimit { condition.unlock(); throw AITranslationError.codexResponseInvalid("协议单条消息过大") }
            if eof { condition.unlock(); diagnose("unexpected_eof"); throw AITranslationError.codexUnavailable("本地进程提前退出，未完成翻译") }
            if !condition.wait(until: deadline) { condition.unlock(); abort(.timedOut); throw AITranslationError.timedOut }
        }
    }

    private static func containsToolActivity(_ object: [String: Any]) -> Bool {
        // The translation client never answers approvals, input, MCP or tools.
        if object["id"] != nil && object["method"] != nil { return true }
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        if method == "rawResponseItem/completed" {
            guard let item = params["item"] as? [String: Any],
                  let type = item["type"] as? String else { return true }
            // Reject calls, outputs without a visible call, and future item kinds.
            return !["message", "reasoning", "compaction", "additional_tools"].contains(type)
        }
        if method == "item/started" || method == "item/completed" {
            guard let item = params["item"] as? [String: Any],
                  let type = item["type"] as? String else { return true }
            if item["delivery"] as? String == "async"
                || !(item["questions"] as? [Any] ?? []).isEmpty { return true }
            return !["userMessage", "agentMessage", "reasoning"].contains(type)
        }
        return method.hasPrefix("item/tool/") || method.hasPrefix("item/permissions/")
            || method.hasPrefix("item/commandExecution/") || method.hasPrefix("item/fileChange/")
            || method.hasPrefix("item/mcpToolCall/")
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
