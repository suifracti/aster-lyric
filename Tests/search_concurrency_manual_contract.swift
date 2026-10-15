import Foundation

private actor ProbeLedger {
    var active = 0
    var peak = 0
    var starts: [String] = []
    var finishes: [String] = []
    func begin(_ name: String) { active += 1; peak = max(peak, active); starts.append(name) }
    func end(_ name: String) { active -= 1; finishes.append(name) }
    func snapshot() -> (Int, Int, [String], [String]) { (active, peak, starts, finishes) }
}
private actor CandidatePreviewLedger {
    private var ids: Set<String> = []
    func record(_ candidates: [LyricsCandidate]) { ids.formUnion(candidates.map(\.id)) }
    func snapshot() -> Set<String> { ids }
}
private struct ProbeProvider: LyricsProvider {
    let name: String
    let executionLane: LyricsProviderExecutionLane
    let delay: UInt64
    let ledger: ProbeLedger
    let source: LyricsSource
    var timeoutInterval: TimeInterval { 4 }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await ledger.begin(name)
        do { try await Task.sleep(nanoseconds: delay) }
        catch { await ledger.end(name); return .failed(.cancelled) }
        await ledger.end(name)
        return .match(LyricsDocument(identity: identity, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration,
            lines: [LyricLine(timestamp: 1, originalText: "Fixture text")],
            source: source, providerSourceID: name))
    }
}
private struct LocalizedTitleProvider: LyricsProvider {
    let includeAlternative: Bool
    var name: String { "localized-title-offline" }
    var executionLane: LyricsProviderExecutionLane { .local }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        let original = LyricsCandidate(id: "localized-original", identity: identity,
            title: "唄を教えてくれたあなたへ", artist: "ミセカイ", album: "Artrium", duration: 254,
            lines: [LyricLine(timestamp: 7, originalText: "Self-authored offline line")],
            isSynchronized: true, source: .neteaseExperimental, confidence: 0.50)
        let differentSong = LyricsCandidate(id: "different-song", identity: identity,
            title: "アオイハル", artist: "ミセカイ", album: "Artrium", duration: 254,
            lines: [LyricLine(timestamp: 9, originalText: "Different offline line")],
            isSynchronized: true, source: .neteaseExperimental, confidence: 0.90)
        return .candidates(includeAlternative ? [differentSong, original] : [original])
    }
}
private struct TypographyTitleProvider: LyricsProvider {
    let includeAlternative: Bool
    let ledger: ProbeLedger
    var name: String { "typography-title-offline" }
    var executionLane: LyricsProviderExecutionLane { .network }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await ledger.begin(name)
        do { try await Task.sleep(nanoseconds: 60_000_000) }
        catch { await ledger.end(name); return .failed(.cancelled) }
        await ledger.end(name)
        let original = LyricsCandidate(id: "typography-original", identity: identity,
            title: "Something Without Form (Another ver.)", artist: track.artist,
            album: track.album, duration: 184,
            lines: [LyricLine(timestamp: 7, originalText: "Self-authored offline line")],
            isSynchronized: true, source: .lrclib, confidence: 0.50)
        let different = LyricsCandidate(id: "other-version", identity: identity,
            title: "Something Without Form (Original ver.)", artist: track.artist,
            album: track.album, duration: 184,
            lines: [LyricLine(timestamp: 9, originalText: "Other self-authored line")],
            isSynchronized: true, source: .lrclib, confidence: 0.90)
        return .candidates(includeAlternative ? [different, original] : [original])
    }
}
@main struct SearchConcurrencyManualContract {
    static func main() async {
        let track = Track(title: "Contract song", artist: "Contract artist", album: "Contract album", duration: 180)
        let identity = TrackIdentity(track: track)
        let localizedTrack = Track(title: "Uta o Oshietekureta Anata e", artist: "ミセカイ", album: "Artrium", duration: 253.677, spotifyId: "7eqgj3zza04nswadcvqnyk")
        for multiple in [false, true] {
            let outcome = await LyricsSearchManager(providers: [LocalizedTitleProvider(includeAlternative: multiple)]).search(track: localizedTrack, identity: TrackIdentity(track: localizedTrack))
            guard case .match(let original) = outcome.result else { fatalError("localized title stopped at manual choice") }
            precondition(original.title == "唄を教えてくれたあなたへ" && original.isSynchronized && original.lines[0].timestamp == 7, "automatic adoption must keep the selected source's real original and timing")
            precondition(outcome.automaticDecision?.tier == .autoMedium, "retain automatic selection persistence receipt")
            precondition(outcome.alternatives.count == (multiple ? 2 : 1), "automatic choice must retain available alternatives for later change")
        }
        print("PASS Japanese/Latin title automatic selection for one/multiple candidates; original/timing/alternatives retained")
        let typographyTrack = Track(title: "Something without form - Another ver.", artist: "Nemo_Suzumi", album: "Something without form (Another ver.)", duration: 183.913, spotifyId: "5M2kd1tO6wlFp7uDtn3YKG")
        for multiple in [false, true] {
            let typographyLedger = ProbeLedger()
            let source = TypographyTitleProvider(includeAlternative: multiple, ledger: typographyLedger)
            let slow = (0..<4).map { ProbeProvider(name: "slow-typography-\($0)", executionLane: .network, delay: 2_000_000_000, ledger: typographyLedger, source: .lrclib) }
            let started = Date()
            let outcome = await LyricsSearchManager(providers: [source] + slow).search(track: typographyTrack, identity: TrackIdentity(track: typographyTrack))
            guard case .match(let chosen) = outcome.result else { fatalError("typography title stopped at manual choice") }
            precondition(chosen.title == "Something Without Form (Another ver.)" && chosen.lines[0].timestamp == 7 && chosen.isSynchronized)
            precondition(outcome.automaticDecision?.tier == .autoMedium)
            precondition(outcome.alternatives.count == (multiple ? 2 : 1), "keep alternatives for optional later change")
            precondition(Date().timeIntervalSince(started) < 1, "whole-title match must stop waiting for unrelated providers")
            let state = await typographyLedger.snapshot()
            precondition(state.0 == 0 && state.1 == 3 && state.2.count == 3, "cancel and drain only started probes")
        }
        print("PASS dash/bracket title automatically selected in <1s for one/multiple candidates; slow probes cancelled, alternatives/timing retained")
        let ledger = ProbeLedger()
        let providers = (0..<7).map { ProbeProvider(name: "priority-\($0)", executionLane: .network,
            delay: $0 == 0 ? 60_000_000 : 2_000_000_000, ledger: ledger, source: .lrclib) }
        let started = Date()
        let result = await LyricsSearchManager(providers: providers).lookup(track: track, identity: identity)
        guard case .match(let chosen) = result else { fatalError("expected automatic candidate") }
        precondition(chosen.providerSourceID == "priority-0", "completion order must not change configured priority")
        precondition(Date().timeIntervalSince(started) < 1, "ready lyrics blocked on unrelated provider timeouts")
        let network = await ledger.snapshot()
        precondition(network.0 == 0 && network.1 == 3 && network.2.count == 3, "eligible first provider must cancel unrelated slow probes and drain the group")
        let localLedger = ProbeLedger()
        let local = ProbeProvider(name: "local", executionLane: .local, delay: 1, ledger: localLedger, source: .local)
        let online = ProbeProvider(name: "network-after-local", executionLane: .network, delay: 1, ledger: localLedger, source: .lrclib)
        guard case .match(let localChoice) = await LyricsSearchManager(providers: [online, local]).lookup(track: track, identity: identity) else { fatalError("local match") }
        precondition(localChoice.source == .lrclib, "configured order decides equal-quality results after local-first probing")
        let localRun = await localLedger.snapshot()
        precondition(localRun.2 == ["local", "network-after-local"], "local providers execute before network providers even when a network provider has higher configured priority")
        let manual = LyricsCandidate(id: "body", identity: identity, title: track.title, artist: track.artist, album: track.album,
            duration: track.duration, lines: [LyricLine(timestamp: 0, originalText: "Body")], source: .lyricsOVH,
            confidence: 1, spotifyTrackID: track.spotifyId, isrc: track.isrc)
        let decision = LyricsSafeMatcher.decide(candidate: manual, metadata: TrackMetadata.bootstrap(from: track))
        precondition(decision.tier == .candidates && !decision.hardReject)
        let empty = LyricsCandidate(id: "empty", identity: identity, title: track.title, artist: track.artist, album: track.album,
            duration: track.duration, lines: [LyricLine(timestamp: 0, originalText: "   ")], source: .lyricsOVH, confidence: 1)
        let emptyDecision = LyricsSafeMatcher.decide(candidate: empty, metadata: TrackMetadata.bootstrap(from: track))
        precondition(emptyDecision.tier == .reject && emptyDecision.hardReject)
        let ovhLedger = ProbeLedger()
        let ovh = ProbeProvider(name: "OVH", executionLane: .network, delay: 1, ledger: ovhLedger, source: .lyricsOVH)
        guard case .candidates(let visible) = await LyricsSearchManager(providers: [ovh]).lookup(track: track, identity: identity), !visible.isEmpty else { fatalError("OVH body must remain visible and never auto-adopt even if provider returns match") }
        precondition(visible.allSatisfy { $0.source == .lyricsOVH && $0.displayedConfidence == 0 })
        print("PASS peak3, configured selection priority, local-first execution, OVH manual-only visible candidate")
        fflush(stdout)

        let versionsLedger = ProbeLedger()
        let versionProviders = (0..<5).map { ProbeProvider(name: "version-\($0)", executionLane: .network,
            delay: UInt64($0 + 1) * 10_000_000, ledger: versionsLedger, source: .lrclib) }
        let previewLedger = CandidatePreviewLedger()
        let versions = await LyricsSearchManager(providers: versionProviders).search(track: track, identity: identity,
            collectCandidatesOnly: true,
            onProvisional: { _ in fatalError("version browsing must never publish an adopted document") },
            onCandidates: { await previewLedger.record($0) })
        guard case .candidates(let alternatives) = versions.result else { fatalError("version browsing must return candidates even for exact matches") }
        precondition(alternatives.count == 5 && versions.automaticDecision == nil)
        let previewIDs = await previewLedger.snapshot()
        precondition(previewIDs == Set(alternatives.map(\.id)), "progressive candidates must retain stable IDs when the final list arrives")
        let versionsRun = await versionsLedger.snapshot()
        precondition(versionsRun.0 == 0 && versionsRun.1 == 3 && versionsRun.2.count == 5 && versionsRun.3.count == 5,
            "version browsing must collect every enabled source once, still bounded to three parallel probes")
        print("PASS explicit version search collects all five sources with peak3; no provisional or automatic adoption")

        // One result finishes before cancellation while the bounded group is
        // still awaiting other providers. It must never be adopted afterward.
        let cancelLedger = ProbeLedger()
        let cancellingProviders = (0..<7).map { ProbeProvider(name: "cancel-\($0)", executionLane: .network,
            delay: $0 == 1 ? 20_000_000 : 2_000_000_000, ledger: cancelLedger, source: .lrclib) }
        let task = Task { await LyricsSearchManager(providers: cancellingProviders).lookup(track: track, identity: identity) }
        for _ in 0..<1000 {
            if await cancelLedger.snapshot().3.contains("cancel-1") { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let beforeCancel = await cancelLedger.snapshot()
        precondition(beforeCancel.3.contains("cancel-1"))
        task.cancel()
        let cancelled = await task.value
        guard case .failed(.cancelled) = cancelled else { fatalError("cancelled search adopted previously completed network result") }
        let end = await cancelLedger.snapshot()
        precondition(end.0 == 0 && end.2.count <= 4, "cancellation must drain active work and stop queued providers")
        print("PASS cancellation drains active probes and blocks adoption of buffered successes")
    }
}
