import Foundation
import Darwin
import CryptoKit

/// Explicit, metadata-only model queries. No automatic provider fallback.
struct ProviderModelDirectoryLoader: Sendable {
    func models(configuration input:AITranslationConfiguration) async throws -> [TranslationModelDescriptor] {
        var c=input
        switch TranslationEngineID(rawValue:c.engineID) {
        case .codexChatGPT: return try await CodexAppServerTranslationService().listModels()
        case .grokBuild: return try await GrokBuildTranslationService().listModels()
        case .openAICompatible, .deepSeekAPI:
            if c.engineID == TranslationEngineID.deepSeekAPI.rawValue, c.baseURL.isEmpty { c.baseURL=DeepSeekTranslationService.defaultBaseURL }
            guard !c.baseURL.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AITranslationError.invalidEndpoint }
            let account = c.engineID == TranslationEngineID.deepSeekAPI.rawValue ? DeepSeekTranslationService.keychainAccount : c.apiCredentialAccount
            let keys=KeychainAITranslationAPIKeyStore(account:account)
            guard let key=keys.read(), !key.isEmpty else { throw AITranslationError.missingAPIKey }
            return try await OpenAICompatibleClient().listModels(configuration:c,apiKey:key)
        case .geminiCLI: throw AITranslationError.engineUnavailable("Gemini CLI 当前没有已验证的模型目录接口；可手动填写模型 ID")
        case .antigravityCLI:return try await AntigravityCLITranslationService().listModels()
        default: throw AITranslationError.engineUnavailable("此提供方不提供模型目录")
        }
    }
}

struct ProviderTranslationOutput: Sendable {
    let lines: [AITranslationLine]
    let model: String
    let tokenUsage: AITranslationTokenUsage?
    let reasoningSetting: String
}

struct ProviderCLIResult: Sendable {
    let stdout: Data
    let exitCode: Int32
    var failureSummary: String? = nil
}

protocol ProviderCLIExecuting: Sendable {
    func execute(executable: String, arguments: [String], cwd: URL, timeout: TimeInterval, stdin: Data?,
                 environmentOverrides: [String: String]) async throws -> ProviderCLIResult
}

private struct FoundationProviderCLIExecutor: ProviderCLIExecuting {
    var antigravityEvents=false
    func execute(executable: String, arguments: [String], cwd: URL, timeout: TimeInterval, stdin: Data?,
                 environmentOverrides: [String: String]) async throws -> ProviderCLIResult {
        let owner=ProviderCLIProcessOwner()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await Task.detached {
                let output=Pipe(),errorOutput=Pipe(),input=stdin.map { _ in Pipe() }
                var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
                posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attributes)
                defer { posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes) }
                posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP));posix_spawnattr_setpgroup(&attributes,0)
                let readFD=output.fileHandleForReading.fileDescriptor,writeFD=output.fileHandleForWriting.fileDescriptor
                posix_spawn_file_actions_adddup2(&actions,writeFD,STDOUT_FILENO)
                posix_spawn_file_actions_adddup2(&actions,errorOutput.fileHandleForWriting.fileDescriptor,STDERR_FILENO)
                posix_spawn_file_actions_addclose(&actions,errorOutput.fileHandleForReading.fileDescriptor)
                posix_spawn_file_actions_addclose(&actions,errorOutput.fileHandleForWriting.fileDescriptor)
                posix_spawn_file_actions_addclose(&actions,readFD);posix_spawn_file_actions_addclose(&actions,writeFD)
                if let input {
                    posix_spawn_file_actions_adddup2(&actions,input.fileHandleForReading.fileDescriptor,STDIN_FILENO)
                    posix_spawn_file_actions_addclose(&actions,input.fileHandleForReading.fileDescriptor)
                    posix_spawn_file_actions_addclose(&actions,input.fileHandleForWriting.fileDescriptor)
                } else { posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0) }
                if #available(macOS 26,*) { posix_spawn_file_actions_addchdir(&actions,cwd.path) }
                else { posix_spawn_file_actions_addchdir_np(&actions,cwd.path) }
                var pid:pid_t=0
                let environment=Self.safeEnvironment.merging(environmentOverrides){_,override in override}
                let error=Self.withPointers([executable]+arguments) { argv in
                    Self.withPointers(environment.map { $0.key+"="+$0.value }) { env in
                        posix_spawn(&pid,executable,&actions,&attributes,argv,env)
                    }
                }
                try output.fileHandleForWriting.close();try input?.fileHandleForReading.close()
                try errorOutput.fileHandleForWriting.close()
                guard error==0 else { try? errorOutput.fileHandleForReading.close(); throw NSError(domain:NSPOSIXErrorDomain,code:Int(error)) }
                let stderrCapture = ProviderCLIErrorCapture()
                let stderrDrain = DispatchGroup(); stderrDrain.enter()
                DispatchQueue.global().async {
                    stderrCapture.drain(errorOutput.fileHandleForReading)
                    stderrDrain.leave()
                }
                owner.install(pid)
                var status:Int32=0
                defer {
                    while waitpid(pid,&status,0)<0 && errno==EINTR {}
                    stderrCapture.waitForDrain(stderrDrain)
                    owner.finished();try? output.fileHandleForReading.close()
                }
                let timeoutWork=DispatchWorkItem{owner.timeout()}
                DispatchQueue.global().asyncAfter(deadline:.now()+max(1,min(timeout,600)),execute:timeoutWork)
                defer { timeoutWork.cancel() }
                do {
                    if let stdin,let input { try input.fileHandleForWriting.write(contentsOf:stdin);try input.fileHandleForWriting.close() }
                    let observeEvents=antigravityEvents && arguments.contains("--input-format")
                    var data=Data(),pending=Data(),buffer=[UInt8](repeating:0,count:4096)
                    while true {
                        let count=Darwin.read(readFD,&buffer,buffer.count)
                        if count<0 && errno==EINTR { continue }
                        if count<=0 { break }
                        data.append(contentsOf:buffer.prefix(count))
                        guard data.count<=4_194_304 else { throw AITranslationError.invalidResponse("CLI 输出超出大小限制") }
                        if observeEvents {
                            pending.append(contentsOf:buffer.prefix(count))
                            while let end=pending.firstIndex(of:0x0a) {
                                let line=Data(pending[..<end]);pending.removeSubrange(...end)
                                if !line.isEmpty { try AntigravityCLIStreamParser.validateEvent(line) }
                            }
                        }
                    }
                    if observeEvents,!pending.isEmpty { try AntigravityCLIStreamParser.validateEvent(pending) }
                    while waitpid(pid,&status,0)<0 && errno==EINTR {}
                    if owner.wasCancelled { throw AITranslationError.cancelled }
                    if owner.didTimeout { throw AITranslationError.timedOut }
                    let code:Int32=(status & 0x7f)==0 ? (status>>8)&0xff : 128+(status & 0x7f)
                    stderrCapture.waitForDrain(stderrDrain)
                    return ProviderCLIResult(stdout:data,exitCode:code,
                        failureSummary: code == 0 ? nil : stderrCapture.summary(stdout: data))
                } catch {
                    // Policy failure stops this owned group immediately, before reading further events.
                    owner.forceStop();try? input?.fileHandleForWriting.close();throw error
                }
            }.value
        },onCancel:{owner.cancel()})
    }
    private static func withPointers<T>(_ strings:[String],body:(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>)->T) -> T {
        var pointers=strings.map{strdup($0)}+[nil];defer{pointers.dropLast().forEach{free($0)}}
        return pointers.withUnsafeMutableBufferPointer{body($0.baseAddress!)}
    }
    private static var safeEnvironment:[String:String] {
        let blocked=["token","secret","password","api_key","apikey","authorization","credential","cookie","private_key"]
        var env=ProcessInfo.processInfo.environment.filter { key,_ in !blocked.contains(where:key.lowercased().contains) }
        env["LANG"]=env["LANG"] ?? "en_US.UTF-8"
        return TranslationCLIHost.childEnvironment(from: env)
    }
}

