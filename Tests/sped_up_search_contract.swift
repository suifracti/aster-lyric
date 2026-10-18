import Foundation

private struct FixtureProvider: LyricsProvider {
    let name: String
    let result: LyricsLookupResult
    var executionLane: LyricsProviderExecutionLane { .network }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { result }
}
private actor SearchProgress {
    var queries = 0
    var provisional = false
    func began() { queries += 1 }
    func published() { provisional = true }
    func snapshot() -> (Int, Bool) { (queries, provisional) }
}
private struct TranslationCompanionProvider: LyricsProvider {
    let progress: SearchProgress
    let translated: [LyricLine]
    var name: String { "translation-companion-fixture" }
    var executionLane: LyricsProviderExecutionLane { .network }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        await progress.began()
        if track.title != "アーカイブ" { return .failed(.lyricsBodyUnavailable("fixture metadata only")) }
        // The plain exact original must be visible before this optional lookup.
        let state = await progress.snapshot()
        precondition(state.1, "optional translation search blocked first lyrics")
        return .candidates([LyricsCandidate(id: "base-translation", identity: identity,
            title: "アーカイブ", artist: "stb, NEA, ささ。", album: "アーカイブ", duration: 238.977,
            lines: translated, isSynchronized: true, source: .neteaseExperimental, confidence: 0.8)])
    }
}
@main struct SpedUpSearchContract {
    static func require(_ value: Bool, _ label: String) {
        if !value { print("FAIL: \(label)"); exit(1) }
    }
    static let track = Track(title: "アーカイブ - Sped Up Ver.", artist: "stb", album: "アーカイブ", duration: 211.327, isrc: "JPTEST0000001", spotifyId: "2HqNw4rFwPATZZSYiaXpCD")
    static func candidate(title: String = "アーカイブ", artist: String = "stb, NEA, ささ。", duration: Double = 238.977, spotifyID: String? = nil, isrc: String? = nil) -> LyricsCandidate {
        LyricsCandidate(id: "fixture:archive", identity: TrackIdentity(track: track), title: title, artist: artist, album: "アーカイブ", duration: duration,
            lines: [LyricLine(timestamp: 8, originalText: "自写测试：那封信仍在这里", endTime: 10, translationText: "Self-authored reference", timedSpans: [TimedTextSpan(id: 0, text: "自", startTime: 8, endTime: 9, utf16Start: 0, utf16Length: 1)])],
            isSynchronized: true, source: .neteaseExperimental, confidence: 0.8, providerSourceID: "fixture:archive", spotifyTrackID: spotifyID, isrc: isrc, explicitlyTimedLineIndices: [0])
    }
    static func featuredIdentityContract() async {
        let track = Track(title: "Song (feat. Alice)", artist: "Artist", album: "Fixture", duration: 120,
            isrc: "JPTEST0000001", spotifyId: "fixture-recording")
        let metadata = TrackMetadata.bootstrap(from: track)
        func candidate(_ guest: String, id: String? = nil, isrc: String? = nil, omitGuest: Bool = false) -> LyricsCandidate {
            LyricsCandidate(id: "guest-\(guest)", identity: metadata.identity,
                title: omitGuest ? "Song" : "Song (feat. \(guest))", artist: omitGuest ? "Artist" : "Artist, \(guest)",
                album: "Fixture", duration: 120, lines: [LyricLine(timestamp: 0, originalText: "synthetic fixture")],
                isSynchronized: true, source: .lrclib, confidence: 1, spotifyTrackID: id, isrc: isrc)
        }
        for item in [candidate("Bob"), candidate("Alice", omitGuest: true)] {
            let decision = LyricsSafeMatcher.decide(candidate: item, metadata: metadata)
            require(![.autoHigh, .autoMedium].contains(decision.tier), "unverified different/missing guest became automatic")
            let outcome = await LyricsSearchManager(providers: [FixtureProvider(name: "guest-negative", result: .candidates([item]))])
                .search(track: track, identity: metadata.identity)
            if case .match = outcome.result { require(false, "different guest automatically adopted") }
        }
        for item in [candidate("Alice"), candidate("Bob", id: track.spotifyId), candidate("Bob", isrc: track.isrc)] {
            require([.autoHigh, .autoMedium].contains(LyricsSafeMatcher.decide(candidate: item, metadata: metadata).tier),
                "same guest/independent recording identity positive lost")
        }
        let conflict = LyricsSafeMatcher.decide(candidate: candidate("Bob", id: "other-recording"), metadata: metadata)
        require(conflict.hardReject && conflict.tier == .reject, "guest alias bypassed conflicting recording ID")
        let alias = TrackAlias(id: "confirmed-guest-title", field: .title, kind: .userAlias,
            value: "Song (feat. Alicia)", source: .user, confidence: 1, isOfficial: true)
        var confirmed = metadata; confirmed.aliases.append(alias)
        let aliased = candidate("Alicia")
        require([.autoHigh, .autoMedium].contains(LyricsSafeMatcher.decide(candidate: aliased, metadata: confirmed, aliasUsed: alias).tier),
            "explicit trusted full-title guest alias no longer usable")
        let machine = TrackAlias(id: "machine-guest-title", field: .title, kind: .alternativeTitle,
            value: aliased.title, source: .machineGenerated, confidence: 1, isOfficial: false)
        var untrusted = metadata; untrusted.aliases.append(machine)
        require(![.autoHigh, .autoMedium].contains(LyricsSafeMatcher.decide(candidate: aliased, metadata: untrusted, aliasUsed: machine).tier),
            "machine guest alias promoted automatic adoption")
        let aliasOutcome = await LyricsSearchManager(providers: [FixtureProvider(name: "guest-alias", result: .candidates([aliased]))])
            .search(track: track, identity: metadata.identity, aliases: [alias])
        guard case .match = aliasOutcome.result else { require(false, "confirmed guest alias not adopted by search"); return }
        print("PASS guest identity: Alice/Bob and missing guests candidate-only; exact guest/SpotifyID/ISRC/trusted alias positives; conflicts/machine aliases blocked")
    }
    static func main() async {
        let privateHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).resolvingSymlinksInPath()
        precondition(FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() == privateHome, "contract preferences must be private")
        let homeAttributes = try! FileManager.default.attributesOfItem(atPath: privateHome.path)
        precondition((homeAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        await featuredIdentityContract()
        let metadata = TrackMetadata.bootstrap(from: track)
        print("BASELINE_QUERY_PLAN", LyricsQueryPlanner.plan(for: metadata).map { "\($0.rank):\($0.titleQuery)|\($0.artistQuery ?? "")" })
        for title in ["アーカイブ - Sped Up Ver.", "アーカイブ (SPEED UP VERSION)", "アーカイブ（Sped-Up）", "アーカイブ [speed up]", "アーカイブ — Sped Up", "アーカイブ - Sped Up Version"] {
            require(TrackTextNormalizer.stripVersionMarkers(fromTitle: title) == "アーカイブ", "explicit tempo suffix must produce base-title fallback: \(title)")
            require(!TrackTextNormalizer.extractVersionTags(fromTitle: title).isEmpty, "tempo trait retained")
        }
        for title in ["Speed Up Your Life", "Sped Up", "アーカイブ Sped Up Love"] {
            require(TrackTextNormalizer.stripVersionMarkers(fromTitle: title) == title, "ordinary title must remain intact")
        }
        require(LyricsQueryPlanner.plan(for: metadata).contains { $0.titleQuery == "アーカイブ" && $0.artistQuery == "stb" && $0.queryKind == .normalizedVersionTitleFullArtist }, "artist-scoped fallback missing")
        let plainLines = ["自写甲：星の手紙", "自写乙：空を見よう", "自写丙：朝を待って"].map { LyricLine(timestamp: 0, originalText: $0) }
        let plain = LyricsDocument(identity: metadata.identity, title: "アーカイブ (Sped Up Ver.)",
            artist: "stb, NEA, ささ。", album: "アーカイブ", duration: 211.327, lines: plainLines,
            isSynchronized: false, source: .qqExperimental, providerSourceID: "fixture-exact-plain")
        let translated = plainLines.enumerated().map { i, line in
            LyricLine(timestamp: Double(i + 1) * 10, originalText: line.originalText, translationText: "Self authored translation \(i)")
        }
        let donor = LyricsCandidate(id: "donor", identity: metadata.identity, title: "アーカイブ", artist: "stb, NEA, ささ。",
            album: "アーカイブ", duration: 238.977, lines: translated, isSynchronized: true, source: .neteaseExperimental, confidence: 0.8)
        let wrongWords = plain.replacingLines([plainLines[0], LyricLine(timestamp: 0, originalText: "a different verse"), plainLines[2]])
        require(LyricsSearchManager.mergingTranslationCompanion(donor, into: wrongWords, metadata: metadata) == nil, "partial text overlap paired a different verse")
        let reordered = plain.replacingLines(plainLines.reversed())
        require(LyricsSearchManager.mergingTranslationCompanion(donor, into: reordered, metadata: metadata) == nil, "out of order text paired a different arrangement")
        let pianoDonor = LyricsCandidate(id: "piano-donor", identity: metadata.identity, title: "アーカイブ (Piano Ver.)", artist: "stb",
            album: "アーカイブ", duration: 240, lines: translated, isSynchronized: true, source: .neteaseExperimental, confidence: 0.8)
        require(LyricsSearchManager.mergingTranslationCompanion(pianoDonor, into: plain, metadata: metadata) == nil, "piano arrangement supplied a tempo companion")
        let progress = SearchProgress()
        let plainOutcome = await LyricsSearchManager(providers: [
            TranslationCompanionProvider(progress: progress, translated: translated),
            FixtureProvider(name: "QQ plain", result: .match(plain))
        ]).search(track: track, identity: metadata.identity, onProvisional: { _ in await progress.published() })
        guard case .match(let paired) = plainOutcome.result else { require(false, "exact plain recording not automatically adopted"); return }
        require(paired.lines.map(\.translationText) == translated.map(\.translationText), "identical original text did not recover source translation")
        require(!paired.isSynchronized && paired.lines.map(\.timestamp) == plainLines.map(\.timestamp), "other tempo timestamps leaked")
        require(paired.lines.map(\.id) == plainLines.map(\.id) && paired.providerSourceID == plain.providerSourceID, "companion replaced original identity")
        let progressState = await progress.snapshot()
        require(progressState.0 == 2 && progressState.1, "unnecessary query variants ran after exact plain match")
        let original = candidate()
        let d = LyricsSafeMatcher.decide(candidate: original, metadata: metadata)
        require(d.tier == .candidates && d.versionConflict && !d.hardReject, "same composition can preview text only, never auto adopt recording")
        for bad in [candidate(artist: "Other Artist"), candidate(spotifyID:"2SufJjq3cM8qjsc6jhdRP6"), candidate(isrc:"JPTEST0000002"), candidate(title:"別の歌")] {
            require(LyricsSafeMatcher.decide(candidate: bad, metadata: metadata).tier == .reject, "independent identity or composition conflict escaped")
        }
        for title in ["アーカイブ (Piano Ver.)", "アーカイブ (Live)", "アーカイブ (Remix)"] {
            let conflict = LyricsSafeMatcher.decide(candidate: candidate(title:title), metadata:metadata)
            require(conflict.versionConflict && conflict.tier != .autoHigh && conflict.tier != .autoMedium, "other recording adopted")
        }
        let plainTrack = Track(title:"アーカイブ", artist:"stb", album:"アーカイブ", duration:238.977, spotifyId:"2SufJjq3cM8qjsc6jhdRP6")
        require(!LyricsSafeMatcher.decide(candidate:original, metadata:TrackMetadata.bootstrap(from:plainTrack)).versionConflict, "ordinary recording wrongly marked tempo conflict")
        // Playback exposes only the primary artist; providers include the release credits.
        let credited = candidate(title: "アーカイブ (Sped Up Ver.)", duration: 211.327)
        let creditedDecision = LyricsSafeMatcher.decide(candidate: credited, metadata: metadata)
        require([.autoHigh, .autoMedium].contains(creditedDecision.tier), "same title/version/duration blocked by additional release credits")
        require(creditedDecision.reasons.contains("collaboratorMetadataDifference"), "credit difference must be explicit, not unconfirmed")
        let creditedOutcome = await LyricsSearchManager(providers: [FixtureProvider(name: "release-credits", result: .candidates([credited]))])
            .search(track: track, identity: metadata.identity)
        guard case .match = creditedOutcome.result else { require(false, "matching release credits forced full fallback search"); return }
        for bad in [candidate(title: credited.title, duration: 238.977), candidate(title: "アーカイブ (Piano Ver.)", duration: 211.327), candidate(title: credited.title, artist: "Other Artist", duration: 211.327)] {
            require(![.autoHigh, .autoMedium].contains(LyricsSafeMatcher.decide(candidate: bad, metadata: metadata).tier), "credit tolerance bypassed recording mismatch")
        }
        let exact = candidate(title:track.title, artist:"stb", duration:211.327)
        let exactD = LyricsSafeMatcher.decide(candidate:exact, metadata:metadata)
        require(!exactD.versionConflict && [.autoHigh,.autoMedium].contains(exactD.tier), "matching tempo recording no longer usable")
        let exactOutcome = await LyricsSearchManager(providers: [FixtureProvider(name: "matching tempo fixture", result: .candidates([exact]))]).search(track: track, identity: metadata.identity)
        guard case .match(let exactDocument) = exactOutcome.result else { require(false, "same recording valid synchronization must be retained"); return }
        require(exactDocument.isSynchronized && exactDocument.lines[0].timestamp == 8 && exactDocument.lines[0].timedSpans == exact.lines[0].timedSpans, "valid sped-up timeline changed")
        let outcome = await LyricsSearchManager(providers:[FixtureProvider(name:"QQ fixture",result:.failed(.serverError(500))),FixtureProvider(name:"NetEase fixture",result:.candidates([original]))]).search(track:track,identity:metadata.identity)
        guard case .candidates(let visible) = outcome.result else { require(false,"500 contaminated useful text candidate");return }
        require(visible.count == 1, "repeated query hits must deduplicate")
        let safe = visible[0]
        require(!safe.isSynchronized && safe.explicitlyTimedLineIndices == nil && safe.lines.allSatisfy { $0.timestamp == 0 && $0.endTime == nil && $0.timedSpans == nil }, "wrong recording timing leaked into preview")
        require(safe.lines.map(\.id) == original.lines.map(\.id) && safe.lines.map(\.originalText) == original.lines.map(\.originalText), "text or immutable line identity changed")
        require(!safe.makeDocument().isSynchronized && safe.arrangementNotice != nil, "manual adoption falsely verifies timing")
        require(outcome.diagnostics.contains { if case .failed(.serverError(500)) = $0.outcome { return true };return false }, "provider failure lost")
        require(outcome.sourceFailureSummary?.contains("QQ fixture：歌词服务错误（HTTP 500）") == true, "source failure must retain provider name separately from candidates")
        let direct = LyricsCandidate(id:original.id, identity:original.identity, title:original.title, artist:original.artist, album:original.album, duration:original.duration, lines:original.lines, source:original.source, confidence:original.confidence, matchExplanation:d.explanation)
        require(!direct.makeDocument().isSynchronized && direct.makeDocument().lines[0].timedSpans == nil, "direct adoption bypassed tempo text guard")
        let manual = await LyricsSearchManager(providers:[FixtureProvider(name:"NetEase fixture",result:.candidates([original]))]).search(track:track,identity:metadata.identity,queryOverride:"アーカイブ")
        guard case .candidates(let manualList) = manual.result else { require(false,"manual search must remain available");return }
        require(manualList.allSatisfy { !$0.isSynchronized }, "manual search bypassed timeline barrier")
        print("PASS: explicit suffixes, scoped fallback, candidate-only composition, ID/ISRC conflicts, recording restrictions, provider isolation, dedup, text-only preview/adoption")
    }
}
