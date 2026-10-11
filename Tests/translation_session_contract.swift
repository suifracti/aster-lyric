import Foundation

private func makeTrack(_ id: String, title: String) -> Track {
    Track(
        title: title,
        artist: "Contract Artist",
        album: "Contract Album",
        duration: 120,
        spotifyId: id,
        spotifyURL: URL(string: "spotify:track:\(id)")
    )
}

private func makeDocument(track: Track, identity: TrackIdentity) -> LyricsDocument {
    LyricsDocument(
        identity: identity,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        lines: [
            LyricLine(timestamp: 0, originalText: "第一行"),
            LyricLine(timestamp: 2, originalText: "第二行")
        ],
        isSynchronized: true,
        source: .lrclib,
        confidence: 0.99,
        providerSourceID: "session-contract"
    )
}

private actor MemoryTranslationRepository: TranslationRepository {
    private var requests: [String: StoredTranslationRequest] = [:]
    func loadTranslationRequest(key: String) async throws -> StoredTranslationRequest? { requests[key] }
    func beginTranslationRequest(key: String, explicitRetry: Bool) async throws -> StoredTranslationRequest {
        if let prior = requests[key], prior.phase != .prepared, !explicitRetry { throw TranslationRepositoryError.database("interrupted") }
        let request = StoredTranslationRequest(key: key); requests[key] = request; return request
    }
    func updateTranslationRequest(_ request: StoredTranslationRequest) async throws {
        guard requests[request.key]?.attemptID == request.attemptID else { throw TranslationRepositoryError.database("stale attempt") }
        requests[request.key] = request
    }

    struct Save: Sendable {
        let lyricsVersionID: UUID
        let sourceContentHash: String
        let model: String
        let promptHash: String
    }

    private(set) var saves: [Save] = []
    private var versions: [StoredTranslationVersion] = []

    func loadTranslationVersions(
        lyricsVersionID: UUID,
        targetLanguage: String,
        sourceContentHash: String
    ) async throws -> [StoredTranslationVersion] {
        _ = lyricsVersionID
        _ = targetLanguage
        _ = sourceContentHash
        return versions.filter { $0.record.lyricsVersionID == lyricsVersionID && $0.record.targetLanguage == targetLanguage && $0.record.sourceContentHash == sourceContentHash }
    }

    func saveTranslation(
        lyricsVersionID: UUID,
        sourceContentHash: String,
        originalLines: [String],
        draft: AITranslationDraft,
        forceNewVersion: Bool
    ) async throws -> StoredTranslationVersion {
        _ = originalLines
        _ = forceNewVersion
        let id = UUID()
        saves.append(Save(lyricsVersionID: lyricsVersionID, sourceContentHash: sourceContentHash, model: draft.model, promptHash: draft.promptHash))
        let now = Date()
        let record = DatabaseTranslationVersionRecord(
            id: id,
            lyricsVersionID: lyricsVersionID,
            sourceKind: draft.sourceKind,
            targetLanguage: draft.targetLanguage,
            model: draft.model,
            baseURLHost: draft.baseURLHost,
            promptHash: draft.promptHash,
            sourceContentHash: draft.sourceContentHash,
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: true,
            isManuallyEdited: false,
            isLocked: false,
            status: .complete,
            confidence: draft.confidence,
            engineID: draft.engineID,
            promptPresetID: draft.promptPresetID,
            profileID: draft.profileID,
            profileSnapshot: draft.profileSnapshot,
            temperature: draft.temperature,
            workflowID: draft.workflowID,
            fallbackStrategy: draft.fallbackStrategy,
            providerExecutionMetadata: AITranslationProviderExecutionMetadata(
                reasoningSetting: draft.providerReasoningSetting, tokenUsage: draft.tokenUsage, cacheIdentity: draft.providerCacheIdentity
            ),
            isDraft: draft.isDraft,
            isArchived: draft.isArchived
        )
        let lines = draft.lines.map {
            DatabaseTranslationLineRecord(
                translationVersionID: id,
                lineIndex: $0.index,
                translatedText: $0.translation
            )
        }
        let result = StoredTranslationVersion(record: record, lines: lines)
        versions.insert(result, at: 0)
        return result
    }

    func markTranslationLocked(versionID: UUID, locked: Bool) async throws {
        _ = versionID
        _ = locked
    }

    func deleteTranslation(versionID: UUID) async throws {
        _ = versionID
    }

    func adoptTranslation(versionID: UUID) async throws {
        versions = versions.map { $0.record.id == versionID ? $0.with(record: $0.record.with(isDraft: false)) : $0 }
    }
    func archiveTranslation(versionID: UUID, archived: Bool) async throws {
        versions = versions.map { $0.record.id == versionID ? $0.with(record: $0.record.with(isArchived: archived)) : $0 }
    }
    func seed(_ version: StoredTranslationVersion) { versions.insert(version, at: 0) }
    func saveSnapshot() -> [Save] { saves }
}

