import Foundation

@main
struct AITranslationContract {
    static func main() async throws {
        try naturalStyleContract()
        try await readingBudgetContract()
        try endpointContract()
        try blankLineContract()
        try responseSafetyContract()
        try stableIDResponseContract()
        try await clientErrorContract()
        try await testConnectionContract()
        try await codexOfflineContract()
        try await protectedRecoveryContract()
        print("AI translation contracts passed")
    }

    static func readingBudgetContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("budget.json")
        let budgetState = TranslationAcceptanceRequestBudget.State(maximum: 0, providers: [TranslationEngineID.openAICompatible.rawValue], trackKeys: ["synthetic"])
        let initial = try JSONEncoder().encode(budgetState)
        try initial.write(to: url)
        let keys = MemoryKeyStore(value: "synthetic-unused")
        let service = AIReadingCandidateService(keyStore: keys, acceptanceBudget: TranslationAcceptanceRequestBudget(fileURL: url))
        let request = ReadingGenerationRequest(lyricsVersionID: UUID(), sourceContentHash: "synthetic",
            lines: [.init(lineIndex: 0, originalText: "fixture")], languageHint: "ja", trackStableKey: "synthetic", representationID: .kana)
        let result = ReadingGenerationResult(engineID: .japaneseContextual, representationID: .kana,
            lines: [.init(lineIndex: 0, originalText: "fixture", readingText: nil, language: .japanese,
                tokens: [], warnings: [.unknownToken], confidence: 0)], language: .japanese, confidence: 0, contextHash: "synthetic")
        for engine in [TranslationEngineID.codexChatGPT, .openAICompatible] {
            let configuration = AITranslationConfiguration(baseURL: "https://example.invalid/v1", model: "fixture", engineID: engine.rawValue)
            do {
                _ = try await service.refine(result: result, request: request, configuration: configuration)
                throw ContractFailure(message: "reading provider/budget gate allowed dispatch")
            } catch AITranslationError.engineUnavailable { }
        }
        precondition(keys.reads == 0, "provider and zero-budget gates must reject before credential access")
        let finalBudget = try Data(contentsOf: url)
        precondition(finalBudget == initial, "zero budget must not be reset or increased")
        let accounts = ReadingCredentialAccounts()
        let routedService = AIReadingCandidateService(acceptanceBudget: nil, keyStoreFactory: { account in
            accounts.record(account)
            return MemoryKeyStore(value: nil)
        })
        for account in ["fixture-endpoint-a", "fixture-endpoint-b", "fixture-endpoint-a"] {
            let config = AITranslationConfiguration(baseURL: "https://example.invalid/v1", model: "fixture", apiCredentialAccount: account)
            do {
                _ = try await routedService.refine(result: result, request: request, configuration: config)
                throw ContractFailure(message: "missing credentials accepted")
            } catch AITranslationError.notConfigured { }
        }
        precondition(accounts.values == ["fixture-endpoint-a", "fixture-endpoint-b", "fixture-endpoint-a"],
            "each explicit request must resolve its own current endpoint account without cached old keys")
        print("PASS reading provider/budget/credential-account gates; zero real credentials or network")
    }

    static func naturalStyleContract() throws {
        let lines = [AITranslationSourceLine(index: 0, original: "synthetic continuation"),
                     AITranslationSourceLine(index: 1, original: ""),
                     AITranslationSourceLine(index: 2, original: "synthetic changed question?")]
        let context = AITranslationContext(title: "Fixture", artist: "Fixture", album: "",
            sourceLanguage: "mixed", targetLanguage: "zh-Hans", style: "natural_song", lines: lines)
        let builder = AITranslationPromptBuilder()
        for engine in [TranslationEngineID.openAICompatible, .codexChatGPT] {
            var configuration = AITranslationConfiguration(model: "fixture", engineID: engine.rawValue)
            let natural = try builder.build(context: context, configuration: configuration)
            precondition(natural.system.contains("Natural song style v2"))
            let payload = try JSONSerialization.jsonObject(with: Data(natural.user.utf8)) as! [String: Any]
            let sentLines = payload["lines"] as! [[String: Any]]
            precondition(sentLines.map { $0["text"] as! String } == lines.map(\.original),
                "style changes must not rewrite, merge or remove source lines")
            configuration.promptPresetID = TranslationPromptPresetID.literalFaithful.rawValue
            let literal = try builder.build(context: context, configuration: configuration)
            precondition(!literal.system.contains("Natural song style v2") && literal.promptHash != natural.promptHash,
                "literal/custom choices retain their own guidance and cache identity")
            configuration.promptPresetID = TranslationPromptPresetID.custom.rawValue
            configuration.customSystemPrompt = "fixture-specific style"
            let custom = try builder.build(context: context, configuration: configuration)
            precondition(!custom.system.contains("Natural song style v2"))
            precondition((custom.system + custom.user).contains("fixture-specific style"))
        }
        print("PASS natural style preserves source boundaries, preset choice and prompt identity; no model calls")
    }

    static func codexOfflineContract() async throws {
        let config = AITranslationConfiguration(model: "synthetic-model", engineID: TranslationEngineID.codexChatGPT.rawValue,
            codexReasoningEffort: "low")
        precondition(config.isConfigured)
        let source = [AITranslationSourceLine(index: 0, original: "synthetic one"),
                      AITranslationSourceLine(index: 1, original: "")]
        func context(_ lines: [AITranslationSourceLine]) -> AITranslationContext {
            AITranslationContext(title: "Synthetic", artist: "Fixture", album: "", sourceLanguage: "en",
                targetLanguage: config.targetLanguage, style: config.style, lines: lines)
        }
        let input = context(source)
        let first = try AITranslationPromptBuilder().build(context: input, configuration: config)
        let reloaded = context(source.enumerated().map { AITranslationSourceLine(index: $0.offset, original: $0.element.original) })
        let second = try AITranslationPromptBuilder().build(context: reloaded, configuration: config)
        guard let wire = first.codexWireRequest, let secondWire = second.codexWireRequest else { fatalError("wire missing") }
        precondition(wire.requestID != secondWire.requestID && first.promptHash == second.promptHash,
            "nonce/display UUID changes must not invalidate stable semantic cache")
        precondition(Set(wire.sourcesByWireID.keys) == Set(["L0", "L1"]))
        var rules = config; rules.customSystemPrompt = "synthetic rule change"
        let changedRulesPrompt = try AITranslationPromptBuilder().build(context: input, configuration: rules)
        precondition(changedRulesPrompt.promptHash != first.promptHash)
        var effort = config; effort.codexReasoningEffort = "high"
        precondition(effort.providerCacheIdentity != config.providerCacheIdentity && effort.requestIdentity != config.requestIdentity)
        let valid: [String: Any] = ["requestID": wire.requestID.uuidString,
            "lines": [["lineID": "L1", "translation": ""], ["lineID": "L0", "translation": "synthetic translated"]]]
        let parsed = try AITranslationResponseParser.parseCodex(JSONSerialization.data(withJSONObject: valid), request: wire)
        precondition(parsed.map(\.lineID) == source.map(\.lineID) && parsed.map(\.index) == [0, 1])
        var wrongNonce = valid; wrongNonce["requestID"] = UUID().uuidString
        var extraField = valid; extraField["timestamp"] = 1
        var duplicate = valid; duplicate["lines"] = [["lineID":"L0","translation":"one"],["lineID":"L0","translation":"two"]]
        var unknown = valid; unknown["lines"] = [["lineID":"L9","translation":"one"],["lineID":"L1","translation":""]]
        var blankMismatch = valid; blankMismatch["lines"] = [["lineID":"L0","translation":"one"],["lineID":"L1","translation":"nonblank"]]
        for invalid in [wrongNonce, extraField, duplicate, unknown, blankMismatch] {
            do {
                _ = try AITranslationResponseParser.parseCodex(JSONSerialization.data(withJSONObject: invalid), request: wire)
                fatalError("malformed Codex payload accepted")
            } catch AITranslationResponseError.validationFailed { }
        }
        let fake = CodexAppServerTranslationService(executableCandidates: ["/usr/bin/true"], transport: SyntheticCodexTransport(corruptNonce: false))
        let draft = try await fake.translate(context: input, sourceContentHash: "synthetic-hash", configuration: config)
        precondition(draft.engineID == config.engineID && draft.model == config.model && draft.sourceContentHash == "synthetic-hash")
        precondition(draft.tokenUsage?.totalTokens == 10 && draft.providerReasoningSetting == "effort=low")
        do {
            _ = try await CodexAppServerTranslationService(executableCandidates: ["/usr/bin/true"], transport: SyntheticCodexTransport(corruptNonce: true))
                .translate(context: input, sourceContentHash: "synthetic-hash", configuration: config)
            fatalError("fake transport nonce mismatch accepted")
        } catch AITranslationError.codexResponseInvalid { }
        print("PASS Codex short IDs/UUID restore/nonce/malformed payloads/stable cache/rules/reasoning/fake transport; zero processes or network")
    }

    @MainActor
    static func protectedRecoveryContract() async throws {
        guard let path = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_CONTRACT_ROOT"] else { fatalError("isolated fixtures required") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        precondition(root.lastPathComponent == "fixtures")
        precondition(root.deletingLastPathComponent().path == URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path)
        precondition(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for kind in ["manual", "locked"] {
            let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent(kind + ".sqlite3"),
                alignmentProvenanceDirectory: root.appendingPathComponent(kind + "-provenance"))
            try await repo.prepare()
            let track = Track(title: "Synthetic Protected", artist: "Fixture", album: "", duration: 10, spotifyId: kind)
            let identity = TrackIdentity(track: track)
            let document = LyricsDocument(identity: identity, title: track.title, artist: track.artist, album: track.album,
                duration: 10, lines: [LyricLine(timestamp: 0, originalText: "synthetic original")],
                isSynchronized: true, source: .lrclib, confidence: 1, providerSourceID: kind)
            let source = try await repo.save(track: track, identity: identity, document: document)
            guard let versionID = source.versionID, let hash = source.sourceContentHash else { fatalError("source missing") }
            let config = AITranslationConfiguration(model: "synthetic-model", autoTranslateNewLyrics: true,
                engineID: TranslationEngineID.codexChatGPT.rawValue, codexReasoningEffort: "low")
            let context = AITranslationContext(title: track.title, artist: track.artist, album: "", sourceLanguage: "ja",
                targetLanguage: config.targetLanguage, style: config.style,
                lines: [AITranslationSourceLine(index: 0, original: document.lines[0].originalText, lineID: document.lines[0].id, timestamp: 0)])
            let old = AITranslationDraft(lines: [AITranslationLine(index: 0, translation: "synthetic protected old")],
                targetLanguage: config.targetLanguage, model: "old-model", baseURLHost: "fixture", promptHash: "old-rules",
                sourceContentHash: hash, sourceKind: kind == "manual" ? .manualEdit : .ai,
                isMachineGenerated: kind != "manual", isManuallyEdited: kind == "manual", engineID: config.engineID)
            let protected = try await repo.saveTranslation(lyricsVersionID: versionID, sourceContentHash: hash,
                originalLines: document.lines.map(\.originalText), draft: old, forceNewVersion: false)
            if kind == "locked" { try await repo.markTranslationLocked(versionID: protected.record.id, locked: true) }
            let key = try AITranslationRequestExecution.key(identity: identity, versionID: versionID, sourceHash: hash,
                context: context, configuration: config)
            var request = try await repo.beginTranslationRequest(key: key, explicitRetry: false)
            request.phase = .dispatching; try await repo.updateTranslationRequest(request)
            request.phase = .received
            request.result = AITranslationDraft(lines: [AITranslationLine(index: 0, translation: "synthetic recovered new")],
                targetLanguage: config.targetLanguage, model: config.model, baseURLHost: "fixture",
                promptHash: try AITranslationPromptBuilder().build(context: context, configuration: config).promptHash,
                sourceContentHash: hash, engineID: config.engineID, providerReasoningSetting: config.providerReasoningSetting)
            try await repo.updateTranslationRequest(request)
            let fake = NeverDispatchService()
            let controller = TranslationSessionController(repository: repo, service: fake, acceptanceBudget: nil)
            controller.synchronize(document: document, lyricsVersionID: versionID, sourceContentHash: hash, configuration: config)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let journal = try await repo.loadTranslationRequest(key: key), journal.phase == .saved { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let calls = await fake.calls
            let journal = try await repo.loadTranslationRequest(key: key)
            let versions = try await repo.loadTranslationVersions(lyricsVersionID: versionID,
                targetLanguage: config.targetLanguage, sourceContentHash: hash)
            precondition(calls == 0 && journal?.phase == .saved && versions.count == 2)
            precondition(controller.selectedVersion?.record.id == protected.record.id, "recovery overwrote manual/locked adopted version")
            precondition(controller.project(onto: document.lines).first?.translationText == "synthetic protected old")
            guard let candidate = versions.first(where: { $0.record.id != protected.record.id }) else { fatalError("new candidate missing") }
            precondition(candidate.record.isDraft && !candidate.record.isArchived && candidate.record.parentVersionID == nil,
                "independent AI generation must remain a draft with no fabricated translation parent")
            precondition(candidate.record.lyricsVersionID == versionID && candidate.record.sourceContentHash == hash)
            guard let retained = versions.first(where: { $0.record.id == protected.record.id }) else { fatalError("protected history lost") }
            precondition(retained.lines == protected.lines && retained.record.parentVersionID == protected.record.parentVersionID)
            precondition(retained.record.isLocked == (kind == "locked") && retained.record.isManuallyEdited == (kind == "manual"))
            var unknownConfig = config
            unknownConfig.customSystemPrompt = "synthetic unknown request rules"
            let unknownKey = try AITranslationRequestExecution.key(identity: identity, versionID: versionID,
                sourceHash: hash, context: context, configuration: unknownConfig)
            var unknownRequest = try await repo.beginTranslationRequest(key: unknownKey, explicitRetry: false)
            unknownRequest.phase = .dispatching
            try await repo.updateTranslationRequest(unknownRequest)
            let unknownController = TranslationSessionController(repository: repo, service: fake, acceptanceBudget: nil)
            unknownController.synchronize(document: document, lyricsVersionID: versionID, sourceContentHash: hash, configuration: unknownConfig)
            let unknownDeadline = Date().addingTimeInterval(2)
            while Date() < unknownDeadline && !unknownController.progressMessage.contains("不会自动重发") {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let unknownJournal = try await repo.loadTranslationRequest(key: unknownKey)
            let unknownCalls = await fake.calls
            precondition(unknownJournal?.phase == .dispatching && unknownJournal?.attemptID == unknownRequest.attemptID && unknownCalls == 0)
            precondition(unknownController.selectedVersion?.record.id == protected.record.id && unknownController.progressMessage.contains("不会自动重发"))
            unknownController.cancel()
            let edit = ManualTranslationEdit(targetLanguage: config.targetLanguage, lines: ["synthetic derived edit"],
                parentVersionID: protected.record.id)
            let editResult = try await repo.saveManualEdit(LyricsEditSaveRequest(track: track, identity: identity,
                sourceVersionID: versionID, sourceContentHash: hash, document: document, createLyricsVersion: false,
                preserveCurrentLyricsSelection: true, translation: edit))
            guard let derived = editResult.translationVersion else { fatalError("derived translation missing") }
            precondition(derived.record.id != protected.record.id && derived.record.parentVersionID == protected.record.id)
            precondition(derived.record.sourceKind == .manualEdit && derived.record.isManuallyEdited)
            precondition(derived.record.lyricsVersionID == versionID && derived.record.sourceContentHash == hash)
            let afterEdit = try await repo.loadTranslationVersions(lyricsVersionID: versionID, targetLanguage: config.targetLanguage, sourceContentHash: hash)
            precondition(afterEdit.count == 3 && afterEdit.contains { $0.record.id == protected.record.id && $0.lines == protected.lines })
            do {
                _ = try await repo.saveManualEdit(LyricsEditSaveRequest(track: track, identity: identity,
                    sourceVersionID: versionID, sourceContentHash: "synthetic stale hash", document: document,
                    createLyricsVersion: false, translation: edit))
                fatalError("stale source edit accepted")
            } catch LyricsEditingRepositoryError.sourceContentMismatch { }
            let afterRejectedEdit = try await repo.loadTranslationVersions(lyricsVersionID: versionID,
                targetLanguage: config.targetLanguage, sourceContentHash: hash)
            precondition(afterRejectedEdit == afterEdit, "failed edit changed translation versions or parent chain")
            controller.selectNone()
            precondition(controller.project(onto: document.lines).allSatisfy { $0.translationText == nil })
            controller.cancel()
            print("PASS received recovery protects \(kind) old version; independent AI nil parent/manual edit explicit parent/stale hash rejection/unknown dispatch/none; zero fake dispatch")
        }
    }

    static func endpointContract() throws {
        let cases: [(String, String)] = [
            ("https://example.test", "https://example.test/v1/chat/completions"),
            ("https://example.test/", "https://example.test/v1/chat/completions"),
            ("https://example.test/v1", "https://example.test/v1/chat/completions"),
            ("https://example.test/v1/", "https://example.test/v1/chat/completions"),
            ("https://example.test/v1/chat/completions", "https://example.test/v1/chat/completions"),
            ("https://proxy.test/api/openai/v1", "https://proxy.test/api/openai/v1/chat/completions")
        ]
        for (base, expected) in cases {
            guard AITranslationEndpoint(baseURL: base).chatCompletionsURL.absoluteString == expected else {
                throw ContractFailure(message: "endpoint normalization: \(base)")
            }
        }
    }

    static func blankLineContract() throws {
        let original = ["第一行", "", "第三行"]
        let valid = [
            AITranslationLine(index: 0, translation: "第一行译文"),
            AITranslationLine(index: 1, translation: ""),
            AITranslationLine(index: 2, translation: "第三行译文")
        ]
        guard try AITranslationResponseParser.validate(valid, against: original).count == 3 else {
            throw ContractFailure(message: "blank line should be preserved")
        }
        let invalid = [
            AITranslationLine(index: 0, translation: ""),
            AITranslationLine(index: 1, translation: ""),
            AITranslationLine(index: 2, translation: "第三行译文")
        ]
        do {
            _ = try AITranslationResponseParser.validate(invalid, against: original)
            throw ContractFailure(message: "nonblank source accepted blank translation")
        } catch AITranslationResponseError.validationFailed { }
    }

    static func responseSafetyContract() throws {
        let response = #"[{"index":0,"translation":"译文"}]"#.data(using: .utf8)!
        let parsed = try AITranslationResponseParser.parse(response, expectedLineCount: 1)
        guard parsed.count == 1, parsed[0].translation == "译文" else {
            throw ContractFailure(message: "strict response parse")
        }
        for body in [
            #"[{"index":0,"translation":"译文","startTime":1}]"#,
            #"{"index":0,"translation":"译文"}"#,
            #"[{"index":true,"translation":"译文"}]"#,
            #"[{"index":0.5,"translation":"译文"}]"#,
            #"not json"#
        ] {
            do {
                _ = try AITranslationResponseParser.parse(Data(body.utf8), expectedLineCount: 1)
                throw ContractFailure(message: "unsafe response accepted")
            } catch AITranslationResponseError.validationFailed { }
        }
    }

    static func stableIDResponseContract() throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let source = [
            AITranslationSourceLine(index: 0, original: "one", lineID: first, timestamp: 10),
            AITranslationSourceLine(index: 1, original: "two", lineID: second, timestamp: 20)
        ]
        let body = "[{\"lineID\":\"\(second.uuidString)\",\"translation\":\"二\"},{\"lineID\":\"\(first.uuidString)\",\"translation\":\"一\"}]"
        let parsed = try AITranslationResponseParser.parseStable(Data(body.utf8), expectedLines: source)
        guard parsed.map(\.index) == [0, 1], parsed.map(\.lineID) == [first, second] else {
            throw ContractFailure(message: "stable line IDs were not restored to source order")
        }
        do {
            _ = try AITranslationResponseParser.parseStable(
                Data("[{\"lineID\":\"\(first.uuidString)\",\"translation\":\"一\",\"timestamp\":99},{\"lineID\":\"\(second.uuidString)\",\"translation\":\"二\"}]".utf8),
                expectedLines: source
            )
            throw ContractFailure(message: "stable response accepted a timestamp mutation")
        } catch AITranslationResponseError.validationFailed { }
        guard !AITranslationConfiguration(engineID: TranslationEngineID.codexChatGPT.rawValue).isConfigured,
              !CodexAppServerTranslationService().metadata.requiresAPIKey else {
            throw ContractFailure(message: "Codex offline gate must not claim configured or request an API key")
        }
    }

    static func clientErrorContract() async throws {
        let configuration = AITranslationConfiguration(baseURL: "https://proxy.test/api/openai/v1", model: "contract-model")
        let prompt = AITranslationPrompt(system: "system", user: "source", promptHash: "hash")

        let successBody = Data(#"{"choices":[{"message":{"content":"[{\"index\":0,\"translation\":\"ok\"}]"}}]}"#.utf8)
        let recording = RecordingHTTPClient(result: .response(successBody, 200))
        let client = OpenAICompatibleClient(httpClient: recording)
        let success = try await client.complete(
            prompt: prompt,
            configuration: configuration,
            apiKey: "test-key-not-logged",
            inputLineCount: 1
        )
        guard success.statusCode == 200,
              recording.lastRequest?.url?.absoluteString == "https://proxy.test/api/openai/v1/chat/completions" else {
            throw ContractFailure(message: "custom endpoint request")
        }
        guard let requestBody = recording.lastRequest?.httpBody,
              String(data: requestBody, encoding: .utf8)?.contains("source") == true else {
            throw ContractFailure(message: "request body missing prompt")
        }

        for (status, expected) in [(401, AITranslationError.unauthorized), (429, AITranslationError.rateLimited), (500, AITranslationError.server(500))] {
            let errorClient = OpenAICompatibleClient(httpClient: RecordingHTTPClient(result: .response(Data("{}".utf8), status)))
            do {
                _ = try await errorClient.complete(prompt: prompt, configuration: configuration, apiKey: "key", inputLineCount: 1)
                throw ContractFailure(message: "HTTP \(status) accepted")
            } catch let error as AITranslationError {
                guard error == expected else { throw ContractFailure(message: "HTTP \(status) classification") }
            }
        }

        let timeoutClient = OpenAICompatibleClient(httpClient: RecordingHTTPClient(result: .failure(.timedOut)))
        do {
            _ = try await timeoutClient.complete(prompt: prompt, configuration: configuration, apiKey: "key", inputLineCount: 1)
            throw ContractFailure(message: "timeout accepted")
        } catch AITranslationError.timedOut { }

        let networkClient = OpenAICompatibleClient(httpClient: RecordingHTTPClient(result: .failure(.network)))
        do {
            _ = try await networkClient.complete(prompt: prompt, configuration: configuration, apiKey: "key", inputLineCount: 1)
            throw ContractFailure(message: "network failure accepted")
        } catch AITranslationError.network { }

        let parseClient = OpenAICompatibleClient(httpClient: RecordingHTTPClient(result: .response(Data("{}".utf8), 200)))
        do {
            _ = try await parseClient.complete(prompt: prompt, configuration: configuration, apiKey: "key", inputLineCount: 1)
            throw ContractFailure(message: "parse failure accepted")
        } catch AITranslationError.invalidResponse { }
    }

    static func testConnectionContract() async throws {
        let keyStore = MemoryKeyStore(value: "key-not-printed")
        let http = RecordingHTTPClient(result: .response(
            Data(#"{"choices":[{"message":{"content":"[{\"index\":0,\"translation\":\"ok\"}]"}}]}"#.utf8),
            200
        ))
        let service = OpenAICompatibleTranslationService(
            client: OpenAICompatibleClient(httpClient: http),
            keyStore: keyStore
        )
        try await service.testConnection(
            configuration: AITranslationConfiguration(baseURL: "https://host.test", model: "model")
        )
        guard let body = http.lastRequest?.httpBody,
              let text = String(data: body, encoding: .utf8),
              text.contains("ping"), !text.contains("当前歌词") else {
            throw ContractFailure(message: "test connection was not minimal")
        }
    }
}

struct ContractFailure: Error { let message: String }

private enum FakeHTTPError: Error { case timedOut, network }

private final class RecordingHTTPClient: AIHTTPClient, @unchecked Sendable {
    enum Result {
        case response(Data, Int)
        case failure(FakeHTTPError)
    }

    let result: Result
    private(set) var lastRequest: URLRequest?

    init(result: Result) { self.result = result }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        switch result {
        case .response(let data, let status):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, response)
        case .failure(.timedOut): throw URLError(.timedOut)
        case .failure(.network): throw FakeHTTPError.network
        }
    }
}

