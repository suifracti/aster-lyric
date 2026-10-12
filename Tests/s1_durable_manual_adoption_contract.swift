import Foundation
import SQLite3
import Darwin

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ContractFailure(description: message) }
}

private struct FixedLyricsProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        result
    }
}

private actor LyricsProviderCallCounter {
    private var calls = 0

    func record() { calls += 1 }
    func value() -> Int { calls }
}

private struct CountingLyricsProvider: LyricsProvider {
    let name: String
    let counter: LyricsProviderCallCounter
    let result: LyricsLookupResult

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await counter.record()
        return result
    }
}

private func makeTrack(_ suffix: String) -> Track {
    Track(
        title: "采用测试 \(suffix)",
        artist: "S1 Contract",
        album: "Temporary Fixture",
        duration: 121,
        spotifyId: "s1-adoption-\(suffix)"
    )
}

private func makeCandidate(
    track: Track,
    source: LyricsSource,
    confidence: Double,
    providerID: String,
    isSynchronized: Bool = true,
    hasTiming: Bool = false,
    explicitlyTimedLineIndices: Set<Int>? = nil
) -> LyricsCandidate {
    let text = hasTiming ? "A🙂A" : "採用候補 \(track.title)"
    let spans = hasTiming ? [
        TimedTextSpan(id: 0, text: "A", startTime: 1.0, endTime: 1.2, utf16Start: 0, utf16Length: 1),
        TimedTextSpan(id: 1, text: "🙂", startTime: 1.2, endTime: 1.4, utf16Start: 1, utf16Length: 2),
        TimedTextSpan(id: 2, text: "A", startTime: 1.4, endTime: 1.8, utf16Start: 3, utf16Length: 1)
    ] : nil
    return LyricsCandidate(
        id: providerID,
        identity: TrackIdentity(track: track),
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        lines: [LyricLine(
            timestamp: hasTiming ? 1.0 : 0,
            originalText: text,
            endTime: hasTiming ? 2.0 : nil,
            performerID: hasTiming ? "v1" : nil,
            timedSpans: spans
        )],
        isSynchronized: isSynchronized,
        source: source,
        confidence: confidence,
        providerSourceID: providerID,
        spotifyTrackID: track.spotifyId,
        isrc: track.isrc,
        language: hasTiming ? "ja" : nil,
        explicitlyTimedLineIndices: explicitlyTimedLineIndices
    )
}

private func makeRepository(root: URL) -> SQLiteLyricsRepository {
    SQLiteLyricsRepository(
        databaseURL: root.appendingPathComponent("lyrics.sqlite3"),
        alignmentProvenanceDirectory: root.appendingPathComponent("provenance", isDirectory: true)
    )
}

private func withTemporaryRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SpotifyLyricsS1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    print("S1 preserved synthetic root: \(root.path)")
    return try await body(root)
}

private func installTrigger(databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw ContractFailure(description: "could not open temporary SQLite database for failure injection")
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw ContractFailure(description: "could not install temporary SQLite failure trigger")
    }
}

private func preferredVersionID(databaseURL: URL, stableKey: String) throws -> UUID? {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw ContractFailure(description: "could not open temporary SQLite database for readback")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT id FROM lyrics_versions WHERE track_stable_key = ? AND is_preferred = 1;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw ContractFailure(description: "could not prepare preferred-version readback")
    }
    defer { sqlite3_finalize(statement) }
    _ = stableKey.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else { return nil }
    return UUID(uuidString: String(cString: value))
}

private func timingOwnerVersionID(databaseURL: URL, timingVersionID: UUID) throws -> UUID? {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw ContractFailure(description: "could not open temporary SQLite database for timing-owner readback")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT lyrics_version_id FROM lyrics_timing_versions WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw ContractFailure(description: "could not prepare timing-owner readback")
    }
    defer { sqlite3_finalize(statement) }
    _ = timingVersionID.uuidString.withCString {
        sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else { return nil }
    return UUID(uuidString: String(cString: value))
}

