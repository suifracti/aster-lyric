import Foundation
import Darwin
import SQLite3

public final class AppSettingsStore: @unchecked Sendable {
    public static let shared = AppSettingsStore()
    public let translationProfiles = TranslationProfileStore(
        defaults: UserDefaults(suiteName: "SpotifyLyrics-O1-profile-\(UUID().uuidString)")!
    )
    private init() {}
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func sqliteExec(_ databaseURL: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let database else {
        throw NSError(domain: "O1.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "temporary fixture database could not be opened"])
    }
    defer { sqlite3_close(database) }
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    guard result == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "SQLite error \(result)"
        sqlite3_free(error)
        throw NSError(domain: "O1.SQLite", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class ReadOnlyDataVersionProbe {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            throw NSError(domain: "O1.SQLite", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "read-only database probe could not be opened"])
        }
        handle = opened
    }

    deinit { sqlite3_close(handle) }

    func dataVersion() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA data_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "O1.SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: "data_version query could not be prepared"])
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "O1.SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: "data_version query returned no row"])
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}

private struct DelayedScopeResolver: LyricsOffsetScopeResolving {
    let repository: SQLiteLyricsRepository
    let delayedTrackKey: String

    func canonicalStableKeyForSavedLyricsVersion(
        trackStableKey: String,
        versionID: UUID
    ) async throws -> String? {
        if trackStableKey == delayedTrackKey {
            // Intentionally ignore task cancellation so the production binding
            // must reject a late identity result after a newer scope request.
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        return try await repository.canonicalStableKeyForSavedLyricsVersion(
            trackStableKey: trackStableKey,
            versionID: versionID
        )
    }
}

@main
struct O1ScopedLyricsOffsetContract {
    @MainActor
    static func main() async throws {
        let suiteName = "SpotifyLyrics-O1-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = "lyrics.presentationOffset.v1"
        let legacyValue = NSNumber(value: 1.375)
        defaults.set(legacyValue, forKey: legacyKey)

        let store = ScopedLyricsOffsetStore(defaults: defaults)
        require(store.activeScope == nil && store.activeOffset == 0, "missing persistent identity must start unscoped at zero")
        require(!store.setActiveValue(4), "a missing persistent scope must refuse offset writes")
        require(defaults.object(forKey: legacyKey) as? NSNumber == legacyValue, "legacy global offset must remain byte-for-byte equivalent as a defaults number")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotifyLyrics-O1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("o1.sqlite3")
        let provenanceURL = root.appendingPathComponent("provenance", isDirectory: true)

        let trackA = Track(title: "O1 A", artist: "Fixture", album: "O1", duration: 180)
        let trackB = Track(title: "O1 B", artist: "Fixture", album: "O1", duration: 180)
        let historicalA = Track(title: "O1 A (historical metadata)", artist: "Fixture", album: "O1", duration: 181)
        let identityA = TrackIdentity(track: trackA)
        let identityB = TrackIdentity(track: trackB)
        let historicalIdentityA = TrackIdentity(track: historicalA)

        var seedingRepository: SQLiteLyricsRepository? = SQLiteLyricsRepository(
            databaseURL: databaseURL,
            alignmentProvenanceDirectory: provenanceURL
        )
        guard let seedRepository = seedingRepository else { fatalError("missing temporary repository") }
        try await seedRepository.prepare()

        func saveVersion(track: Track, identity: TrackIdentity, text: String, sourceID: String) async throws -> UUID {
            let document = LyricsDocument(
                identity: identity,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                lines: [LyricLine(timestamp: 0, originalText: text)],
                isSynchronized: false,
                source: .lrclib,
                confidence: 1,
                providerSourceID: sourceID
            )
            let result = try await seedRepository.save(track: track, identity: identity, document: document)
            guard let versionID = result.versionID else {
                fatalError("fixture lyrics version was rejected: \(result.disposition)")
            }
            return versionID
        }

        let aV1 = try await saveVersion(track: trackA, identity: identityA, text: "A version one", sourceID: "a-v1")
        let aV2 = try await saveVersion(track: trackA, identity: identityA, text: "A version two", sourceID: "a-v2")
        let bV1 = try await saveVersion(track: trackB, identity: identityB, text: "B version one", sourceID: "b-v1")
        let historicalVersion = try await saveVersion(
            track: historicalA,
            identity: historicalIdentityA,
            text: "Historical A",
            sourceID: "historical-a"
        )
        seedingRepository = nil

        let sqlSafeSource = historicalIdentityA.stableKey.replacingOccurrences(of: "'", with: "''")
        let sqlSafeTarget = identityA.stableKey.replacingOccurrences(of: "'", with: "''")
        try sqliteExec(databaseURL, """
            INSERT INTO track_identity_redirects(source_stable_key, canonical_stable_key, reason, evidence_kind, migration_id, created_at)
            VALUES ('\(sqlSafeSource)', '\(sqlSafeTarget)', 'o1 fixture', 'contract', 'o1-contract', 1);
            """)

        let repository = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: provenanceURL)
        try await repository.prepare()
        let redirectedVersionKey = try await repository.canonicalStableKeyForSavedLyricsVersion(
            trackStableKey: historicalIdentityA.stableKey,
            versionID: aV1
        )
        require(redirectedVersionKey == identityA.stableKey, "redirected persisted version must resolve to the canonical track key")
        let mismatchedVersionKey = try await repository.canonicalStableKeyForSavedLyricsVersion(
            trackStableKey: identityA.stableKey,
            versionID: bV1
        )
        require(mismatchedVersionKey == nil, "a version owned by another track must not create a mismatched scope")

