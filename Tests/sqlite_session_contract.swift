import Foundation

private final class Counter: @unchecked Sendable {
    var value = 0
}

private struct SaveReleaseError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private actor SaveOrderGate {
    private var blocked: [String: CheckedContinuation<Void, Error>] = [:]
    private var completed: Set<String> = []
    private var results: [String: LyricsPersistenceSaveResult] = [:]

    func waitUntilReleased(_ key: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            blocked[key] = continuation
        }
    }

    func waitForBlockedCount(_ count: Int) async {
        for _ in 0..<500 {
            if blocked.count >= count { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("timed out waiting for \(count) blocked saves")
    }

    func release(_ key: String, error: String? = nil) {
        guard let continuation = blocked.removeValue(forKey: key) else {
            fatalError("no blocked save for \(key)")
        }
        if let error { continuation.resume(throwing: SaveReleaseError(message: error)) }
        else { continuation.resume() }
    }

    func recordCompletion(_ key: String, result: LyricsPersistenceSaveResult? = nil) {
        completed.insert(key)
        if let result { results[key] = result }
    }

    func waitForCompletion(_ key: String) async {
        for _ in 0..<500 {
            if completed.contains(key) { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("timed out waiting for save completion: \(key)")
    }

    func waitForResult(_ key: String) async -> LyricsPersistenceSaveResult {
        for _ in 0..<500 {
            if let result = results[key] { return result }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("timed out waiting for save result: \(key)")
    }
}

private struct DelayedSaveLyricsRepository: LyricsRepository {
    let base: SQLiteLyricsRepository
    let gate: SaveOrderGate

    func prepare() async throws { try await base.prepare() }

    func loadBest(track: Track, identity: TrackIdentity) async throws -> LyricsDocument? {
        try await base.loadBest(track: track, identity: identity)
    }

    func save(track: Track, identity: TrackIdentity, document: LyricsDocument) async throws -> LyricsPersistenceSaveResult {
        let key = document.lines.first?.originalText ?? "empty"
        do {
            try await gate.waitUntilReleased(key)
        } catch {
            await gate.recordCompletion(key)
            throw error
        }
        let result = try await base.save(track: track, identity: identity, document: document)
        await gate.recordCompletion(key, result: result)
        return result
    }

    func markLocked(versionID: UUID, locked: Bool) async throws {
        try await base.markLocked(versionID: versionID, locked: locked)
    }
}

private struct CountingProvider: LyricsProvider {
    let counter: Counter
    let resultBuilder: @Sendable (Track, TrackIdentity) -> LyricsLookupResult
    let name = "contract-provider"

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        counter.value += 1
        return resultBuilder(track, identity)
    }
}

private struct SlowSwitchProvider: LyricsProvider {
    let name = "slow-switch-provider"

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        if track.title == "A 歌" {
            // Ignore cancellation at the provider boundary to model a late
            // network callback. Session revision/identity guards must still
            // prevent it from being applied or persisted.
            try? await Task.sleep(nanoseconds: 220_000_000)
        }
        return .match(makeDocument(track: track, identity: identity, source: .lrclib, synced: true))
    }
}

private func makeDocument(track: Track, identity: TrackIdentity, source: LyricsSource, synced: Bool) -> LyricsDocument {
    LyricsDocument(
        identity: identity,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        lines: [
            LyricLine(
                timestamp: synced ? 12 : 0,
                originalText: "歌词 \(track.title)",
                romajiText: "kashi",
                kanaText: "かし"
            )
        ],
        isSynchronized: synced,
        source: source,
        confidence: 1,
        providerSourceID: "contract:\(track.spotifyId ?? track.title)"
    )
}

private func makeAdoptionDocument(track: Track, identity: TrackIdentity, text: String) -> LyricsDocument {
    LyricsDocument(
        identity: identity,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        lines: [LyricLine(timestamp: 0, originalText: text)],
        isSynchronized: false,
        source: .asrMachineGenerated,
        confidence: 1,
        providerSourceID: "adoption-contract:\(text)"
    )
}

@main
@MainActor
struct SQLiteSessionContract {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotifyLyricsSQLiteSessionContract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("SpotifyLyrics.sqlite3"), alignmentProvenanceDirectory: root.appendingPathComponent("provenance"))
        let track = Track(
            title: "恋風",
            artist: "Lilas",
            album: "Album",
            duration: 205,
            spotifyId: "session-koikaze",
            spotifyURL: URL(string: "spotify:track:session-koikaze")
        )
        let identity = TrackIdentity(track: track)
        let counter = Counter()
        let provider = CountingProvider(counter: counter) { track, identity in
            .match(makeDocument(track: track, identity: identity, source: .lrclib, synced: true))
        }
        let first = LyricsSessionController(providers: [provider], repository: repository)
        first.begin(track: track, identity: identity)
        try await Task.sleep(nanoseconds: 250_000_000)
        guard case .loaded(let firstDocument) = first.state else {
            fatalError("first provider run should load lyrics: \(first.state)")
        }
        precondition(firstDocument.lines.count == 1)
        precondition(counter.value == 1)

        let offlineCounter = Counter()
        let offlineProvider = CountingProvider(counter: offlineCounter) { _, _ in
            .failed(.networkUnavailable)
        }
        let restarted = LyricsSessionController(providers: [offlineProvider], repository: repository)
        restarted.begin(track: track, identity: identity)
        try await Task.sleep(nanoseconds: 120_000_000)
        guard case .loaded(let restored) = restarted.state else {
            fatalError("restart should restore SQLite lyrics: \(restarted.state)")
        }
        precondition(restored.lines.count == 1)
        precondition(offlineCounter.value == 0)
        precondition(restored.source == .lrclib)

        let plainTrack = Track(
            title: "水曜日の約束",
            artist: "Kawasaki.Rio",
            album: "Album",
            duration: 171.177,
            spotifyId: "session-suiyoubi",
            spotifyURL: URL(string: "spotify:track:session-suiyoubi")
        )
        let plainIdentity = TrackIdentity(track: plainTrack)
        let plainProvider = CountingProvider(counter: Counter()) { track, identity in
            .match(makeDocument(track: track, identity: identity, source: .qqExperimental, synced: false))
        }
        let plainSession = LyricsSessionController(providers: [plainProvider], repository: repository)
        plainSession.begin(track: plainTrack, identity: plainIdentity)
        try await Task.sleep(nanoseconds: 180_000_000)
        guard case .alignmentQueued = plainSession.state else {
            fatalError("plain SQLite/provider lyrics must stay alignmentQueued: \(plainSession.state)")
        }

        let noTextTrack = Track(
            title: "あやふや",
            artist: "みさき",
            album: "Album",
            duration: 180,
            spotifyId: "session-ayafuya",
            spotifyURL: URL(string: "spotify:track:session-ayafuya")
        )
        let noTextIdentity = TrackIdentity(track: noTextTrack)
        let noTextCounter = Counter()
        let noTextProvider = CountingProvider(counter: noTextCounter) { _, _ in .noMatch }
        let noTextSession = LyricsSessionController(providers: [noTextProvider], repository: repository)
        noTextSession.begin(track: noTextTrack, identity: noTextIdentity)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .noMatch = noTextSession.state else {
            fatalError("no-match should remain noMatch: \(noTextSession.state)")
        }
        let firstNoTextCallCount = noTextCounter.value
        precondition(firstNoTextCallCount > 0)
        let noTextRestart = LyricsSessionController(providers: [noTextProvider], repository: repository)
        noTextRestart.begin(track: noTextTrack, identity: noTextIdentity)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(noTextCounter.value > firstNoTextCallCount, "noMatch must not be cached")

        let trackA = Track(
            title: "A 歌",
            artist: "Artist A",
            album: "Album A",
            duration: 120,
            spotifyId: "switch-a",
            spotifyURL: URL(string: "spotify:track:switch-a")
        )
        let trackB = Track(
            title: "B 歌",
            artist: "Artist B",
            album: "Album B",
            duration: 121,
            spotifyId: "switch-b",
            spotifyURL: URL(string: "spotify:track:switch-b")
        )
        let switchSession = LyricsSessionController(
            providers: [SlowSwitchProvider()],
            repository: repository
        )
        switchSession.begin(track: trackA, identity: TrackIdentity(track: trackA))
        try await Task.sleep(nanoseconds: 20_000_000)
        switchSession.begin(track: trackB, identity: TrackIdentity(track: trackB))
        try await Task.sleep(nanoseconds: 420_000_000)
        guard case .loaded(let switchedDocument) = switchSession.state else {
            fatalError("quick switch should settle on B lyrics: \(switchSession.state)")
        }
        precondition(switchedDocument.title == "B 歌")
        let aVersionCount = try await repository.versionCount(trackStableKey: TrackIdentity(track: trackA).stableKey)
        let bVersionCount = try await repository.versionCount(trackStableKey: TrackIdentity(track: trackB).stableKey)
        precondition(aVersionCount == 0)
        precondition(bVersionCount == 1)

        let adoptionTrack = Track(
            title: "Same Track Adoption",
            artist: "Fixture",
            album: "Fixture",
            duration: 90,
            spotifyId: "same-track-adoption-race"
        )
        let adoptionIdentity = TrackIdentity(track: adoptionTrack)
        let saveGate = SaveOrderGate()
        let delayedRepository = DelayedSaveLyricsRepository(base: repository, gate: saveGate)
        let adoptionSession = LyricsSessionController(providers: [], repository: delayedRepository)
        adoptionSession.begin(track: adoptionTrack, identity: adoptionIdentity, automaticallySearch: false)
        for _ in 0..<100 where adoptionSession.isSearchInProgress {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!adoptionSession.isSearchInProgress)

        let oldSuccessText = "older successful save"
        let newSuccessText = "newer successful save"
        adoptionSession.adopt(document: makeAdoptionDocument(track: adoptionTrack, identity: adoptionIdentity, text: oldSuccessText))
        await saveGate.waitForBlockedCount(1)
        adoptionSession.adopt(document: makeAdoptionDocument(track: adoptionTrack, identity: adoptionIdentity, text: newSuccessText))
        await saveGate.waitForBlockedCount(2)

        await saveGate.release(newSuccessText)
        let newSuccess = await saveGate.waitForResult(newSuccessText)
        guard let newSuccessVersionID = newSuccess.versionID, let newSuccessHash = newSuccess.sourceContentHash else {
            fatalError("newer save must return its persisted binding")
        }
        for _ in 0..<100 where adoptionSession.activeLyricsVersionID != newSuccessVersionID {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(adoptionSession.activeLyricsVersionID == newSuccessVersionID)

        await saveGate.release(oldSuccessText)
        _ = await saveGate.waitForResult(oldSuccessText)
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(adoptionSession.activeLyricsVersionID == newSuccessVersionID, "late same-track success must not replace the newer active version")
        precondition(adoptionSession.activeSourceContentHash == newSuccessHash, "late same-track success must not replace the newer source hash")

        let oldFailureText = "older failed save"
        let newFailureScenarioText = "newer save before old failure"
        adoptionSession.adopt(document: makeAdoptionDocument(track: adoptionTrack, identity: adoptionIdentity, text: oldFailureText))
        await saveGate.waitForBlockedCount(1)
        adoptionSession.adopt(document: makeAdoptionDocument(track: adoptionTrack, identity: adoptionIdentity, text: newFailureScenarioText))
        await saveGate.waitForBlockedCount(2)
        await saveGate.release(newFailureScenarioText)
        let latestBeforeOldFailure = await saveGate.waitForResult(newFailureScenarioText)
        guard let latestBeforeOldFailureID = latestBeforeOldFailure.versionID else {
            fatalError("newer save before old failure must persist")
        }
        for _ in 0..<100 where adoptionSession.activeLyricsVersionID != latestBeforeOldFailureID {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(adoptionSession.activeLyricsVersionID == latestBeforeOldFailureID)

        await saveGate.release(oldFailureText, error: "stale save failure")
        await saveGate.waitForCompletion(oldFailureText)
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(adoptionSession.activeLyricsVersionID == latestBeforeOldFailureID, "late same-track failure must not change the current binding")
        precondition(adoptionSession.persistenceStatusMessage == nil, "late same-track failure must not replace current-session status")

        // Round 1: an unprotected plain cache is provisional; a selected
        // original is stable even when a synchronized source later exists.
        let upgradeTrack=Track(title:"Self-written plain",artist:"Fixture",album:"Fixture",duration:30,spotifyId:"round1-plain")
        let upgradeIdentity=TrackIdentity(track:upgradeTrack)
        let plainCache=try await repository.save(track:upgradeTrack,identity:upgradeIdentity,document:makeDocument(track:upgradeTrack,identity:upgradeIdentity,source:.lrclib,synced:false))
        let unprotected=try await repository.loadBestStored(track:upgradeTrack,identity:upgradeIdentity)!
        precondition(!unprotected.isUserProtected)
        let upgradeCounter=Counter()
        let upgrade=LyricsSessionController(providers:[CountingProvider(counter:upgradeCounter,resultBuilder:{track,identity in .match(makeDocument(track:track,identity:identity,source:.lrclib,synced:true))})],repository:repository)
        upgrade.begin(track:upgradeTrack,identity:upgradeIdentity,automaticallySearch:true)
        try await Task.sleep(nanoseconds:200_000_000)
        precondition(upgrade.isSynchronized && upgradeCounter.value==1,"plain cache permanently blocked synchronized search")
        try await repository.setPersonalLibraryActiveLyrics(trackStableKey:upgradeIdentity.stableKey,lyricsVersionID:plainCache.versionID!)
        let protectedCounter=Counter()
        let protected=LyricsSessionController(providers:[CountingProvider(counter:protectedCounter,resultBuilder:{track,identity in .match(makeDocument(track:track,identity:identity,source:.lrclib,synced:true))})],repository:repository)
        protected.begin(track:upgradeTrack,identity:upgradeIdentity,automaticallySearch:true)
        try await Task.sleep(nanoseconds:200_000_000)
        precondition(!protected.isSynchronized && protectedCounter.value==0 && protected.activeLyricsVersionID==plainCache.versionID,"user-selected original silently replaced")
        print("PASS unprotected plain cache upgrades; explicit original choice skips source replacement")
        print("sqlite session contract passed")
    }
}