private actor CallCounter {
    var value = 0

    func increment() { value += 1 }
}

private final class SlowTranslationService: AITranslationService, @unchecked Sendable {
    private let counter = CallCounter()

    func translate(
        context: AITranslationContext,
        sourceContentHash: String,
        configuration: AITranslationConfiguration
    ) async throws -> AITranslationDraft {
        await counter.increment()

        // Deliberately ignore cancellation. The controller must still reject
        // the result after a track switch before it reaches the repository.
        try? await Task.sleep(nanoseconds: 150_000_000)
        return AITranslationDraft(
            lines: context.lines.map { AITranslationLine(index: $0.index, translation: "译文 \($0.index)") },
            targetLanguage: configuration.targetLanguage,
            model: configuration.model,
            baseURLHost: "contract.test",
            promptHash: try AITranslationPromptBuilder().build(context: context, configuration: configuration).promptHash,
            sourceContentHash: sourceContentHash,
            engineID: configuration.engineID,
            workflowID: configuration.workflowID,
            providerReasoningSetting: configuration.providerReasoningSetting
        )
    }

    func testConnection(configuration: AITranslationConfiguration) async throws {
        _ = configuration
    }

    func calls() async -> Int { await counter.value }
}

private final class SlowAppleTranslationEngine: TranslationEngine, @unchecked Sendable {
    let metadata = TranslationEngineMetadata(
        stableID: TranslationEngineID.appleSystem.rawValue,
        displayName: "Apple 系统翻译",
        availability: .available,
        requiresAPIKey: false,
        supportsModelDirectory: false
    )

    func translate(
        context: AITranslationContext,
        sourceContentHash: String,
        configuration: AITranslationConfiguration
    ) async throws -> AITranslationDraft {
        try await Task.sleep(nanoseconds: 150_000_000)
        return AITranslationDraft(
            lines: context.lines.map { AITranslationLine(index: $0.index, translation: "系统译文 \($0.index)") },
            targetLanguage: configuration.targetLanguage,
            model: "Apple System Translation",
            baseURLHost: "",
            promptHash: "apple-contract",
            sourceContentHash: sourceContentHash,
            engineID: TranslationEngineID.appleSystem.rawValue
        )
    }

    func testConnection(configuration: AITranslationConfiguration) async throws {
        _ = configuration
    }
}

