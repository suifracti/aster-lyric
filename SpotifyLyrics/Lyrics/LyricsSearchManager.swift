import Foundation

/// Multi-variant lyrics search: local first, then bounded parallel online probes per variant.
/// Applies SafeMatcher and does not auto-adopt conflicting versions.
public final class LyricsSearchManager: @unchecked Sendable {
    public let name: String
    private let providersLock = NSLock()
    private let negativeCacheLock = NSLock()
    private var providers: [LyricsProvider]
    private var negativeCache: [String: NegativeCacheEntry] = [:]
    private let negativeCacheLifetime: TimeInterval
    private let spotifyArtistResolver: SpotifyTrackArtistResolver?

    private struct NegativeCacheEntry {
        let result: NegativeResult
        let expiresAt: Date
    }

    private enum NegativeResult {
        case noLyrics
        case noMatch

        var lookupResult: LyricsLookupResult {
            switch self {
            case .noLyrics: return .noLyrics
            case .noMatch: return .noMatch
            }
        }
    }

    private struct IndexedProvider: Sendable {
        let index: Int
        let provider: any LyricsProvider
    }

    private struct ProviderProbeResult: Sendable {
        let index: Int
        let provider: any LyricsProvider
        let result: LyricsLookupResult
        let duration: TimeInterval
    }

    private struct AutomaticAdoption {
        let document: LyricsDocument
        let decision: LyricsMatchDecision
        let timingPriority: Int
        let providerIndex: Int
        let candidateIndex: Int
        let providerName: String
        let cameFromCandidates: Bool
    }

    private struct EvaluatedCandidate {
        let candidate: LyricsCandidate
        let document: LyricsDocument
        let decision: LyricsMatchDecision
        let providerIndex: Int
        let candidateIndex: Int
        let providerName: String
        let cameFromCandidates: Bool
    }

    public init(
        providers: [LyricsProvider],
        name: String = "Lyrics Search",
        negativeCacheLifetime: TimeInterval = 45,
        spotifyArtistResolver: SpotifyTrackArtistResolver? = nil
    ) {
        self.providers = providers
        self.name = name
        self.negativeCacheLifetime = max(1, negativeCacheLifetime)
        self.spotifyArtistResolver = spotifyArtistResolver
    }

    /// Replaces the runtime provider order without exposing provider objects
    /// to SwiftUI. The active session cancels its in-flight request before
    /// calling this method, so a disabled provider cannot receive a new probe.
    public func updateProviders(_ providers: [LyricsProvider]) {
        providersLock.lock()
        self.providers = providers
        providersLock.unlock()
        clearNegativeCache()
        LyricsE2ELog.log("MANAGER providers updated=" + providers.map { $0.name }.joined(separator: ","))
    }

    public func providerNames() -> [String] {
        providerSnapshot().map(\.name)
    }

    private func providerSnapshot() -> [LyricsProvider] {
        providersLock.lock()
        defer { providersLock.unlock() }
        return providers
    }

    private static func probe(
        _ indexedProvider: IndexedProvider,
        track: Track,
        identity: TrackIdentity
    ) async -> ProviderProbeResult {
        let started = Date()
        LyricsE2ELog.log("PROBE start provider=\(indexedProvider.provider.name) queryTitle=\(track.title) queryArtist=\(track.artist)")
        let result = await lookupWithTimeout(
            provider: indexedProvider.provider,
            track: track,
            identity: identity
        )
        LyricsE2ELog.log("PROBE finish provider=\(indexedProvider.provider.name) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))s cancelled=\(Task.isCancelled) outcome=\(probeOutcome(result))")
        return ProviderProbeResult(
            index: indexedProvider.index,
            provider: indexedProvider.provider,
            result: result,
            duration: Date().timeIntervalSince(started)
        )
    }

    private static func probeOutcome(_ result: LyricsLookupResult) -> String {
        switch result {
        case .match: return "match"
        case .candidates(let list): return "candidates(\(list.count))"
        case .noMatch: return "noMatch"
        case .noLyrics: return "noLyrics"
        case .failed(.serverError(let code)): return "http(\(code))"
        case .failed(.timedOut): return "timedOut"
        case .failed(.networkUnavailable): return "networkUnavailable"
        case .failed(.cancelled): return "cancelled"
        case .failed: return "failure"
        }
    }

