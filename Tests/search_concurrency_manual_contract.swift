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
private actor SearchQueryLedger {
    private var queries: [String] = []
    func record(_ title: String, _ artist: String) { queries.append(title + "\u{1F}" + artist) }
    func snapshot() -> [String] { queries }
}
private final class SpotifyAliasFixtureURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var pages: [String: Data] = [:]
    static var requestCount = 0

    static func reset(_ values: [String: Data]) {
        lock.lock(); defer { lock.unlock() }
        pages = values
        requestCount = 0
    }

    static func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "open.spotify.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.url?.lastPathComponent ?? ""
        Self.lock.lock()
        Self.requestCount += 1
        let body = Self.pages[id]
        Self.lock.unlock()
        guard let body else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func spotifyEmbedPage(id: String, title: String, duration: Double, artists: [String]) -> Data {
    let entity: [String: Any] = ["type": "track", "id": id, "uri": "spotify:track:\(id)",
        "title": title, "duration": duration * 1000,
        "artists": artists.enumerated().map { index, name in
            ["name": name, "uri": "spotify:artist:" + String(repeating: index == 0 ? "A" : "B", count: 22)]
        }]
    let json = try! JSONSerialization.data(withJSONObject: ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]])
    return Data(("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">"
        + String(decoding: json, as: UTF8.self) + "</script></html>").utf8)
}

private func fixtureSpotifyResolver() -> SpotifyTrackArtistResolver {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SpotifyAliasFixtureURLProtocol.self]
    return SpotifyTrackArtistResolver(session: URLSession(configuration: config))
}

private struct LocalizedVersionBrowseProvider: LyricsProvider {
    let queries: SearchQueryLedger
    let originalTitle: String
    var includeFirstQueryHit = true
    var name: String { "localized-version-browse-fixture" }
    var executionLane: LyricsProviderExecutionLane { .network }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await queries.record(track.title, track.artist)
        if includeFirstQueryHit && track.title == originalTitle && track.artist == "RADWIMPS" {
            return .candidates([LyricsCandidate(id: "lrclib:movie-edit", identity: identity,
                title: originalTitle, artist: "RADWIMPS", album: "Weathering With You", duration: 156.16,
                lines: [LyricLine(timestamp: 0, originalText: "English fixture")],
                isSynchronized: true, source: .lrclib, confidence: 0.8, providerSourceID: "lrclib:movie-edit")])
        }
        if track.title == "祝祭 - Movie edit" && track.artist == "RADWIMPS" {
            let translatedLines = [
                LyricLine(timestamp: 1, originalText: "目を閉じて", translationText: "闭上双眼"),
                LyricLine(timestamp: 2, originalText: "空を見上げた", translationText: "抬头望向天空")
            ]
            let shortVersion = LyricsCandidate(id: "netease:1378491293", identity: identity,
                title: "祝祭 (Movie edit)", artist: "三浦透子", album: "天気の子", duration: 156.16,
                lines: translatedLines, isSynchronized: true, source: .neteaseExperimental, confidence: 0.9,
                providerSourceID: "netease:1378491293")
            let fullVersion = LyricsCandidate(id: "netease:1401025134", identity: identity,
                title: "祝祭 feat.三浦透子", artist: "RADWIMPS, 三浦透子", album: "天気の子", duration: 274.24,
                lines: [LyricLine(timestamp: 1, originalText: "Full-version fixture")],
                isSynchronized: true, source: .neteaseExperimental, confidence: 0.95,
                providerSourceID: "netease:1401025134")
            return .candidates([shortVersion, fullVersion])
        }
        return .noMatch
    }
}

private struct UtadaRecordingProvider: LyricsProvider {
    var artist = "宇多田ヒカル"
    var duration = 280.938
    var name: String { "netease-utada-fixture" }
    var executionLane: LyricsProviderExecutionLane { .network }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        .candidates([LyricsCandidate(id: "netease:567601200", identity: identity,
            title: "初恋", artist: artist, album: "初恋", duration: duration,
            lines: (0..<52).map { index in
                LyricLine(timestamp: Double(index), originalText: "日本語行\(index + 1)", translationText: "中文行\(index + 1)")
            }, isSynchronized: true, source: .neteaseExperimental, confidence: 0.95,
            providerSourceID: "netease:567601200")])
    }
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