@main
struct TranslationSessionContract {
    @MainActor
    static func recoveryContract() async throws {
        guard let path = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_CONTRACT_ROOT"] else { fatalError("private root required") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        precondition(root.deletingLastPathComponent().path == URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path)
        precondition(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for scenario in ["dispatching", "received", "saved-gap"] {
            let url = root.appendingPathComponent(scenario + ".sqlite3")
            let provenance = root.appendingPathComponent(scenario + "-provenance")
            let repository = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
            try await repository.prepare()
            let track = makeTrack(scenario, title: "Synthetic Recovery")
            let identity = TrackIdentity(track: track)
            let document = makeDocument(track: track, identity: identity)
            let source = try await repository.save(track: track, identity: identity, document: document)
            guard let versionID = source.versionID, let hash = source.sourceContentHash else { fatalError("source missing") }
            let config = AITranslationConfiguration(model: "synthetic-model", autoTranslateNewLyrics: true,
                engineID: TranslationEngineID.codexChatGPT.rawValue)
            let context = AITranslationContext(title: document.title ?? "", artist: document.artist ?? "",
                album: document.album ?? "", sourceLanguage: "ja", targetLanguage: config.targetLanguage,
                style: config.style, lines: document.lines.enumerated().map {
                    AITranslationSourceLine(index: $0.offset, original: $0.element.originalText,
                        lineID: $0.element.id, timestamp: $0.element.timestamp)
                })
            let key = try AITranslationRequestExecution.key(identity: identity, versionID: versionID,
                sourceHash: hash, context: context, configuration: config)
            var request = try await repository.beginTranslationRequest(key: key, explicitRetry: false)
            request.phase = .dispatching
            try await repository.updateTranslationRequest(request)
            let draft = AITranslationDraft(lines: context.lines.map {
                    AITranslationLine(index: $0.index, translation: "synthetic translation \($0.index)")
                }, targetLanguage: config.targetLanguage, model: config.model, baseURLHost: "synthetic",
                promptHash: try AITranslationPromptBuilder().build(context: context, configuration: config).promptHash,
                sourceContentHash: hash, engineID: config.engineID,
                providerReasoningSetting: config.providerReasoningSetting)
            if scenario != "dispatching" {
                request.phase = .received; request.result = draft
                try await repository.updateTranslationRequest(request)
                if scenario == "saved-gap" {
                    _ = try await repository.saveTranslation(lyricsVersionID: versionID, sourceContentHash: hash,
                        originalLines: document.lines.map(\.originalText), draft: draft, forceNewVersion: false)
                }
            }
            let reopened = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
            try await reopened.prepare()
            let fake = SlowTranslationService()
            let controller = TranslationSessionController(repository: reopened, service: fake, acceptanceBudget: nil)
            controller.synchronize(document: document, lyricsVersionID: versionID, sourceContentHash: hash, configuration: config)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if scenario == "dispatching", case .failed = controller.state { break }
                if scenario != "dispatching", controller.selectedVersion != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let calls = await fake.calls()
            precondition(calls == 0, "recovery must never redispatch unknown or received work")
            let journal = try await reopened.loadTranslationRequest(key: key)
            let versions = try await reopened.loadTranslationVersions(lyricsVersionID: versionID,
                targetLanguage: config.targetLanguage, sourceContentHash: hash)
            if scenario == "dispatching" {
                guard case .failed = controller.state else { fatalError("unknown dispatch must be explicit") }
                precondition(journal?.phase == .dispatching && journal?.attemptID == request.attemptID)
                precondition(versions.isEmpty && controller.selectedVersion == nil)
            } else {
                precondition(journal?.phase == .saved && versions.count == 1, "received/save gap duplicated or lost version")
                precondition(controller.selectedVersion?.record.lyricsVersionID == versionID)
                precondition(controller.selectedVersion?.lines.map(\.translatedText) == draft.lines.map(\.translation))
            }
            controller.cancel()
            print("PASS synthetic controller recovery \(scenario): zero fake dispatch; durable journal/parent/version assertions")
        }
    }

    static func main() async {
        let repository = MemoryTranslationRepository()
        let service = SlowTranslationService()
        let configuration = AITranslationConfiguration(
            baseURL: "https://contract.test",
            model: "contract-model",
            autoTranslateNewLyrics: false
        )

        let controller = await MainActor.run {
            TranslationSessionController(repository: repository, service: service)
        }

        let trackA = makeTrack("a", title: "歌曲 A")
        let identityA = TrackIdentity(track: trackA)
        let documentA = makeDocument(track: trackA, identity: identityA)
        let hashA = LyricsPersistenceMapper.sourceContentHash(document: documentA)
        await MainActor.run {
            controller.synchronize(
                document: documentA,
                lyricsVersionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!,
                sourceContentHash: hashA,
                configuration: configuration
            )
            controller.translateCurrentLyrics()
            controller.translateCurrentLyrics()
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        let trackB = makeTrack("b", title: "歌曲 B")
        let identityB = TrackIdentity(track: trackB)
        let documentB = makeDocument(track: trackB, identity: identityB)
        let hashB = LyricsPersistenceMapper.sourceContentHash(document: documentB)
        await MainActor.run {
            controller.synchronize(
                document: documentB,
                lyricsVersionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!,
                sourceContentHash: hashB,
                configuration: configuration
            )
            controller.translateCurrentLyrics()
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        let saves = await repository.saveSnapshot()
        let calls = await service.calls()
        precondition(calls == 2, "duplicate in-flight request was not merged")
        precondition(saves.count == 1, "stale track translation reached persistence")
        precondition(saves[0].sourceContentHash == hashB, "saved translation belongs to the wrong track")

        await MainActor.run {
            controller.selectNone()
            precondition(controller.isNoSelection, "explicit no-translation selection was not retained")
            let projected = controller.project(onto: [
                LyricLine(timestamp: 0, originalText: "原文", translationText: "不应显示")
            ])
            precondition(projected.first?.translationText == nil, "no-selection leaked a translation layer")
            precondition(controller.selectedVersion == nil, "no-selection kept a selected translation")
        }

        let appleController = await MainActor.run {
            TranslationSessionController(repository: repository, engine: SlowAppleTranslationEngine())
        }
        var appleConfiguration = configuration
        appleConfiguration.engineID = TranslationEngineID.appleSystem.rawValue
        await MainActor.run {
            appleController.synchronize(
                document: documentA,
                lyricsVersionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!,
                sourceContentHash: hashA,
                configuration: appleConfiguration
            )
            appleController.translateCurrentLyrics()
            precondition(
                appleController.progressMessage == "正在检查 Apple 语言支持并准备系统翻译…",
                "Apple translation preparation is invisible to the user"
            )
            appleController.cancel()
        }
        try! await recoveryContract()
        print("translation session contracts passed")
    }
}