/// Drain stderr concurrently, retain only a bounded tail in memory. Never
/// return raw CLI text, URLs, paths, credentials, or prompt fragments.
private final class ProviderCLIErrorCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    func drain(_ handle: FileHandle) {
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            lock.lock(); tail.append(contentsOf: buffer.prefix(count))
            if tail.count > 65_536 { tail.removeFirst(tail.count - 65_536) }
            lock.unlock()
        }
    }
    func waitForDrain(_ group: DispatchGroup) { group.wait() }
    func summary(stdout: Data) -> String {
        lock.lock(); let snapshot = tail; lock.unlock()
        var text = String(decoding: snapshot, as: UTF8.self).lowercased()
        if let root = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
           root["type"] as? String == "error", let message = root["message"] as? String {
            text += "\n" + message.lowercased()
        }
        if text.contains("invalid json") { return "phase=prompt-input；reason=invalid-json" }
        if text.contains("failed to read") { return "phase=prompt-input；reason=prompt-read-failed" }
        if text.contains("unknown model id") { return "phase=model-selection；reason=unknown-model-id" }
        if text.contains("unauthorized") || text.contains("401") { return "phase=authentication；reason=unauthorized" }
        if text.contains("403") || text.contains("forbidden") { return "phase=provider；reason=access-denied" }
        if text.contains("429") || text.contains("quota") || text.contains("rate limit") { return "phase=provider；reason=quota-or-rate-limit" }
        if text.contains("error sending request") || text.contains("dns error") || text.contains("connection refused") {
            return "phase=network；reason=connection-failed"
        }
        return "phase=unclassified；stderr-tail-bytes=\(snapshot.count)；stderr-tail-sha256=\(SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined().prefix(12))"
    }
}

private final class ProviderCLIProcessOwner: @unchecked Sendable {
    private let lock=NSLock();private var pid:pid_t?;private var cancelled=false,timedOut=false
    var wasCancelled:Bool{lock.lock();defer{lock.unlock()};return cancelled}
    var didTimeout:Bool{lock.lock();defer{lock.unlock()};return timedOut}
    func install(_ value:pid_t){lock.lock();pid=value;let stop=cancelled;lock.unlock();if stop{terminate(value)}}
    func finished(){lock.lock();pid=nil;lock.unlock()}
    func forceStop(){lock.lock();let p=pid;lock.unlock();if let p{kill(-p,SIGKILL)}}
    func cancel(){lock.lock();cancelled=true;let p=pid;lock.unlock();if let p{terminate(p)}}
    func timeout(){lock.lock();timedOut=true;let p=pid;lock.unlock();if let p{terminate(p)}}
    private func terminate(_ owned:pid_t){
        kill(-owned,SIGTERM)
        DispatchQueue.global().asyncAfter(deadline:.now()+0.5){[self] in
            lock.lock();let active=pid==owned;lock.unlock();if active{kill(-owned,SIGKILL)}
        }
    }
}

private func withProviderJob<T>(_ operation: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spotifylyrics-translation-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await operation(directory)
}

private func writePrivate(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}


// MARK: - Grok Build CLI

