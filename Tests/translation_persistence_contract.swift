import Foundation
import SQLite3
import Darwin


private func makeTrack() -> Track {
    Track(
        title: "Contract Song",
        artist: "Contract Artist",
        album: "Contract Album",
        duration: 120,
        spotifyId: "contract-track",
        spotifyURL: URL(string: "spotify:track:contract-track")
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
            LyricLine(timestamp: 0, originalText: "第一行", romajiText: "daiichi gyou", kanaText: "だいいちぎょう"),
            LyricLine(timestamp: 3, originalText: "", romajiText: nil, kanaText: nil),
            LyricLine(timestamp: 6, originalText: "第三行", romajiText: "daisan gyou", kanaText: "だいさんぎょう")
        ],
        isSynchronized: true,
        source: .lrclib,
        confidence: 0.99,
        providerSourceID: "contract-source"
    )
}

private func execute(_ db: OpaquePointer, _ sql: String) {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(db, sql, nil, nil, &message)
    let errorText = message.map { String(cString: $0) } ?? "sqlite error"
    precondition(result == SQLITE_OK, errorText)
    sqlite3_free(message)
}

private func makeV1Database(at url: URL, stableKey: String) {
    var db: OpaquePointer?
    precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    guard let db else { fatalError("db") }
    execute(db, """
        CREATE TABLE tracks(stable_key TEXT PRIMARY KEY, spotify_id TEXT, spotify_uri TEXT, isrc TEXT, title TEXT, artist_display TEXT, album TEXT, duration REAL, artwork_url TEXT, created_at REAL, updated_at REAL);
        CREATE TABLE track_aliases(track_stable_key TEXT, field TEXT, kind TEXT, value TEXT, language TEXT, script TEXT, source TEXT, confidence REAL, is_official INTEGER, PRIMARY KEY(track_stable_key, field, kind, value));
        CREATE TABLE lyrics_versions(id TEXT PRIMARY KEY, track_stable_key TEXT, source TEXT, provider_source_id TEXT, language TEXT, is_synced INTEGER, raw_text TEXT, content_hash TEXT, created_at REAL, updated_at REAL, is_machine_generated INTEGER, is_manually_edited INTEGER, is_locked INTEGER, confidence REAL);
        CREATE TABLE lyric_lines(lyrics_version_id TEXT, line_index INTEGER, start_time REAL, end_time REAL, original_text TEXT, kana_text TEXT, romaji_text TEXT, translation_text TEXT, PRIMARY KEY(lyrics_version_id, line_index));
        PRAGMA user_version = 1;
        """)
    let now = Date().timeIntervalSince1970
    execute(db, "INSERT INTO tracks VALUES('\(stableKey)','legacy-id','spotify:track:legacy-id',NULL,'Legacy','Artist','Album',90,NULL,\(now),\(now));")
    execute(db, "INSERT INTO lyrics_versions VALUES('00000000-0000-0000-0000-000000000001','\(stableKey)','lrclib','legacy','ja',1,'原文','legacy-hash',\(now),\(now),0,0,0,0.9);")
    execute(db, "INSERT INTO lyric_lines VALUES('00000000-0000-0000-0000-000000000001',0,0,2,'原文','げんぶん','genbun','译文');")
}

