import Foundation
import Combine
import Darwin

public struct TranslationCLIInspection: Equatable, Sendable {
    public let path: String?
    public let version: String?
    public let reason: String
    public init(path:String?=nil,version:String?=nil,reason:String="") { self.path=path;self.version=version;self.reason=reason }
}

public struct TranslationCLIInstallPlan: Identifiable, Sendable {
    public let engineID: String
    public let title: String
    public let documentation: URL
    public let package: String?
    public let explanation: String
    public var id:String { engineID }
    public static func forProvider(_ id:String) -> Self? {
        switch TranslationEngineID(rawValue:id) {
        case .codexChatGPT:
            return .init(engineID:id,title:"Codex CLI",documentation:URL(string:"https://learn.chatgpt.com/docs/codex/cli")!,package:nil,
                explanation:"官方提供原生安装脚本。本版未验证脚本的完整写入范围，请按官方说明安装；不会在后台执行脚本。完成后重新检测，登录另行进行。")
        case .grokBuild:
            return .init(engineID:id,title:"Grok Build CLI",documentation:URL(string:"https://docs.x.ai/build/enterprise")!,package:"@xai-official/grok",
                explanation:"使用官方列出的 npm 包，下载稳定版并安装到本用户的 SpotifyLyrics/TranslationCLI 目录。包安装步骤可能执行供应商脚本；不使用 sudo，不更改 shell 配置，不自动登录。需已有 Node.js 20+ 与 npm；不会自动安装依赖或包管理器。")
        case .geminiCLI:
            return .init(engineID:id,title:"Gemini CLI",documentation:URL(string:"https://geminicli.com/docs/get-started/installation/")!,package:"@google/gemini-cli",
                explanation:"使用官方 npm 包，下载稳定版并安装到本用户的 SpotifyLyrics/TranslationCLI 目录。包安装步骤可能执行供应商脚本；不使用 sudo，不更改 shell 配置，不自动登录。需已有 Node.js 20+ 与 npm；不会自动安装依赖或包管理器。")
        case .antigravityCLI:
            return .init(engineID:id,title:"Gemini（Antigravity CLI）",documentation:URL(string:"https://www.antigravity.google/docs/cli/install/")!,package:nil,
                explanation:"官方提供原生脚本及 skip-path/skip-aliases 选项。本版未验证脚本的完整写入范围，请按官方说明安装；桌面 App 不等于 agy CLI。完成后重新检测，登录另行进行。")
        default:return nil
        }
    }
}

/// Only local version detection and explicit setup. No login, model or authentication operations.
public final class TranslationCLISetupStore: ObservableObject {
    public typealias Inspector = @Sendable (String) async throws -> TranslationCLIInspection
    public typealias Progress = @Sendable (String) -> Void
    public typealias Installer = @Sendable (TranslationCLIInstallPlan,Progress) async throws -> Void
    @Published public private(set) var inspections: [String:TranslationCLIInspection] = [:]
    @Published public private(set) var busy: [String:String] = [:]
    @Published public private(set) var messages: [String:String] = [:]
    private let inspector: Inspector
    private let installer: Installer
    private var tasks: [String:Task<Void,Never>] = [:]
    private var generations: [String:UUID] = [:]
    public init(inspector:Inspector?=nil,installer:Installer?=nil) {
        self.inspector=inspector ?? { try await TranslationCLISetupBackend().inspect($0) }
        self.installer=installer ?? { try await TranslationCLISetupBackend().install($0,progress:$1) }
    }
    public func detect(_ id:String, force:Bool=false) {
        guard TranslationCLIInstallPlan.forProvider(id) != nil, busy[id] == nil,
              force || inspections[id] == nil else { return }
        start(id,install:nil)
    }
    /// Called only after the install sheet's explicit confirmation button.
    public func install(_ plan:TranslationCLIInstallPlan) {
        guard plan.package != nil, busy[plan.engineID] == nil else { return }
        start(plan.engineID,install:plan)
    }
    public func cancel(_ id:String) {
        generations[id]=UUID();tasks[id]?.cancel();tasks[id]=nil;busy[id]=nil
        messages[id]="操作已取消；若安装已开始，已写入的包文件可能保留，请重新检测。"
    }
    private func start(_ id:String,install:TranslationCLIInstallPlan?) {
        let token=UUID();generations[id]=token;messages[id]=""
        busy[id]=install == nil ? "正在检测版本…" : "正在检查依赖并安装…"
        let inspector=inspector,installer=installer
        tasks[id]=Task { @MainActor [weak self] in
            do {
                if let install {
                    try await installer(install) { [weak self] message in
                        Task { @MainActor in
                            guard let self,self.generations[id]==token,self.tasks[id] != nil else { return };self.busy[id]=message
                        }
                    }
                    guard let self,self.generations[id]==token,!Task.isCancelled else { return }
                    self.busy[id]="安装步骤结束，正在重新检测版本…"
                }
                let result=try await inspector(id)
                guard let self,self.generations[id]==token,!Task.isCancelled else { return }
                self.inspections[id]=result;self.busy[id]=nil;self.tasks[id]=nil
                self.messages[id]=install == nil ? "" : (result.version == nil ? "安装步骤结束，但未能确认 CLI 版本。" : "安装完成；下一步可读取模型列表。登录与模型权限尚未验证。")
            } catch {
                guard let self,self.generations[id]==token,!Task.isCancelled else { return }
                self.busy[id]=nil;self.tasks[id]=nil;self.messages[id]=TranslationCLISetupFailure.userMessage(for:error)
            }
        }
    }
}