struct GrokBuildResponseParser {
    static func parse(_ data: Data, expectedLines: [AITranslationSourceLine],
                      requestedModel: String, reasoningEffort: String) throws -> ProviderTranslationOutput {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let root = value as? [String: Any] else { throw AITranslationError.invalidResponse("Grok JSON 响应不是对象") }
        if root["tool_calls"] != nil || root["toolUse"] != nil || root["tool_use"] != nil {
            throw AITranslationError.engineUnavailable("Grok 返回了工具请求；本次候选已停止")
        }
        guard root["type"] as? String != "error", root["is_error"] as? Bool != true,
              (root["stopReason"] as? String).map({ $0 == "end_turn" }) ?? true else {
            throw AITranslationError.invalidResponse("Grok 未正常完成，未创建候选")
        }
        // Native headless JSON identifies actual model rounds in modelUsage.
        // Reject absent, mixed, and fallback models rather than echoing the requested ID.
        let modelUsage = root["modelUsage"] as? [String: Any]
        let nativeModel: String? = modelUsage.flatMap { models in
            guard Set(models.keys) == [requestedModel],
                  let rounds = models[requestedModel] as? [String: Any],
                  let calls = rounds["modelCalls"] as? Int, calls > 0 else { return nil }
            return requestedModel
        }
        guard let model = (root["model"] as? String) ?? (root["modelId"] as? String) ?? nativeModel,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model == requestedModel else {
            throw AITranslationError.invalidResponse("Grok 未返回所请求的实际模型 ID")
        }
        let response: Any
        if root["lines"] != nil { response = root }
        else if let structured = root["structured_output"] { response = structured }
        else if let text = root["text"] as? String { response = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        else if let result = root["result"] { response = result }
        else if let text = root["response"] as? String { response = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        else { throw AITranslationError.invalidResponse("Grok 响应缺少结构化结果") }
        let responseData: Data
        if let data = response as? Data { responseData = data }
        else if let string = response as? String { responseData = Data(string.utf8) }
        else { responseData = try JSONSerialization.data(withJSONObject: response) }
        let object = try JSONSerialization.jsonObject(with: responseData)
        guard let dictionary = object as? [String: Any], Set(dictionary.keys) == ["lines"],
              let lines = dictionary["lines"] else {
            throw AITranslationError.invalidResponse("Grok 结构化结果必须只包含 lines")
        }
        let stable = try JSONSerialization.data(withJSONObject: lines)
        let validated = try AITranslationResponseParser.parseStable(stable, expectedLines: expectedLines)
        return ProviderTranslationOutput(lines: validated, model: model, tokenUsage: Self.usage(root["usage"]),
                                         reasoningSetting: "reasoning_effort=" + (reasoningEffort.isEmpty ? "model-default" : reasoningEffort))
    }

    private static func usage(_ value: Any?) -> AITranslationTokenUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int)
        let output = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int)
        let total = usage["total_tokens"] as? Int
        guard let input, let output, let total else { return nil }
        let cached = usage["cache_read_input_tokens"] as? Int ?? 0
        let created = usage["cache_creation_input_tokens"] as? Int ?? 0
        return AITranslationTokenUsage(inputTokens: input + cached + created, cachedInputTokens: cached, outputTokens: output,
                                       reasoningOutputTokens: usage["reasoning_tokens"] as? Int ?? 0, totalTokens: total)
    }
}

public struct GrokBuildTranslationService: TranslationEngine, Sendable {
    static let executablePaths = [TranslationCLIHost.homeDirectory + "/.grok/bin/grok"] + TranslationCLIHost.searchDirectories.map { $0 + "/grok" }
    private let candidates: [String]
    private let executor: any ProviderCLIExecuting

    public init(executableCandidates: [String]? = nil) {
        candidates = executableCandidates ?? Self.executablePaths
        executor = FoundationProviderCLIExecutor()
    }

    init(executableCandidates: [String], executor: any ProviderCLIExecuting) {
        candidates = executableCandidates
        self.executor = executor
    }

    func resolveExecutable() -> String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(stableID: TranslationEngineID.grokBuild.rawValue, displayName: "Grok Build CLI",
                                  availability: resolveExecutable() == nil ? .unavailable : .available,
                                  requiresAPIKey: false, supportsModelDirectory: true)
    }

    public func listModels(timeout: TimeInterval = 20) async throws -> [TranslationModelDescriptor] {
        guard let executable=resolveExecutable() else { throw AITranslationError.engineUnavailable("未找到 Grok Build CLI") }
        return try await withProviderJob { job in
            let result=try await executor.execute(executable:executable, arguments:["--no-subagents","models"],
                cwd:job, timeout:timeout, stdin:nil, environmentOverrides:[:])
            guard result.exitCode == 0 else { throw AITranslationError.engineUnavailable("Grok 模型目录读取失败（退出码 \(result.exitCode)）；未发翻译请求") }
            return try Self.parseModelDirectory(result.stdout)
        }
    }

    static func parseModelDirectory(_ data:Data) throws -> [TranslationModelDescriptor] {
        guard let text=String(data:data,encoding:.utf8) else { throw AITranslationError.invalidResponse("Grok 模型目录编码无效") }
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw AITranslationError.invalidResponse("Grok 未返回模型目录；不能判定为没有模型") }
        // Fixed CLI's `models` command emits a human-readable model table.
        // Only model IDs are retained; arbitrary output is neither logged nor persisted.
        let pattern = "(?<![A-Za-z0-9_-])grok-[A-Za-z0-9][A-Za-z0-9._:-]*"
        let matches = try NSRegularExpression(pattern:pattern).matches(in:text,range:NSRange(text.startIndex...,in:text))
        let ids = Set(matches.compactMap { Range($0.range,in:text).map { String(text[$0]) } }).sorted()
        guard !ids.isEmpty else { throw AITranslationError.invalidResponse("无法解析 Grok 模型目录；不能判定为没有模型") }
        return ids.map { .init(id:$0,source:"grok-models") }
    }

    static func arguments(configuration: AITranslationConfiguration, promptFile: String, cwd: String) -> [String] {
        var args = ["--prompt-file", promptFile, "--model", configuration.model, "--output-format", "json",
                    "--json-schema", "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"lines\"],\"properties\":{\"lines\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"lineID\",\"translation\"],\"properties\":{\"lineID\":{\"type\":\"string\"},\"translation\":{\"type\":\"string\"}}}}}}",
                    "--cwd", cwd, "--permission-mode", "plan", "--no-subagents", "--disable-web-search"]
        if !configuration.grokReasoningEffort.isEmpty { args += ["--reasoning-effort", configuration.grokReasoningEffort] }
        return args
    }

    public func translate(context: AITranslationContext, sourceContentHash: String,
                          configuration: AITranslationConfiguration) async throws -> AITranslationDraft {
        guard configuration.isConfigured, let executable = resolveExecutable() else {
            throw AITranslationError.engineUnavailable("Grok Build CLI 未安装或未填写模型")
        }
        let prompt = try AITranslationPromptBuilder().build(context: context, configuration: configuration)
        return try await withProviderJob { job in
            let promptFile = job.appendingPathComponent("prompt.txt")
            try writePrivate(prompt.system + "\n\n" + prompt.user, to: promptFile)
            let result = try await executor.execute(executable: executable,
                arguments: Self.arguments(configuration: configuration, promptFile: promptFile.path, cwd: job.path),
                cwd: job, timeout: configuration.timeout, stdin: nil, environmentOverrides: [:])
            guard result.exitCode == 0 else { throw AITranslationError.engineUnavailable("Grok CLI 失败（退出码 \(result.exitCode)；\(result.failureSummary ?? "phase=unclassified；无可分类诊断")），未创建候选") }
            let output = try GrokBuildResponseParser.parse(result.stdout, expectedLines: context.lines,
                requestedModel: configuration.model, reasoningEffort: configuration.grokReasoningEffort)
            return Self.draft(output, context: context, sourceContentHash: sourceContentHash, configuration: configuration)
        }
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        guard resolveExecutable() != nil else { throw AITranslationError.engineUnavailable("未找到 Grok Build CLI") }
        guard !configuration.model.isEmpty else { throw AITranslationError.notConfigured }
        // This checks only the local binary; it does not authenticate or call a model.
    }

    private static func draft(_ output: ProviderTranslationOutput, context: AITranslationContext,
                              sourceContentHash: String, configuration: AITranslationConfiguration) -> AITranslationDraft {
        AITranslationDraft(lines: output.lines, targetLanguage: configuration.targetLanguage, model: output.model,
            baseURLHost: "grok-cli", promptHash: (try? AITranslationPromptBuilder().build(context: context, configuration: configuration).promptHash) ?? "",
            sourceContentHash: sourceContentHash, engineID: TranslationEngineID.grokBuild.rawValue,
            promptPresetID: configuration.promptPresetID, profileID: configuration.profileID,
            profileSnapshot: configuration.profileSnapshot, temperature: 0, workflowID: configuration.workflowID,
            fallbackStrategy: .none, isDraft: true, tokenUsage: output.tokenUsage,
            providerReasoningSetting: output.reasoningSetting)
    }
}