@main
struct TranslationPersistenceContract {
    // Every participant has an independent SQLite connection. Barriers fix the
    // read/read race and both retry commit orders, never rely on sleeps.
    actor Barrier {
        let count: Int
        var waiting: [CheckedContinuation<Void, Never>] = []
        init(_ count: Int) { self.count = count }
        func arrive() async {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if waiting.count == count {
                    let all = waiting; waiting.removeAll()
                    for item in all { item.resume() }
                }
            }
        }
    }
    static func atomicCompletionContracts(root: URL) async throws {
        let track = makeTrack(), identity = TrackIdentity(track: makeTrack())
        let document = makeDocument(track: track, identity: identity)
        let url = root.appendingPathComponent("atomic.sqlite3")
        let provenance = root.appendingPathComponent("atomic-provenance")
        let r1 = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        let r2 = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await r1.prepare(); try await r2.prepare()
        let source = try await r1.save(track: track, identity: identity, document: document)
        let id = source.versionID!, hash = source.sourceContentHash!
        let configuration = AITranslationConfiguration(model: "atomic-fake", engineID: TranslationEngineID.codexChatGPT.rawValue)
        let context = TranslationCompletionContext(identity: identity, lyricsVersionID: id, sourceContentHash: hash,
            originalLines: document.lines.map(\.originalText), targetLanguage: configuration.targetLanguage,
            providerCacheIdentity: configuration.providerCacheIdentity, configurationPromptHash: configuration.promptHash,
            engineID: configuration.engineID, allowsAppleFallback: false)
        let key = try context.requestKey()
        let draft = AITranslationDraft(lines: document.lines.enumerated().map {
                AITranslationLine(index: $0.offset, translation: $0.element.originalText.isEmpty ? "" : "Self-authored translation \($0.offset)")
            }, targetLanguage: configuration.targetLanguage, model: configuration.model, baseURLHost: "synthetic",
            promptHash: "synthetic-prompt", sourceContentHash: hash, engineID: configuration.engineID)
        // Protected old assets are compared byte-for-byte across every completion.
        let old = try await r1.saveTranslation(lyricsVersionID: id, sourceContentHash: hash,
            originalLines: context.originalLines, draft: draft.with(isDraft: false), forceNewVersion: true)
        try await r1.markTranslationLocked(versionID: old.record.id, locked: true)
        let manualDraft = AITranslationDraft(lines: draft.lines, targetLanguage: draft.targetLanguage, model: "manual", baseURLHost: "",
            promptHash: "manual", sourceContentHash: hash, sourceKind: .manualEdit, isMachineGenerated: false, isManuallyEdited: true)
        let manual = try await r1.saveTranslation(lyricsVersionID: id, sourceContentHash: hash,
            originalLines: context.originalLines, draft: manualDraft, forceNewVersion: true)
        let protected = try await r1.loadTranslationVersions(lyricsVersionID: id, targetLanguage: configuration.targetLanguage, sourceContentHash: hash).first(where: { $0.record.id == old.record.id })!
        func received(_ repository: SQLiteLyricsRepository) async throws -> StoredTranslationRequest {
            var request = try await repository.beginTranslationRequest(key: key, explicitRetry: true)
            precondition(request.completionVersionID != nil)
            request.phase = .dispatching; try await repository.updateTranslationRequest(request)
            request.phase = .received; request.result = draft; try await repository.updateTranslationRequest(request)
            return request
        }
        func count() async throws -> Int {
            try await r1.loadTranslationVersions(lyricsVersionID: id, targetLanguage: configuration.targetLanguage, sourceContentHash: hash).count
        }
        func reject(_ attempt: UUID, context override: TranslationCompletionContext? = nil) async throws {
            let before = try await count()
            do {
                _ = try await r2.completeTranslationRequest(key: key, attemptID: attempt, context: override ?? context)
                fatalError("unsafe completion accepted")
            } catch TranslationRepositoryError.database { }
              catch TranslationRepositoryError.sourceContentMismatch { }
            let after = try await count(); precondition(before == after, "rejection inserted a version")
        }
        let request = try await received(r1)
        let barrier = Barrier(2)
        func participant(_ repository: SQLiteLyricsRepository, throughProtocol: Bool = false) async throws -> StoredTranslationVersion {
            let observed = try await repository.loadTranslationRequest(key: key)
            precondition(observed?.phase == .received && observed?.attemptID == request.attemptID)
            await barrier.arrive()
            if throughProtocol {
                let durable: any TranslationRepository = repository
                return try await durable.completeTranslationRequest(key: key, attemptID: request.attemptID, context: context)
            }
            return try await repository.completeTranslationRequest(key: key, attemptID: request.attemptID, context: context)
        }
        async let one = participant(r1)
        async let two = participant(r2, throughProtocol: true)
        let (v1, v2) = try await (one, two)
        precondition(v1.record.id == v2.record.id && v1.record.id == request.completionVersionID)
        let afterRace = try await count(); precondition(afterRace == 3 && v1.isDraft && v1.record.parentVersionID == nil)
        print("PASS same-attempt two-connection read/read barrier: one fixed draft version, same exact ID")
        // Explicit completion barrier: retry is fully committed before stale A completes.
        let a = try await received(r1)
        let retryFirst = Barrier(2)
        async let delayed: Void = { await retryFirst.arrive(); try await reject(a.attemptID) }()
        let b = try await r2.beginTranslationRequest(key: key, explicitRetry: true)
        await retryFirst.arrive(); try await delayed
        let journalB = try await r1.loadTranslationRequest(key: key)
        precondition(journalB?.attemptID == b.attemptID && journalB?.phase == .prepared && journalB?.result == nil)
        print("PASS retry commits first: stale attempt inserts zero and new ledger unchanged")
        // Opposite commit order: A commits before B retry, then late A is rejected.
        let c = try await received(r1)
        let completionFirst = Barrier(2)
        async let laterRetry: StoredTranslationRequest = { await completionFirst.arrive(); return try await r2.beginTranslationRequest(key: key, explicitRetry: true) }()
        let completedC = try await r1.completeTranslationRequest(key: key, attemptID: c.attemptID, context: context)
        await completionFirst.arrive(); let d = try await laterRetry
        try await reject(c.attemptID)
        var resultD = d; resultD.phase = .dispatching; try await r2.updateTranslationRequest(resultD)
        resultD.phase = .received; resultD.result = draft; try await r2.updateTranslationRequest(resultD)
        let completedD = try await r2.completeTranslationRequest(key: key, attemptID: d.attemptID, context: context)
        precondition(completedC.record.id != completedD.record.id)
        print("PASS completion commits first: A remains, retry B owns one independent version, late A rejected")
        // SQL trigger injects failure after version and lines INSERT, during saved CAS.
        let rollback = try await received(r1)
        var db: OpaquePointer?; precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        execute(db!, "CREATE TRIGGER fail_completion BEFORE UPDATE OF phase ON translation_requests WHEN NEW.phase='saved' BEGIN SELECT RAISE(ABORT,'synthetic failure after insertion'); END;")
        let beforeRollback = try await count()
        do {
            _ = try await r1.completeTranslationRequest(key: key, attemptID: rollback.attemptID, context: context)
            fatalError("injected insertion failure accepted")
        } catch { precondition(!(error is CancellationError)) }
        let afterRollback = try await count(); precondition(afterRollback == beforeRollback)
        let retained = try await r2.loadTranslationRequest(key: key)
        precondition(retained?.phase == .received && retained?.result == draft)
        execute(db!, "DROP TRIGGER fail_completion;")
        let reopened = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await reopened.prepare()
        let done = try await reopened.completeTranslationRequest(key: key, attemptID: rollback.attemptID, context: context)
        let reopenedAgain = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await reopenedAgain.prepare()
        let exact = try await reopenedAgain.completeTranslationRequest(key: key, attemptID: rollback.attemptID, context: context)
        precondition(done.record.id == exact.record.id && exact.record.id == rollback.completionVersionID)
        print("PASS insert/CAS injected failure rolls back all rows; reopen before/after commit returns exact version")
        try await reopenedAgain.deleteTranslation(versionID: exact.record.id)
        try await reject(rollback.attemptID)
        let unsafe = try await received(r1)
        let wrong = TranslationCompletionContext(identity: identity, lyricsVersionID: id, sourceContentHash: "stale",
            originalLines: context.originalLines, targetLanguage: context.targetLanguage, providerCacheIdentity: context.providerCacheIdentity,
            configurationPromptHash: context.configurationPromptHash, engineID: context.engineID, allowsAppleFallback: false)
        try await reject(unsafe.attemptID, context: wrong)
        execute(db!, "UPDATE translation_requests SET result_json=NULL WHERE request_key='\(key)';")
        try await reject(unsafe.attemptID)
        execute(db!, "UPDATE translation_requests SET phase='dispatching' WHERE request_key='\(key)';")
        try await reject(unsafe.attemptID)
        execute(db!, "UPDATE translation_requests SET phase='received' WHERE request_key='\(key)';")
        execute(db!, "UPDATE translation_requests SET completion_version_id=NULL WHERE request_key='\(key)';")
        try await reject(unsafe.attemptID)
        // Child exit models loss of the entire connection/process, not just an exception.
        for checkpoint in ["beforeCommit", "afterCommit"] {
            let crashing = try await received(r1)
            let beforeCrash = try await count()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--atomic-crash", url.path, provenance.path, id.uuidString, hash,
                crashing.attemptID.uuidString, checkpoint]
            child.environment = ProcessInfo.processInfo.environment
            try child.run(); child.waitUntilExit()
            precondition(child.terminationReason == .exit && child.terminationStatus == 86, "checkpoint child failed unexpectedly")
            let afterCrash = try await count()
            let crashJournal = try await r2.loadTranslationRequest(key: key)
            precondition(afterCrash == beforeCrash + (checkpoint == "afterCommit" ? 1 : 0))
            precondition(crashJournal?.phase == (checkpoint == "afterCommit" ? .saved : .received))
            let recovery = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
            try await recovery.prepare()
            let recovered = try await recovery.completeTranslationRequest(key: key, attemptID: crashing.attemptID, context: context)
            precondition(recovered.record.id == crashing.completionVersionID)
            let recoveredCount = try await count(); precondition(recoveredCount == beforeCrash + 1)
            print("PASS process exit \(checkpoint): child exit86 expected; reopen exact ID, one version, zero model requests")
        }
        let all = try await r1.loadTranslationVersions(lyricsVersionID: id, targetLanguage: configuration.targetLanguage, sourceContentHash: hash)
        precondition(all.first(where: { $0.record.id == manual.record.id }) == manual, "manual old asset changed")
        precondition(all.first(where: { $0.record.id == protected.record.id }) == protected, "locked old asset changed")
        print("PASS saved deletion not resurrected, stale source/legacy NULL fail closed, old locked rows unchanged; model requests=0")
    }

    static func crashChild() async throws {
        let args = CommandLine.arguments
        precondition(args.count == 8)
        let url = URL(fileURLWithPath: args[2]), provenance = URL(fileURLWithPath: args[3])
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let executable = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        precondition(parent == executable.appendingPathComponent("fixtures"), "crash database outside task")
        let configuration = AITranslationConfiguration(model: "atomic-fake", engineID: TranslationEngineID.codexChatGPT.rawValue)
        let identity = TrackIdentity(track: makeTrack())
        let document = makeDocument(track: makeTrack(), identity: identity)
        let context = TranslationCompletionContext(identity: identity, lyricsVersionID: UUID(uuidString: args[4])!, sourceContentHash: args[5],
            originalLines: document.lines.map(\.originalText), targetLanguage: configuration.targetLanguage,
            providerCacheIdentity: configuration.providerCacheIdentity, configurationPromptHash: configuration.promptHash,
            engineID: configuration.engineID, allowsAppleFallback: false)
        let repository = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await repository.prepare()
        let checkpoint = args[7]
        await repository.setTranslationCompletionCheckpoint { stage in if stage == checkpoint { _exit(86) } }
        _ = try await repository.completeTranslationRequest(key: context.requestKey(), attemptID: UUID(uuidString: args[6])!, context: context)
        fatalError("child checkpoint not reached")
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--atomic-crash") { try await crashChild(); return }
        guard let path = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_CONTRACT_ROOT"] else {
            fatalError("task-private contract root required")
        }
        let requestedRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = requestedRoot.deletingLastPathComponent().resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        let temporaryParent = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        let executableParent = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        print("ISOLATION requested=\(path) parent=\(parent.path) temporary=\(temporaryParent.path) executableParent=\(executableParent.path)")
        precondition(attributes[.type] as? FileAttributeType == .typeDirectory)
        precondition((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition(parent.deletingLastPathComponent().path == temporaryParent.path)
        precondition(parent.lastPathComponent.range(of: "^spotifylyrics-translation-persistence-contract\\.[A-Za-z0-9]{6}$", options: .regularExpression) != nil)
        precondition(parent.path == executableParent.path, "fixtures must belong to this runner's private build")
        precondition(requestedRoot.lastPathComponent == "fixtures")
        guard let homePath = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            fatalError("isolated home required")
        }
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        precondition(home.path == parent.appendingPathComponent("home").path)
        let homeAttributes = try FileManager.default.attributesOfItem(atPath: home.path)
        precondition(homeAttributes[.type] as? FileAttributeType == .typeDirectory)
        let root = parent.appendingPathComponent("fixtures", isDirectory: true)
        print("ISOLATION root=\(root.path) home=\(home.path) owner=\(geteuid()) mode=0700")
        precondition(!FileManager.default.fileExists(atPath: requestedRoot.path), "fixtures must be fresh")
        precondition(!FileManager.default.fileExists(atPath: root.path), "canonical fixtures must be fresh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("SpotifyLyrics.sqlite3")
        let repository = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await repository.prepare()
        let schemaVersion = try await repository.schemaVersion()
        precondition(schemaVersion == DatabaseMigrator.currentVersion)
        let hasUniqueIndex = try await repository.hasUniqueTranslationVersionIndex()
        precondition(hasUniqueIndex == false)

        let track = makeTrack()
        let identity = TrackIdentity(track: track)
        let document = makeDocument(track: track, identity: identity)
        let savedLyrics = try await repository.save(track: track, identity: identity, document: document)
        guard case .inserted = savedLyrics.disposition, let lyricsVersionID = savedLyrics.versionID,
              let sourceHash = savedLyrics.sourceContentHash else { fatalError("lyrics source not saved") }

        let config = AITranslationConfiguration(baseURL: "https://proxy.example/api/openai/v1", model: "test-model")
        let lines = [
            AITranslationLine(index: 0, translation: "第一行译文"),
            AITranslationLine(index: 1, translation: ""),
            AITranslationLine(index: 2, translation: "第三行译文")
        ]
        let draft = AITranslationDraft(
            lines: lines,
            targetLanguage: config.targetLanguage,
            model: config.model,
            baseURLHost: "proxy.example",
            promptHash: "prompt-contract",
            sourceContentHash: sourceHash,
            engineID: TranslationEngineID.codexChatGPT.rawValue,
            tokenUsage: AITranslationTokenUsage(inputTokens: 100, cachedInputTokens: 10, outputTokens: 80,
                                                reasoningOutputTokens: 20, totalTokens: 180),
            providerReasoningSetting: "effort=low"
        )
        let first = try await repository.saveTranslation(
            lyricsVersionID: lyricsVersionID,
            sourceContentHash: sourceHash,
            originalLines: document.lines.map(\.originalText),
            draft: draft,
            forceNewVersion: false
        )
        let second = try await repository.saveTranslation(
            lyricsVersionID: lyricsVersionID,
            sourceContentHash: sourceHash,
            originalLines: document.lines.map(\.originalText),
            draft: draft,
            forceNewVersion: true
        )
        precondition(first.record.id != second.record.id, "explicit retranslation must create a new version")
        let versions = try await repository.loadTranslationVersions(
            lyricsVersionID: lyricsVersionID,
            targetLanguage: config.targetLanguage,
            sourceContentHash: sourceHash
        )
        precondition(versions.count == 2)
        precondition(versions.allSatisfy { $0.lines.count == 3 })
        precondition(versions.allSatisfy {
            $0.record.engineID == TranslationEngineID.codexChatGPT.rawValue
                && $0.record.providerExecutionMetadata.reasoningSetting == "effort=low"
                && $0.record.providerExecutionMetadata.tokenUsage?.totalTokens == 180
                && $0.record.providerExecutionMetadata.tokenUsage?.reasoningOutputTokens == 20
        }, "provider-native reasoning and usage must round-trip with candidate rows")

        do {
            _ = try await repository.saveTranslation(
                lyricsVersionID: lyricsVersionID,
                sourceContentHash: "stale-hash",
                originalLines: document.lines.map(\.originalText),
                draft: draft,
                forceNewVersion: true
            )
            fatalError("stale source accepted")
        } catch TranslationRepositoryError.sourceContentMismatch { }

        do {
            let invalid = AITranslationDraft(
                lines: [AITranslationLine(index: 0, translation: "")],
                targetLanguage: config.targetLanguage,
                model: config.model,
                baseURLHost: "proxy.example",
                promptHash: "bad",
                sourceContentHash: sourceHash
            )
            _ = try await repository.saveTranslation(
                lyricsVersionID: lyricsVersionID,
                sourceContentHash: sourceHash,
                originalLines: document.lines.map(\.originalText),
                draft: invalid,
                forceNewVersion: true
            )
            fatalError("invalid draft persisted")
        } catch TranslationRepositoryError.invalidLines { }
        let afterInvalid = try await repository.loadTranslationVersions(
            lyricsVersionID: lyricsVersionID,
            targetLanguage: config.targetLanguage,
            sourceContentHash: sourceHash
        )
        precondition(afterInvalid.count == 2)

        try await repository.markTranslationLocked(versionID: first.record.id, locked: true)
        let lockedFirst = try await repository.loadTranslationVersions(
            lyricsVersionID: lyricsVersionID,
            targetLanguage: config.targetLanguage,
            sourceContentHash: sourceHash
        ).first
        precondition(lockedFirst?.record.isLocked == true)

        // Migration imports the legacy column without guessing language/model.
        let legacyURL = root.appendingPathComponent("legacy.sqlite3")
        let legacyTrack = Track(title: "Legacy", artist: "Artist", album: "Album", duration: 90, spotifyId: "legacy-id")
        let legacyIdentity = TrackIdentity(track: legacyTrack)
        makeV1Database(at: legacyURL, stableKey: legacyIdentity.stableKey)
        let legacyRepository = SQLiteLyricsRepository(databaseURL: legacyURL, alignmentProvenanceDirectory: root.appendingPathComponent("legacy-provenance"))
        try await legacyRepository.prepare()
        let legacySchemaVersion = try await legacyRepository.schemaVersion()
        precondition(legacySchemaVersion == DatabaseMigrator.currentVersion)
        let legacySource = try await legacyRepository.loadBestStored(track: legacyTrack, identity: legacyIdentity)
        guard let legacySource, let legacyID = legacySource.versionID, let legacyHash = legacySource.sourceContentHash else {
            fatalError("legacy lyrics missing")
        }
        let legacyTranslations = try await legacyRepository.loadTranslationVersions(
            lyricsVersionID: legacyID,
            targetLanguage: "und",
            sourceContentHash: legacyHash
        )
        precondition(legacyTranslations.count == 1)
        precondition(legacyTranslations[0].record.sourceKind == .legacyImported)
        precondition(legacyTranslations[0].lines[0].translatedText == "译文")
        precondition(legacyTranslations[0].record.providerExecutionMetadata == AITranslationProviderExecutionMetadata(),
                     "old manual/legacy translation metadata must remain neutral after additive migration")
        let backupCount = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("pre-v\(DatabaseMigrator.currentVersion)") }.count
        precondition(backupCount == 1, "current migration must make exactly one backup")

        let reopened = SQLiteLyricsRepository(databaseURL: legacyURL, alignmentProvenanceDirectory: root.appendingPathComponent("legacy-provenance"))
        try await reopened.prepare()
        let legacyAgain = try await reopened.loadTranslationVersions(
            lyricsVersionID: legacyID,
            targetLanguage: "und",
            sourceContentHash: legacyHash
        )
        precondition(legacyAgain.count == 1, "migration must be idempotent")

        // Synthetic ledger durability and attempt/phase CAS; no engine is invoked.
        var request = try await repository.beginTranslationRequest(key: "synthetic-request", explicitRetry: false)
        precondition(request.phase == .prepared)
        request.phase = .dispatching
        try await repository.updateTranslationRequest(request)
        do {
            _ = try await repository.beginTranslationRequest(key: request.key, explicitRetry: false)
            fatalError("uncertain dispatch automatically retried")
        } catch TranslationRepositoryError.database { }
        let oldAttempt = request
        request = try await repository.beginTranslationRequest(key: request.key, explicitRetry: true)
        precondition(request.attemptID != oldAttempt.attemptID)
        do {
            try await repository.updateTranslationRequest(oldAttempt)
            fatalError("stale attempt accepted")
        } catch TranslationRepositoryError.database { }
        request.phase = .dispatching
        try await repository.updateTranslationRequest(request)
        request.phase = .received
        request.result = draft
        try await repository.updateTranslationRequest(request)
        let ledgerReopened = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        try await ledgerReopened.prepare()
        let received = try await ledgerReopened.loadTranslationRequest(key: request.key)
        precondition(received?.phase == .received && received?.attemptID == request.attemptID)
        precondition(received?.result == draft, "received result must survive repository reopen")
        do {
            var illegal = request; illegal.phase = .saved; illegal.result = nil
            try await ledgerReopened.updateTranslationRequest(illegal)
            fatalError("generic update must not bypass atomic completion")
        } catch TranslationRepositoryError.database { }
        print("PASS synthetic prepared/dispatching/received, explicit retry, stale-attempt CAS and durable reopen")
        try await atomicCompletionContracts(root: root)
        print("translation persistence contracts passed")
    }
}