struct TranslationCLISetupBackend: Sendable {
    static var prefix:String { NSHomeDirectory()+"/Library/Application Support/SpotifyLyrics/TranslationCLI" }
    static var bin:String { prefix+"/bin" }
    private static var environment:[String:String] {
        ["HOME":NSHomeDirectory(),"PATH":bin+":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin","LANG":"en_US.UTF-8"]
    }
    private let resolver: @Sendable (String) -> String?
    private let probeTimeout:TimeInterval
    init(resolver:(@Sendable (String)->String?)?=nil,probeTimeout:TimeInterval=8) { self.resolver=resolver ?? { Self.resolve($0) };self.probeTimeout=probeTimeout }
    static func resolve(_ id:String) -> String? {
        let path:String?
        switch TranslationEngineID(rawValue:id) {
        case .codexChatGPT:path=try? CodexAppServerTranslationService().resolveExecutable()
        case .grokBuild:path=GrokBuildTranslationService().resolveExecutable()
        case .geminiCLI:path=GeminiCLITranslationService().resolveExecutable()
        case .antigravityCLI:path=AntigravityCLITranslationService().resolveExecutable()
        default:return nil
        }
        return path
    }
    func inspect(_ id:String) async throws -> TranslationCLIInspection {
        guard let path=resolver(id) else { return .init(reason:id == TranslationEngineID.antigravityCLI.rawValue ? "未找到 agy；Antigravity 桌面 App 不包含此 CLI。" : "未找到 \(TranslationCLIInstallPlan.forProvider(id)?.title ?? "本机 CLI") 可执行文件。") }
        do {
            let output=try await run(path,["--version"],timeout:probeTimeout)
            let regex=try NSRegularExpression(pattern:#"(?:^|\s)v?(\d+\.\d+(?:\.\d+)?)(?:$|[\s-])"#)
            let version=output.split(whereSeparator:\.isNewline).compactMap { line -> String? in
                let value=String(line)
                guard let match=regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)),
                      let range=Range(match.range(at:1),in:value) else { return nil }
                return String(value[range])
            }.first
            guard let version else {
                return .init(path:path,reason:"已找到可执行文件，但无法识别版本输出；请查看官方安装说明。")
            }
            return .init(path:path,version:version)
        } catch AITranslationError.cancelled { throw AITranslationError.cancelled }
        catch { return .init(path:path,reason:"已找到CLI，版本检测失败："+TranslationCLISetupFailure.userMessage(for:error)) }
    }
    func install(_ plan:TranslationCLIInstallPlan,progress:TranslationCLISetupStore.Progress) async throws {
        progress("正在检查 Node.js 与 npm…")
        guard let official=TranslationCLIInstallPlan.forProvider(plan.engineID), let package=official.package,
              package==plan.package else { throw AITranslationError.engineUnavailable("此提供方仅支持打开官方安装说明") }
        let fm=FileManager.default
        guard let node=["/opt/homebrew/bin/node","/usr/local/bin/node"].first(where:{fm.isExecutableFile(atPath:$0)}),
              let npm=["/opt/homebrew/bin/npm","/usr/local/bin/npm"].first(where:{fm.isExecutableFile(atPath:$0)}) else {
            throw AITranslationError.engineUnavailable("需要已有 Node.js 20+ 和 npm；未自动安装。请安装依赖后重试，或打开官方说明。")
        }
        let version=try await run(node,["--version"],timeout:8)
        guard let major=Int(version.trimmingCharacters(in:.whitespacesAndNewlines).dropFirst().split(separator:".").first ?? ""),major>=20 else {
            throw AITranslationError.engineUnavailable("当前 Node.js 低于20；未安装CLI，请先处理依赖。")
        }
        progress("正在从官方 npm 包源下载并安装…")
        _=try await run(npm,["install","--global","--prefix",Self.prefix,"--cache",Self.prefix+"/cache","--userconfig","/dev/null","--globalconfig","/dev/null","--registry","https://registry.npmjs.org",package+"@latest"],timeout:300)
    }
    private static func withCStringPointers<T>(_ strings:[String],body:(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>)->T) -> T {
        var pointers=strings.map { strdup($0) }+[nil]
        defer { pointers.dropLast().forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
    private func run(_ executable:String,_ arguments:[String],timeout:TimeInterval) async throws -> String {
        let owner=CLISetupProcessOwner()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await Task.detached {
                let cwd=FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-cli-setup-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:cwd,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                defer { try? FileManager.default.removeItem(at:cwd) }
                let pipe=Pipe()
                var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
                posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attributes)
                defer { posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes) }
                posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP))
                posix_spawnattr_setpgroup(&attributes,0) // Owned root and its ordinary descendants have one group.
                posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0)
                let readFD=pipe.fileHandleForReading.fileDescriptor,writeFD=pipe.fileHandleForWriting.fileDescriptor
                posix_spawn_file_actions_adddup2(&actions,writeFD,STDOUT_FILENO)
                posix_spawn_file_actions_adddup2(&actions,writeFD,STDERR_FILENO)
                posix_spawn_file_actions_addclose(&actions,readFD)
                posix_spawn_file_actions_addclose(&actions,writeFD)
                if #available(macOS 26,*) { posix_spawn_file_actions_addchdir(&actions,cwd.path) }
                else { posix_spawn_file_actions_addchdir_np(&actions,cwd.path) }
                var pid:pid_t=0
                let error=Self.withCStringPointers([executable]+arguments) { argv in
                    Self.withCStringPointers(Self.environment.map { $0.key+"="+$0.value }) { env in
                        posix_spawn(&pid,executable,&actions,&attributes,argv,env)
                    }
                }
                try pipe.fileHandleForWriting.close()
                guard error==0 else { throw TranslationCLISetupProcessFailure.launchFailed }
                owner.install(pid)
                let timer=DispatchWorkItem { owner.stop(timeout:true) }
                DispatchQueue.global().asyncAfter(deadline:.now()+timeout,execute:timer)
                var tail=Data(),bytes=[UInt8](repeating:0,count:4096)
                while true {
                    let n=Darwin.read(readFD,&bytes,bytes.count)
                    if n>0 { tail.append(contentsOf:bytes.prefix(n));if tail.count>16000 { tail=Data(tail.suffix(16000)) } }
                    else if n<0 && errno==EINTR { continue }
                    else { break }
                }
                var status:Int32=0
                while waitpid(pid,&status,0)<0 && errno==EINTR {}
                timer.cancel();owner.finished()
                if owner.cancelled { throw AITranslationError.cancelled }
                if owner.timedOut { throw AITranslationError.timedOut }
                let code=(status & 0x7f)==0 ? (status>>8)&0xff : 128+(status & 0x7f)
                guard code==0 else { throw TranslationCLISetupProcessFailure.commandFailed(exitCode:code) }
                return String(decoding:tail,as:UTF8.self)
            }.value
        },onCancel:{owner.stop(timeout:false)})
    }
}