// MARK: - Gemini CLI

struct GeminiCLIStreamParser {
    static func parse(_ data: Data, expectedLines: [AITranslationSourceLine],
                      thinkingLevel: String, thinkingBudget: Int?) throws -> ProviderTranslationOutput {
        let completion = try completedResponse(data)
        let output = try JSONSerialization.jsonObject(with: Data(completion.text.utf8))
        guard let root = output as? [String: Any], Set(root.keys) == ["lines"], let lines = root["lines"] else {
            throw AITranslationError.invalidResponse("Gemini JSON 结果必须只包含 lines")
        }
        let validated = try AITranslationResponseParser.parseStable(JSONSerialization.data(withJSONObject: lines), expectedLines: expectedLines)
        let reasoning = !thinkingLevel.isEmpty ? "thinkingLevel=\(thinkingLevel)" : (thinkingBudget.map { "thinkingBudget=\($0)" } ?? "model-default")
        return ProviderTranslationOutput(lines: validated, model: completion.model, tokenUsage: completion.usage, reasoningSetting: reasoning)
    }

    struct Completion: Sendable {
        let text: String
        let model: String
        let usage: AITranslationTokenUsage?
    }

    static func completedResponse(_ data: Data) throws -> Completion {
        guard let text = String(data: data, encoding: .utf8) else { throw AITranslationError.invalidResponse("Gemini stream 不是 UTF-8") }
        var model = ""
        var response = ""
        var usage: AITranslationTokenUsage?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let event = try JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any],
                  let type = event["type"] as? String else {
                throw AITranslationError.invalidResponse("Gemini stream 含无效 JSONL 事件")
            }
            switch type {
            case "init": model = (event["model"] as? String) ?? (event["modelId"] as? String) ?? model
            case "message":
                if let role = event["role"] as? String, role != "assistant" { continue }
                if let delta = event["delta"] as? String { response += delta }
                else if let content = event["content"] as? String { response += content }
                else if let content = event["content"] as? [[String: Any]] {
                    response += content.compactMap { $0["text"] as? String }.joined()
                }
            case "tool_use", "tool_result":
                throw AITranslationError.engineUnavailable("Gemini 返回工具事件；本次候选已停止")
            case "error":
                throw AITranslationError.engineUnavailable("Gemini CLI 返回错误事件；本次候选已停止")
            case "result":
                if let actual = event["model"] as? String { model = actual }
                if let final = event["response"] as? String { response = final }
                usage = parseUsage(event["stats"] ?? event["usage"])
                if let status = event["status"] as? String, status.lowercased() != "success" {
                    throw AITranslationError.engineUnavailable("Gemini CLI 未成功完成本轮请求")
                }
            default:
                throw AITranslationError.engineUnavailable("Gemini 返回未知事件 (type)；本次候选已停止")
            }
        }
        guard !model.isEmpty, !response.isEmpty else { throw AITranslationError.invalidResponse("Gemini 未返回实际模型或最终文本") }
        return Completion(text: response, model: model, usage: usage)
    }

    private static func parseUsage(_ value: Any?) -> AITranslationTokenUsage? {
        guard let usage = value as? [String: Any],
              let input = (usage["input_tokens"] as? Int) ?? (usage["promptTokenCount"] as? Int),
              let output = (usage["output_tokens"] as? Int) ?? (usage["candidatesTokenCount"] as? Int),
              let total = (usage["total_tokens"] as? Int) ?? (usage["totalTokenCount"] as? Int) else { return nil }
        return AITranslationTokenUsage(inputTokens: input, outputTokens: output, totalTokens: total)
    }
}

public struct GeminiCLITranslationService: TranslationEngine, Sendable {
    static let executablePaths = TranslationCLIHost.searchDirectories.map { $0 + "/gemini" }
    private let candidates: [String]
    private let executor: any ProviderCLIExecuting

    public init(executableCandidates: [String]? = nil) {
        candidates = executableCandidates ?? Self.executablePaths
        executor = FoundationProviderCLIExecutor()
    }