private func runAliasRecallContracts() async {
    let celebrationID = "4KSdoYvrxRIHyvIvMPBfgw"
    let hatsukoiID = "5EgW6VV9LW6xtgJ1sFN5RU"
    SpotifyAliasFixtureURLProtocol.reset([
        celebrationID: spotifyEmbedPage(id: celebrationID, title: "祝祭 - Movie edit", duration: 156.16,
            artists: ["RADWIMPS", "Toko Miura"]),
        hatsukoiID: spotifyEmbedPage(id: hatsukoiID, title: "初恋", duration: 280.938,
            artists: ["Hikaru Utada"])
    ])
    let celebration = Track(title: "Celebration (Movie Edit) [feat. Toko Miura]", artist: "RADWIMPS",
        album: "Weathering With You", duration: 156.16, spotifyId: celebrationID)
    let aliasMetadata = TrackMetadata(identity: TrackIdentity(track: celebration), track: celebration,
        aliases: TrackMetadata.bootstrap(from: celebration).aliases + [
            TrackAlias(id: "spotify-entity-title", field: .title, kind: .localizedTitle, value: "祝祭 - Movie edit",
                script: .mixed, source: .spotifyMetadata, confidence: 1, isOfficial: true),
            TrackAlias(id: "spotify-entity-artist-0", field: .artist, kind: .localizedTitle, value: "RADWIMPS",
                script: .latin, source: .spotifyMetadata, confidence: 1, isOfficial: true),
            TrackAlias(id: "spotify-entity-artist-1", field: .artist, kind: .localizedTitle, value: "Toko Miura",
                script: .latin, source: .spotifyMetadata, confidence: 1, isOfficial: true)
        ])
    let aliasProbe = LyricsCandidate(id: "alias-probe", identity: TrackIdentity(track: celebration),
        title: "祝祭 (Movie edit)", artist: "三浦透子", album: "天気の子", duration: 156.16,
        lines: [LyricLine(timestamp: 1, originalText: "目を閉じて", translationText: "闭上双眼")],
        isSynchronized: true, source: .neteaseExperimental, confidence: 0.9)
    let aliasProbeDecision = LyricsSafeMatcher.decide(candidate: aliasProbe, metadata: aliasMetadata,
        aliasUsed: aliasMetadata.aliases.first { $0.id == "spotify-entity-title" },
        queryVariant: LyricsQueryPlanner.plan(for: aliasMetadata).first { $0.titleQuery == "祝祭 - Movie edit" && $0.artistQuery == "RADWIMPS" })
    precondition(aliasProbeDecision.tier == .autoMedium && !aliasProbeDecision.hardReject,
        "a complete official credited-artist reading with exact localized version and duration should auto-match")
    let celebrationQueries = SearchQueryLedger()
    let browseOutcome = await LyricsSearchManager(
        providers: [LocalizedVersionBrowseProvider(queries: celebrationQueries, originalTitle: celebration.title)],
        spotifyArtistResolver: fixtureSpotifyResolver()
    ).search(track: celebration, identity: TrackIdentity(track: celebration), collectCandidatesOnly: true)
    guard case .candidates(let browsed) = browseOutcome.result else { fatalError("localized version browse returned no candidates") }
    let browsedIDs = Set(browsed.compactMap(\.providerSourceID))
    precondition(browsedIDs.contains("netease:1378491293") && browsedIDs.contains("lrclib:movie-edit"),
        "a first-query LRCLIB hit must not suppress the later localized NetEase title/artist query")
    precondition(!browsedIDs.contains("netease:1401025134"), "the full 274-second recording must not replace Movie edit")
    guard let localizedCandidate = browsed.first(where: { $0.providerSourceID == "netease:1378491293" }) else {
        fatalError("localized NetEase candidate missing")
    }
    precondition(localizedCandidate.artist == "三浦透子"
        && localizedCandidate.lines.map(\.translationText) == ["闭上双眼", "抬头望向天空"],
        "preserve the source's credited performer and line-aligned translations")
    let celebrationQueriesSeen = await celebrationQueries.snapshot()
    precondition(celebrationQueriesSeen.contains("祝祭 - Movie edit\u{1F}RADWIMPS"),
        "version browse must try the exact Spotify localized title with its primary credited artist")
    precondition(SpotifyAliasFixtureURLProtocol.count() == 1 && browseOutcome.automaticDecision == nil,
        "exact-track alias fetch is cached once and version browse never adopts automatically")
    print("PASS Celebration Movie edit: first-query hit retained, localized NetEase candidate and translations discovered, full version excluded")

    SpotifyAliasFixtureURLProtocol.reset([
        celebrationID: spotifyEmbedPage(id: celebrationID, title: "祝祭 - Movie edit", duration: 156.16,
            artists: ["RADWIMPS", "Toko Miura"])
    ])
    let autoQueries = SearchQueryLedger()
    let celebrationAuto = await LyricsSearchManager(
        providers: [LocalizedVersionBrowseProvider(queries: autoQueries, originalTitle: celebration.title,
            includeFirstQueryHit: false)],
        spotifyArtistResolver: fixtureSpotifyResolver()
    ).search(track: celebration, identity: TrackIdentity(track: celebration))
    guard case .match(let localizedDocument) = celebrationAuto.result else {
        fatalError("exact Spotify canonical title and credited Toko Miura reading should auto-match the Movie edit")
    }
    precondition(localizedDocument.providerSourceID == "netease:1378491293"
        && localizedDocument.lines.map(\.translationText) == ["闭上双眼", "抬头望向天空"]
        && celebrationAuto.automaticDecision?.tier == .autoMedium,
        "automatically select the localized Movie edit while preserving source-aligned translations")
    precondition(SpotifyAliasFixtureURLProtocol.count() == 1,
        "normal no-match search should resolve this exact Spotify recording once")
    print("PASS Celebration Movie edit: exact canonical title and credited guest reading auto-select the 156-second translation")

    SpotifyAliasFixtureURLProtocol.reset([
        hatsukoiID: spotifyEmbedPage(id: hatsukoiID, title: "初恋", duration: 280.938,
            artists: ["Hikaru Utada"])
    ])
    let hatsukoi = Track(title: "初恋", artist: "宇多田光", album: "初恋", duration: 280.938, spotifyId: hatsukoiID)
    let hatsukoiOutcome = await LyricsSearchManager(providers: [UtadaRecordingProvider()],
        spotifyArtistResolver: fixtureSpotifyResolver())
        .search(track: hatsukoi, identity: TrackIdentity(track: hatsukoi))
    guard case .match(let hatsukoiDocument) = hatsukoiOutcome.result else {
        fatalError("Spotify-verified Japanese artist reading should auto-match the NetEase recording")
    }
    precondition(hatsukoiOutcome.automaticDecision?.tier == .autoMedium
        && hatsukoiOutcome.automaticDecision?.reasons.contains("primaryArtistReadingExact") == true,
        "exact Spotify artist reading should authorize a medium-confidence match")
    precondition(hatsukoiDocument.providerSourceID == "netease:567601200"
        && hatsukoiDocument.lines.count == 52
        && hatsukoiDocument.lines.allSatisfy { $0.translationText != nil },
        "keep all 52 source-aligned Chinese translations when adopting the exact recording")
    precondition(SpotifyAliasFixtureURLProtocol.count() == 1, "automatic no-match enrichment must use one cached exact-track metadata read")
    print("PASS 初恋: Spotify-backed Utada reading resolves 宇多田ヒカル and keeps 52 aligned translations")

    let wrongArtistOutcome = await LyricsSearchManager(providers: [UtadaRecordingProvider(artist: "Aimer")],
        spotifyArtistResolver: fixtureSpotifyResolver())
        .search(track: hatsukoi, identity: TrackIdentity(track: hatsukoi))
    if case .match = wrongArtistOutcome.result {
        fatalError("an unrelated provider artist must not auto-match from exact title and duration")
    }
    let wrongDurationOutcome = await LyricsSearchManager(providers: [UtadaRecordingProvider(duration: 286)],
        spotifyArtistResolver: fixtureSpotifyResolver())
        .search(track: hatsukoi, identity: TrackIdentity(track: hatsukoi))
    precondition(wrongDurationOutcome.automaticDecision == nil,
        "official artist reading must not auto-match when recording duration differs by more than two seconds")
    print("PASS official artist reading still rejects wrong artist and keeps duration-mismatched results manual")
}

