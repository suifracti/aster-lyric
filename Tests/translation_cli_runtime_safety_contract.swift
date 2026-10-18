import Foundation

@main
@MainActor
struct TranslationCLIRuntimeSafetyContract {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-cli-safety-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousCLIHome = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_TRANSLATION_CLI_HOME"]
        setenv("SPOTIFYLYRICS_TRANSLATION_CLI_HOME", root.path, 1)
        defer {
            if let previousCLIHome { setenv("SPOTIFYLYRICS_TRANSLATION_CLI_HOME", previousCLIHome, 1) }
            else { unsetenv("SPOTIFYLYRICS_TRANSLATION_CLI_HOME") }
        }
        precondition(TranslationCLIHost.homeDirectory == root.path)
        let child = TranslationCLIHost.childEnvironment(from: ["CFFIXED_USER_HOME": "/private/app-data", "TMPDIR": root.path])
        precondition(child["HOME"] == root.path && child["CFFIXED_USER_HOME"] == nil)
        precondition(child["TMPDIR"] == root.path, "CLI login home must not move application temporary files")
        let grokBin = root.appendingPathComponent(".grok/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: grokBin, withIntermediateDirectories: true)
        let hostGrok = try makeFakeCLI(at: grokBin.appendingPathComponent("grok"), body: "echo called >> \"$HOME/grok-called\"\nexit 0\n")
        precondition(GrokBuildTranslationService().resolveExecutable() == hostGrok.path,
            "private app home hid the existing CLI installation")
        precondition(Set(TranslationPromptPresetID.allCases.map(\.legacyStyle)).count == TranslationPromptPresetID.allCases.count)

        let marker = "SYNTHETIC_CLI_TOKEN_OUTPUT_DO_NOT_LEAK"
        let fakeFailure = try makeFakeCLI(
            at: root.appendingPathComponent("fake-failure"),
            body: "echo '\(marker) /Users/synthetic/private/cli-output.log' >&2\nexit 37\n"
        )
        let failure = try await TranslationCLISetupBackend(
            resolver: { _ in fakeFailure.path },
            probeTimeout: 3
        ).inspect(TranslationEngineID.grokBuild.rawValue)
        precondition(failure.reason.contains("37"), "A nonzero exit should retain its numeric exit code")
        precondition(!failure.reason.contains(marker), "CLI output must not appear in inspection diagnostics")
        precondition(!failure.reason.contains("/Users/synthetic/private/cli-output.log"), "CLI output paths must not appear in inspection diagnostics")

        let fakeVersion = try makeFakeCLI(
            at: root.appendingPathComponent("fake-version"),
            body: "echo 'grok v1.2.3 \(marker) /Users/synthetic/private/cli-output.log'\nexit 0\n"
        )
        let version = try await TranslationCLISetupBackend(
            resolver: { _ in fakeVersion.path },
            probeTimeout: 3
        ).inspect(TranslationEngineID.grokBuild.rawValue)
        precondition(version.version == "1.2.3", "Version detection should expose only the semantic version token")
        precondition(!version.reason.contains(marker), "Version diagnostics must not expose CLI output")

        let store = TranslationCLISetupStore(
            inspector: { _ in throw AITranslationError.engineUnavailable("\(marker) /Users/synthetic/private/installer.log") },
            installer: { _, _ in throw AITranslationError.engineUnavailable("\(marker) /Users/synthetic/private/installer.log") }
        )
        guard let plan = TranslationCLIInstallPlan.forProvider(TranslationEngineID.grokBuild.rawValue) else {
            fatalError("Expected a local Grok Build install plan")
        }
        store.install(plan)
        for _ in 0..<200 where store.busy[plan.engineID] != nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let message = store.messages[plan.engineID] ?? ""
        precondition(!message.contains(marker), "The visible setup message must not expose installer output")
        precondition(!message.contains("/Users/synthetic/private/installer.log"), "The visible setup message must not expose installer paths")

        let context = AITranslationContext(
            title: "Synthetic",
            artist: "Synthetic",
            album: "Synthetic",
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            style: "natural_song",
            lines: []
        )
        let grokID = TranslationEngineID.grokBuild.rawValue
        let grokEngine = TranslationEngineRegistry.make(stableID: grokID)
        precondition(grokEngine.metadata.availability == .available, "Grok dispatch must use the installed local CLI")
        let grokConfiguration = AITranslationConfiguration(model: "synthetic-model", engineID: grokID)
        try await grokEngine.testConnection(configuration: grokConfiguration)
        do {
            _ = try await grokEngine.translate(context: context, sourceContentHash: "synthetic", configuration: grokConfiguration)
            fatalError("The empty fake CLI response must fail structured-response validation")
        } catch AITranslationError.engineUnavailable(let message) {
            precondition(!message.contains("尚未接线"), "Grok failures must come from the selected CLI, not an unwired registry stub")
        } catch {
            // The fake CLI exits successfully without JSON; the parser should reject that response.
        }
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("grok-called").path),
            "Grok translation must reach the selected local executable")

        let grokReuseSuite = "com.lyricsq.test.conversation.grok." + UUID().uuidString
        let grokReuseDefaults = UserDefaults(suiteName: grokReuseSuite)!
        defer { grokReuseDefaults.removePersistentDomain(forName: grokReuseSuite) }
        let grokReuseStore = AIConversationStore(defaults: grokReuseDefaults)
        let fakeGrokSession = try makeFakeCLI(at: root.appendingPathComponent("grok-session"), body: """
printf '%s\\n' "$@" >> "$HOME/grok-session-args"
pwd >> "$HOME/grok-session-cwds"
printf '%s\\n' '{"model":"synthetic-model","structured_output":{"lines":[]}}'
""")
        let grokReuseService = GrokBuildTranslationService(executableCandidates: [fakeGrokSession.path],
            conversationStore: grokReuseStore)
        let grokReuseConfiguration = AITranslationConfiguration(model: "synthetic-model", engineID: grokID)
        _ = try await grokReuseService.translate(context: context, sourceContentHash: "first-song", configuration: grokReuseConfiguration)
        guard let grokSessionID = grokReuseStore.threadID(for: grokID) else {
            fatalError("Grok should persist the first successful session ID")
        }
        _ = try await grokReuseService.translate(context: context, sourceContentHash: "second-song", configuration: grokReuseConfiguration)
        let grokArgs = try String(contentsOf: root.appendingPathComponent("grok-session-args"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        precondition(grokArgs.firstIndex(of: "--session-id").map { grokArgs[$0 + 1] == grokSessionID } == true,
            "Grok should create its first native session with the persisted ID")
        precondition(grokArgs.firstIndex(of: "--resume").map { grokArgs[$0 + 1] == grokSessionID } == true,
            "later Grok songs should resume the same native conversation")
        let grokCWDs = try String(contentsOf: root.appendingPathComponent("grok-session-cwds"), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        precondition(Set(grokCWDs).count == 1 && grokCWDs.first?.contains("/AIConversations/") == true,
            "Grok session reuse requires the same app-owned CLI working directory")

        let geminiID = TranslationEngineID.geminiCLI.rawValue
        let geminiBin = root.appendingPathComponent("Library/Application Support/SpotifyLyrics/TranslationCLI/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiBin, withIntermediateDirectories: true)
        let geminiSessionID = "11111111-2222-4333-8444-555555555555"
        let fakeGemini = try makeFakeCLI(at: geminiBin.appendingPathComponent("gemini"), body: """
printf '%s\\n' "$@" >> "$HOME/gemini-args"
printf '%s\\n' '{"type":"init","session_id":"\(geminiSessionID)","model":"synthetic-model"}'
printf '%s\\n' '{"type":"message","role":"assistant","content":"{\\"lines\\":[]}"}'
printf '%s\\n' '{"type":"result","status":"success","model":"synthetic-model","response":"{\\"lines\\":[]}"}'
""")
        let geminiEngine = TranslationEngineRegistry.make(stableID: geminiID)
        precondition(geminiEngine.metadata.availability == .available, "Gemini dispatch must use the installed local CLI")
        let geminiSuite = "com.lyricsq.test.conversation." + UUID().uuidString
        let geminiDefaults = UserDefaults(suiteName: geminiSuite)!
        defer { geminiDefaults.removePersistentDomain(forName: geminiSuite) }
        let geminiStore = AIConversationStore(defaults: geminiDefaults)
        let geminiService = GeminiCLITranslationService(executableCandidates: [fakeGemini.path], conversationStore: geminiStore)
        let geminiConfiguration = AITranslationConfiguration(model: "synthetic-model", engineID: geminiID)
        _ = try await geminiService.translate(context: context, sourceContentHash: "first-song", configuration: geminiConfiguration)
        precondition(geminiStore.threadID(for: geminiID) == geminiSessionID, "Gemini stream init session_id should be persisted")
        _ = try await geminiService.translate(context: context, sourceContentHash: "second-song", configuration: geminiConfiguration)
        let geminiArgs = try String(contentsOf: root.appendingPathComponent("gemini-args"), encoding: .utf8)
        precondition(geminiArgs.contains("--resume\n\(geminiSessionID)"), "later Gemini songs should resume the stored CLI conversation")

        let agyID = TranslationEngineID.antigravityCLI.rawValue
        let agyBin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: agyBin, withIntermediateDirectories: true)
        let agyConversationID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let fakeAgy = try makeFakeCLI(at: agyBin.appendingPathComponent("agy"), body: """
printf '%s\\n' "$@" >> "$HOME/agy-args"
printf '%s\\n' '{"event":"init","conversation_id":"\(agyConversationID)","init":{"permission_mode":"request-review","model":"synthetic-model"}}'
printf '%s\\n' '{"event":"step_update","step_update":{"conversation_id":"\(agyConversationID)","step_index":0,"state":"DONE","step_type":"user_input"}}'
printf '%s\\n' '{"event":"result","result":{"conversation_id":"\(agyConversationID)","status":"SUCCESS","response":"","structured_output":{"lines":[]}}}'
""")
        let agyEngine = TranslationEngineRegistry.make(stableID: agyID)
        precondition(agyEngine.metadata.availability == .available, "Antigravity dispatch must use the installed local CLI")
        let agySuite = "com.lyricsq.test.conversation.agy." + UUID().uuidString
        let agyDefaults = UserDefaults(suiteName: agySuite)!
        defer { agyDefaults.removePersistentDomain(forName: agySuite) }
        let agyStore = AIConversationStore(defaults: agyDefaults)
        let agyService = AntigravityCLITranslationService(executableCandidates: [fakeAgy.path], conversationStore: agyStore)
        let agyConfiguration = AITranslationConfiguration(model: "synthetic-model", engineID: agyID)
        _ = try await agyService.translate(context: context, sourceContentHash: "first-song", configuration: agyConfiguration)
        precondition(agyStore.threadID(for: agyID) == agyConversationID, "Antigravity result conversation_id should be persisted")
        _ = try await agyService.translate(context: context, sourceContentHash: "second-song", configuration: agyConfiguration)
        let agyArgs = try String(contentsOf: root.appendingPathComponent("agy-args"), encoding: .utf8)
        precondition(agyArgs.contains("--conversation\n\(agyConversationID)"), "later Antigravity songs should resume the stored conversation")

        for id in [TranslationEngineID.deepSeekAPI] {
            let engine = TranslationEngineRegistry.make(stableID: id.rawValue)
            precondition(engine.metadata.stableID == id.rawValue, "Registry must preserve the selected engine identity")
            precondition(engine.metadata.availability == .unavailable, "Unwired providers must fail closed")
            try await assertNotWired { try await engine.testConnection(configuration: .init(model: "synthetic-model", engineID: id.rawValue)) }
            try await assertNotWired { _ = try await engine.translate(context: context, sourceContentHash: "synthetic", configuration: .init(model: "synthetic-model", engineID: id.rawValue)) }
        }

        print("translation_cli_runtime_safety_contract: PASS")
    }

    private static func makeFakeCLI(at url: URL, body: String) throws -> URL {
        let script = "#!/bin/sh\n" + body
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func assertNotWired(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            fatalError("An unwired provider must not route to an unrelated translation backend")
        } catch AITranslationError.engineUnavailable(let message) {
            precondition(message.contains("尚未接线"), "The failure should explain the unwired execution boundary")
        }
    }
}