    init(executableCandidates: [String], executor: any ProviderCLIExecuting) {
        candidates = executableCandidates
        self.executor = executor
    }

    func resolveExecutable() -> String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(stableID: TranslationEngineID.geminiCLI.rawValue, displayName: "Gemini CLI",
            availability: resolveExecutable() == nil ? .unavailable : .available, requiresAPIKey: false, supportsModelDirectory: false)
    }

    static func settingsFileContents(model: String, thinkingLevel: String, thinkingBudget: Int?, alias: String) throws -> String {
        guard thinkingLevel.isEmpty || thinkingBudget == nil, thinkingBudget.map({ $0 >= 0 }) ?? true else {
            throw AITranslationError.invalidResponse("Gemini thinkingLevel 与 thinkingBudget 只能设置一个，budget 不能为负数")
        }
        var generation: [String: Any] = [:]
        if !thinkingLevel.isEmpty { generation["thinkingConfig"] = ["thinkingLevel": thinkingLevel] }
        if let thinkingBudget { generation["thinkingConfig"] = ["thinkingBudget": thinkingBudget] }
        var modelConfig: [String: Any] = ["model": model]
        if !generation.isEmpty { modelConfig["generateContentConfig"] = generation }
        let payload: [String: Any] = ["modelConfigs": ["customAliases": [alias: ["modelConfig": modelConfig]]]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func arguments(alias: String, prompt: String) -> [String] {
        ["--model", alias, "--output-format", "stream-json", "--prompt", prompt,
         "--approval-mode", "plan", "--extensions", "none"]
    }

    public func translate(context: AITranslationContext, sourceContentHash: String,
                          configuration: AITranslationConfiguration) async throws -> AITranslationDraft {
        guard configuration.isConfigured, resolveExecutable() != nil else {
            throw AITranslationError.engineUnavailable("Gemini CLI 未安装或未填写模型；本阶段不会自动安装或登录")
        }
        let prompt = try AITranslationPromptBuilder().build(context: context, configuration: configuration)
        let output = try await completeResponse(prompt: prompt, configuration: configuration)
        let data = try JSONSerialization.jsonObject(with: Data(output.text.utf8))
        guard let root = data as? [String: Any], Set(root.keys) == ["lines"], let lines = root["lines"] else {
            throw AITranslationError.invalidResponse("Gemini JSON 结果必须只包含 lines")
        }
        let validated = try AITranslationResponseParser.parseStable(JSONSerialization.data(withJSONObject: lines), expectedLines: context.lines)
        let reasoning = !configuration.geminiThinkingLevel.isEmpty ? "thinkingLevel=\(configuration.geminiThinkingLevel)" : (configuration.geminiThinkingBudget.map { "thinkingBudget=\($0)" } ?? "model-default")
        return AITranslationDraft(lines: validated, targetLanguage: configuration.targetLanguage, model: output.model,
            baseURLHost: "gemini-cli", promptHash: prompt.promptHash, sourceContentHash: sourceContentHash,
            engineID: TranslationEngineID.geminiCLI.rawValue, promptPresetID: configuration.promptPresetID,
            profileID: configuration.profileID, profileSnapshot: configuration.profileSnapshot, temperature: 0,
            workflowID: configuration.workflowID, fallbackStrategy: .none, isDraft: true,
            tokenUsage: output.usage, providerReasoningSetting: reasoning)
    }

    func complete(prompt: AITranslationPrompt, configuration: AITranslationConfiguration) async throws -> Data {
        Data(try await completeResponse(prompt: prompt, configuration: configuration).text.utf8)
    }

    private func completeResponse(prompt: AITranslationPrompt, configuration: AITranslationConfiguration) async throws -> GeminiCLIStreamParser.Completion {
        guard configuration.isConfigured, let executable = resolveExecutable() else {
            throw AITranslationError.engineUnavailable("Gemini CLI 未安装或未填写模型")
        }
        try Task.checkCancellation()
        return try await withProviderJob { job in
            let alias = "spotifylyrics-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let geminiDirectory = job.appendingPathComponent(".gemini", isDirectory: true)
            try FileManager.default.createDirectory(at: geminiDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let settings = try Self.settingsFileContents(model: configuration.model,
                thinkingLevel: configuration.geminiThinkingLevel, thinkingBudget: configuration.geminiThinkingBudget, alias: alias)
            try writePrivate(settings, to: geminiDirectory.appendingPathComponent("settings.json"))
            let result = try await executor.execute(executable: executable,
                arguments: Self.arguments(alias: alias, prompt: prompt.system + "\n\n" + prompt.user), cwd: job,
                timeout: configuration.timeout, stdin: nil, environmentOverrides: [:])
            guard result.exitCode == 0 else { throw AITranslationError.engineUnavailable("Gemini CLI 失败（退出码 \(result.exitCode)），未创建候选") }
            let output = try GeminiCLIStreamParser.completedResponse(result.stdout)
            guard output.model == configuration.model else { throw AITranslationError.invalidResponse("Gemini 实际模型与设置模型不一致") }
            try Task.checkCancellation()
            return output
        }
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        guard resolveExecutable() != nil else { throw AITranslationError.engineUnavailable("未找到 Gemini CLI；本阶段不会自动安装或发起登录") }
        guard !configuration.model.isEmpty else { throw AITranslationError.notConfigured }
        // This checks only the local binary; it does not authenticate or call a model.
    }
}

// MARK: - Antigravity CLI (Gemini)

struct AntigravityCLIStreamParser {
    /// Observed stream policy, not a guarantee that an event precedes a tool's side effect.
    private static func label(_ value: Any?, known: Set<String>) -> String {
        guard let text = value as? String else { return "missing" }
        if known.contains(text) { return text }
        // Unknown labels may contain arbitrary provider/model text. Preserve a
        // comparable identity, never their text, tool arguments, or error body.
        let hash = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "unknown#" + hash
    }
    private static func stop(category: String, event: String, step: String = "n/a", state: String = "n/a") -> AITranslationError {
        .engineUnavailable("Antigravity 客户端工具/协议检查停止：event=\(event); step=\(step); state=\(state); category=\(category); phase=stream-monitor。未自动重试或切换提供方")
    }
    static func validateEvent(_ data:Data) throws {
        guard let event=try JSONSerialization.jsonObject(with:data) as? [String:Any],let kind=event["event"] as? String else {
            throw AITranslationError.invalidResponse("Antigravity stream 含无效事件；phase=stream-monitor; category=invalid-event")
        }
        switch kind {
        case "init":
            let payload=event["init"] as? [String:Any] ?? [:]
            guard ["request-review","strict"].contains(payload["permission_mode"] as? String ?? ""),payload["agent"]==nil else {
                throw stop(category: payload["agent"] == nil ? "permission-policy" : "subagent", event: kind)
            }
        case "step_update":
            let step=event["step_update"] as? [String:Any] ?? [:]
            let type = label(step["step_type"], known: ["user_input","agent_response","checkpoint","tool","tool_call","subagent"])
            let state = label(step["state"], known: ["ACTIVE","DONE","ERROR","FAILED","PENDING"])
            if step["subagent_info"] != nil || type == "subagent" { throw stop(category: "subagent", event: kind, step: type, state: state) }
            if step["tool_name"] != nil || step["tool_info"] != nil || ["tool","tool_call"].contains(type) { throw stop(category: "tool", event: kind, step: type, state: state) }
            guard ["user_input","agent_response","checkpoint"].contains(type) else { throw stop(category: "unknown-step", event: kind, step: type, state: state) }
            if step["error"] != nil { throw stop(category: "provider-step-error-unclassified", event: kind, step: type, state: state) }
        case "result":
            if let result=event["result"] as? [String:Any], (result["status"] as? String) != "SUCCESS" {
                throw stop(category: "provider-result-error-unclassified", event: kind,
                           state: label(result["status"], known: ["ERROR","FAILED","CANCELLED","TIMEOUT","AUTHENTICATION_REQUIRED","PERMISSION_DENIED"]))
            }
        default:throw stop(category: "unknown-event", event: label(kind,known: ["init","step_update","result"]))
        }
    }
    static func parse(_ data: Data, expectedLines: [AITranslationSourceLine], requestedModel: String,
                      effort: String) throws -> ProviderTranslationOutput {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AITranslationError.invalidResponse("Antigravity stream 不是 UTF-8")
        }
        var model = ""
        var resultPayload: [String: Any]?
        var sawResult = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            try validateEvent(Data(rawLine.utf8))
            guard let event = try JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any],
                  let kind = event["event"] as? String else {
                throw AITranslationError.invalidResponse("Antigravity stream 含无效 JSONL 事件")
            }
            switch kind {
            case "init":
                let initPayload = event["init"] as? [String: Any] ?? [:]
                if let actual = initPayload["model"] as? String { model = actual }
            case "step_update":
                let step = event["step_update"] as? [String: Any] ?? [:]
                if step["subagent_info"] != nil || (step["step_type"] as? String) == "tool" {
                    throw AITranslationError.engineUnavailable("Antigravity 尝试调用工具或子代理；本次候选已停止")
                }
                if let error = step["error"] { throw AITranslationError.engineUnavailable("Antigravity 步骤失败：\(String(describing: error))") }
            case "result":
                guard !sawResult, let result = event["result"] as? [String: Any] else {
                    throw AITranslationError.invalidResponse("Antigravity 缺少唯一的最终结果")
                }
                sawResult = true
                guard (result["status"] as? String) == "SUCCESS" else {
                    throw AITranslationError.engineUnavailable("Antigravity 未成功完成：\(result["status"] as? String ?? "unknown")")
                }
                resultPayload = result
            default:
                throw AITranslationError.engineUnavailable("Antigravity 返回未知事件；本次候选已停止")
            }
        }
        guard sawResult, !model.isEmpty, model == requestedModel, let result = resultPayload,
              let structured = result["structured_output"] as? [String: Any],
              Set(structured.keys) == ["lines"], let lines = structured["lines"] else {
            throw AITranslationError.invalidResponse("Antigravity 未返回成功状态、所选模型 ID 或严格结构化结果")
        }
        let validated = try AITranslationResponseParser.parseStable(
            JSONSerialization.data(withJSONObject: lines), expectedLines: expectedLines)
        let usageValue = result["usage"] as? [String: Any]
        let usage: AITranslationTokenUsage?
        if let usageValue,
           let input = usageValue["input_tokens"] as? Int,
           let output = usageValue["output_tokens"] as? Int,
           let total = usageValue["total_tokens"] as? Int {
            usage = AITranslationTokenUsage(inputTokens: input,
                cachedInputTokens: usageValue["cache_read_tokens"] as? Int ?? 0,
                outputTokens: output,
                reasoningOutputTokens: usageValue["thinking_tokens"] as? Int ?? 0,
                totalTokens: total)
        } else {
            usage = nil
        }
        return ProviderTranslationOutput(lines: validated, model: model, tokenUsage: usage,
            reasoningSetting: "effort=" + (effort.isEmpty ? "model-default" : effort))
    }
}