        let binder = LyricsOffsetScopeBinding(store: store)
        var revision: UInt64 = 1

        func bind(_ trackKey: String?, _ versionID: UUID?) async throws {
            revision &+= 1
            binder.bind(
                trackStableKey: trackKey,
                lyricsVersionID: versionID,
                sessionRevision: revision,
                resolver: repository
            )
            if trackKey != nil, let versionID {
                try await waitUntil("scope binding did not resolve for \(versionID)") {
                    store.activeScope?.lyricsVersionID == versionID
                }
            } else {
                require(store.activeScope == nil && store.activeOffset == 0, "missing identity/version must clear the current scope synchronously")
            }
        }

        let session = LyricsSessionController(providers: [], repository: repository)
        try await repository.adoptLyricsVersion(trackStableKey: identityA.stableKey, lyricsVersionID: aV1)
        let repositorySelectedA = try await repository.loadBestStored(track: trackA, identity: identityA)
        require(repositorySelectedA?.versionID == aV1, "repository must expose selected A/v1 before the session opens it")
        session.begin(track: trackA, identity: identityA)
        try await waitUntil("production lyrics session did not restore A/v1") {
            session.activeLyricsVersionID == aV1
        }
        binder.bind(
            trackStableKey: session.activeIdentity?.stableKey,
            lyricsVersionID: session.activeLyricsVersionID,
            sessionRevision: session.revision,
            resolver: repository
        )
        try await waitUntil("A/v1 scope did not activate") { store.activeScope?.lyricsVersionID == aV1 }
        let scopeAV1 = store.activeScope!
        require(scopeAV1.canonicalTrackStableKey == identityA.stableKey, "live A/v1 must use the canonical stable key")
        let scopeAV2 = LyricsOffsetScope(canonicalTrackStableKey: identityA.stableKey, lyricsVersionID: aV2)!
        require(store.activeOffset == 0, "new A/v1 scope must default to zero")
        let readOnlyProbe = try ReadOnlyDataVersionProbe(url: databaseURL)
        let dataVersionBeforeOffsetWrite = try readOnlyProbe.dataVersion()
        require(store.setActiveValue(0.75), "active saved scope accepts offset edits")
        let dataVersionAfterOffsetWrite = try readOnlyProbe.dataVersion()
        require(dataVersionAfterOffsetWrite == dataVersionBeforeOffsetWrite, "scoped offset write must not modify SQLite")

        try await repository.adoptLyricsVersion(trackStableKey: identityA.stableKey, lyricsVersionID: aV2)
        session.begin(track: trackA, identity: identityA)
        try await waitUntil("production lyrics session did not restore A/v2") { session.activeLyricsVersionID == aV2 }
        binder.bind(trackStableKey: identityA.stableKey, lyricsVersionID: session.activeLyricsVersionID, sessionRevision: session.revision, resolver: repository)
        try await waitUntil("A/v2 scope did not activate") { store.activeScope?.lyricsVersionID == aV2 }
        require(store.activeOffset == 0, "new lyrics version must not inherit its parent offset")
        require(store.setActiveValue(-0.5), "A/v2 offset edit should persist independently")
        require(store.setActiveValue(50) && store.activeOffset == 10, "scoped offset must retain C1's upper clamp")
        require(store.setActiveValue(-50) && store.activeOffset == -10, "scoped offset must retain C1's lower clamp")
        require(store.setActiveValue(.infinity) && store.activeOffset == 0, "non-finite scoped input must normalize to zero")
        require(store.setActiveValue(-0.5), "A/v2 fixture offset should be restored after clamp checks")