    private static func probeNetworkProviders(
        track: Track,
        identity: TrackIdentity,
        providers: [IndexedProvider],
        metadata: TrackMetadata,
        variant: LyricsQueryVariant,
        collectCandidatesOnly: Bool = false,
        onProvisional: (@Sendable (LyricsDocument) async -> Void)? = nil,
        onCandidates: (@Sendable ([LyricsCandidate]) async -> Void)? = nil
    ) async -> [ProviderProbeResult] {
        await withTaskGroup(of: ProviderProbeResult.self) { group in
            var next = 0
            var settled = false
            func enqueueNext() {
                guard !settled, !Task.isCancelled, next < providers.count else { return }
                let indexedProvider = providers[next]
                next += 1
                group.addTask {
                    await probe(indexedProvider, track: track, identity: identity)
                }
            }
            for _ in 0..<min(3, providers.count) { enqueueNext() }
            var results: [ProviderProbeResult] = []
            for await result in group {
                if !settled {
                    results.append(result)
                    // A safely identified original can appear while preceding
                    // sources settle. Final ranking/persistence still occurs
                    // after the bounded group; no candidate confirmation needed.
                    if !collectCandidatesOnly, !Task.isCancelled, let document = automaticProvisionalDocument(result, metadata: metadata, variant: variant) {
                        await onProvisional?(document)
                    }
                    if !Task.isCancelled {
                        let previews = safePreviewCandidates(result, metadata: metadata, variant: variant)
                        if !previews.isEmpty { await onCandidates?(previews) }
                    }
                }
                if Task.isCancelled { group.cancelAll() }
                else if !collectCandidatesOnly, !settled, let ready = results.filter({ hasAutomaticResult($0, metadata: metadata, variant: variant) }).min(by: { $0.index < $1.index }),
                        providers.filter({ $0.index < ready.index }).allSatisfy({ prior in results.contains { $0.index == prior.index } }) {
                    // Once an eligible result and its preceding providers have
                    // resolved, unrelated lower-priority network work cannot
                    // keep the listening UI blocked until its own timeout.
                    settled = true
                    group.cancelAll()
                } else { enqueueNext() }
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    /// Uses the same decision/enrichment as final acceptance. Publishing a
    /// preview never adopts it or upgrades incompatible recording timestamps.
    private static func safePreviewCandidates(_ probe: ProviderProbeResult, metadata: TrackMetadata, variant: LyricsQueryVariant) -> [LyricsCandidate] {
        let list: [LyricsCandidate]
        switch probe.result {
        case .candidates(let candidates): list = candidates
        case .match(let document):
            let candidateID = document.providerSourceID.map { "\(probe.provider.name):document:\($0)" }
                ?? "\(probe.provider.name):document:\(document.title ?? variant.titleQuery)"
            list = [LyricsCandidate(id: candidateID, identity: document.identity,
                title: document.title ?? metadata.track.title, artist: document.artist ?? metadata.track.artist,
                album: document.album ?? metadata.track.album, duration: document.duration ?? metadata.track.duration,
                lines: document.lines, isSynchronized: document.isSynchronized, source: document.source,
                confidence: document.confidence, providerSourceID: document.providerSourceID,
                spotifyTrackID: document.spotifyTrackID, isrc: document.isrc, language: document.language,
                explicitlyTimedLineIndices: document.explicitlyTimedLineIndices)]
        default: return []
        }
        var accepted: [String: LyricsCandidate] = [:]
        for item in list where item.identity == metadata.identity {
            let decision = LyricsSafeMatcher.decide(candidate: item, metadata: metadata,
                aliasUsed: metadata.aliases.first { $0.id == variant.aliasIDs.first }, queryVariant: variant)
            if decision.tier != .reject {
                acceptCandidate(item, provider: probe.provider.name, variant: variant, decision: decision, into: &accepted)
            }
        }
        return accepted.values.sorted(by: LyricsCandidate.hasPrecedence)
    }

    private static func hasAutomaticResult(_ probe: ProviderProbeResult, metadata: TrackMetadata, variant: LyricsQueryVariant) -> Bool {
        let candidates: [LyricsCandidate]
        switch probe.result {
        case .candidates(let list): candidates = list
        case .match(let d):
            candidates = [LyricsCandidate(id: "probe", identity: d.identity,
                title: d.title ?? metadata.track.title, artist: d.artist ?? metadata.track.artist,
                album: d.album ?? metadata.track.album, duration: d.duration ?? metadata.track.duration,
                lines: d.lines, isSynchronized: d.isSynchronized, source: d.source,
                confidence: d.confidence, providerSourceID: d.providerSourceID,
                spotifyTrackID: d.spotifyTrackID, isrc: d.isrc, language: d.language)]
        default: return false
        }
        return candidates.contains { candidate in
            guard candidate.identity == metadata.identity, candidate.isSynchronized else { return false }
            let decision = LyricsSafeMatcher.decide(candidate: candidate, metadata: metadata, aliasUsed: metadata.aliases.first { $0.id == variant.aliasIDs.first }, queryVariant: variant)
            return decision.tier == .autoHigh || decision.tier == .autoMedium
        }
    }

    private static func automaticProvisionalDocument(_ probe: ProviderProbeResult, metadata: TrackMetadata, variant: LyricsQueryVariant) -> LyricsDocument? {
        let list: [LyricsCandidate]
        switch probe.result {
        case .candidates(let candidates): list = candidates
        case .match(let d): list = [LyricsCandidate(id: "plain", identity: d.identity, title: d.title ?? "", artist: d.artist ?? "", album: d.album ?? "", duration: d.duration ?? 0, lines: d.lines, isSynchronized: d.isSynchronized, source: d.source, confidence: d.confidence, spotifyTrackID: d.spotifyTrackID, isrc: d.isrc)]
        default: return nil
        }
        return list.first(where: { candidate in
            guard candidate.identity == metadata.identity, !candidate.requiresTextOnlyPreview else { return false }
            if candidate.isSynchronized && timingPriority(of: candidate) == 0 { return false }
            let decision = LyricsSafeMatcher.decide(candidate: candidate, metadata: metadata, aliasUsed: metadata.aliases.first { $0.id == variant.aliasIDs.first }, queryVariant: variant)
            return decision.tier == .autoHigh || decision.tier == .autoMedium
        }).map { finalizeDocument($0.makeDocument(), identity: metadata.identity) }
    }

    private static func lookupWithTimeout(
        provider: any LyricsProvider,
        track: Track,
        identity: TrackIdentity
    ) async -> LyricsLookupResult {
        await withTaskGroup(of: LyricsLookupResult.self) { group in
            group.addTask {
                await provider.lookup(track: track, identity: identity)
            }
            group.addTask {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0.01, provider.timeoutInterval) * 1_000_000_000)
                    )
                    return .failed(.timedOut)
                } catch {
                    return .failed(.cancelled)
                }
            }

            guard let first = await group.next() else {
                return .failed(.unknown("歌词 Provider 未返回结果"))
            }
            group.cancelAll()
            if Task.isCancelled {
                return .failed(.cancelled)
            }
            return first
        }
    }

    public func lookup(
        track: Track,
        identity: TrackIdentity,
        queryOverride: String? = nil,
        forceRefresh: Bool = false,
        aliases: [TrackAlias] = []
    ) async -> LyricsLookupResult {
        let outcome = await search(
            track: track,
            identity: identity,
            queryOverride: queryOverride,
            forceRefresh: forceRefresh,
            aliases: aliases
        )
        return outcome.result
    }

    public func search(
        track: Track,
        identity: TrackIdentity,
        queryOverride: String? = nil,
        forceRefresh: Bool = false,
        aliases: [TrackAlias] = [],
        collectCandidatesOnly: Bool = false,
        onProvisional: (@Sendable (LyricsDocument) async -> Void)? = nil,
        onCandidates: (@Sendable ([LyricsCandidate]) async -> Void)? = nil
    ) async -> SearchOutcome {
        if Task.isCancelled {
            return SearchOutcome(result: .failed(.cancelled), diagnostics: [])
        }
        let started = Date()
        let searchID = String(UUID().uuidString.prefix(8))
        defer { LyricsE2ELog.log("SEARCH end id=\(searchID) total=\(String(format: "%.3f", Date().timeIntervalSince(started)))s cancelled=\(Task.isCancelled)") }
        let metadata = TrackMetadata.bootstrap(from: track)
        let mergedAliases = Self.mergeAliases(metadata.aliases, aliases)
        // Keep identity stable with caller-supplied identity (playback).
        var meta = TrackMetadata(
            identity: identity,
            track: track,
            aliases: mergedAliases,
            versionTags: metadata.versionTags
        )
        let variants = LyricsQueryPlanner.plan(for: meta, manualQuery: queryOverride)
        let cacheKey = Self.negativeCacheKey(
            identity: identity,
            queryOverride: queryOverride
        )
        if forceRefresh {
            removeNegativeCache(for: cacheKey)
        } else if let cached = cachedNegativeResult(for: cacheKey) {
            LyricsE2ELog.log("MANAGER negative-cache hit identity=\(identity.stableKey) result=\(cached)")
            return SearchOutcome(result: cached.lookupResult, diagnostics: [])
        }
        let configuredProviders = providerSnapshot()
        LyricsE2ELog.log("MANAGER start title=\(track.title) artist=\(track.artist) variants=\(variants.count) providers=\(configuredProviders.map { $0.name }) queryOverride=\(queryOverride ?? "")")
        var diagnostics: [LyricsProviderDiagnostic] = []
        var acceptedCandidates: [String: LyricsCandidate] = [:]
        var rejectedForExplanation: [EvaluatedCandidate] = []
        var sawNoLyrics = false
        var sawNoMatch = false
        var firstFailure: LyricsFailure?
        // Only this search: next user/recovery search gets a fresh probe.
        var unavailableProviders: Set<Int> = []
        var probeCache: [String: [ProviderProbeResult]] = [:]
        var attemptedArtistEnrichment = false

        func alias(for variant: LyricsQueryVariant) -> TrackAlias? {
            guard let id = variant.aliasIDs.first else { return nil }
            return meta.aliases.first { $0.id == id }
        }

        for variant in variants {
            if Task.isCancelled {
                return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics)
            }

            let probeTrack = Track(
                id: track.id,
                title: variant.titleQuery,
                // A nil artist is deliberate for broad/manual recovery.
                // Keep original identity separately for SafeMatcher below.
                artist: variant.artistQuery ?? "",
                album: track.album,
                duration: track.duration,
                artworkName: track.artworkName,
                isrc: track.isrc,
                spotifyId: track.spotifyId,
                artworkURL: track.artworkURL,
                spotifyURL: track.spotifyURL
            )

            let indexedProviders = configuredProviders.enumerated().map {
                IndexedProvider(index: $0.offset, provider: $0.element)
            }
            let localProviders = indexedProviders.filter { $0.provider.executionLane == .local }
            let networkProviders = indexedProviders.filter { $0.provider.executionLane == .network }
            var localCursor = 0
            var didProbeNetwork = false
            var automaticAdoptions: [AutomaticAdoption] = []
            var evaluatedCandidates: [EvaluatedCandidate] = []

            while localCursor < localProviders.count || !didProbeNetwork {
                if Task.isCancelled {
                    return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics)
                }

                let probeResults: [ProviderProbeResult]
                if localCursor < localProviders.count {
                    probeResults = [await Self.probe(
                        localProviders[localCursor],
                        track: probeTrack,
                        identity: identity
                    )]
                    localCursor += 1
                } else {
                    didProbeNetwork = true
                    let queryKey = probeTrack.title + "\u{1F}" + probeTrack.artist
                    if let reused = probeCache[queryKey] {
                        probeResults = reused.map { ProviderProbeResult(index: $0.index, provider: $0.provider, result: $0.result, duration: 0) }
                        LyricsE2ELog.log("SEARCH reuse id=\(searchID) rank=\(variant.rank) providerCount=\(reused.count)")
                    } else {
                        let enabled = networkProviders.filter { !unavailableProviders.contains($0.index) }
                        probeResults = await Self.probeNetworkProviders(
                            track: probeTrack, identity: identity, providers: enabled,
                            metadata: meta, variant: variant, collectCandidatesOnly: collectCandidatesOnly,
                            onProvisional: onProvisional,
                            onCandidates: { candidates in
                                LyricsE2ELog.log("SEARCH preview id=\(searchID) rank=\(variant.rank) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))s count=\(candidates.count)")
                                await onCandidates?(candidates)
                            }
                        )
                        probeCache[queryKey] = probeResults
                        for probe in probeResults {
                            if case .failed(let failure) = probe.result {
                                switch failure {
                                case .serverError(let code) where (500...599).contains(code): unavailableProviders.insert(probe.index)
                                case .timedOut, .networkUnavailable: unavailableProviders.insert(probe.index)
                                default: break
                                }
                            }
                        }
                        if enabled.count < networkProviders.count {
                            LyricsE2ELog.log("SEARCH skip-unavailable id=\(searchID) rank=\(variant.rank) count=\(networkProviders.count - enabled.count)")
                        }
                    }
                }

                for probe in probeResults {
                    guard !Task.isCancelled else {
                        return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics)
                    }
                    let provider = probe.provider
                    let result = probe.result
                    let elapsed = probe.duration

                    switch result {
                case .match(let document):
                    guard document.identity == identity else {
                        diagnostics.append(
                            LyricsProviderDiagnostic(
                                provider: "\(provider.name)@\(variant.strategy.rawValue)",
                                outcome: .failed(.unknown("歌词身份不一致")),
                                duration: elapsed
                            )
                        )
                        continue
                    }

                    let candidateID = document.providerSourceID.map {
                        "\(provider.name):document:\($0)"
                    } ?? "\(provider.name):document:\(document.title ?? probeTrack.title)"
                    let candidate = LyricsCandidate(
                        id: candidateID,
                        identity: identity,
                        title: document.title ?? probeTrack.title,
                        artist: document.artist ?? probeTrack.artist,
                        album: document.album ?? track.album,
                        duration: document.duration ?? track.duration,
                        lines: document.lines,
                        isSynchronized: document.isSynchronized,
                        source: document.source,
                        confidence: document.confidence,
                        providerSourceID: document.providerSourceID,
                        spotifyTrackID: document.spotifyTrackID,
                        isrc: document.isrc,
                        language: document.language,
                        explicitlyTimedLineIndices: document.explicitlyTimedLineIndices
                    )
                    let decision = LyricsSafeMatcher.decide(
                        candidate: candidate,
                        metadata: meta,
                        aliasUsed: alias(for: variant),
                        queryVariant: variant
                    )
                    evaluatedCandidates.append(EvaluatedCandidate(candidate: candidate, document: document,
                        decision: decision, providerIndex: probe.index, candidateIndex: 0,
                        providerName: provider.name, cameFromCandidates: false))
                    diagnostics.append(
                        LyricsProviderDiagnostic(
                            provider: "\(provider.name)@\(variant.strategy.rawValue)",
                            outcome: .match,
                            duration: elapsed,
                            matchDecisions: [decision]
                        )
                    )

                    if decision.tier == .autoHigh || decision.tier == .autoMedium {
                        automaticAdoptions.append(AutomaticAdoption(
                            document: document,
                            decision: decision,
                            timingPriority: Self.timingPriority(of: candidate),
                            providerIndex: probe.index,
                            candidateIndex: 0,
                            providerName: provider.name,
                            cameFromCandidates: false
                        ))
                    }
                    if decision.tier != .reject {
                        Self.acceptCandidate(
                            candidate,
                            provider: provider.name,
                            variant: variant,
                            decision: decision,
                            into: &acceptedCandidates
                        )
                    }
                    // reject → ignore

                case .candidates(let list):
                    var candidateDecisions: [LyricsMatchDecision] = []
                    for (candidateIndex, item) in list.enumerated() where item.identity == identity {
                        let decision = LyricsSafeMatcher.decide(
                            candidate: item,
                            metadata: meta,
                            aliasUsed: alias(for: variant),
                            queryVariant: variant
                        )
                        evaluatedCandidates.append(EvaluatedCandidate(candidate: item, document: item.makeDocument(),
                            decision: decision, providerIndex: probe.index, candidateIndex: candidateIndex,
                            providerName: provider.name, cameFromCandidates: true))
                        candidateDecisions.append(decision)
                        LyricsE2ELog.log("MATCH provider=\(provider.name) rank=\(variant.rank) sourceID=\(item.providerSourceID ?? item.id) title=\(item.title) artist=\(item.artist) duration=\(item.duration) tier=\(decision.tier.rawValue) evidence=\(decision.explanation.joined(separator: ";"))")
                        if decision.tier == .autoHigh || decision.tier == .autoMedium {
                            automaticAdoptions.append(AutomaticAdoption(
                                document: item.makeDocument(),
                                decision: decision,
                                timingPriority: Self.timingPriority(of: item),
                                providerIndex: probe.index,
                                candidateIndex: candidateIndex,
                                providerName: provider.name,
                                cameFromCandidates: true
                            ))
                        }
                        if decision.tier != .reject {
                            Self.acceptCandidate(
                                item,
                                provider: provider.name,
                                variant: variant,
                                decision: decision,
                                into: &acceptedCandidates
                            )
                        }
                    }
                    diagnostics.append(
                        LyricsProviderDiagnostic(
                            provider: "\(provider.name)@\(variant.strategy.rawValue)",
                            outcome: .candidates(list.count),
                            duration: elapsed,
                            matchDecisions: candidateDecisions
                        )
                    )

                case .noLyrics:
                    sawNoLyrics = true
                    diagnostics.append(
                        LyricsProviderDiagnostic(
                            provider: "\(provider.name)@\(variant.strategy.rawValue)",
                            outcome: .noLyrics,
                            duration: elapsed
                        )
                    )

                case .noMatch:
                    sawNoMatch = true
                    diagnostics.append(
                        LyricsProviderDiagnostic(
                            provider: "\(provider.name)@\(variant.strategy.rawValue)",
                            outcome: .noMatch,
                            duration: elapsed
                        )
                    )

                case .failed(let failure):
                    if failure == .cancelled {
                        return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics)
                    }
                    if firstFailure == nil {
                        firstFailure = failure
                    }
                    diagnostics.append(
                        LyricsProviderDiagnostic(
                            provider: "\(provider.name)@\(variant.strategy.rawValue)",
                            outcome: .failed(failure),
                            duration: elapsed
                        )
                    )
                    // Isolate: continue other providers/variants
                    }
                }

            }

            // Desktop can expose only the primary artist. Consult the exact
            // official recording only when that omission blocks an otherwise
            // matching candidate; reuse these results without another lyric request.
            if (queryOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               automaticAdoptions.isEmpty, !attemptedArtistEnrichment, let spotifyArtistResolver,
               variant.queryKind != .manualOverride, variant.queryKind != .titleOnlyLoose,
               evaluatedCandidates.contains(where: {
                   !$0.decision.hardReject && !$0.decision.versionConflict
                       && ($0.decision.reasons.contains("extraFeaturedArtist")
                           || $0.decision.reasons.contains("missingFeaturedArtist")
                           || $0.decision.reasons.contains("featuredNameUnverified")
                           || $0.decision.reasons.contains("titleFeaturedBaseExact"))
                       && ($0.decision.reasons.contains("primaryArtistExact") || $0.decision.reasons.contains("primaryArtistAlias"))
                       && ($0.decision.reasons.contains("titleExact")
                           || $0.decision.reasons.contains("titleTypographyExact")
                           || $0.decision.reasons.contains("titleParallelExact")
                           || $0.decision.reasons.contains("titleLatinSpacingExact")
                           || $0.decision.reasons.contains("titleFeaturedBaseExact")
                           || $0.decision.reasons.contains("titleProviderAliasConfirmed")
                           || $0.decision.reasons.contains("titleAliasConfirmed")
                           || $0.decision.reasons.contains("titleReadingExact"))
               }) {
                attemptedArtistEnrichment = true
                let enrichmentStarted = Date()
                if let names = await spotifyArtistResolver.artists(for: track), !Task.isCancelled {
                    meta.verifiedSpotifyArtists = names
                    var verifiedDecisions: [LyricsMatchDecision] = []
                    for item in evaluatedCandidates {
                        let decision = LyricsSafeMatcher.decide(candidate: item.candidate, metadata: meta,
                            aliasUsed: alias(for: variant), queryVariant: variant)
                        verifiedDecisions.append(decision)
                        if decision.tier == .reject {
                            acceptedCandidates.removeValue(forKey: item.candidate.id)
                        } else {
                            acceptedCandidates[item.candidate.id] = Self.enrichCandidate(item.candidate,
                                providerName: item.providerName, variant: variant, decision: decision)
                        }
                        if decision.tier == .autoHigh || decision.tier == .autoMedium {
                            automaticAdoptions.append(AutomaticAdoption(document: item.document, decision: decision,
                                timingPriority: Self.timingPriority(of: item.candidate), providerIndex: item.providerIndex,
                                candidateIndex: item.candidateIndex, providerName: item.providerName,
                                cameFromCandidates: item.cameFromCandidates))
                        }
                    }
                    diagnostics.append(LyricsProviderDiagnostic(provider: "Spotify official artist metadata",
                        outcome: .match, duration: Date().timeIntervalSince(enrichmentStarted), matchDecisions: verifiedDecisions))
                    LyricsE2ELog.log("SEARCH official artists verified count=\(names.count) rescored=\(verifiedDecisions.count)")
                }
            }
            // A romanized Desktop name and a localized official name need
            // evidence from the exact Spotify entity, not a lower match score.
            if (queryOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               automaticAdoptions.isEmpty, !attemptedArtistEnrichment, let spotifyArtistResolver,
               variant.queryKind != .manualOverride, variant.queryKind != .titleOnlyLoose,
               evaluatedCandidates.contains(where: {
                   $0.decision.reasons.contains("durationClose")
                       && ($0.decision.reasons.contains("primaryArtistConflict") || $0.decision.reasons.contains("titleMismatch"))
                       && ScriptDetector.detect(track.title + track.artist) != ScriptDetector.detect($0.candidate.title + $0.candidate.artist)
               }) {
                attemptedArtistEnrichment = true
                let officialAliases = await spotifyArtistResolver.aliases(for: track)
                meta.aliases = Self.mergeAliases(meta.aliases, officialAliases)
                for item in evaluatedCandidates where !officialAliases.isEmpty {
                    let decision = LyricsSafeMatcher.decide(candidate: item.candidate, metadata: meta,
                        aliasUsed: alias(for: variant), queryVariant: variant)
                    if decision.tier != .reject {
                        acceptedCandidates[item.candidate.id] = Self.enrichCandidate(item.candidate,
                            providerName: item.providerName, variant: variant, decision: decision)
                    }
                    if decision.tier == .autoHigh || decision.tier == .autoMedium {
                        automaticAdoptions.append(AutomaticAdoption(document: item.document, decision: decision,
                            timingPriority: Self.timingPriority(of: item.candidate), providerIndex: item.providerIndex,
                            candidateIndex: item.candidateIndex, providerName: item.providerName,
                            cameFromCandidates: item.cameFromCandidates))
                    }
                }
            }
            guard !Task.isCancelled else { return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics) }

            rejectedForExplanation.append(contentsOf: evaluatedCandidates.filter { $0.decision.tier == .reject })

            // Explicit version browsing collects all enabled sources for this
            // query, but never turns a trusted result into an active selection.
            // Only use broader fallback queries when this batch found nothing.
            if collectCandidatesOnly, !acceptedCandidates.isEmpty {
                let candidates = acceptedCandidates.values.sorted(by: LyricsCandidate.hasPrecedence)
                return SearchOutcome(result: .candidates(candidates), diagnostics: diagnostics, alternatives: candidates)
            }

            if let selected = Self.bestAutomaticAdoption(in: automaticAdoptions) {
                let enriched = Self.finalizeDocument(selected.document, identity: identity)
                let selectionPath = selected.cameFromCandidates ? "from-candidates" : "provider-result"
                LyricsE2ELog.log("MANAGER AUTO_ADOPT \(selectionPath) provider=\(selected.providerName) strategy=\(variant.strategy.rawValue) kind=\(variant.queryKind.rawValue) tier=\(selected.decision.tier) score=\(selected.decision.score) timingPriority=\(selected.timingPriority) evidence=\(selected.decision.explanation.joined(separator: ";")) lines=\(enriched.lines.count) sync=\(enriched.isSynchronized)")
                return SearchOutcome(result: .match(enriched), diagnostics: diagnostics,
                    alternatives: acceptedCandidates.values.sorted(by: LyricsCandidate.hasPrecedence),
                    automaticDecision: selected.decision)
            }
        }

        if !acceptedCandidates.isEmpty {
            let sorted = acceptedCandidates.values
                .sorted(by: LyricsCandidate.hasPrecedence)
            return SearchOutcome(result: .candidates(sorted), diagnostics: diagnostics)
        }

        let rejected = diagnostics.flatMap(\.matchDecisions).filter { $0.tier == .reject }
        if !rejected.isEmpty {
            var details = Self.identityRejectionDetail(rejectedForExplanation, track: track)
            if let sourceFailures = SearchOutcome.sourceFailureSummary(for: diagnostics) {
                details += (details.isEmpty ? "" : " ") + "部分来源同时失败：" + sourceFailures
            }
            return SearchOutcome(result: .failed(.identityUnconfirmed(rejected.count, details)), diagnostics: diagnostics)
        }
        if firstFailure == nil, sawNoLyrics {
            storeNegativeResult(.noLyrics, for: cacheKey)
            return SearchOutcome(result: .noLyrics, diagnostics: diagnostics)
        }
        if firstFailure == nil, sawNoMatch {
            storeNegativeResult(.noMatch, for: cacheKey)
            return SearchOutcome(result: .noMatch, diagnostics: diagnostics)
        }

        if let firstFailure {
            return SearchOutcome(result: .failed(firstFailure), diagnostics: diagnostics)
        }
        return SearchOutcome(result: .noMatch, diagnostics: diagnostics)
    }

    /// Explain one relevant rejected result without turning it into a selectable candidate.
    private static func identityRejectionDetail(_ evaluated: [EvaluatedCandidate], track: Track) -> String {
        func relevance(_ item: EvaluatedCandidate) -> Int {
            let reasons = item.decision.reasons
            if !item.decision.hardReject, reasons.contains("primaryArtistExact"), reasons.contains("durationClose") { return 2 }
            if reasons.contains("titleExact") || reasons.contains("titleReadingExact") || reasons.contains("titleTypographyExact") { return 1 }
            return 0
        }
        guard let closest = evaluated.filter({ $0.decision.tier == .reject && relevance($0) > 0 }).max(by: {
            if relevance($0) != relevance($1) { return relevance($0) < relevance($1) }
            return $0.decision.score < $1.decision.score
        }) else { return "" }
        let item = closest.candidate
        let reasons = closest.decision.reasons
        var differences: [String] = []
        if reasons.contains("titleMismatch") { differences.append("标题与当前“\(track.title)”不同") }
        if reasons.contains("primaryArtistConflict") || reasons.contains("primaryArtistMissing") {
            differences.append("歌手与当前“\(track.artist)”不符")
        }
        if reasons.contains("durationFar") || reasons.contains("durationQuestionable") {
            differences.append("时长为 \(Int(item.duration.rounded())) 秒，与当前 \(Int(track.duration.rounded())) 秒不符")
        }
        if reasons.contains("spotifyIDConflict") || reasons.contains("isrcConflict") {
            differences.append("来源指向另一首歌曲")
        }
        if differences.isEmpty { differences.append("歌曲信息尚未匹配") }
        return "找到“\(item.title)”（\(item.artist)），但" + differences.joined(separator: "，") + "，未自动采用。"
    }

    public func clearNegativeCache() {
        negativeCacheLock.lock()
        negativeCache.removeAll()
        negativeCacheLock.unlock()
    }

    private static func mergeAliases(_ generated: [TrackAlias], _ stored: [TrackAlias]) -> [TrackAlias] {
        var result: [TrackAlias] = []
        var seen = Set<String>()
        for alias in generated + stored {
            let key = [alias.field.rawValue, alias.kind.rawValue, TrackTextNormalizer.normalize(alias.value)].joined(separator: "\u{1f}")
            guard seen.insert(key).inserted else { continue }
            result.append(alias)
        }
        return result
    }

    private static func negativeCacheKey(identity: TrackIdentity, queryOverride: String?) -> String {
        let query = TrackTextNormalizer.normalize(queryOverride ?? "")
        return identity.stableKey + "|query:" + query
    }

    private func cachedNegativeResult(for key: String) -> NegativeResult? {
        negativeCacheLock.lock()
        defer { negativeCacheLock.unlock() }
        guard let entry = negativeCache[key] else { return nil }
        if entry.expiresAt <= Date() {
            negativeCache.removeValue(forKey: key)
            return nil
        }
        return entry.result
    }

    private func removeNegativeCache(for key: String) {
        negativeCacheLock.lock()
        negativeCache.removeValue(forKey: key)
        negativeCacheLock.unlock()
    }

    private func storeNegativeResult(_ result: NegativeResult, for key: String) {
        negativeCacheLock.lock()
        negativeCache[key] = NegativeCacheEntry(
            result: result,
            expiresAt: Date().addingTimeInterval(negativeCacheLifetime)
        )
        negativeCacheLock.unlock()
    }

    private static func timingPriority(of candidate: LyricsCandidate) -> Int {
        let suppliedSpanLines = candidate.lines.enumerated().filter { _, line in
            !(line.timedSpans?.isEmpty ?? true)
        }
        let hasValidWordTiming = !suppliedSpanLines.isEmpty && suppliedSpanLines.allSatisfy { index, line in
            let lineStartIsMeaningful = candidate.isSynchronized
                || candidate.explicitlyTimedLineIndices?.contains(index) == true
            return line.hasValidTimedSpans(lineStartIsMeaningful: lineStartIsMeaningful)
        }
        if hasValidWordTiming { return 2 }

        let hasValidLineTiming: Bool
        if candidate.isSynchronized {
            hasValidLineTiming = !candidate.lines.isEmpty
                && candidate.lines.allSatisfy { $0.timestamp.isFinite && $0.timestamp >= 0 }
        } else {
            if let indices = candidate.explicitlyTimedLineIndices, !indices.isEmpty {
                hasValidLineTiming = indices.allSatisfy { index in
                    candidate.lines.indices.contains(index)
                        && candidate.lines[index].timestamp.isFinite
                        && candidate.lines[index].timestamp >= 0
                }
            } else {
                hasValidLineTiming = false
            }
        }
        return hasValidLineTiming ? 1 : 0
    }

    private static func bestAutomaticAdoption(in candidates: [AutomaticAdoption]) -> AutomaticAdoption? {
        candidates.max { lhs, rhs in
            // Timing is preferred only among already safely matched recordings.
            if lhs.decision.score != rhs.decision.score {
                return lhs.decision.score < rhs.decision.score
            }
            let lhsTier = automaticTierPriority(lhs.decision.tier)
            let rhsTier = automaticTierPriority(rhs.decision.tier)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            if lhs.timingPriority != rhs.timingPriority {
                return lhs.timingPriority < rhs.timingPriority
            }
            if lhs.providerIndex != rhs.providerIndex {
                return lhs.providerIndex > rhs.providerIndex
            }
            return lhs.candidateIndex > rhs.candidateIndex
        }
    }

    private static func automaticTierPriority(_ tier: LyricsMatchTier) -> Int {
        switch tier {
        case .autoHigh: return 2
        case .autoMedium: return 1
        case .candidates, .reject: return 0
        }
    }

    private static func acceptCandidate(
        _ candidate: LyricsCandidate,
        provider: String,
        variant: LyricsQueryVariant,
        decision: LyricsMatchDecision,
        into storage: inout [String: LyricsCandidate]
    ) {
        let enriched = enrichCandidate(
            candidate,
            providerName: provider,
            variant: variant,
            decision: decision
        )
        guard let existing = storage[enriched.id] else {
            storage[enriched.id] = enriched
            return
        }
        if enriched.displayedConfidence > existing.displayedConfidence {
            storage[enriched.id] = enriched
        }
    }

    /// Enrich layers; preserve originalText; mark unsynced documents clearly.
    private static func finalizeDocument(_ document: LyricsDocument, identity: TrackIdentity) -> LyricsDocument {
        let lines = LyricsLayerEnricher.enrich(lines: document.lines)
        let identified: LyricsDocument
        if document.identity == identity {
            identified = document
        } else {
            identified = LyricsDocument(
                identity: identity,
                title: document.title,
                artist: document.artist,
                album: document.album,
                duration: document.duration,
                lines: document.lines,
                isSynchronized: document.isSynchronized,
                source: document.source,
                confidence: document.confidence,
                providerSourceID: document.providerSourceID,
                spotifyTrackID: document.spotifyTrackID,
                isrc: document.isrc,
                language: document.language,
                explicitlyTimedLineIndices: document.explicitlyTimedLineIndices,
                timingVersionID: document.timingVersionID
            )
        }
        return identified.replacingLines(lines)
    }

    private static func enrichCandidate(
        _ candidate: LyricsCandidate,
        providerName: String? = nil,
        variant: LyricsQueryVariant? = nil,
        decision: LyricsMatchDecision? = nil
    ) -> LyricsCandidate {
        let textOnly = decision?.reasons.contains("spedUpConflict") == true || candidate.requiresTextOnlyPreview
        let safeLines = textOnly ? candidate.lines.map { line in
            var text = line
            text.timestamp = 0
            text.endTime = nil
            text.timedSpans = nil
            return text
        } : candidate.lines
        return LyricsCandidate(
            id: candidate.id,
            identity: candidate.identity,
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            duration: candidate.duration,
            lines: LyricsLayerEnricher.enrich(lines: safeLines),
            isSynchronized: textOnly ? false : candidate.isSynchronized,
            source: candidate.source,
            confidence: candidate.confidence,
            providerSourceID: candidate.providerSourceID,
            spotifyTrackID: candidate.spotifyTrackID,
            isrc: candidate.isrc,
            language: candidate.language,
            explicitlyTimedLineIndices: textOnly ? nil : candidate.explicitlyTimedLineIndices,
            providerName: providerName ?? candidate.providerName,
            queryKind: variant?.queryKind.rawValue ?? candidate.queryKind,
            queryTitle: variant?.titleQuery ?? candidate.queryTitle,
            queryArtist: variant?.artistQuery ?? candidate.queryArtist,
            matchScore: decision?.score ?? candidate.matchScore,
            matchExplanation: decision?.explanation ?? candidate.matchExplanation,
            declaredTitleAliases: candidate.declaredTitleAliases
        )
    }
}

