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
        let hostGrok = try makeFakeCLI(at: grokBin.appendingPathComponent("grok"), body: "exit 0\n")
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
        for id in [TranslationEngineID.grokBuild, .geminiCLI, .antigravityCLI, .deepSeekAPI] {
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