public struct AntigravityCLITranslationService: TranslationEngine, Sendable {
    static let executablePaths = TranslationCLIHost.searchDirectories.map { $0 + "/agy" }
    private let candidates: [String]
    private let executor: any ProviderCLIExecuting

    public init(executableCandidates: [String]? = nil) {
        candidates = executableCandidates ?? Self.executablePaths
        executor = FoundationProviderCLIExecutor(antigravityEvents:true)
    }

    init(executableCandidates: [String], executor: any ProviderCLIExecuting) {
        candidates = executableCandidates
        self.executor = executor
    }

    func resolveExecutable() -> String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(stableID: TranslationEngineID.antigravityCLI.rawValue,
            displayName: "Gemini（Antigravity CLI）",
            availability: resolveExecutable() == nil ? .unavailable : .available,
            requiresAPIKey: false, supportsModelDirectory: true)
    }

    public func listModels() async throws -> [TranslationModelDescriptor] {
        guard let executable=resolveExecutable() else { throw AITranslationError.engineUnavailable("未找到 agy；请安装 Antigravity CLI") }
        return try await withProviderJob { job in
            let result=try await executor.execute(executable:executable,arguments:["models"],cwd:job,timeout:30,stdin:nil,environmentOverrides:[:])
            guard result.exitCode==0 else { throw AITranslationError.engineUnavailable("agy 模型目录读取失败（退出码 \(result.exitCode)）；请核实 CLI 登录") }
            return try Self.parseModels(result.stdout)
        }
    }

    static func parseModels(_ data:Data) throws -> [TranslationModelDescriptor] {
        guard let text=String(data:data,encoding:.utf8) else { throw AITranslationError.invalidResponse("agy 模型目录不是 UTF-8") }
        var result:[TranslationModelDescriptor]=[],seen=Set<String>()
        for row in text.split(whereSeparator:\.isNewline) {
            let columns=row.split(separator:"\t",maxSplits:1,omittingEmptySubsequences:false)
            guard columns.count==2 else { throw AITranslationError.invalidResponse("agy 模型目录格式未知；不能当作空目录") }
            let id=String(columns[0]).trimmingCharacters(in:.whitespacesAndNewlines)
            let name=String(columns[1]).trimmingCharacters(in:.whitespacesAndNewlines)
            guard !id.isEmpty,!name.isEmpty,id.range(of:#"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#,options:.regularExpression) != nil,seen.insert(id).inserted else {
                throw AITranslationError.invalidResponse("agy 模型目录含无效或重复 ID")
            }
            // Native `models` supplies ID/name only. Labels are not capability fields.
            result.append(.init(id:id,displayName:name,source:"antigravity-cli-models",reasoningEfforts:nil))
        }
        return result
    }

    static let jsonSchema = """
    {"type":"object","additionalProperties":false,"required":["lines"],"properties":{"lines":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["lineID","translation"],"properties":{"lineID":{"type":"string"},"translation":{"type":"string"}}}}}}
    """

    static func arguments(configuration: AITranslationConfiguration) -> [String] {
        var args = ["--input-format", "stream-json", "--output-format", "stream-json",
                    "--json-schema", jsonSchema, "--model", configuration.model, "--sandbox",
                    "--mode", "plan", "--disable-slash-commands", "--print-timeout", "\(Int(configuration.timeout))s"]
        if !configuration.antigravityEffort.isEmpty { args += ["--effort", configuration.antigravityEffort] }
        return args
    }

    public func translate(context: AITranslationContext, sourceContentHash: String,
                          configuration: AITranslationConfiguration) async throws -> AITranslationDraft {
        guard configuration.isConfigured, let executable = resolveExecutable() else {
            throw AITranslationError.engineUnavailable("Antigravity CLI (agy) 未安装或未填写模型；本阶段不会自动安装或登录")
        }
        guard configuration.antigravityEffort.isEmpty || ["low", "medium", "high", "xhigh", "max"].contains(configuration.antigravityEffort) else {
            throw AITranslationError.invalidResponse("Antigravity 1.3.1 --effort 只接受 low/medium/high/xhigh/max")
        }
        let prompt = try AITranslationPromptBuilder().build(context: context, configuration: configuration)
        let message = try JSONSerialization.data(withJSONObject: [
            "event": "user", "message": ["content": prompt.system + "\n\n" + prompt.user]
        ], options: [.sortedKeys]) + Data([0x0A])
        return try await withProviderJob { job in
            let result = try await executor.execute(executable: executable,
                arguments: Self.arguments(configuration: configuration), cwd: job,
                timeout: configuration.timeout, stdin: message, environmentOverrides: [:])
            guard result.exitCode == 0 else {
                throw AITranslationError.engineUnavailable("Antigravity CLI 失败（退出码 \(result.exitCode)），未创建候选")
            }
            let output = try AntigravityCLIStreamParser.parse(result.stdout, expectedLines: context.lines,
                requestedModel: configuration.model, effort: configuration.antigravityEffort)
            return AITranslationDraft(lines: output.lines, targetLanguage: configuration.targetLanguage,
                model: output.model, baseURLHost: "antigravity-cli", promptHash: prompt.promptHash,
                sourceContentHash: sourceContentHash, engineID: TranslationEngineID.antigravityCLI.rawValue,
                promptPresetID: configuration.promptPresetID, profileID: configuration.profileID,
                profileSnapshot: configuration.profileSnapshot, temperature: 0, workflowID: configuration.workflowID,
                fallbackStrategy: .none, isDraft: true, tokenUsage: output.tokenUsage,
                providerReasoningSetting: output.reasoningSetting)
        }
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        guard resolveExecutable() != nil else {
            throw AITranslationError.engineUnavailable("未找到 Antigravity CLI（agy）；不会自动安装或发起登录")
        }
        guard !configuration.model.isEmpty else { throw AITranslationError.notConfigured }
        // Local binary/model presence only; no auth check or model request.
    }
}

