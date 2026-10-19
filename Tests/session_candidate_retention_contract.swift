import Combine
import Foundation

private struct CandidateSource: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    let executionLane: LyricsProviderExecutionLane = .network
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { result }
}

private actor CachedLyricsFixture: LyricsRepository {
    let stored: StoredLyricsDocument
    private(set) var writes = 0
    init(_ stored: StoredLyricsDocument) { self.stored = stored }
    func prepare() async throws {}
    func loadBest(track: Track, identity: TrackIdentity) async throws -> LyricsDocument? { stored.document }
    func loadBestStored(track: Track, identity: TrackIdentity) async throws -> StoredLyricsDocument? { stored }
    func save(track: Track, identity: TrackIdentity, document: LyricsDocument) async throws -> LyricsPersistenceSaveResult {
        writes += 1
        return LyricsPersistenceSaveResult(versionID: nil, disposition: .rejected("Unexpected test write"))
    }
    func markLocked(versionID: UUID, locked: Bool) async throws {}
}

@main @MainActor struct SessionCandidateRetentionContract {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: Bool, _ reason: String) {
            print("\(condition ? "PASS" : "FAIL") \(reason)")
            if !condition { failures += 1 }
        }
        func settle(_ session: LyricsSessionController) async throws {
            for _ in 0..<1000 {
                if !session.isSearchInProgress { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            fatalError("session did not settle")
        }
        let track = Track(title: "Candidate fixture", artist: "Fixture artist", album: "Fixture", duration: 180)
        let identity = TrackIdentity(track: track)
        let candidate = LyricsCandidate(id: "manual-candidate", identity: identity, title: track.title,
            artist: track.artist, album: track.album, duration: 180,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored candidate")],
            isSynchronized: false, source: .lyricsOVH, confidence: 0, providerSourceID: "manual-candidate")
        let source = CandidateSource(name: "Manual source", result: .candidates([candidate]))
        let outcome = await LyricsSearchManager(providers: [source]).search(track: track, identity: identity)
        expect(outcome.alternatives.map(\.id) == ["manual-candidate"],
            "final search outcome retains its review candidates")

        let session = LyricsSessionController(providers: [source], recoveryCooldowns: [])
        var previewAppeared = false
        let subscription = session.$availableCandidates.sink { if !$0.isEmpty { previewAppeared = true } }
        session.begin(track: track, identity: identity)
        try await settle(session)
        expect(previewAppeared, "candidate was progressively published before search completion")
        expect(session.availableCandidates.map(\.id) == ["manual-candidate"],
            "candidate list stays available when final review state is applied")
        if case .candidates(_, let review) = session.state {
            expect(review.map(\.id) == ["manual-candidate"] && session.lyrics.isEmpty,
                "candidate remains unadopted and review state is intact")
        } else { expect(false, "candidate stays in review state") }
        subscription.cancel()

        let cached = LyricsDocument(identity: identity, title: track.title, artist: track.artist,
            album: track.album, duration: 180,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored cached original")],
            isSynchronized: false, source: .lrclib, providerSourceID: "cached-original")
        let versionID = UUID()
        let stored = StoredLyricsDocument(document: cached, versionID: versionID, sourceContentHash: "cached-source-hash")
        let cache = CachedLyricsFixture(stored)
        let cachedSession = LyricsSessionController(providers: [source], repository: cache, recoveryCooldowns: [])
        cachedSession.begin(track: track, identity: identity)
        try await settle(cachedSession)
        expect(cachedSession.availableCandidates.map(\.id) == ["manual-candidate"],
            "keeping plain cached lyrics does not discard newly found review candidates")
        expect(cachedSession.activeDocument?.providerSourceID == "cached-original"
            && cachedSession.activeLyricsVersionID == versionID
            && cachedSession.activeSourceContentHash == "cached-source-hash",
            "new review candidates cannot replace the cached selection")

        let alternate = LyricsDocument(identity: identity, title: track.title, artist: track.artist,
            album: track.album, duration: 180,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored alternate original")],
            isSynchronized: false, source: .lrclib, providerSourceID: "alternate-plain")
        let otherSession = LyricsSessionController(providers: [CandidateSource(name: "Other plain source", result: .match(alternate))],
            repository: cache, recoveryCooldowns: [])
        otherSession.begin(track: track, identity: identity)
        try await settle(otherSession)
        expect(otherSession.availableCandidates.map(\.providerSourceID) == ["alternate-plain"],
            "an alternate plain match remains previewable while cached lyrics stay selected")
        expect(otherSession.activeDocument?.providerSourceID == "cached-original"
            && otherSession.activeLyricsVersionID == versionID,
            "plain alternatives do not silently replace the cache")
        let writes = await cache.writes
        expect(writes == 0, "retaining alternatives does not create or modify stored versions")
        print("SESSION_CANDIDATE_RETENTION_FAILURES=\(failures)")
        if failures > 0 { exit(1) }
    }
}