private actor ManualAdoptionGate {
    private var isOpen = false
    private var isWaiting = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        if isOpen { return }
        isWaiting = true
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    func waitUntilBlocked() async throws {
        for _ in 0..<200 {
            if isWaiting { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ContractFailure(description: "manual adoption did not reach the injected external-I/O gate")
    }
}

/// Delays one repository call, then delegates every persistence operation to
/// the production SQLite actor. It contains no persistence or selection logic.
private struct DeferredManualAdoptionRepository: LyricsRepository {
    let base: SQLiteLyricsRepository
    let gate: ManualAdoptionGate
    let delayedRequestID: UUID
    let forcedManualResult: LyricsPersistenceSaveResult?

    func prepare() async throws { try await base.prepare() }
    func loadAliases(stableKey: String) async throws -> [TrackAlias] { try await base.loadAliases(stableKey: stableKey) }
    func saveTrackMetadata(_ metadata: TrackMetadata) async throws { try await base.saveTrackMetadata(metadata) }
    func loadBest(track: Track, identity: TrackIdentity) async throws -> LyricsDocument? { try await base.loadBest(track: track, identity: identity) }
    func loadBestStored(track: Track, identity: TrackIdentity) async throws -> StoredLyricsDocument? { try await base.loadBestStored(track: track, identity: identity) }
    func upsertListeningHistory(_ entry: ListeningHistoryEntry) async throws { try await base.upsertListeningHistory(entry) }
    func loadListeningHistory(limit: Int) async throws -> [ListeningHistoryEntry] { try await base.loadListeningHistory(limit: limit) }
    func loadListeningStatistics(for timeRange: ListeningStatisticsTimeRange) async throws -> ListeningStatistics { try await base.loadListeningStatistics(for: timeRange) }
    func alignmentProvenanceAvailability(versionID: UUID) async -> AlignmentProvenanceAvailability { await base.alignmentProvenanceAvailability(versionID: versionID) }
    func registerManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws { try await base.registerManualAdoptionRequest(identity: identity, requestID: requestID) }
    func cancelManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws { try await base.cancelManualAdoptionRequest(identity: identity, requestID: requestID) }
    func save(track: Track, identity: TrackIdentity, document: LyricsDocument) async throws -> LyricsPersistenceSaveResult { try await base.save(track: track, identity: identity, document: document) }
    func saveAndAdoptManually(track: Track, identity: TrackIdentity, document: LyricsDocument, requestID: UUID, confirmedLockedVersionIDs: [UUID]?) async throws -> LyricsPersistenceSaveResult {
        print("S1 repository proxy manual save request=\(requestID)")
        if requestID == delayedRequestID { await gate.pause() }
        if let forcedManualResult { return forcedManualResult }
        let result = try await base.saveAndAdoptManually(
            track: track,
            identity: identity,
            document: document,
            requestID: requestID,
            confirmedLockedVersionIDs: confirmedLockedVersionIDs
        )
        print("S1 repository proxy manual save result=\(result.disposition)")
        return result
    }
    func saveAlignedVersion(_ request: AlignmentPersistenceRequest) async throws -> LyricsPersistenceSaveResult { try await base.saveAlignedVersion(request) }
    func deleteLyricsVersion(versionID: UUID) async throws { try await base.deleteLyricsVersion(versionID: versionID) }
    func markLocked(versionID: UUID, locked: Bool) async throws { try await base.markLocked(versionID: versionID, locked: locked) }
    func statistics() async throws -> LyricsDatabaseStats { try await base.statistics() }
    func createBackup() async throws -> URL { try await base.createBackup() }
    func clearLyricsCache() async throws { try await base.clearLyricsCache() }
}

@main
@MainActor
struct S1DurableManualAdoptionContract {
    static func main() async {
        let privateHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).resolvingSymlinksInPath()
        precondition(FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() == privateHome, "contract preferences must be private")
        let homeAttributes = try! FileManager.default.attributesOfItem(atPath: privateHome.path)
        precondition((homeAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let scenario = CommandLine.arguments.dropFirst().first ?? "all"
        let scenarios = scenario == "all"
            ? ["force-refresh-protected", "lyrics-ovh-zero", "kugou-half", "timed-spans", "auto-search-timed-reopen", "auto-search-disabled-loads-selection", "locked-current", "selection-throws", "timing-throws", "invalid-content", "failed-results", "track-switch", "same-track-order"]
            : [scenario]
        var failures = 0
        for item in scenarios {
            do {
                try await run(item)
                print("S1 manual adoption scenario passed: \(item)")
            } catch {
                failures += 1
                print("S1 manual adoption scenario failed: \(item): \(error)")
            }
        }
        exit(failures > 0 ? 1 : 0)
    }

    private static func run(_ scenario: String) async throws {
        switch scenario {
        case "force-refresh-protected": try await forceRefreshProtectedSelectionContract()
        case "bilingual-auto-cache": try await bilingualAutomaticCacheContract()
        case "selection-read-fails": try await failedSelectionReadStopsSearch()
        case "revoke-schema": try await revocationSchemaCompatibility()
        case "revoke-progress": try await previewProgressSession()
        case "revoke-selection": try await revocationSelectionContract()
        case "revoke-rollback": try await revocationRollbackContract()
        case "lyrics-ovh-zero": try await lowConfidenceAdoption(source: .lyricsOVH, confidence: 0, suffix: "ovh", isSynchronized: false)
        case "kugou-half": try await lowConfidenceAdoption(source: .kugouExperimental, confidence: 0.5, suffix: "kugou")
        case "timed-spans": try await lowConfidenceAdoption(source: .amll, confidence: 0.5, suffix: "timed", hasTiming: true)
        case "auto-search-timed-reopen": try await automaticSearchPersistsBestTimedCandidate()
        case "auto-search-disabled-loads-selection": try await disabledAutoSearchLoadsStoredSelectionWithoutProviderCalls()
        case "locked-current": try await lockedCurrentRequiresConfirmation()
        case "selection-throws": try await preferredSelectionFailureRollsBack()
        case "timing-throws": try await timingAttachmentFailureRollsBack()
        case "invalid-content": try await invalidIdentityAndContentAreRejected()
        case "failed-results": try await rejectedAndSkippedResultsPreserveCurrent()
        case "track-return": try await lateAdoptionStaysBoundToItsTrack(returnToA: true)
        case "track-switch": try await lateAdoptionStaysBoundToItsTrack()
        case "same-track-order": try await newerSameTrackRequestWins()
        default: throw ContractFailure(description: "unknown scenario \(scenario)")
        }
    }

    private static func forceRefreshProtectedSelectionContract() async throws {
        for kind in ["preferred", "manual", "locked"] {
            try await withTemporaryRoot { root in
                let track = makeTrack("refresh-\(kind)"), identity = TrackIdentity(track: makeTrack("refresh-\(kind)"))
                let old = makeCandidate(track: track, source: kind == "manual" ? .manualCreate : .lrclib,
                    confidence: 1, providerID: "protected-old").makeDocument()
                let repo = makeRepository(root: root)
                try await repo.prepare()
                let saved = try await repo.save(track: track, identity: identity, document: old)
                guard let id = saved.versionID, let hash = saved.sourceContentHash else { throw ContractFailure(description: "refresh source missing") }
                try await repo.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: id)
                if kind == "locked" { try await repo.markLocked(versionID: id, locked: true) }
                // Manual/locked fixtures clear preferred so each protection is independent.
                if kind != "preferred" { try installTrigger(databaseURL: root.appendingPathComponent("lyrics.sqlite3"),
                    sql: "UPDATE lyrics_versions SET is_preferred = 0;") }
                let fresh = makeCandidate(track: track, source: .amll, confidence: 1, providerID: "refresh-candidate", hasTiming: true)
                let counter = LyricsProviderCallCounter()
                let provider = CountingLyricsProvider(name: "refresh-fixture", counter: counter, result: .match(fresh.makeDocument()))
                let session = LyricsSessionController(providers: [provider], repository: repo)
                session.begin(track: track, identity: identity)
                for _ in 0..<200 where session.isSearchInProgress { try await Task.sleep(nanoseconds: 5_000_000) }
                try check(session.activeLyricsVersionID == id && session.activeSourceContentHash == hash, "initial protected load mismatch")
                let projection = session.lyrics
                // Repository reads regenerate UI line UUIDs; compare display/timing, not ephemeral IDs.
                func sameProjection(_ lines: [LyricLine]) -> Bool {
                    lines.count == projection.count && zip(lines, projection).allSatisfy {
                        $0.0.originalText == $0.1.originalText && $0.0.timestamp == $0.1.timestamp
                            && $0.0.endTime == $0.1.endTime && $0.0.timedSpans == $0.1.timedSpans
                            && $0.0.translationText == $0.1.translationText && $0.0.kanaText == $0.1.kanaText
                            && $0.0.romajiText == $0.1.romajiText
                    }
                }
                try check(projection.map(\.originalText) == old.lines.map(\.originalText), "protected original changed")
                let preferredBefore = try preferredVersionID(databaseURL: root.appendingPathComponent("lyrics.sqlite3"), stableKey: identity.stableKey)
                session.retry(track: track, identity: identity)
                try check(session.activeLyricsVersionID == id && session.activeSourceContentHash == hash && sameProjection(session.lyrics),
                    "retry immediately cleared protected projection/ID/hash")
                for _ in 0..<400 where session.isSearchInProgress {
                    try check(session.activeLyricsVersionID == id && session.activeSourceContentHash == hash && sameProjection(session.lyrics),
                        "provisional refresh replaced protected projection")
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let calls = await counter.value()
                try check(!session.isSearchInProgress && calls > 0, "forced search did not complete")
                try check(session.activeLyricsVersionID == id && session.activeSourceContentHash == hash && sameProjection(session.lyrics),
                    "final refresh replaced protected projection")
                try check(session.availableCandidates.contains { $0.providerSourceID == "refresh-candidate" }, "refresh result missing from candidates")
                try check(try preferredVersionID(databaseURL: root.appendingPathComponent("lyrics.sqlite3"), stableKey: identity.stableKey) == preferredBefore,
                    "refresh changed persisted preferred selection")
                let reopened = makeRepository(root: root)
                try await reopened.prepare()
                let second = LyricsSessionController(providers: [provider], repository: reopened)
                second.begin(track: track, identity: identity)
                for _ in 0..<200 where second.isSearchInProgress { try await Task.sleep(nanoseconds: 5_000_000) }
                try check(second.activeLyricsVersionID == id && second.activeSourceContentHash == hash && sameProjection(second.lyrics),
                    "reopen lost protected selection")
                print("PASS force refresh \(kind): active projection/ID/hash retained throughout; candidates only; SQLite reopen unchanged")
            }
        }
    }

    private static func bilingualAutomaticCacheContract() async throws {
        try await withTemporaryRoot { root in
            let a = Track(title: "GIJIKOI", artist: "Haruki Hamano", album: "GIJIKOI (Korean ver.)", duration: 216.875, spotifyId: "0ZLWH8kZv299eRlEoMelAD")
            let b = makeTrack("protected-B")
            let aIdentity = TrackIdentity(track: a), bIdentity = TrackIdentity(track: b)
            let repository = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("contract.sqlite3"))
            try await repository.prepare()
            let bDocument = makeCandidate(track: b, source: .local, confidence: 1, providerID: "existing-B").makeDocument()
            let bSaved = try await repository.save(track: b, identity: bIdentity, document: bDocument)
            guard let bID = bSaved.versionID else { throw ContractFailure(description: "seed B missing") }
            try await repository.setPersonalLibraryActiveLyrics(trackStableKey: bIdentity.stableKey, lyricsVersionID: bID)
            let candidate = LyricsCandidate(id: "isolated:gijikoi", identity: aIdentity, title: "ギジコイ - GIJIKOI", artist: "Haruki Hamano", album: "GIJIKOI", duration: 217,
                lines: [LyricLine(timestamp: 1, originalText: "Self-authored line one"), LyricLine(timestamp: 3, originalText: "Self-authored line two")], isSynchronized: true, source: .lrclib, confidence: 0.46, providerSourceID: "isolated:gijikoi")
            let counter = LyricsProviderCallCounter()
            let provider = CountingLyricsProvider(name: "LRCLIB isolated", counter: counter, result: .candidates([candidate]))
            let session = LyricsSessionController(providers: [provider], repository: repository)
            session.begin(track: a, identity: aIdentity, automaticallySearch: true)
            for _ in 0..<400 where session.isSearchInProgress { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!session.isSearchInProgress, "isolated session did not settle")
            guard let aID = session.activeLyricsVersionID else { throw ContractFailure(description: "bilingual search stopped before automatic adoption/save") }
            try check(session.activeDocument?.lines.map(\.originalText) == candidate.lines.map(\.originalText), "automatic display changed original")
            try check(session.activeDocument?.lines.map(\.timestamp) == [1, 3], "automatic display changed timing")
            try check(await counter.value() == 1, "unexpected repeated lookup")
            session.begin(track: b, identity: bIdentity, automaticallySearch: true); for _ in 0..<400 where session.isSearchInProgress { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!session.isSearchInProgress, "isolated session did not settle")
            try check(session.activeLyricsVersionID == bID, "manual preferred B was overwritten")
            session.begin(track: a, identity: aIdentity, automaticallySearch: true); for _ in 0..<400 where session.isSearchInProgress { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!session.isSearchInProgress, "isolated session did not settle")
            try check(session.activeLyricsVersionID == aID, "A-B-A changed cached selected version")
            try check(await counter.value() == 1, "return to A failed cache reuse")
            let reopened = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("contract.sqlite3"))
            let restored = LyricsSessionController(providers: [provider], repository: reopened)
            restored.begin(track: a, identity: aIdentity, automaticallySearch: true); for _ in 0..<400 where restored.isSearchInProgress { try await Task.sleep(nanoseconds: 5_000_000) }
            try check(!restored.isSearchInProgress, "isolated reopen did not settle")
            try check(restored.activeLyricsVersionID == aID && restored.activeDocument?.lines.map(\.timestamp) == [1, 3], "reopen did not restore exact original and timing")
            try check(await counter.value() == 1, "reopen dispatched a provider instead of reading cache")
            print("PASS bilingual automatic search/display/save, protected B, A-B-A and normal repository reopen cache zero additional lookup")
        }
    }

    private static func failedSelectionReadStopsSearch() async throws {
        try await withTemporaryRoot { root in
            let repo = makeRepository(root: root);try await repo.prepare()
            try installTrigger(databaseURL: repo.databaseURL, sql: "DROP TABLE lyrics_selection_revocations;")
            let track = makeTrack("unreadable-selection");let counter = LyricsProviderCallCounter()
            let session = LyricsSessionController(providers: [CountingLyricsProvider(name: "must not search", counter: counter, result: .noMatch)], repository: repo)
            session.begin(track: track, identity: TrackIdentity(track: track))
            for _ in 0..<200 { if case .failed = session.state { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            guard case .failed = session.state else { throw ContractFailure(description: "selection read failure must stop automatic search") }
            try check(await counter.value() == 0 && session.activeLyricsVersionID == nil, "cannot bypass unreadable persisted choice")
        }
    }

    private static func revocationSchemaCompatibility() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("old-schema")
            let identity = TrackIdentity(track: track)
            let original = makeRepository(root: root)
            try await original.prepare()
            let candidate = makeCandidate(track: track, source: .neteaseExperimental, confidence: 1, providerID: "fixture:old-schema")
            let saved = try await original.save(track: track, identity: identity, document: candidate.makeDocument())
            let id = saved.versionID!
            let before = try await original.loadEditableVersion(versionID: id, track: track, identity: identity)
            try installTrigger(databaseURL: original.databaseURL, sql: "DROP INDEX translation_requests_completion_id; ALTER TABLE translation_requests DROP COLUMN completion_version_id; DELETE FROM schema_migrations WHERE version>11; DROP TABLE lyrics_selection_revocations; PRAGMA user_version=11;")
            let migrated = makeRepository(root: root)
            try await migrated.prepare()
            let after = try await migrated.loadEditableVersion(versionID: id, track: track, identity: identity)
            try check(before?.record == after?.record && before?.lines == after?.lines, "v11 assets unchanged after additive v12 migration")
            try check(!(try await migrated.isLyricsSelectionRevoked(identity: identity)), "old selection not implicitly revoked")
            try await migrated.revokeLyricsVersionSelection(trackStableKey: identity.stableKey, lyricsVersionID: id)
            let again = makeRepository(root: root);try await again.prepare()
            try check(try await again.isLyricsSelectionRevoked(identity: identity), "v12 repeated prepare retains revocation")
        }
    }

    private static func previewProgressSession() async throws {
        let track = Track(title: "アーカイブ - Sped Up Ver.", artist: "stb", album: "アーカイブ", duration: 211.327, spotifyId: "fixture:sped-progress")
        let identity = TrackIdentity(track: track)
        let candidate = LyricsCandidate(id: "preview:normal", identity: identity, title: "アーカイブ", artist: "stb", album: "アーカイブ", duration: 238.977,
            lines: [LyricLine(timestamp: 8, originalText: "自写测试")], source: .neteaseExperimental, confidence: 1)
        struct DelayedFailure: LyricsProvider {
            let name = "slow500"
            var executionLane: LyricsProviderExecutionLane { .network }
            func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return .failed(.cancelled) }
                return .failed(.serverError(500))
            }
        }
        let session = LyricsSessionController(providers: [DelayedFailure(), FixedLyricsProvider(name: "preview", result: .candidates([candidate]))])
        session.begin(track: track, identity: identity)
        for _ in 0..<40 { if case .candidates = session.state { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        guard case .candidates(_, let previews) = session.state else { throw ContractFailure(description: "preview must publish while search remains active") }
        try check(session.isSearchInProgress && previews.count == 1 && !previews[0].isSynchronized && previews[0].lines[0].timestamp == 0, "preview available before 500, with incompatible timing stripped")
        let other = makeTrack("progress-other")
        session.begin(track: other, identity: TrackIdentity(track: other), automaticallySearch: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        try check(session.activeIdentity == TrackIdentity(track: other) && session.lyrics.isEmpty && session.availableCandidates.isEmpty, "late progress/final cannot enter next song")
    }

    private static func revocationSelectionContract() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("revocation")
            let identity = TrackIdentity(track: track)
            let repo = makeRepository(root: root)
            try await repo.prepare()
            let request = UUID()
            let candidate = makeCandidate(track: track, source: .neteaseExperimental, confidence: 0.95, providerID: "netease:fixture", isSynchronized: false)
            try await repo.registerManualAdoptionRequest(identity: identity, requestID: request)
            let saved = try await repo.saveAndAdoptManually(track: track, identity: identity, document: candidate.makeDocument(), requestID: request, confirmedLockedVersionIDs: nil)
            guard let id = saved.versionID else { throw ContractFailure(description: "adoption setup") }
            try await repo.markLocked(versionID: id, locked: true)
            let translationID = UUID()
            try installTrigger(databaseURL: repo.databaseURL, sql: """
                INSERT INTO translation_versions(id, lyrics_version_id, source_kind, target_language, source_content_hash, created_at, updated_at, status, is_manually_edited, is_locked)
                VALUES ('\(translationID.uuidString)', '\(id.uuidString)', 'manual', 'zh-Hans', '\(saved.sourceContentHash ?? "fixture")', 1, 1, 'complete', 1, 1);
                INSERT INTO translation_lines VALUES ('\(translationID.uuidString)', 0, '自写人工译文');
                INSERT INTO lyric_reading_layers VALUES ('\(id.uuidString)', 0, 'じしゃ', 'jisha', 'manual', 1, 1, 1);
                CREATE TRIGGER protect_translation BEFORE DELETE ON translation_versions BEGIN SELECT RAISE(ABORT, 'protected translation touched'); END;
                CREATE TRIGGER protect_translation_update BEFORE UPDATE ON translation_versions BEGIN SELECT RAISE(ABORT, 'protected translation changed'); END;
                CREATE TRIGGER protect_translation_line BEFORE DELETE ON translation_lines BEGIN SELECT RAISE(ABORT, 'protected translation line touched'); END;
                CREATE TRIGGER protect_translation_line_update BEFORE UPDATE ON translation_lines BEGIN SELECT RAISE(ABORT, 'protected translation line changed'); END;
                """)
            let before = try await repo.loadEditableVersion(versionID: id, track: track, identity: identity)
            let other = makeTrack("unrelated")
            let otherIdentity = TrackIdentity(track: other)
            let otherDocument = makeCandidate(track: other, source: .lrclib, confidence: 1, providerID: "other").makeDocument()
            _ = try await repo.save(track: other, identity: otherIdentity, document: otherDocument)
            let pending = UUID()
            try await repo.registerManualAdoptionRequest(identity: identity, requestID: pending)
            try await repo.revokeLyricsVersionSelection(trackStableKey: identity.stableKey, lyricsVersionID: id)
            try check(try preferredVersionID(databaseURL: repo.databaseURL, stableKey: identity.stableKey) == nil, "preferred binding removed")
            try check(try await repo.loadBestStored(track: track, identity: identity) == nil, "locked/high confidence cannot restore revoked selection")
            let after = try await repo.loadEditableVersion(versionID: id, track: track, identity: identity)
            // Runtime projection UUIDs are regenerated on read; compare the
            // actual persisted rows, not those ephemeral projection identities.
            try check(after?.record == before?.record && after?.lines == before?.lines && after?.lockedReadingLayers == before?.lockedReadingLayers, "all persisted source rows and lock unchanged")
            try check(try await repo.loadBestStored(track: other, identity: otherIdentity) != nil, "other song unaffected")
            let late = try await repo.saveAndAdoptManually(track: track, identity: identity, document: candidate.makeDocument(), requestID: pending, confirmedLockedVersionIDs: [])
            try check(late.versionID == nil, "pending manual adoption invalidated")
            let lateAutomatic = try await repo.save(track: track, identity: identity, document: candidate.makeDocument())
            try check(lateAutomatic.versionID == nil, "old automatic save cannot revive selection")
            let reopened = makeRepository(root: root)
            try await reopened.prepare()
            try check(try await reopened.loadBestStored(track: track, identity: identity) == nil, "new repository retains no-selection")
            let counter = LyricsProviderCallCounter()
            let provider = CountingLyricsProvider(name: "fixture", counter: counter, result: .candidates([candidate]))
            let session = LyricsSessionController(providers: [provider], repository: reopened)
            session.begin(track: track, identity: identity)
            for _ in 0..<200 { if session.isNoSelection { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(session.isNoSelection && session.lyrics.isEmpty, "session reopen does not auto search/adopt")
            try check(await counter.value() == 0, "revoked reopen sends zero provider requests")
            session.retry(track: track, identity: identity)
            for _ in 0..<200 { if case .candidates = session.state { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            guard case .candidates(_, let previews) = session.state else { throw ContractFailure(description: "explicit search must show previews") }
            try check(session.lyrics.isEmpty && session.activeLyricsVersionID == nil && !previews.isEmpty, "explicit search stays preview-only after cancellation")
            try check(try await reopened.loadBestStored(track: track, identity: identity) == nil, "manual search does not resurrect cached preferred")
            try await reopened.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: id)
            session.begin(track: track, identity: identity)
            for _ in 0..<200 { if session.activeLyricsVersionID == id { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try check(session.activeLyricsVersionID == id, "explicit re-adoption clears persistent cancellation")
            session.selectNoVersion(identity: identity)
            try check(try await reopened.loadBestStored(track: track, identity: identity)?.versionID == id, "temporary hide keeps persistent choice")
            session.begin(track: other, identity: otherIdentity)
            try check(!(try await session.revokeCurrentVersion(identity: identity, versionID: id)), "stale song revoke rejected")
            try check(try await reopened.loadBestStored(track: track, identity: identity)?.versionID == id, "stale revoke cannot clear previous explicit choice")
        }
    }

    private static func revocationRollbackContract() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("rollback-revoke")
            let identity = TrackIdentity(track: track)
            let repo = makeRepository(root: root)
            try await repo.prepare()
            let request = UUID()
            let candidate = makeCandidate(track: track, source: .neteaseExperimental, confidence: 0.95, providerID: "fixture:rollback")
            try await repo.registerManualAdoptionRequest(identity: identity, requestID: request)
            let saved = try await repo.saveAndAdoptManually(track: track, identity: identity, document: candidate.makeDocument(), requestID: request, confirmedLockedVersionIDs: nil)
            let id = saved.versionID!
            try installTrigger(databaseURL: repo.databaseURL, sql: "CREATE TRIGGER revoke_fail BEFORE INSERT ON lyrics_selection_revocations BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
            do { try await repo.revokeLyricsVersionSelection(trackStableKey: identity.stableKey, lyricsVersionID: id); throw ContractFailure(description: "must fail") }
            catch let error as ContractFailure { throw error }
            catch { }
            try check(try preferredVersionID(databaseURL: repo.databaseURL, stableKey: identity.stableKey) == id, "failed revocation rolls back preferred binding")
            try check(try await repo.loadBestStored(track: track, identity: identity)?.versionID == id, "original asset still loads after failed revoke")
        }
    }

    private static func automaticSearchPersistsBestTimedCandidate() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("nightly-auto")
            let identity = TrackIdentity(track: track)
            let partialTimed = makeCandidate(
                track: track,
                source: .amll,
                confidence: 1,
                providerID: "valid-partial-timing",
                isSynchronized: false,
                hasTiming: true,
                explicitlyTimedLineIndices: [0]
            )
            var invalidLine = partialTimed.lines[0]
            invalidLine.timedSpans = [TimedTextSpan(
                id: 0,
                text: "wrong",
                startTime: 1.4,
                endTime: 1.2,
                utf16Start: 0,
                utf16Length: 1
            )]
            let invalidTimed = LyricsCandidate(
                id: "invalid-timing",
                identity: identity,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                lines: [invalidLine],
                isSynchronized: false,
                source: .lrclib,
                confidence: 1,
                providerSourceID: "invalid-timing"
            )
            let mixedMalformed = LyricsCandidate(
                id: "mixed-malformed-timing",
                identity: identity,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                lines: [partialTimed.lines[0], invalidLine],
                isSynchronized: false,
                source: .amll,
                confidence: 1,
                providerSourceID: "mixed-malformed-timing",
                spotifyTrackID: track.spotifyId,
                explicitlyTimedLineIndices: [0, 1]
            )
            let plain = makeCandidate(
                track: track,
                source: .lrclib,
                confidence: 1,
                providerID: "plain-exact"
            )
            let provider = FixedLyricsProvider(
                name: "isolated automatic-selection fixture",
                result: .candidates([mixedMalformed, invalidTimed, plain, partialTimed])
            )

            @MainActor func runInitialSession() async throws -> UUID {
                let repository = makeRepository(root: root)
                let session = LyricsSessionController(providers: [provider], repository: repository)
                session.begin(track: track, identity: identity, automaticallySearch: true)
                for _ in 0..<200 {
                    if let versionID = session.activeLyricsVersionID {
                        guard let document = session.activeDocument else {
                            throw ContractFailure(description: "automatic search saved a version without publishing its document")
                        }
                        try check(document.source == .amll, "best timed provider source was not selected")
                        try check(document.providerSourceID == partialTimed.providerSourceID, "candidate with mixed valid/malformed spans was persisted instead of the valid partial timing source")
                        try check(!document.isSynchronized, "partial timing semantics changed during automatic search")
                        try check(document.explicitlyTimedLineIndices == Set([0]), "partial timing mask was lost during automatic search")
                        try check(document.lines.first?.timedSpans == partialTimed.lines.first?.timedSpans, "valid provider spans changed during automatic search")
                        return versionID
                    }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                throw ContractFailure(description: "automatic search did not persist a selected version")
            }

            let selectedVersionID = try await runInitialSession()
            let reopened = makeRepository(root: root)
            try await reopened.prepare()
            guard let stored = try await reopened.loadBestStored(track: track, identity: identity) else {
                throw ContractFailure(description: "automatic selection did not survive database reopen")
            }
            try check(stored.versionID == selectedVersionID, "reopen selected a different automatic version")
            try check(stored.document.source == .amll, "reopen changed the selected provider")
            try check(stored.document.providerSourceID == partialTimed.providerSourceID, "reopen restored the mixed malformed timing source")
            try check(!stored.document.isSynchronized, "reopen changed partial timing semantics")
            try check(stored.document.explicitlyTimedLineIndices == Set([0]), "reopen lost explicit partial mask")
            try check(stored.document.timingVersionID != nil, "selected word spans have no persisted attachment")
            try check(stored.document.lines.first?.timedSpans == partialTimed.lines.first?.timedSpans, "reopen changed valid spans")

            let restoredSession = LyricsSessionController(providers: [], repository: reopened)
            restoredSession.begin(track: track, identity: identity, automaticallySearch: true)
            for _ in 0..<200 where restoredSession.activeLyricsVersionID != selectedVersionID {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try check(restoredSession.activeLyricsVersionID == selectedVersionID, "new session did not restore the same automatic selection")
            try check(restoredSession.activeDocument?.lines.first?.timedSpans == partialTimed.lines.first?.timedSpans, "restored session renderer input lost word timing")
            try check(restoredSession.activeDocument?.explicitlyTimedLineIndices == Set([0]), "restored session renderer input lost partial mask")
        }
    }

    private static func disabledAutoSearchLoadsStoredSelectionWithoutProviderCalls() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("auto-disabled-stored")
            let identity = TrackIdentity(track: track)
            let preferred = makeCandidate(
                track: track,
                source: .amll,
                confidence: 1,
                providerID: "persisted-preferred"
            ).makeDocument()
            let alternate = makeCandidate(
                track: track,
                source: .lrclib,
                confidence: 0.96,
                providerID: "persisted-alternate"
            ).makeDocument()
            let repository = makeRepository(root: root)
            try await repository.prepare()
            guard let preferredID = try await repository.save(
                track: track,
                identity: identity,
                document: preferred
            ).versionID,
            try await repository.save(track: track, identity: identity, document: alternate).versionID != nil else {
                throw ContractFailure(description: "auto-search-disabled fixture versions were not saved")
            }
            try await repository.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: preferredID)
            try await repository.markLocked(versionID: preferredID, locked: true)

            let counter = LyricsProviderCallCounter()
            let provider = CountingLyricsProvider(
                name: "must-not-run-when-auto-search-is-disabled",
                counter: counter,
                result: .noMatch
            )
            let session = LyricsSessionController(providers: [provider], repository: repository)
            session.begin(track: track, identity: identity, automaticallySearch: false)

            for _ in 0..<200 where session.activeLyricsVersionID != preferredID {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try check(session.activeLyricsVersionID == preferredID, "turning off automatic search skipped the persisted preferred/locked lyric load")
            try check(session.activeDocument?.identity == identity, "disabled auto-search restored a document for the wrong song")
            try check(session.activeDocument?.source == preferred.source, "disabled auto-search changed the selected source")
            try check(session.activeDocument?.lines.map(\.originalText) == preferred.lines.map(\.originalText), "disabled auto-search did not restore the selected original text")
            try check(session.automaticSearchDisabledForCurrentTrack, "session did not retain the disabled-search reason for the current track")
            try check(await counter.value() == 0, "provider was queried while automatic search was disabled")

            let uncachedTrack = makeTrack("auto-disabled-empty")
            let uncachedIdentity = TrackIdentity(track: uncachedTrack)
            session.begin(track: uncachedTrack, identity: uncachedIdentity, automaticallySearch: false)
            for _ in 0..<200 where session.state != .idle {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try check(session.state == .idle, "disabled automatic search should settle to idle when no saved version exists")
            try check(session.automaticSearchDisabledForCurrentTrack, "idle state lost the disabled-search reason")
            try check(await counter.value() == 0, "provider was queried for an uncached track while automatic search was disabled")

            session.retry(track: uncachedTrack, identity: uncachedIdentity)
            for _ in 0..<200 {
                if await counter.value() > 0 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try check(await counter.value() > 0, "explicit manual retry was blocked by the automatic-search preference")
            try check(!session.automaticSearchDisabledForCurrentTrack, "manual search still presented the automatic-search-disabled state")
        }
    }

    private static func lowConfidenceAdoption(
        source: LyricsSource,
        confidence: Double,
        suffix: String,
        isSynchronized: Bool = true,
        hasTiming: Bool = false
    ) async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack(suffix)
            let identity = TrackIdentity(track: track)
            let candidate = makeCandidate(
                track: track,
                source: source,
                confidence: confidence,
                providerID: "provider-record-\(suffix)",
                isSynchronized: isSynchronized,
                hasTiming: hasTiming
            )
            let expected = candidate.makeDocument()
            let versionID: UUID
            do {
                let repository = makeRepository(root: root)
                try await repository.prepare()
                let automatic = try await repository.save(track: track, identity: identity, document: expected)
                if case .rejected = automatic.disposition {} else {
                    throw ContractFailure(description: "automatic low-confidence save bypassed the existing gate")
                }
                try check(try await repository.versionCount(trackStableKey: identity.stableKey) == 0, "automatic low-confidence save wrote an asset")

                let session = LyricsSessionController(providers: [], repository: repository)
                session.begin(track: track, identity: identity, automaticallySearch: false)
                let requestID = UUID()
                try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: requestID), "manual request did not bind to the active song")
                let didShowCurrentBeforeCommit = session.activeDocument != nil || session.activeLyricsVersionID != nil
                let result = try await session.adoptManually(document: expected, track: track, requestID: requestID)
                guard let savedID = result.versionID else {
                    throw ContractFailure(description: "manual adoption returned no committed version id: \(result.disposition)")
                }
                versionID = savedID
                try check(result.disposition == .inserted, "new manual candidate was not inserted atomically")
                try check(!didShowCurrentBeforeCommit, "candidate was presented as current before commit")
                try check(session.activeLyricsVersionID == savedID, "session did not publish the committed version after success")
                let stored = try await repository.loadBestStored(track: track, identity: identity)
                try check(stored?.versionID == savedID, "durable preferred version was not selected")
                try check(stored?.document.source == source, "provider source changed during manual adoption")
                try check(stored?.document.confidence == confidence, "provider confidence changed during manual adoption")
                try check(stored?.document.providerSourceID == candidate.providerSourceID, "provider record identity was not preserved")
                try check(try preferredVersionID(databaseURL: repository.databaseURL, stableKey: identity.stableKey) == savedID, "manual adoption did not persist the preferred choice")
                if hasTiming {
                    try check(stored?.document.timingVersionID != nil, "real spans did not receive a timing attachment")
                    try check(stored?.document.lines.first?.timedSpans == expected.lines.first?.timedSpans, "real spans changed during adoption")
                    try check(stored?.document.lines.first?.performerID == "v1", "timing performer metadata was lost")
                }
            }

            let reopened = makeRepository(root: root)
            try await reopened.prepare()
            let stored = try await reopened.loadBestStored(track: track, identity: identity)
            try check(stored?.versionID == versionID, "closed/reopened database selected a different lyrics version")
            try check(stored?.document.source == source && stored?.document.confidence == confidence, "source/confidence changed after reopen")
            try check(stored?.document.providerSourceID == candidate.providerSourceID, "provider identity changed after reopen")
            let restarted = LyricsSessionController(providers: [], repository: reopened)
            restarted.begin(track: track, identity: identity)
            try await Task.sleep(nanoseconds: 120_000_000)
            try check(restarted.activeLyricsVersionID == versionID, "new session did not restore the same preferred version")
            try check(restarted.activeDocument?.source == source, "new session restored a different source")
            if hasTiming {
                try check(stored?.document.timingVersionID != nil, "timing attachment identity was lost after reopen")
                try check(stored?.document.lines.first?.timedSpans == expected.lines.first?.timedSpans, "renderer input spans changed after reopen")
                try check(stored?.document.lines.first?.performerID == "v1", "renderer input performer changed after reopen")

                guard let parentTimingID = stored?.document.timingVersionID else {
                    throw ContractFailure(description: "timing parent had no attachment identity")
                }
                let duplicateRequestID = UUID()
                try check(try await restarted.beginManualAdoptionRequest(identity: identity, requestID: duplicateRequestID), "duplicate timing request did not bind")
                let duplicate = try await restarted.adoptManually(
                    document: expected,
                    track: track,
                    requestID: duplicateRequestID
                )
                try check(duplicate.disposition == .duplicate && duplicate.versionID == versionID, "existing candidate did not reuse its lyrics version identity")
                try check(duplicate.timingVersionID == parentTimingID, "identical duplicate candidate did not reuse its timing attachment identity")

                let childDocument = LyricsDocument(
                    identity: stored!.document.identity,
                    title: stored!.document.title,
                    artist: stored!.document.artist,
                    album: stored!.document.album,
                    duration: stored!.document.duration,
                    lines: stored!.document.lines,
                    isSynchronized: stored!.document.isSynchronized,
                    source: stored!.document.source,
                    confidence: stored!.document.confidence,
                    providerSourceID: "provider-record-\(suffix)-copy",
                    spotifyTrackID: stored!.document.spotifyTrackID,
                    isrc: stored!.document.isrc,
                    language: stored!.document.language,
                    explicitlyTimedLineIndices: stored!.document.explicitlyTimedLineIndices,
                    timingVersionID: parentTimingID
                )
                let copyRequestID = UUID()
                try check(try await restarted.beginManualAdoptionRequest(identity: identity, requestID: copyRequestID), "timing copy request did not bind")
                let copied = try await restarted.adoptManually(document: childDocument, track: track, requestID: copyRequestID)
                guard let copiedVersionID = copied.versionID, let copiedTimingID = copied.timingVersionID else {
                    throw ContractFailure(description: "copied timing document did not receive persisted identities")
                }
                try check(copied.disposition == .inserted && copiedVersionID != versionID, "timing copy did not create an independent lyrics version")
                try check(copiedTimingID != parentTimingID, "child version reused its parent's timing attachment identity")
                try check(try timingOwnerVersionID(databaseURL: reopened.databaseURL, timingVersionID: parentTimingID) == versionID, "parent attachment ownership changed")
                try check(try timingOwnerVersionID(databaseURL: reopened.databaseURL, timingVersionID: copiedTimingID) == copiedVersionID, "child attachment was bound to the wrong lyrics version")
                try check(restarted.activeDocument?.timingVersionID == copiedTimingID, "session published the parent's attachment identity for the child")
                let copiedStored = try await reopened.loadBestStored(track: track, identity: identity)
                try check(copiedStored?.versionID == copiedVersionID, "copied timed version was not persistently selected")
                try check(copiedStored?.document.timingVersionID == copiedTimingID, "copied timing attachment identity did not survive repository reload")
                try check(copiedStored?.document.lines.first?.timedSpans == expected.lines.first?.timedSpans, "copied timed spans changed")
            }
            print("durable manual adoption source=\(source.rawValue) confidence=\(confidence) version=\(versionID) reopened=true")
        }
    }

    private static func lockedCurrentRequiresConfirmation() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("locked")
            let identity = TrackIdentity(track: track)
            let current = LyricsDocument(
                identity: identity,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                lines: [LyricLine(timestamp: 4, originalText: "已锁定版本")],
                source: .lrclib,
                confidence: 0.98,
                providerSourceID: "locked-provider-record"
            )
            let second = LyricsDocument(
                identity: identity,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                lines: [LyricLine(timestamp: 8, originalText: "另一个锁定版本")],
                source: .local,
                confidence: 0.99,
                providerSourceID: "second-provider-record"
            )
            let repository = makeRepository(root: root)
            try await repository.prepare()
            guard let currentID = try await repository.save(track: track, identity: identity, document: current).versionID,
                  let secondID = try await repository.save(track: track, identity: identity, document: second).versionID else {
                throw ContractFailure(description: "locked fixture could not be saved")
            }
            try await repository.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: currentID)
            try await repository.markLocked(versionID: currentID, locked: true)

            let session = LyricsSessionController(providers: [], repository: repository)
            session.begin(track: track, identity: identity, automaticallySearch: false)
            let selected = try await repository.loadBestStored(track: track, identity: identity)
            guard let selected, let sourceHash = selected.sourceContentHash else {
                throw ContractFailure(description: "current locked fixture could not be loaded")
            }
            session.adoptPersisted(document: selected.document, versionID: currentID, sourceContentHash: sourceHash)

            let candidate = makeCandidate(track: track, source: .kugouExperimental, confidence: 0.5, providerID: "unlocked-candidate")
            let requestID = UUID()
            try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: requestID), "locked adoption request did not bind")
            let conflict = try await session.adoptManually(document: candidate.makeDocument(), track: track, requestID: requestID)
            try check(conflict.disposition == .lockedConflict, "locked current did not require explicit confirmation")
            try check(conflict.conflictingLockedVersionIDs == [currentID], "initial lock conflict returned the wrong locked version")
            try check(try await repository.versionCount(trackStableKey: identity.stableKey) == 2, "lock conflict wrote a candidate asset")
            try check(session.activeLyricsVersionID == currentID, "lock conflict published a candidate as current")
            try check(session.activeDocument?.lines.first?.originalText == "已锁定版本", "lock conflict replaced the live document")
            session.cancelManualAdoptionRequest(identity: identity, requestID: requestID)
            try check(try await repository.loadBestStored(track: track, identity: identity)?.versionID == currentID, "cancel changed the persistent choice")
            try check(try await repository.versionCount(trackStableKey: identity.stableKey) == 2, "cancel wrote a candidate asset")

            let confirmedRequestID = UUID()
            try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: confirmedRequestID), "confirmed adoption request did not bind")
            let firstConflict = try await session.adoptManually(document: candidate.makeDocument(), track: track, requestID: confirmedRequestID)
            try check(firstConflict.disposition == .lockedConflict, "second attempt did not recheck the existing lock")
            try await repository.markLocked(versionID: secondID, locked: true)
            let staleConfirmation = try await session.adoptManually(
                document: candidate.makeDocument(),
                track: track,
                requestID: confirmedRequestID,
                confirmedLockedVersionIDs: firstConflict.conflictingLockedVersionIDs
            )
            try check(staleConfirmation.disposition == .lockedConflict, "commit did not recheck a newly-added lock")
            try check(Set(staleConfirmation.conflictingLockedVersionIDs) == Set([currentID, secondID]), "commit conflict did not name the newly locked version")
            try check(try await repository.versionCount(trackStableKey: identity.stableKey) == 2, "stale lock confirmation wrote a candidate asset")
            let confirmed = try await session.adoptManually(
                document: candidate.makeDocument(),
                track: track,
                requestID: confirmedRequestID,
                confirmedLockedVersionIDs: staleConfirmation.conflictingLockedVersionIDs
            )
            guard let adoptedID = confirmed.versionID else { throw ContractFailure(description: "confirmed adoption did not commit") }
            try check(confirmed.disposition == .inserted, "confirmed candidate was not saved")
            try check(try await repository.loadBestStored(track: track, identity: identity)?.versionID == adoptedID, "confirmed candidate was not persisted as current")
            try check(Set(try lockedVersionIDs(databaseURL: repository.databaseURL, stableKey: identity.stableKey)) == Set([currentID, secondID]), "explicit adoption silently unlocked an old version")
            try check(try preferredVersionID(databaseURL: repository.databaseURL, stableKey: identity.stableKey) == adoptedID, "confirmed selection was not persisted")
            print("locked candidate: cancel unchanged; stale confirmation re-prompted; explicit confirmation selected candidate and retained locks")
        }
    }

    private static func preferredSelectionFailureRollsBack() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("selection-failure")
            let identity = TrackIdentity(track: track)
            let existing = LyricsDocument(
                identity: identity,
                lines: [LyricLine(timestamp: 3, originalText: "既有当前版本")],
                source: .lrclib,
                confidence: 0.98,
                providerSourceID: "old-version"
            )
            let repository = makeRepository(root: root)
            try await repository.prepare()
            guard let existingID = try await repository.save(track: track, identity: identity, document: existing).versionID else {
                throw ContractFailure(description: "existing selection fixture could not be saved")
            }
            try await repository.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: existingID)
            try installTrigger(
                databaseURL: repository.databaseURL,
                sql: "CREATE TRIGGER reject_s1_preferred BEFORE UPDATE OF is_preferred ON lyrics_versions WHEN NEW.is_preferred = 1 BEGIN SELECT RAISE(ABORT, 'injected S1 preferred update failure'); END;"
            )

            let session = LyricsSessionController(providers: [], repository: repository)
            session.begin(track: track, identity: identity, automaticallySearch: false)
            let stored = try await repository.loadBestStored(track: track, identity: identity)!
            session.adoptPersisted(document: stored.document, versionID: existingID, sourceContentHash: stored.sourceContentHash!)
            let candidate = makeCandidate(track: track, source: .kugouExperimental, confidence: 0.5, providerID: "selection-failure-candidate")
            let requestID = UUID()
            try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: requestID), "failure request did not bind")
            do {
                _ = try await session.adoptManually(document: candidate.makeDocument(), track: track, requestID: requestID)
                throw ContractFailure(description: "injected preferred-selection write failure was swallowed")
            } catch is ContractFailure {
                throw ContractFailure(description: "injected preferred-selection write failure was swallowed")
            } catch {
                // Expected SQLite exception from the production transaction.
            }
            try check(try await repository.versionCount(trackStableKey: identity.stableKey) == 1, "selection failure left an orphan candidate asset")
            try check(try await repository.loadBestStored(track: track, identity: identity)?.versionID == existingID, "selection failure changed the prior persistent choice")
            try check(session.activeLyricsVersionID == existingID, "selection failure changed the live current version")
            try check(session.activeDocument?.lines.first?.originalText == "既有当前版本", "selection failure replaced the live document")
            print("preferred-selection failure rolled back candidate rows and preserved the prior selection")
        }
    }

    private static func timingAttachmentFailureRollsBack() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("timing-failure")
            let identity = TrackIdentity(track: track)
            let existing = LyricsDocument(
                identity: identity,
                lines: [LyricLine(timestamp: 3, originalText: "既有当前版本")],
                source: .lrclib,
                confidence: 0.98,
                providerSourceID: "old-version"
            )
            let repository = makeRepository(root: root)
            try await repository.prepare()
            guard let existingID = try await repository.save(track: track, identity: identity, document: existing).versionID else {
                throw ContractFailure(description: "existing selection fixture could not be saved")
            }
            try await repository.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: existingID)
            try installTrigger(
                databaseURL: repository.databaseURL,
                sql: "CREATE TRIGGER reject_s1_timing BEFORE INSERT ON lyrics_timing_versions BEGIN SELECT RAISE(ABORT, 'injected S1 timing attachment failure'); END;"
            )

            let session = LyricsSessionController(providers: [], repository: repository)
            session.begin(track: track, identity: identity, automaticallySearch: false)
            let stored = try await repository.loadBestStored(track: track, identity: identity)!
            session.adoptPersisted(document: stored.document, versionID: existingID, sourceContentHash: stored.sourceContentHash!)
            let candidate = makeCandidate(track: track, source: .amll, confidence: 0.5, providerID: "timing-failure-candidate", hasTiming: true)
            let requestID = UUID()
            try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: requestID), "timing failure request did not bind")
            do {
                _ = try await session.adoptManually(document: candidate.makeDocument(), track: track, requestID: requestID)
                throw ContractFailure(description: "injected timing write failure was swallowed")
            } catch is ContractFailure {
                throw ContractFailure(description: "injected timing write failure was swallowed")
            } catch {
                // Expected SQLite exception from the production transaction.
            }
            try check(try await repository.versionCount(trackStableKey: identity.stableKey) == 1, "timing failure left an orphan candidate asset")
            try check(try await repository.loadBestStored(track: track, identity: identity)?.versionID == existingID, "timing failure changed the prior persistent choice")
            try check(session.activeLyricsVersionID == existingID, "timing failure changed the live current version")
            print("timing-attachment failure rolled back candidate rows and preserved the prior selection")
        }
    }

    private static func invalidIdentityAndContentAreRejected() async throws {
        try await withTemporaryRoot { root in
            let track = makeTrack("validation")
            let identity = TrackIdentity(track: track)
            let repository = makeRepository(root: root)
            try await repository.prepare()
            let wrongIdentity = TrackIdentity(track: makeTrack("wrong"))
            let wrongDocument = LyricsDocument(
                identity: wrongIdentity,
                lines: [LyricLine(timestamp: 0, originalText: "错误歌曲歌词")],
                source: .lyricsOVH,
                confidence: 0,
                providerSourceID: "wrong-identity"
            )
            let requestID = UUID()
            try await repository.registerManualAdoptionRequest(identity: identity, requestID: requestID)
            let wrong = try await repository.saveAndAdoptManually(
                track: track,
                identity: identity,
                document: wrongDocument,
                requestID: requestID,
                confirmedLockedVersionIDs: nil
            )
            try check(wrong.versionID == nil, "wrong identity was accepted")
            let mismatchedClaim = LyricsDocument(
                identity: identity,
                lines: [LyricLine(timestamp: 0, originalText: "其他 Spotify 歌曲歌词")],
                source: .lyricsOVH,
                confidence: 0,
                providerSourceID: "mismatched-claim",
                spotifyTrackID: "s1-adoption-not-validation"
            )
            let mismatched = try await repository.saveAndAdoptManually(
                track: track,
                identity: identity,
                document: mismatchedClaim,
                requestID: requestID,
                confirmedLockedVersionIDs: nil
            )
            try check(mismatched.versionID == nil, "mismatched independent Spotify identity claim was accepted")
            let empty = LyricsDocument(
                identity: identity,
                lines: [LyricLine(timestamp: 0, originalText: "  \n")],
                source: .lyricsOVH,
                confidence: 0,
                providerSourceID: "empty-body"
            )
            let incomplete = try await repository.saveAndAdoptManually(
                track: track,
                identity: identity,
                document: empty,
                requestID: requestID,
                confirmedLockedVersionIDs: nil
            )
            try check(incomplete.versionID == nil, "incomplete lyrics were accepted")
            try check(try await repository.versionCount(trackStableKey: identity.stableKey) == 0, "invalid candidates wrote database rows")
        }
    }

    private static func rejectedAndSkippedResultsPreserveCurrent() async throws {
        for disposition in [
            LyricsPersistenceSaveDisposition.rejected("injected repository rejection"),
            LyricsPersistenceSaveDisposition.skippedLocked
        ] {
            try await withTemporaryRoot { root in
                let base = makeRepository(root: root)
                try await base.prepare()
                let track = makeTrack("failure-\(String(describing: disposition))")
                let identity = TrackIdentity(track: track)
                let old = LyricsDocument(
                    identity: identity,
                    lines: [LyricLine(timestamp: 2, originalText: "保留的当前版本")],
                    source: .lrclib,
                    confidence: 0.99,
                    providerSourceID: "persisted-current"
                )
                guard let oldID = try await base.save(track: track, identity: identity, document: old).versionID else {
                    throw ContractFailure(description: "failure-result fixture could not create a prior version")
                }
                try await base.adoptLyricsVersion(trackStableKey: identity.stableKey, lyricsVersionID: oldID)
                let gate = ManualAdoptionGate()
                let failureID = UUID()
                let forced = LyricsPersistenceSaveResult(versionID: nil, disposition: disposition)
                let repository = DeferredManualAdoptionRepository(
                    base: base,
                    gate: gate,
                    delayedRequestID: failureID,
                    forcedManualResult: forced
                )
                let session = LyricsSessionController(providers: [], repository: repository)
                session.begin(track: track, identity: identity, automaticallySearch: false)
                let oldStored = try await base.loadBestStored(track: track, identity: identity)!
                session.adoptPersisted(document: oldStored.document, versionID: oldID, sourceContentHash: oldStored.sourceContentHash!)
                let requestID = UUID()
                try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: requestID), "failure-result request did not bind")
                let candidate = makeCandidate(track: track, source: .kugouExperimental, confidence: 0.5, providerID: "failure-result-candidate")
                let result = try await session.adoptManually(document: candidate.makeDocument(), track: track, requestID: requestID)
                try check(result.disposition == disposition && result.versionID == nil, "repository failure response changed unexpectedly")
                try check(session.activeLyricsVersionID == oldID, "repository failure response published candidate as current")
                try check(session.activeDocument?.lines.first?.originalText == "保留的当前版本", "repository failure response replaced live lyrics")
                try check(try await base.loadBestStored(track: track, identity: identity)?.versionID == oldID, "repository failure response changed persistent selection")
                try check(try await base.versionCount(trackStableKey: identity.stableKey) == 1, "repository failure response wrote candidate rows")
            }
        }
    }

    private static func lateAdoptionStaysBoundToItsTrack(returnToA: Bool = false) async throws {
        try await withTemporaryRoot { root in
            let base = makeRepository(root: root)
            try await base.prepare()
            let gate = ManualAdoptionGate()
            let requestID = UUID()
            let delayed = DeferredManualAdoptionRepository(base: base, gate: gate, delayedRequestID: requestID, forcedManualResult: nil)
            let trackA = makeTrack("late-A")
            let identityA = TrackIdentity(track: trackA)
            let trackB = makeTrack("late-B")
            let identityB = TrackIdentity(track: trackB)
            let session = LyricsSessionController(providers: [], repository: delayed)
            session.begin(track: trackA, identity: identityA, automaticallySearch: false)
            let candidateA = makeCandidate(track: trackA, source: .lyricsOVH, confidence: 0, providerID: "late-a-candidate", isSynchronized: false)
            try check(try await session.beginManualAdoptionRequest(identity: identityA, requestID: requestID), "A adoption request did not bind")
            let saveA = Task {
                try await session.adoptManually(document: candidateA.makeDocument(), track: trackA, requestID: requestID)
            }
            try await gate.waitUntilBlocked()
            session.begin(track: trackB, identity: identityB, automaticallySearch: false)
            if returnToA {
                session.begin(track: trackA, identity: identityA, automaticallySearch: false)
                for _ in 0..<200 { if case .idle = session.state { break }; try await Task.sleep(nanoseconds: 5_000_000) }
                try check(session.activeDocument == nil, "returned A starts without old pending result")
            }
            await gate.release()
            let resultA = try await saveA.value
            try check(resultA.versionID != nil, "late A persistence did not complete for its captured song: \(resultA.disposition)")
            try check(session.activeIdentity == (returnToA ? identityA : identityB), "late A completion changed the active identity")
            try check(session.activeDocument == nil && session.activeLyricsVersionID == nil, "late A completion contaminated the new playback session")
            try check(try await base.loadBestStored(track: trackA, identity: identityA)?.versionID == resultA.versionID, "late A version was not durably selected for A")
            try check(try await base.loadBestStored(track: trackB, identity: identityB) == nil, "late A completion wrote lyrics under B")
            print(returnToA ? "A→B→A old completion persisted only its asset; new revision remained untouched" : "A→B late completion persisted only to A and left B's live state untouched")
        }
    }

    private static func newerSameTrackRequestWins() async throws {
        try await withTemporaryRoot { root in
            let base = makeRepository(root: root)
            try await base.prepare()
            let gate = ManualAdoptionGate()
            let oldRequestID = UUID()
            let delayed = DeferredManualAdoptionRepository(base: base, gate: gate, delayedRequestID: oldRequestID, forcedManualResult: nil)
            let track = makeTrack("same-track")
            let identity = TrackIdentity(track: track)
            let session = LyricsSessionController(providers: [], repository: delayed)
            session.begin(track: track, identity: identity, automaticallySearch: false)
            let oldCandidate = makeCandidate(track: track, source: .lyricsOVH, confidence: 0, providerID: "older-candidate", isSynchronized: false)
            try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: oldRequestID), "older request did not bind")
            let oldSave = Task {
                try await session.adoptManually(document: oldCandidate.makeDocument(), track: track, requestID: oldRequestID)
            }
            try await gate.waitUntilBlocked()

            let newRequestID = UUID()
            try check(try await session.beginManualAdoptionRequest(identity: identity, requestID: newRequestID), "newer request did not replace the old token")
            let newCandidate = makeCandidate(track: track, source: .kugouExperimental, confidence: 0.5, providerID: "newer-candidate")
            let newResult = try await session.adoptManually(document: newCandidate.makeDocument(), track: track, requestID: newRequestID)
            guard let newVersionID = newResult.versionID else { throw ContractFailure(description: "newer same-track request did not commit: \(newResult.disposition)") }
            await gate.release()
            let oldResult = try await oldSave.value
            try check(oldResult.versionID == nil, "older same-track request committed after a newer request")
            try check(try await base.loadBestStored(track: track, identity: identity)?.versionID == newVersionID, "older same-track request replaced the newer persistent selection")
            try check(session.activeLyricsVersionID == newVersionID, "older same-track result changed the active current tag")
            print("same-track late request was rejected after a newer manual adoption")
        }
    }
}

private func lockedVersionIDs(databaseURL: URL, stableKey: String) throws -> [UUID] {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw ContractFailure(description: "could not open temporary SQLite database for lock readback")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT id FROM lyrics_versions WHERE track_stable_key = ? AND is_locked = 1 ORDER BY id;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw ContractFailure(description: "could not prepare lock readback")
    }
    defer { sqlite3_finalize(statement) }
    _ = stableKey.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    var ids: [UUID] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let value = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: value)) else { continue }
        ids.append(id)
    }
    return ids
}