@main struct SearchConcurrencyManualContract {
    static func main() async {
        if CommandLine.arguments.contains("--alias-search-recall") {
            await runAliasRecallContracts()
            return
        }
        let track = Track(title: "Contract song", artist: "Contract artist", album: "Contract album", duration: 180)
        let identity = TrackIdentity(track: track)
        let localizedTrack = Track(title: "Uta o Oshietekureta Anata e", artist: "ミセカイ", album: "Artrium", duration: 253.677, spotifyId: "7eqgj3zza04nswadcvqnyk")
        for multiple in [false, true] {
            let outcome = await LyricsSearchManager(providers: [LocalizedTitleProvider(includeAlternative: multiple)]).search(track: localizedTrack, identity: TrackIdentity(track: localizedTrack))
            guard case .match(let original) = outcome.result else { fatalError("localized title stopped at manual choice") }
            precondition(original.title == "唄を教えてくれたあなたへ" && original.isSynchronized && original.lines[0].timestamp == 7, "automatic adoption must keep the selected source's real original and timing")
            precondition(outcome.automaticDecision?.tier == .autoMedium, "retain automatic selection persistence receipt")
            precondition(outcome.alternatives.map(\.id) == ["localized-original"],
                "keep the adopted source available, but do not retain another song by the same artist as a version")
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
            precondition(outcome.alternatives.map(\.id) == ["typography-original"],
                "a differently tagged recording must not be retained as the selected Another ver. source")
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
        precondition(versionsRun.0 == 0 && versionsRun.1 == 3 && versionsRun.2.count == 10 && versionsRun.3.count == 10,
            "version browsing must inspect both distinct query variants across all sources, with at most three parallel probes")
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
        await runAliasRecallContracts()
    }
}