// MARK: - DeepSeek API

struct DeepSeekTranslationRequestBuilder {
    static func body(prompt: AITranslationPrompt, configuration: AITranslationConfiguration) throws -> Data {
        guard ["model-default", "enabled", "disabled"].contains(configuration.deepSeekThinkingMode) else {
            throw AITranslationError.invalidResponse("DeepSeek 原生推理设置无效")
        }
        let effort = configuration.deepSeekReasoningEffort
        guard effort.isEmpty || ["none", "low", "high", "max"].contains(effort) else {
            throw AITranslationError.invalidResponse("DeepSeek reasoning_effort 只接受 none/low/high/max")
        }
        if configuration.deepSeekThinkingMode == "enabled" && effort == "none" {
            throw AITranslationError.invalidResponse("DeepSeek thinking=enabled 与 reasoning_effort=none 冲突")
        }
        if configuration.deepSeekThinkingMode == "disabled" && !effort.isEmpty && effort != "none" {
            throw AITranslationError.invalidResponse("DeepSeek thinking=disabled 与非 none effort 冲突")
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [["role": "system", "content": prompt.system], ["role": "user", "content": prompt.user]],
            "response_format": ["type": "json_object"],
            "max_tokens": 4096,
            "tool_choice": "none"
        ]
        if configuration.deepSeekThinkingMode != "model-default" {
            body["thinking"] = ["type": configuration.deepSeekThinkingMode]
        }
        if !effort.isEmpty { body["reasoning_effort"] = effort }
        if configuration.deepSeekThinkingMode == "disabled" {
            body["temperature"] = configuration.temperature
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

struct DeepSeekTranslationResponseParser {
    static func parse(_ data: Data, expectedLines: [AITranslationSourceLine], requestedModel: String,
                      thinkingMode: String, reasoningEffort: String) throws -> ProviderTranslationOutput {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? String, model == requestedModel,
              let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, let finish = choice["finish_reason"] as? String,
              finish == "stop", let message = choice["message"] as? [String: Any],
              message["tool_calls"] == nil || (message["tool_calls"] as? [Any])?.isEmpty == true,
              let content = message["content"] as? String else {
            throw AITranslationError.invalidResponse("DeepSeek 未正常完成、模型 ID 不符、发生工具调用或响应字段无效")
        }
        let decoded = try JSONSerialization.jsonObject(with: Data(content.utf8))
        guard let result = decoded as? [String: Any], Set(result.keys) == ["lines"], let lines = result["lines"] else {
            throw AITranslationError.invalidResponse("DeepSeek JSON 输出必须只包含 lines")
        }
        let stable = try JSONSerialization.data(withJSONObject: lines)
        let validated = try AITranslationResponseParser.parseStable(stable, expectedLines: expectedLines)
        let usage = usageValue(root["usage"])
        let mode = thinkingMode.isEmpty ? "model-default" : thinkingMode
        let effort = reasoningEffort.isEmpty ? "model-default" : reasoningEffort
        return ProviderTranslationOutput(lines: validated, model: model, tokenUsage: usage,
            reasoningSetting: "thinking=\(mode);reasoning_effort=\(effort)")
    }

    private static func usageValue(_ value: Any?) -> AITranslationTokenUsage? {
        guard let usage = value as? [String: Any],
              let input = usage["prompt_tokens"] as? Int,
              let output = usage["completion_tokens"] as? Int,
              let total = usage["total_tokens"] as? Int else { return nil }
        let details = usage["completion_tokens_details"] as? [String: Any]
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let cached = (promptDetails?["cached_tokens"] as? Int) ?? (usage["prompt_cache_hit_tokens"] as? Int) ?? 0
        let reasoning = details?["reasoning_tokens"] as? Int ?? 0
        return AITranslationTokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                                       reasoningOutputTokens: reasoning, totalTokens: total)
    }
}

public struct DeepSeekTranslationService: TranslationEngine, Sendable {
    public static let keychainAccount = "deepseek-api.v1"
    public static let defaultBaseURL = "https://api.deepseek.com"
    private let httpClient: any AIHTTPClient
    private let keyStore: any AITranslationAPIKeyStore

    public init(httpClient: any AIHTTPClient = URLSession.shared,
                keyStore: any AITranslationAPIKeyStore = KeychainAITranslationAPIKeyStore(account: keychainAccount)) {
        self.httpClient = httpClient
        self.keyStore = keyStore
    }

    public var metadata: TranslationEngineMetadata {
        TranslationEngineMetadata(stableID: TranslationEngineID.deepSeekAPI.rawValue, displayName: "DeepSeek API",
            availability: .requiresConfiguration, requiresAPIKey: true, supportsModelDirectory: true)
    }

    func resolvedURL(configuration: AITranslationConfiguration) throws -> URL {
        let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultBaseURL : configuration.baseURL
        var value = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix("/chat/completions") {
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), url.host != nil else { throw AITranslationError.invalidEndpoint }
            return url
        }
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), url.host != nil,
              url.query == nil, url.fragment == nil else { throw AITranslationError.invalidEndpoint }
        return URL(string: value + "/chat/completions")!
    }