public struct SearchOutcome {
    public let result: LyricsLookupResult
    public let diagnostics: [LyricsProviderDiagnostic]
    public let alternatives: [LyricsCandidate]
    public let automaticDecision: LyricsMatchDecision?

    public var sourceFailureSummary: String? { Self.sourceFailureSummary(for: diagnostics) }

    static func sourceFailureSummary(for diagnostics: [LyricsProviderDiagnostic]) -> String? {
        var seen = Set<String>()
        let failures = diagnostics.compactMap { diagnostic -> String? in
            guard case .failed(let failure) = diagnostic.outcome, failure != .cancelled else { return nil }
            let provider = diagnostic.provider.components(separatedBy: "@").first ?? diagnostic.provider
            let label = provider + "：" + failure.userFacingMessage
            return seen.insert(label).inserted ? label : nil
        }
        return failures.isEmpty ? nil : failures.joined(separator: "；")
    }

    public init(result: LyricsLookupResult, diagnostics: [LyricsProviderDiagnostic], alternatives: [LyricsCandidate] = [], automaticDecision: LyricsMatchDecision? = nil) {
        self.result = result
        self.diagnostics = diagnostics
        self.alternatives = alternatives
        self.automaticDecision = automaticDecision
    }
}

public struct LyricsProviderDiagnostic: Equatable {
    public enum Outcome: Equatable {
        case match
        case candidates(Int)
        case noLyrics
        case noMatch
        case failed(LyricsFailure)
    }

    public let provider: String
    public let outcome: Outcome
    public let duration: TimeInterval
    public let matchDecisions: [LyricsMatchDecision]

    public init(
        provider: String,
        outcome: Outcome,
        duration: TimeInterval,
        matchDecisions: [LyricsMatchDecision] = []
    ) {
        self.provider = provider
        self.outcome = outcome
        self.duration = duration
        self.matchDecisions = matchDecisions
    }
}