private final class MemoryKeyStore: AITranslationAPIKeyStore, @unchecked Sendable {
    var value: String?
    init(value: String?) { self.value = value }
    var reads = 0
    func read() -> String? { reads += 1; return value }
    func save(_ key: String) throws { value = key }
    func delete() throws { value = nil }
}

private struct SyntheticCodexTransport: CodexTranslationTransport {
    let corruptNonce: Bool
    func run(executable: String, prompt: AITranslationPrompt, model: String, reasoningEffort: String,
             timeout: TimeInterval, outputSchema: [String: Any]) async throws -> CodexTranslationResult {
        precondition(executable == "/usr/bin/true") // Presence probe only; never executed.
        guard let wire = prompt.codexWireRequest else { fatalError("missing wire") }
        let body: [String: Any] = ["requestID": corruptNonce ? UUID().uuidString : wire.requestID.uuidString,
            "lines": wire.sourceLines.enumerated().map { ["lineID": "L\($0.offset)",
                "translation": $0.element.original.isEmpty ? "" : "synthetic translated"] }]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        return CodexTranslationResult(text: text, model: model, reasoningEffort: reasoningEffort,
            tokenUsage: AITranslationTokenUsage(inputTokens: 6, outputTokens: 4, totalTokens: 10))
    }
}
private actor NeverDispatchService: AITranslationService {
    private(set) var calls = 0
    func translate(context: AITranslationContext, sourceContentHash: String, configuration: AITranslationConfiguration) async throws -> AITranslationDraft {
        calls += 1
        throw AITranslationError.engineUnavailable("synthetic unexpected dispatch")
    }
    func testConnection(configuration: AITranslationConfiguration) async throws { }
}

private final class ReadingCredentialAccounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