    public func translate(context: AITranslationContext, sourceContentHash: String,
                          configuration: AITranslationConfiguration) async throws -> AITranslationDraft {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AITranslationError.notConfigured }
        guard let key = keyStore.read(), !key.isEmpty else { throw AITranslationError.missingAPIKey }
        let prompt = try AITranslationPromptBuilder().build(context: context, configuration: configuration)
        var request = URLRequest(url: try resolvedURL(configuration: configuration))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try DeepSeekTranslationRequestBuilder.body(prompt: prompt, configuration: configuration)
        do {
            let (data, response) = try await httpClient.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                switch status {
                case 401, 403: throw AITranslationError.unauthorized
                case 429: throw AITranslationError.rateLimited
                default: throw AITranslationError.server(status)
                }
            }
            let output = try DeepSeekTranslationResponseParser.parse(data, expectedLines: context.lines,
                requestedModel: configuration.model, thinkingMode: configuration.deepSeekThinkingMode,
                reasoningEffort: configuration.deepSeekReasoningEffort)
            return AITranslationDraft(lines: output.lines, targetLanguage: configuration.targetLanguage, model: output.model,
                baseURLHost: (request.url?.host ?? "api.deepseek.com"), promptHash: prompt.promptHash,
                sourceContentHash: sourceContentHash, engineID: TranslationEngineID.deepSeekAPI.rawValue,
                promptPresetID: configuration.promptPresetID, profileID: configuration.profileID,
                profileSnapshot: configuration.profileSnapshot, temperature: 0, workflowID: configuration.workflowID,
                fallbackStrategy: .none, isDraft: true, tokenUsage: output.tokenUsage,
                providerReasoningSetting: output.reasoningSetting)
        } catch is CancellationError { throw AITranslationError.cancelled }
        catch let error as URLError where error.code == .timedOut { throw AITranslationError.timedOut }
        catch let error as AITranslationError { throw error }
        catch { throw AITranslationError.network(error.localizedDescription) }
    }

    public func testConnection(configuration: AITranslationConfiguration) async throws {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AITranslationError.notConfigured }
        _ = try resolvedURL(configuration: configuration)
        // Deliberately performs no Keychain read and no potentially chargeable API request.
    }
}
