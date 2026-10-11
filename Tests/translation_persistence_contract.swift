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
    static func main() async throws {
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
        request.phase = .saved
        request.result = nil
        try await ledgerReopened.updateTranslationRequest(request)
        let saved = try await repository.loadTranslationRequest(key: request.key)
        precondition(saved?.phase == .saved && saved?.result == nil)
        print("PASS synthetic prepared/dispatching/received/saved, explicit retry, stale-attempt CAS and durable reopen")
        print("translation persistence contracts passed")
    }
}
