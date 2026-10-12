import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private final class CountingProvider: LyricsProvider, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var calls = 0
    private let result: LyricsLookupResult

    init(name: String, result: LyricsLookupResult) {
        self.name = name
        self.result = result
    }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        incrementCallCount()
        return result
    }

    private func incrementCallCount() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class FallbackProvider: LyricsProvider, @unchecked Sendable {
    let name: String
    private let result: LyricsLookupResult

    init(name: String, result: LyricsLookupResult) {
        self.name = name
        self.result = result
    }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        result
    }
}

private final class LocalLaneProvider: LyricsProvider, @unchecked Sendable {
    let name = "Local fixture"
    let executionLane: LyricsProviderExecutionLane = .local
    let timeoutInterval: TimeInterval = 2

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        .noMatch
    }
}

private final class DelayedProvider: LyricsProvider, @unchecked Sendable {
    let name: String
    let executionLane: LyricsProviderExecutionLane
    let timeoutInterval: TimeInterval
    private let delay: TimeInterval
    private let result: LyricsLookupResult
    private let lock = NSLock()
    private var calls = 0

    init(
        name: String,
        lane: LyricsProviderExecutionLane = .network,
        timeout: TimeInterval = 8,
        delay: TimeInterval,
        result: LyricsLookupResult
    ) {
        self.name = name
        self.executionLane = lane
        self.timeoutInterval = timeout
        self.delay = delay
        self.result = result
    }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        lock.withLock { calls += 1 }
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            return .failed(.cancelled)
        }
        return result
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@main
struct Phase211ARetrievalContract {
    static func main() async {
        let defaultNetworkProvider = FallbackProvider(name: "Network fixture", result: .noMatch)
        require(defaultNetworkProvider.executionLane == .network, "providers default to the network lane")
        require(defaultNetworkProvider.timeoutInterval == 8, "network timeout default")
        let localLaneProvider = LocalLaneProvider()
        require(localLaneProvider.executionLane == .local, "local provider lane")
        require(localLaneProvider.timeoutInterval == 2, "local provider timeout")

        let liveTrack = Track(
            title: "春を告げる - From THE FIRST TAKE",
            artist: "yama",
            album: "春を告げる - From THE FIRST TAKE",
            duration: 300,
            spotifyId: "track-id"
        )
        let liveMetadata = TrackMetadata.bootstrap(from: liveTrack)
        let liveIdentity = TrackIdentity(track: liveTrack)

        func document(
            source: LyricsSource,
            providerID: String,
            lines: [LyricLine]? = nil
        ) -> LyricsDocument {
            LyricsDocument(
                identity: liveIdentity,
                title: liveTrack.title,
                artist: liveTrack.artist,
                album: liveTrack.album,
                duration: liveTrack.duration,
                lines: lines ?? [LyricLine(timestamp: 0, originalText: "fixture")],
                isSynchronized: true,
                source: source,
                confidence: 1,
                providerSourceID: providerID,
                spotifyTrackID: liveTrack.spotifyId
            )
        }

        let equalQualityNetwork = DelayedProvider(
            name: "equal-quality-network",
            delay: 0.01,
            result: .match(document(source: .lrclib, providerID: "network"))
        )
        let localFirstManager = LyricsSearchManager(providers: [
            DelayedProvider(
                name: "local",
                lane: .local,
                delay: 0,
                result: .match(document(source: .local, providerID: "local"))
            ),
            equalQualityNetwork
        ])
        guard case .match(let localDocument) = await localFirstManager.lookup(
            track: liveTrack,
            identity: liveIdentity
        ) else {
            preconditionFailure("local exact match should be adopted")
        }
        require(localDocument.source == .local, "configured provider order wins equivalent local/network timing")

        let crossLanePlainLine = LyricLine(timestamp: 0, originalText: "A🙂A")
        let crossLaneTimedLine = LyricLine(
            timestamp: 0,
            originalText: "A🙂A",
            timedSpans: [
                TimedTextSpan(id: 0, text: "A", startTime: 0, endTime: 0.3, utf16Start: 0, utf16Length: 1),
                TimedTextSpan(id: 1, text: "🙂", startTime: 0.3, endTime: 0.6, utf16Start: 1, utf16Length: 2),
                TimedTextSpan(id: 2, text: "A", startTime: 0.6, endTime: 1, utf16Start: 3, utf16Length: 1)
            ]
        )
        let localPlainMatch = DelayedProvider(
            name: "local-plain",
            lane: .local,
            delay: 0,
            result: .match(document(source: .local, providerID: "local-plain", lines: [crossLanePlainLine]))
        )
        let networkWordTimedMatch = DelayedProvider(
            name: "network-word-timed",
            delay: 0,
            result: .match(document(source: .lrclib, providerID: "network-word-timed", lines: [crossLaneTimedLine]))
        )
        let crossLaneOutcome = await LyricsSearchManager(providers: [localPlainMatch, networkWordTimedMatch]).search(
            track: liveTrack,
            identity: liveIdentity
        )
        guard case .match(let crossLaneDocument) = crossLaneOutcome.result else {
            preconditionFailure("a trusted cross-lane candidate should be auto-selected")
        }
        require(
            crossLaneDocument.source == .lrclib,
            "valid network word timing should beat an equivalent local line-timed match"
        )
        require(
            crossLaneDocument.lines.first?.timedSpans == crossLaneTimedLine.timedSpans,
            "the selected richer network candidate must preserve its actual spans"
        )
        require(localPlainMatch.callCount() == 1 && networkWordTimedMatch.callCount() == 1, "the manager must compare local and network automatic results")
        require(equalQualityNetwork.callCount() == 1, "automatic selection compares equivalent-quality network results after the local lane")

        let concurrentManager = LyricsSearchManager(providers: [
            DelayedProvider(name: "slow miss", delay: 0.20, result: .noMatch),
            DelayedProvider(
                name: "slow match",
                delay: 0.20,
                result: .match(document(source: .amll, providerID: "concurrent"))
            )
        ])
        let concurrentStart = Date()
        guard case .match = await concurrentManager.lookup(track: liveTrack, identity: liveIdentity) else {
            preconditionFailure("concurrent network fallback should match")
        }
        require(
            Date().timeIntervalSince(concurrentStart) < 0.34,
            "network providers must complete near the slower single delay, not their sum"
        )

        let timeoutManager = LyricsSearchManager(providers: [
            DelayedProvider(name: "timeout", timeout: 0.05, delay: 0.30, result: .noMatch),
            DelayedProvider(
                name: "match after timeout",
                delay: 0.03,
                result: .match(document(source: .qqExperimental, providerID: "timeout-fallback"))
            )
        ])
        let timeoutStart = Date()
        guard case .match(let timeoutFallback) = await timeoutManager.lookup(
            track: liveTrack,
            identity: liveIdentity
        ) else {
            preconditionFailure("one provider timeout must not suppress another match")
        }
        require(timeoutFallback.source == .qqExperimental, "post-timeout provider match")
        require(Date().timeIntervalSince(timeoutStart) < 0.18, "provider timeout must bound the variant")

        let orderedManager = LyricsSearchManager(providers: [
            DelayedProvider(
                name: "configured first",
                delay: 0.14,
                result: .match(document(source: .lrclib, providerID: "first"))
            ),
            DelayedProvider(
                name: "finishes first",
                delay: 0.01,
                result: .match(document(source: .amll, providerID: "second"))
            )
        ])
        guard case .match(let orderedDocument) = await orderedManager.lookup(
            track: liveTrack,
            identity: liveIdentity
        ) else {
            preconditionFailure("configured provider priority should produce a match")
        }
        require(orderedDocument.source == .lrclib, "completion order must not replace configured priority")

        let invalidTimedLine = LyricLine(
            timestamp: 0,
            originalText: "A🙂A",
            timedSpans: [TimedTextSpan(
                id: 0,
                text: "Z",
                startTime: 0.5,
                endTime: 0.2,
                utf16Start: 0,
                utf16Length: 1
            )]
        )
        let plainLine = LyricLine(timestamp: 0, originalText: "A🙂A")
        let validTimedLine = LyricLine(
            timestamp: 0,
            originalText: "A🙂A",
            timedSpans: [
                TimedTextSpan(id: 0, text: "A", startTime: 0, endTime: 0.3, utf16Start: 0, utf16Length: 1),
                TimedTextSpan(id: 1, text: "🙂", startTime: 0.3, endTime: 0.6, utf16Start: 1, utf16Length: 2),
                TimedTextSpan(id: 2, text: "A", startTime: 0.6, endTime: 1, utf16Start: 3, utf16Length: 1)
            ]
        )
        func candidate(
            _ id: String,
            lines: [LyricLine],
            title: String = liveTrack.title,
            isSynchronized: Bool = true,
            explicitlyTimedLineIndices: Set<Int>? = nil
        ) -> LyricsCandidate {
            LyricsCandidate(
                id: id,
                identity: liveIdentity,
                title: title,
                artist: liveTrack.artist,
                album: liveTrack.album,
                duration: liveTrack.duration,
                lines: lines,
                isSynchronized: isSynchronized,
                source: .lrclib,
                confidence: 1,
                providerSourceID: id,
                spotifyTrackID: liveTrack.spotifyId,
                explicitlyTimedLineIndices: explicitlyTimedLineIndices
            )
        }
        let validPartialCandidate = candidate(
            "valid-timed-partial",
            lines: [validTimedLine],
            isSynchronized: false,
            explicitlyTimedLineIndices: [0]
        )
        let mixedValidAndMalformedCandidate = candidate(
            "mixed-valid-and-malformed",
            lines: [validTimedLine, invalidTimedLine]
        )
        let qualityProvider = CountingProvider(
            name: "timing-quality fixture",
            result: .candidates([
                mixedValidAndMalformedCandidate,
                candidate("invalid-timed", lines: [invalidTimedLine]),
                candidate("plain", lines: [plainLine], isSynchronized: false),
                validPartialCandidate
            ])
        )
        let qualityOutcome = await LyricsSearchManager(providers: [qualityProvider]).search(
            track: liveTrack,
            identity: liveIdentity
        )
        guard case .match(let qualityDocument) = qualityOutcome.result else {
            preconditionFailure("a trusted exact candidate should be auto-selected")
        }
        require(
            qualityDocument.lines.first?.timedSpans == validTimedLine.timedSpans,
            "valid real word timing must win an equivalent match; a malformed span anywhere must not boost a mixed payload"
        )
        require(
            qualityDocument.providerSourceID == validPartialCandidate.providerSourceID,
            "a candidate with valid spans on one line and malformed spans on another must not outrank a fully valid partial payload"
        )
        require(!qualityDocument.isSynchronized, "partial timeline remains unsynchronized after candidate projection")
        require(qualityDocument.explicitlyTimedLineIndices == Set([0]), "explicit partial line mask survives candidate projection")

        let lineTimedCandidate = candidate("line-timed", lines: [plainLine])
        let untimedCandidate = candidate("untimed", lines: [plainLine], isSynchronized: false)
        let lineQualityOutcome = await LyricsSearchManager(providers: [
            CountingProvider(name: "line timing before plain text", result: .candidates([untimedCandidate, lineTimedCandidate]))
        ]).search(track: liveTrack, identity: liveIdentity)
        guard case .match(let lineQualityDocument) = lineQualityOutcome.result else {
            preconditionFailure("line-timed trusted candidate should be auto-selected")
        }
        require(lineQualityDocument.providerSourceID == lineTimedCandidate.providerSourceID, "valid line timing outranks plain text")

        let weakLyricsOVH = LyricsCandidate(
            id: "weak-lyrics-ovh",
            identity: liveIdentity,
            title: liveTrack.title,
            artist: liveTrack.artist,
            album: liveTrack.album,
            duration: liveTrack.duration,
            lines: [plainLine],
            isSynchronized: false,
            source: .lyricsOVH,
            confidence: 0,
            providerSourceID: "lyrics-ovh-query-only",
            spotifyTrackID: liveTrack.spotifyId
        )
        let weakOutcome = await LyricsSearchManager(providers: [
            CountingProvider(name: "low-trust provider", result: .candidates([weakLyricsOVH]))
        ]).search(track: liveTrack, identity: liveIdentity)
        guard case .candidates(let weakResults) = weakOutcome.result else {
            preconditionFailure("zero-confidence lyrics.ovh result must remain a review candidate, not automatic selection")
        }
        require(weakResults.count == 1 && weakResults[0].source == .lyricsOVH && weakResults[0].confidence == 0, "manual-only source and confidence remain unchanged")

        let validTimedDocument = LyricsDocument(
            identity: liveIdentity,
            title: liveTrack.title,
            artist: liveTrack.artist,
            album: liveTrack.album,
            duration: liveTrack.duration,
            lines: [validTimedLine],
            isSynchronized: true,
            source: .amll,
            confidence: 1,
            providerSourceID: "timed-provider",
            spotifyTrackID: liveTrack.spotifyId
        )
        let providerQualityManager = LyricsSearchManager(providers: [
            CountingProvider(name: "configured plain", result: .match(document(source: .lrclib, providerID: "plain-first"))),
            CountingProvider(name: "configured timed", result: .match(validTimedDocument))
        ])
        let providerQualityOutcome = await providerQualityManager.search(track: liveTrack, identity: liveIdentity)
        guard case .match(let providerQualityDocument) = providerQualityOutcome.result else {
            preconditionFailure("equivalent trusted provider documents should auto-select")
        }
        require(
            providerQualityDocument.providerSourceID == "timed-provider",
            "valid word timing wins equivalent provider matches while equal-quality ties retain configured order"
        )

        let liveVariant = candidate("timed-live", lines: [validTimedLine], title: liveTrack.title + " - Live")
        let correctRecording = candidate("plain-original", lines: [plainLine])
        let recordingProvider = CountingProvider(
            name: "recording identity fixture",
            result: .candidates([liveVariant, correctRecording])
        )
        let recordingOutcome = await LyricsSearchManager(providers: [recordingProvider]).search(
            track: liveTrack,
            identity: liveIdentity
        )
        guard case .match(let recordingDocument) = recordingOutcome.result else {
            preconditionFailure("matching recording candidate should remain eligible")
        }
        require(
            recordingDocument.title == liveTrack.title,
            "richer timing must not make a live recording replace the exact recording"
        )

        let cancellationManager = LyricsSearchManager(providers: [
            DelayedProvider(name: "cancellable", delay: 1, result: .noMatch)
        ])
        let cancelledTask = Task {
            await cancellationManager.lookup(track: liveTrack, identity: liveIdentity)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        cancelledTask.cancel()
        if case .failed(.cancelled) = await cancelledTask.value {} else {
            preconditionFailure("cancelled search must return cancelled")
        }

        let versionPlan = LyricsQueryPlanner.plan(for: liveMetadata)
        require(
            versionPlan.contains {
                $0.queryKind == .normalizedVersionTitleFullArtist
                    && $0.titleQuery == "春を告げる"
                    && $0.artistQuery == "yama"
            },
            "version-stripped query must preserve the full artist"
        )
        let multiVersionTrack = Track(
            title: "Forever - Live",
            artist: "VILLSHANA, Mahiru",
            album: "KILL is LOVE",
            duration: 169
        )
        let multiVersionPlan = LyricsQueryPlanner.plan(
            for: TrackMetadata.bootstrap(from: multiVersionTrack)
        )
        require(
            multiVersionPlan.contains { $0.queryKind == .normalizedVersionTitlePrimaryArtist },
            "version-stripped primary-artist fallback"
        )

        let manualPlan = LyricsQueryPlanner.plan(
            for: liveMetadata,
            manualQuery: "Haru wo Tsugeru yama"
        )
        require(manualPlan.first?.queryKind == .manualOverride, "manual query must run first")
        require(manualPlan.first?.titleQuery == "Haru wo Tsugeru yama", "manual query is preserved")

        let aliasMetadata = TrackMetadata(
            identity: liveMetadata.identity,
            track: liveMetadata.track,
            aliases: liveMetadata.aliases + [
                TrackAlias(
                    id: "english-title",
                    field: .title,
                    kind: .officialEnglish,
                    value: "Spring Is Coming",
                    language: "en",
                    script: .latin,
                    source: .spotifyMetadata,
                    confidence: 1,
                    isOfficial: true
                )
            ],
            versionTags: liveMetadata.versionTags
        )
        require(
            LyricsQueryPlanner.plan(for: aliasMetadata).contains { $0.queryKind == .officialEnglishAlias },
            "persisted official alias must be queryable"
        )

        let candidateTrack = Track(
            title: "Forever",
            artist: "VILLSHANA, Mahiru",
            album: "KILL is LOVE",
            duration: 169,
            spotifyId: "forever-id"
        )
        let candidateIdentity = TrackIdentity(track: candidateTrack)
        let featuredCandidate = LyricsCandidate(
            id: "netease:42",
            identity: candidateIdentity,
            title: "Forever",
            artist: "VILLSHANA",
            album: candidateTrack.album,
            duration: candidateTrack.duration,
            lines: [LyricLine(timestamp: 0, originalText: "Forever")],
            source: .neteaseExperimental,
            confidence: 0.8,
            providerSourceID: "42"
        )
        let candidateProvider = CountingProvider(name: "网易云实验源", result: .candidates([featuredCandidate]))
        let candidateManager = LyricsSearchManager(providers: [candidateProvider])
        let candidateOutcome = await candidateManager.search(track: candidateTrack, identity: candidateIdentity)
        guard case .candidates(let candidates) = candidateOutcome.result,
              let enriched = candidates.first else {
            preconditionFailure("expected a user-selectable candidate")
        }
        require(enriched.providerName == "网易云实验源", "candidate provider explanation")
        require(enriched.queryKind != nil, "candidate query method explanation")
        require(!enriched.matchExplanation.isEmpty, "candidate match explanation")
        require(enriched.matchExplanation.contains { $0.contains("titleExact") }, "title evidence explanation")
        require(enriched.matchExplanation.contains { $0.contains("primaryArtistExact") }, "artist evidence explanation")
        require(enriched.matchScore != nil, "safe matcher score explanation")

        let noMatchProvider = CountingProvider(name: "LRCLIB", result: .noMatch)
        let noMatchManager = LyricsSearchManager(providers: [noMatchProvider])
        let first = await noMatchManager.search(track: liveTrack, identity: TrackIdentity(track: liveTrack))
        let callsAfterFirst = noMatchProvider.callCount()
        let second = await noMatchManager.search(track: liveTrack, identity: TrackIdentity(track: liveTrack))
        let callsAfterSecond = noMatchProvider.callCount()
        require(callsAfterFirst > 0, "no-match search should query a provider")
        require(callsAfterSecond == callsAfterFirst, "short negative cache should avoid duplicate automatic requests")
        if case .noMatch = first.result {} else { preconditionFailure("first result should be noMatch") }
        if case .noMatch = second.result {} else { preconditionFailure("cached result should remain noMatch") }

        let mixedFailureManager = LyricsSearchManager(providers: [
            FallbackProvider(name: "本地歌词", result: .noMatch),
            FallbackProvider(name: "LRCLIB", result: .failed(.networkUnavailable))
        ])
        let mixedFailure = await mixedFailureManager.search(
            track: liveTrack,
            identity: TrackIdentity(track: liveTrack)
        )
        if case .failed(.networkUnavailable) = mixedFailure.result {} else {
            preconditionFailure("network failure must not be disguised as noMatch")
        }

        _ = await noMatchManager.search(
            track: liveTrack,
            identity: TrackIdentity(track: liveTrack),
            forceRefresh: true
        )
        require(noMatchProvider.callCount() > callsAfterSecond, "explicit retry must bypass negative cache")

        let fallbackDocument = LyricsDocument(
            identity: TrackIdentity(track: liveTrack),
            title: liveTrack.title,
            artist: liveTrack.artist,
            album: liveTrack.album,
            duration: liveTrack.duration,
            lines: [LyricLine(timestamp: 0, originalText: "fallback")],
            isSynchronized: false,
            source: .qqExperimental,
            confidence: 0.95,
            providerSourceID: "qq:42",
            spotifyTrackID: liveTrack.spotifyId
        )
        let fallbackManager = LyricsSearchManager(providers: [
            FallbackProvider(name: "LRCLIB", result: .failed(.networkUnavailable)),
            FallbackProvider(name: "QQ 音乐实验源", result: .match(fallbackDocument))
        ])
        let fallback = await fallbackManager.search(track: liveTrack, identity: TrackIdentity(track: liveTrack))
        guard case .match(let adopted) = fallback.result else {
            preconditionFailure("provider failure must fall through to the next provider")
        }
        require(adopted.source == .qqExperimental, "fallback source adopted")

        print("phase 2.11A retrieval contract passed")
    }
}
