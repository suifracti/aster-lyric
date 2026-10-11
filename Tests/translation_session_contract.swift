import Foundation
import SQLite3

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
        let request = StoredTranslationRequest(key: key, completionVersionID: UUID()); requests[key] = request; return request
    }
    func updateTranslationRequest(_ request: StoredTranslationRequest) async throws {
        guard requests[request.key]?.attemptID == request.attemptID else { throw TranslationRepositoryError.database("stale attempt") }
        requests[request.key] = request
    }

    func completeTranslationRequest(key: String, attemptID: UUID, context: TranslationCompletionContext) async throws -> StoredTranslationVersion {
        guard var request = requests[key], request.attemptID == attemptID,
              try context.requestKey() == key, let output = request.completionVersionID else { throw TranslationRepositoryError.database("unsafe completion") }
        if request.phase == .saved {
            guard let exact = versions.first(where: { $0.record.id == output }) else { throw TranslationRepositoryError.versionNotFound }
            return exact
        }
        guard request.phase == .received, let draft = request.result else { throw TranslationRepositoryError.database("missing result") }
        let saved = try await saveTranslation(lyricsVersionID: context.lyricsVersionID, sourceContentHash: context.sourceContentHash,
            originalLines: context.originalLines, draft: draft.with(isDraft: true, providerCacheIdentity: context.providerCacheIdentity),
            forceNewVersion: false, outputID: output)
        request.phase = .saved; request.result = nil; requests[key] = request
        return saved
    }

    struct Save: Sendable {
        let lyricsVersionID: UUID
        let sourceContentHash: String
        let model: String
        let promptHash: String
    }

    private var versionLoads = 0
    func loadCount() -> Int { versionLoads }
    private(set) var saves: [Save] = []
    private var versions: [StoredTranslationVersion] = []

    func loadTranslationVersions(
        lyricsVersionID: UUID,
        targetLanguage: String,
        sourceContentHash: String
    ) async throws -> [StoredTranslationVersion] {
        versionLoads += 1
        _ = lyricsVersionID
        _ = targetLanguage
        _ = sourceContentHash
        return versions.filter { $0.record.lyricsVersionID == lyricsVersionID && $0.record.targetLanguage == targetLanguage && $0.record.sourceContentHash == sourceContentHash }
    }

    func saveTranslation(lyricsVersionID: UUID, sourceContentHash: String, originalLines: [String],
                         draft: AITranslationDraft, forceNewVersion: Bool) async throws -> StoredTranslationVersion {
        try await saveTranslation(lyricsVersionID: lyricsVersionID, sourceContentHash: sourceContentHash,
            originalLines: originalLines, draft: draft, forceNewVersion: forceNewVersion, outputID: nil)
    }

    func saveTranslation(
        lyricsVersionID: UUID,
        sourceContentHash: String,
        originalLines: [String],
        draft: AITranslationDraft,
        forceNewVersion: Bool,
        outputID: UUID?
    ) async throws -> StoredTranslationVersion {
        _ = originalLines
        _ = forceNewVersion
        let id = outputID ?? UUID()
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
        for scenario in ["dispatching", "received", "saved", "legacy-received", "legacy-saved"] {
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
                if scenario == "saved" {
                    _ = try await repository.completeTranslationRequest(key: key, attemptID: request.attemptID,
                        context: TranslationCompletionContext(identity: identity, lyricsVersionID: versionID, sourceContentHash: hash,
                            originalLines: document.lines.map(\.originalText), targetLanguage: config.targetLanguage,
                            providerCacheIdentity: config.providerCacheIdentity, configurationPromptHash: config.promptHash,
                            engineID: config.engineID, allowsAppleFallback: false))
                }
                if scenario.hasPrefix("legacy-") {
                    if scenario == "legacy-saved" {
                        _ = try await repository.saveTranslation(lyricsVersionID: versionID, sourceContentHash: hash,
                            originalLines: document.lines.map(\.originalText), draft: draft.with(isDraft: true), forceNewVersion: false)
                    }
                    var db: OpaquePointer?; precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
                    defer { sqlite3_close(db) }
                    precondition(sqlite3_exec(db, "UPDATE translation_requests SET completion_version_id=NULL;", nil, nil, nil) == SQLITE_OK)
                    if scenario == "legacy-saved" {
                        precondition(sqlite3_exec(db, "UPDATE translation_requests SET phase='saved',result_json=NULL;", nil, nil, nil) == SQLITE_OK)
                    }
                }
            }
            let reopened = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
            try await reopened.prepare()
            let fake = SlowTranslationService()
            let controller = TranslationSessionController(repository: reopened, service: fake, acceptanceBudget: nil)
            controller.synchronize(document: document, lyricsVersionID: versionID, sourceContentHash: hash, configuration: config)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if scenario == "dispatching" || scenario.hasPrefix("legacy-"), case .failed = controller.state { break }
                if scenario == "received" || scenario == "saved", controller.selectedVersion != nil { break }
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
            } else if scenario.hasPrefix("legacy-") {
                guard case .failed = controller.state else { fatalError("legacy NULL must fail closed") }
                precondition(journal?.completionVersionID == nil && journal?.attemptID == request.attemptID)
                precondition(versions.count == (scenario == "legacy-saved" ? 1 : 0))
                precondition(controller.selectedVersion == nil, "legacy unlinked draft cannot be adopted")
            } else {
                precondition(journal?.phase == .saved && versions.count == 1, "atomic completion duplicated or lost version")
                precondition(versions[0].record.id == journal?.completionVersionID)
                precondition(controller.selectedVersion?.record.lyricsVersionID == versionID)
                precondition(controller.selectedVersion?.lines.map(\.translatedText) == draft.lines.map(\.translation))
            }
            controller.cancel()
            print("PASS synthetic controller recovery \(scenario): zero fake dispatch; durable journal/parent/version assertions")
        }
    }

    @MainActor
    static func selectionPersistenceContract() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPOTIFYLYRICS_CONTRACT_ROOT"]!)
        precondition(FileManager.default.fileExists(atPath: root.path)) // recoveryContract created this private root
        let suite = "LyricsQTranslationSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        precondition(defaults.persistentDomain(forName: suite) == nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("selection.sqlite3")
        precondition(!FileManager.default.fileExists(atPath: url.path))
        let provenance = root.appendingPathComponent("selection-provenance")
        let repo = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await repo.prepare()
        let trackA = makeTrack("selection-a", title: "Synthetic Selection A")
        let documentA = makeDocument(track: trackA, identity: TrackIdentity(track: trackA))
        let source = try await repo.save(track: trackA, identity: documentA.identity, document: documentA)
        let versionID = source.versionID!, hash = source.sourceContentHash!
        let config = AITranslationConfiguration(model: "fixture", autoTranslateNewLyrics: false)
        func save(_ text: String, manual: Bool) async throws -> StoredTranslationVersion {
            let draft = AITranslationDraft(lines: documentA.lines.indices.map {
                AITranslationLine(index: $0, translation: "\(text) \($0)")
            }, targetLanguage: config.targetLanguage, model: "fixture", baseURLHost: "fixture",
                promptHash: text, sourceContentHash: hash, sourceKind: manual ? .manualEdit : .ai,
                isMachineGenerated: !manual, isManuallyEdited: manual, isDraft: true)
            return try await repo.saveTranslation(lyricsVersionID: versionID, sourceContentHash: hash,
                originalLines: documentA.lines.map(\.originalText), draft: draft, forceNewVersion: true)
        }
        let protected = try await save("protected manual", manual: true)
        try await repo.adoptTranslation(versionID: protected.record.id)
        try await repo.markTranslationLocked(versionID: protected.record.id, locked: true)
        let alternate = try await save("alternate", manual: false)
        try await repo.adoptTranslation(versionID: alternate.record.id)
        let candidate = try await save("candidate", manual: false)
        let fake = SlowTranslationService()
        let first = TranslationSessionController(repository: repo, service: fake,
            selectionDefaults: defaults, acceptanceBudget: nil)
        let reopened = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await reopened.prepare()
        let second = TranslationSessionController(repository: reopened, service: fake,
            selectionDefaults: UserDefaults(suiteName: suite)!, acceptanceBudget: nil)
        func load(_ controller: TranslationSessionController) async throws {
            controller.synchronize(document: documentA, lyricsVersionID: versionID, sourceContentHash: hash, configuration: config)
            let deadline = Date().addingTimeInterval(2)
            while controller.availableVersions.count != 3 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(controller.availableVersions.count == 3, "selection fixture did not load")
        }
        let key = TranslationSessionController.selectionPreferenceKey(trackStableKey: documentA.identity.stableKey,
            versionID: versionID, sourceHash: hash, targetLanguage: config.targetLanguage)
        let libraryKey = "ai.libraryTranslationSelection.v1." + documentA.identity.stableKey
        try await load(first)
        precondition(first.selectedVersion?.record.id == protected.record.id)
        first.selectNone()
        precondition(defaults.string(forKey: key) == "none" && defaults.string(forKey: libraryKey) == "none")
        try await load(second)
        precondition(second.isNoSelection && second.selectedVersion == nil)
        precondition(second.project(onto: documentA.lines).allSatisfy { $0.translationText == nil })
        second.select(versionID: alternate.record.id)
        precondition(defaults.string(forKey: key) == alternate.record.id.uuidString)
        let trackB = makeTrack("selection-b", title: "Synthetic Selection B")
        let documentB = makeDocument(track: trackB, identity: TrackIdentity(track: trackB))
        let sourceB = try await repo.save(track: trackB, identity: documentB.identity, document: documentB)
        second.synchronize(document: documentB, lyricsVersionID: sourceB.versionID,
            sourceContentHash: sourceB.sourceContentHash, configuration: config)
        try await load(second) // A -> B -> A restores the persisted non-default choice
        precondition(second.selectedVersion?.record.id == alternate.record.id && !second.isNoSelection)
        second.adoptTranslation(versionID: candidate.record.id)
        let deadline = Date().addingTimeInterval(2)
        while second.selectedVersion?.record.id != candidate.record.id && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(second.selectedVersion?.record.id == candidate.record.id)
        precondition(defaults.string(forKey: key) == candidate.record.id.uuidString)
        let rebuilt = TranslationSessionController(repository: reopened, service: fake,
            selectionDefaults: UserDefaults(suiteName: suite)!, acceptanceBudget: nil)
        try await load(rebuilt)
        precondition(rebuilt.selectedVersion?.record.id == candidate.record.id, "adopted choice lost on independent rebuild")
        rebuilt.restoreRecommended()
        let restoreDeadline = Date().addingTimeInterval(2)
        while rebuilt.selectedVersion?.record.id != protected.record.id && Date() < restoreDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(defaults.object(forKey: key) == nil && defaults.object(forKey: libraryKey) == nil)
        precondition(rebuilt.selectedVersion?.record.id == protected.record.id && !rebuilt.isNoSelection)
        let third = TranslationSessionController(repository: reopened, service: fake,
            selectionDefaults: UserDefaults(suiteName: suite)!, acceptanceBudget: nil)
        try await load(third)
        precondition(third.selectedVersion?.record.id == protected.record.id)
        let retained = try await reopened.loadTranslationVersions(lyricsVersionID: versionID,
            targetLanguage: config.targetLanguage, sourceContentHash: hash)
        precondition(retained.count == 3 && retained.contains {
            $0.record.id == protected.record.id && $0.record.isLocked && $0.record.isManuallyEdited && $0.lines == protected.lines
        })
        let calls = await fake.calls()
        precondition(calls == 0, "selection/reconstruction must not dispatch a translation")
        first.cancel(); second.cancel(); rebuilt.cancel(); third.cancel()
        print("PASS selection persistence: private suite/SQLite; independent controllers; none/non-default/A-B-A/adoption/rebuild/recommended clearing; manual locked retained; zero fake dispatch")
    }

    @MainActor
    static func settingsRequestBoundaryContract() async throws {
        let suite = "LyricsQSettingsBoundary-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        precondition(defaults.persistentDomain(forName: suite) == nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = MemoryTranslationRepository(), fake = SlowTranslationService()
        let controller = TranslationSessionController(repository: repository, service: fake,
            selectionDefaults: defaults, acceptanceBudget: nil)
        let a = makeTrack("settings-a", title: "Synthetic Settings A")
        let document = makeDocument(track: a, identity: TrackIdentity(track: a))
        let version = UUID(), hash = LyricsPersistenceMapper.sourceContentHash(document: document)
        var config = AITranslationConfiguration(baseURL: "https://fixture.test", model: "fixture", autoTranslateNewLyrics: false)
        func load(_ document: LyricsDocument, _ version: UUID, _ hash: String, _ config: AITranslationConfiguration) async throws {
            let before = await repository.loadCount()
            controller.synchronize(document: document, lyricsVersionID: version, sourceContentHash: hash, configuration: config)
            let deadline = Date().addingTimeInterval(2)
            while await repository.loadCount() <= before && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            let observed = await repository.loadCount()
            precondition(observed > before, "configuration load did not execute")
            // The fake returns in 150ms; observe the completed async load/dispatch window.
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try await load(document, version, hash, config)
        config.autoTranslateNewLyrics = true
        config.targetLanguage = "en"
        try await load(document, version, hash, config)
        var count = await fake.calls()
        precondition(count == 0, "target-language settings dispatched a request")
        config.targetLanguage = "fr"; config.profileID = UUID(); config.profileSnapshot = "{}"
        try await load(document, version, hash, config)
        count = await fake.calls()
        precondition(count == 0, "profile/target-language settings dispatched a request")
        config.profileID = UUID(); config.customSystemPrompt = "synthetic updated rules"
        try await load(document, version, hash, config)
        count = await fake.calls()
        precondition(count == 0, "same-source profile/rules settings dispatched a request")
        controller.translateCurrentLyrics()
        controller.translateCurrentLyrics()
        let explicitDeadline = Date().addingTimeInterval(2)
        while controller.selectedVersion == nil && Date() < explicitDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
        count = await fake.calls()
        precondition(count == 1 && controller.selectedVersion != nil, "explicit translation lost/duplicated")
        controller.retranslateCurrentLyrics()
        let retryDeadline = Date().addingTimeInterval(2)
        while await fake.calls() != 2 && Date() < retryDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        count = await fake.calls()
        precondition(count == 2, "explicit retry lost or repeated")
        let b = makeTrack("settings-b", title: "Synthetic Settings B")
        let next = makeDocument(track: b, identity: TrackIdentity(track: b))
        try await load(next, UUID(), LyricsPersistenceMapper.sourceContentHash(document: next), config)
        count = await fake.calls()
        precondition(count == 3 && controller.selectedVersion != nil, "eligible new song did not auto-translate exactly once")
        controller.cancel()
        print("PASS settings boundary: language/profile/rules zero fake requests; explicit and retry retained/in-flight dedup; new song automatic exactly once")
    }

    static func main() async {
        let privateHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).resolvingSymlinksInPath()
        precondition(FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() == privateHome, "contract preferences must be private")
        let homeAttributes = try! FileManager.default.attributesOfItem(atPath: privateHome.path)
        precondition((homeAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

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
        try! await selectionPersistenceContract()
        try! await settingsRequestBoundaryContract()
        print("translation session contracts passed")
    }
}