        try await repository.adoptLyricsVersion(trackStableKey: identityB.stableKey, lyricsVersionID: bV1)
        session.begin(track: trackB, identity: identityB)
        try await waitUntil("production lyrics session did not restore B/v1") { session.activeLyricsVersionID == bV1 }
        binder.bind(trackStableKey: identityB.stableKey, lyricsVersionID: session.activeLyricsVersionID, sessionRevision: session.revision, resolver: repository)
        try await waitUntil("B/v1 scope did not activate") { store.activeScope?.lyricsVersionID == bV1 }
        require(store.activeOffset == 0, "new track/version pair must default to zero")
        let scopeBV1 = store.activeScope!
        require(store.setActiveValue(1.25), "B/v1 offset edit should persist independently")

        try await bind(identityA.stableKey, aV1)
        require(store.activeOffset == 0.75, "switching back to A/v1 must restore its stored value")
        try await bind(identityA.stableKey, aV2)
        require(store.activeOffset == -0.5, "switching to A/v2 must restore its own value")
        try await bind(identityB.stableKey, bV1)
        require(store.activeOffset == 1.25, "switching to B/v1 must restore its own value")

        let unknownVersionID = UUID()
        revision &+= 1
        binder.bind(
            trackStableKey: identityA.stableKey,
            lyricsVersionID: unknownVersionID,
            sessionRevision: revision,
            resolver: repository
        )
        try await Task.sleep(nanoseconds: 80_000_000)
        require(store.activeScope == nil && store.activeOffset == 0, "unknown persisted version must not create a scope")
        require(!store.setActiveValue(2), "unknown version scope must reject offset writes")
        try await bind(nil, nil)

        // A fixed editor scope for B/v2 is independent from live A/v1. The
        // production UI obtains this pair from the selected saved record.
        let bV2Document = LyricsDocument(
            identity: identityB,
            title: trackB.title,
            artist: trackB.artist,
            album: trackB.album,
            duration: trackB.duration,
            lines: [LyricLine(timestamp: 0, originalText: "B version two")],
            isSynchronized: false,
            source: .lrclib,
            confidence: 1,
            providerSourceID: "b-v2"
        )
        guard let bV2 = try await repository.save(track: trackB, identity: identityB, document: bV2Document).versionID else {
            fatalError("B/v2 fixture was rejected")
        }
        let scopeBV2 = LyricsOffsetScope(canonicalTrackStableKey: identityB.stableKey, lyricsVersionID: bV2)!
        require(store.value(for: scopeBV2) == 0, "a newly saved lyrics version must start at zero")
        try await bind(identityA.stableKey, aV1)
        let liveOffsetBeforeEditorWrite = store.activeOffset
        store.setValue(-1.75, for: scopeBV2)
        require(store.activeScope?.lyricsVersionID == aV1, "editor scope write must not switch the live pair")
        require(store.activeOffset == liveOffsetBeforeEditorWrite, "editor B/v2 offset must not alter live A/v1 clock")
        require(store.value(for: scopeBV2) == -1.75, "editor should read/write the explicit saved B/v2 pair")

        guard let storedBv2 = try await repository.loadEditableVersion(versionID: bV2, track: trackB, identity: identityB) else {
            fatalError("saved B/v2 editor fixture could not be loaded")
        }
        let editor = LyricsEditorSessionController(repository: repository)
        editor.begin(
            track: trackB,
            identity: identityB,
            document: storedBv2.document,
            lyricsVersionID: bV2,
            sourceContentHash: storedBv2.sourceContentHash,
            revision: 1,
            translations: [],
            selectedTranslation: nil,
            configuration: AITranslationConfiguration()
        )
        try await waitUntil("editor did not load the selected saved B/v2 record") {
            editor.availableVersions.contains(where: { $0.record.id == bV2 })
        }
        try await waitUntil("editor did not resolve its selected saved B/v2 offset scope") {
            editor.persistentLyricsOffsetScope == scopeBV2 && editor.lyricsOffsetDisabledReason == nil
        }
        require(editor.persistentLyricsOffsetScope == scopeBV2, "editor scope must use its selected saved record's canonical track key and version ID")
        require(editor.lyricsOffsetDisabledReason == nil, "clean saved editor draft should permit its own offset")
        if let lineID = editor.draft?.lines.first?.id {
            editor.updateLine(lineID) { $0.originalText += " changed" }
        } else {
            fatalError("editor draft line missing")
        }
        require(editor.persistentLyricsOffsetScope == nil, "dirty editor draft must not be bound to a saved-version scope")
        require(editor.lyricsOffsetDisabledReason?.contains("未保存修改") == true, "dirty editor draft must explain why offset writes are disabled")