enum TranslationCLISetupFailure {
    static func userMessage(for error:Error) -> String {
        if let failure=error as? TranslationCLISetupProcessFailure {
            return failure.localizedDescription
        }
        if let translationError=error as? AITranslationError {
            switch translationError {
            case .cancelled: return "操作已取消。"
            case .timedOut: return "CLI 操作超时；请重新检测或查看官方安装说明。"
            default: break
            }
        }
        return "CLI 操作失败；请查看官方安装说明并重试。"
    }
}

enum TranslationCLISetupProcessFailure: Error, Sendable, LocalizedError {
    case commandFailed(exitCode:Int32)
    case launchFailed

    var errorDescription:String? {
        switch self {
        case .commandFailed(let exitCode): return "命令失败（退出码 \(exitCode)）；原始输出已隐藏。"
        case .launchFailed: return "无法启动 CLI 命令；原始系统错误已隐藏。"
        }
    }
}

private final class CLISetupProcessOwner: @unchecked Sendable {
    private let lock=NSLock();private var pid:pid_t?
    private var didCancel=false,didTimeout=false
    var cancelled:Bool { lock.lock();defer{lock.unlock()};return didCancel }
    var timedOut:Bool { lock.lock();defer{lock.unlock()};return didTimeout }
    func install(_ value:pid_t) { lock.lock();pid=value;let stop=didCancel || didTimeout;lock.unlock();if stop { terminate(value) } }
    func finished() { lock.lock();pid=nil;lock.unlock() }
    func stop(timeout:Bool) { lock.lock();if timeout { didTimeout=true } else { didCancel=true };let p=pid;lock.unlock();if let p { terminate(p) } }
    private func terminate(_ owned:pid_t) {
        kill(-owned,SIGTERM)
        DispatchQueue.global().asyncAfter(deadline:.now()+0.5) { [self] in
            lock.lock();let active=pid==owned;lock.unlock()
            if active { kill(-owned,SIGKILL) }
        }
    }
}