        guard let redirectedStored = try await repository.loadEditableVersion(
            versionID: historicalVersion,
            track: trackA,
            identity: identityA
        ) else {
            fatalError("redirected saved version could not be loaded into the editor")
        }
        let redirectedEditor = LyricsEditorSessionController(repository: repository)
        redirectedEditor.begin(
            track: trackA,
            identity: identityA,
            document: redirectedStored.document,
            lyricsVersionID: historicalVersion,
            sourceContentHash: redirectedStored.sourceContentHash,
            revision: 1,
            translations: [],
            selectedTranslation: nil,
            configuration: AITranslationConfiguration()
        )
        try await waitUntil("editor did not load the redirected saved version") {
            redirectedEditor.availableVersions.contains(where: { $0.record.id == historicalVersion })
        }
        try await waitUntil("editor did not resolve the redirected version's canonical offset scope") {
            redirectedEditor.persistentLyricsOffsetScope?.lyricsVersionID == historicalVersion
        }
        require(
            redirectedEditor.persistentLyricsOffsetScope?.canonicalTrackStableKey == identityA.stableKey,
            "editor redirect-family record must use the canonical track key for its offset pair"
        )

        // The redirect alias and its canonical key must address the same pair.
        try await bind(historicalIdentityA.stableKey, aV1)
        require(store.activeScope == scopeAV1, "redirect aliases must resolve to the canonical A/v1 scope")

        let delayedResolver = DelayedScopeResolver(repository: repository, delayedTrackKey: historicalIdentityA.stableKey)
        revision &+= 1
        binder.bind(trackStableKey: historicalIdentityA.stableKey, lyricsVersionID: aV1, sessionRevision: revision, resolver: delayedResolver)
        require(store.activeScope == nil && store.activeOffset == 0, "scope transition must clear old offset before async resolution")
        revision &+= 1
        binder.bind(trackStableKey: identityB.stableKey, lyricsVersionID: bV1, sessionRevision: revision, resolver: repository)
        try await waitUntil("new B/v1 scope did not win over delayed A callback") { store.activeScope?.lyricsVersionID == bV1 }
        try await Task.sleep(nanoseconds: 240_000_000)
        require(store.activeScope?.lyricsVersionID == bV1 && store.activeOffset == 1.25, "late A resolution must not restore A into the live scope")

        store.resetValue(for: scopeAV1)
        require(store.value(for: scopeAV1) == 0, "reset must clear the specified pair")
        require(store.value(for: scopeAV2) == -0.5 && store.value(for: scopeBV2) == -1.75, "reset must preserve other pairs")
        require(store.resetActiveValue(), "current B/v1 scope should support reset")
        require(store.value(for: scopeBV1) == 0, "active reset must clear B/v1 only")
        require(store.value(for: scopeAV2) == -0.5 && store.value(for: scopeBV2) == -1.75, "active reset must leave other pairs untouched")
        require(defaults.object(forKey: legacyKey) as? NSNumber == legacyValue, "scoped edits and reset must leave the legacy global key untouched")

        let reopenedRepository = SQLiteLyricsRepository(databaseURL: databaseURL, alignmentProvenanceDirectory: provenanceURL)
        try await reopenedRepository.prepare()
        try await reopenedRepository.adoptLyricsVersion(trackStableKey: identityA.stableKey, lyricsVersionID: aV2)
        let reopenedSession = LyricsSessionController(providers: [], repository: reopenedRepository)
        reopenedSession.begin(track: trackA, identity: identityA)
        try await waitUntil("new session did not restore A/v2 after reopening the temporary database") {
            reopenedSession.activeLyricsVersionID == aV2
        }

        let reopenedStore = ScopedLyricsOffsetStore(defaults: defaults)
        let reopenedBinder = LyricsOffsetScopeBinding(store: reopenedStore)
        reopenedBinder.bind(
            trackStableKey: reopenedSession.activeIdentity?.stableKey,
            lyricsVersionID: reopenedSession.activeLyricsVersionID,
            sessionRevision: reopenedSession.revision,
            resolver: reopenedRepository
        )
        try await waitUntil("recreated store did not restore A/v2") { reopenedStore.activeScope?.lyricsVersionID == aV2 }
        require(reopenedStore.activeOffset == -0.5, "new store must recover persisted pair value")

        let rawClock = LyricsPresentationClock(
            authoritativePosition: 42,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "o1-clock-fixture",
            trackDuration: 180,
            presentationOffset: 0
        )
        let adjustedClock = rawClock.withPresentationOffset(reopenedStore.activeOffset)
        require(rawClock.playbackTime(at: 500) == adjustedClock.playbackTime(at: 500), "offset must not alter paused transport time")
        require(adjustedClock.presentationTime(at: 500) == 41.5, "active scoped offset must immediately change lyric presentation time")
        require(rawClock.authoritativePosition == adjustedClock.authoritativePosition, "offset must preserve the playback anchor")

        print("O1 scoped offset production contract: PASS")
    }

    @MainActor
    private static func waitUntil(
        _ message: String,
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "O1.Contract", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
