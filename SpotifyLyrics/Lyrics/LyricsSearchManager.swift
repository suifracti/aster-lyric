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

    /// A task group waits for cancelled children before returning. A provider
    /// awaiting shared catalog work may not finish until that HTTP request ends,
    /// so race the result without making the search wait for its cleanup.
    private final class ProviderLookupRace: @unchecked Sendable {
        private let lock = NSLock()
        private var result: LyricsLookupResult?
        private var continuation: CheckedContinuation<LyricsLookupResult, Never>?
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<LyricsLookupResult, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func start(timeout: TimeInterval, lookup: @escaping @Sendable () async -> LyricsLookupResult) {
            lock.lock()
            defer { lock.unlock() }
            guard result == nil else { return }
            tasks = [
                Task {
                    guard !Task.isCancelled else { return }
                    finish(await lookup())
                },
                Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
                        finish(.failed(.timedOut))
                    } catch { /* The winning result already cancelled this timer. */ }
                }
            ]
        }

        func finish(_ result: LyricsLookupResult) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            let tasks = self.tasks
            self.tasks = []
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation?.resume(returning: result)
        }
    }

    private struct AutomaticAdoption {
        let document: LyricsDocument
        let decision: LyricsMatchDecision
        let timingPriority: Int
        let providerIndex: Int
        let candidateIndex: Int
        let providerName: String
        let cameFromCandidates: Bool
        /// Set when several sources independently agree on one recording whose
        /// length differs from Spotify's own duration.
        let agreement: LyricsAutomaticSelection?
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

    private enum ProbeEvent: Sendable {
        case result(ProviderProbeResult)
        case graceTick
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
        await withTaskGroup(of: ProbeEvent.self) { group in
            var next = 0
            var settled = false
            var graceStarted = false
            var results: [ProviderProbeResult] = []
            func enqueueNext() {
                guard !settled, !Task.isCancelled, next < providers.count else { return }
                let indexedProvider = providers[next]
                next += 1
                group.addTask {
                    .result(await probe(indexedProvider, track: track, identity: identity))
                }
            }
            /// A plain-text result may already be adoptable, but a source with
            /// real timestamps is worth a short wait inside the same round.
            func startGrace() {
                guard !graceStarted else { return }
                graceStarted = true
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return .graceTick
                }
            }
            func precedingResolved(_ index: Int) -> Bool {
                providers.filter { $0.index < index }.allSatisfy { prior in
                    results.contains { $0.index == prior.index }
                }
            }
            for _ in 0..<min(3, providers.count) { enqueueNext() }
            for await event in group {
                switch event {
                case .graceTick:
                    guard !settled, !collectCandidatesOnly else { continue }
                    if let plain = results.filter({ hasAutomaticResult($0, metadata: metadata, variant: variant) })
                        .min(by: { $0.index < $1.index }), precedingResolved(plain.index) {
                        settled = true
                        group.cancelAll()
                    }
                case .result(let result):
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
                    else if !collectCandidatesOnly, !settled {
                        let automatic = results.filter {
                            hasAutomaticResult($0, metadata: metadata, variant: variant)
                        }
                        let timed = automatic.filter {
                            hasAutomaticResult($0, metadata: metadata, variant: variant, requiresTiming: true)
                        }
                        if let timedReady = timed.min(by: { $0.index < $1.index }),
                           precedingResolved(timedReady.index) {
                            // Once an eligible timed result and its preceding
                            // providers have resolved, unrelated lower-priority
                            // work cannot keep the listening UI blocked.
                            settled = true
                            group.cancelAll()
                        } else if let plainReady = automatic.min(by: { $0.index < $1.index }),
                                  precedingResolved(plainReady.index) {
                            startGrace()
                            enqueueNext()
                        } else { enqueueNext() }
                    } else { enqueueNext() }
                }
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

    private static func hasAutomaticResult(_ probe: ProviderProbeResult, metadata: TrackMetadata, variant: LyricsQueryVariant, requiresTiming: Bool = false) -> Bool {
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
            guard candidate.identity == metadata.identity,
                  !candidate.requiresTextOnlyPreview,
                  !requiresTiming || timingPriority(of: candidate) > 0,
                  candidate.lines.contains(where: { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
            let decision = LyricsSafeMatcher.decide(candidate: candidate, metadata: metadata, aliasUsed: metadata.aliases.first { $0.id == variant.aliasIDs.first }, queryVariant: variant)
            return decision.tier == .autoHigh || decision.tier == .autoMedium
        }
    }

    private static func automaticProvisionalDocument(_ probe: ProviderProbeResult, metadata: TrackMetadata, variant: LyricsQueryVariant) -> LyricsDocument? {
        let list: [LyricsCandidate]
        switch probe.result {
        case .candidates(let candidates): list = candidates
        case .match(let d): list = [LyricsCandidate(id: "plain", identity: d.identity, title: d.title ?? "", artist: d.artist ?? "", album: d.album ?? "", duration: d.duration ?? 0, lines: d.lines, isSynchronized: d.isSynchronized, source: d.source, confidence: d.confidence, providerSourceID: d.providerSourceID, spotifyTrackID: d.spotifyTrackID, isrc: d.isrc, language: d.language, explicitlyTimedLineIndices: d.explicitlyTimedLineIndices)]
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
        let race = ProviderLookupRace()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                race.start(timeout: provider.timeoutInterval) {
                    await provider.lookup(track: track, identity: identity)
                }
            }
        } onCancel: {
            race.finish(.failed(.cancelled))
        }
        return Task.isCancelled ? .failed(.cancelled) : result
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
        onCandidates: (@Sendable ([LyricsCandidate]) async -> Void)? = nil,
        onlyProviders: Set<String>? = nil
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
        var attemptedSpotifyAliasEnrichment = false
        if collectCandidatesOnly,
           (queryOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let spotifyArtistResolver {
            if let verifiedNames = await spotifyArtistResolver.artists(for: track) {
                meta.verifiedSpotifyArtists = verifiedNames
            }
            let officialAliases = await spotifyArtistResolver.aliases(for: track)
            guard !Task.isCancelled else { return SearchOutcome(result: .failed(.cancelled), diagnostics: []) }
            meta.aliases = Self.mergeAliases(meta.aliases, officialAliases)
            attemptedSpotifyAliasEnrichment = true
        }
        var variants = LyricsQueryPlanner.plan(for: meta, manualQuery: queryOverride)
        let cacheKey = Self.negativeCacheKey(
            identity: identity,
            queryOverride: queryOverride
        )
        if forceRefresh {
            removeNegativeCache(for: cacheKey)
        } else if !collectCandidatesOnly, let cached = cachedNegativeResult(for: cacheKey) {
            LyricsE2ELog.log("MANAGER negative-cache hit identity=\(identity.stableKey) result=\(cached)")
            return SearchOutcome(result: cached.lookupResult, diagnostics: [])
        }
        let configuredProviders = providerSnapshot().filter { onlyProviders?.contains($0.name) ?? true }
        LyricsE2ELog.log("MANAGER start title=\(track.title) artist=\(track.artist) variants=\(variants.count) providers=\(configuredProviders.map { $0.name }) queryOverride=\(queryOverride ?? "")")
        var diagnostics: [LyricsProviderDiagnostic] = []
        var acceptedCandidates: [String: LyricsCandidate] = [:]
        var translationDonors: [String: EvaluatedCandidate] = [:]
        var rejectedForExplanation: [EvaluatedCandidate] = []
        var sawNoLyrics = false
        var sawNoMatch = false
        var firstFailure: LyricsFailure?
        // Only this search: next user/recovery search gets a fresh probe.
        var unavailableProviders: Set<Int> = []
        var probeCache: [String: [ProviderProbeResult]] = [:]
        var queriedVariants = Set(variants.map { $0.titleQuery + "\u{1F}" + ($0.artistQuery ?? "") })

        func alias(for variant: LyricsQueryVariant) -> TrackAlias? {
            guard let id = variant.aliasIDs.first else { return nil }
            return meta.aliases.first { $0.id == id }
        }

        var variantCursor = 0
        while variantCursor < variants.count {
            let variant = variants[variantCursor]
            variantCursor += 1
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
                            cameFromCandidates: false,
                            agreement: nil
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
                                cameFromCandidates: true,
                                agreement: nil
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

            if !collectCandidatesOnly, automaticAdoptions.isEmpty,
               configuredProviders.contains(where: { $0 is LinkCoreLyricsProvider }),
               (queryOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let publisherAliases = await LinkCoreCatalog.shared.cachedAliases(for: track)
                if !publisherAliases.isEmpty {
                    meta.aliases = Self.mergeAliases(meta.aliases, publisherAliases)
                    // At most two extra queries, tied to an independently verified
                    // publisher entity and this track. No generic parenthesis alias.
                    let publisherPlan = LyricsQueryPlanner.plan(for: meta, manualQuery: nil)
                        .filter { plan in plan.aliasIDs.contains { $0.hasPrefix("linkcore-entity:") } }
                        .filter { queriedVariants.insert($0.titleQuery + "\u{1F}" + ($0.artistQuery ?? "")).inserted }
                        .prefix(2)
                    let additions = publisherPlan.enumerated().map { offset, item in
                        LyricsQueryVariant(rank: variantCursor + offset + 1, strategy: item.strategy,
                            queryKind: item.queryKind, titleQuery: item.titleQuery,
                            artistQuery: item.artistQuery, aliasIDs: item.aliasIDs)
                    }
                    variants.insert(contentsOf: additions, at: variantCursor)
                    var rescored: [LyricsMatchDecision] = []
                    for item in evaluatedCandidates {
                        let decision = LyricsSafeMatcher.decide(candidate: item.candidate, metadata: meta,
                            aliasUsed: alias(for: variant), queryVariant: variant)
                        rescored.append(decision)
                        if decision.tier != .reject {
                            acceptedCandidates[item.candidate.id] = Self.enrichCandidate(item.candidate,
                                providerName: item.providerName, variant: variant, decision: decision)
                        }
                        if decision.tier == .autoHigh || decision.tier == .autoMedium {
                            automaticAdoptions.append(AutomaticAdoption(document: item.document, decision: decision,
                                timingPriority: Self.timingPriority(of: item.candidate), providerIndex: item.providerIndex,
                                candidateIndex: item.candidateIndex, providerName: item.providerName,
                                cameFromCandidates: item.cameFromCandidates, agreement: nil))
                        }
                    }
                    diagnostics.append(LyricsProviderDiagnostic(provider: "LinkCore verified artist entity",
                        outcome: .match, duration: 0, matchDecisions: rescored))
                }
            }

            // If the first exact query did not settle automatically, consult
            // Spotify's exact recording even when no source candidate exists.
            // Its title and credited artist spellings both expand bounded,
            // artist-scoped queries; any result still passes SafeMatcher.
            if !collectCandidatesOnly,
               (queryOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               automaticAdoptions.isEmpty, !attemptedSpotifyAliasEnrichment,
               variantCursor == 1, let spotifyArtistResolver {
                attemptedSpotifyAliasEnrichment = true
                let enrichmentStarted = Date()
                if let verifiedNames = await spotifyArtistResolver.artists(for: track) {
                    meta.verifiedSpotifyArtists = verifiedNames
                }
                let officialAliases = await spotifyArtistResolver.aliases(for: track)
                guard !Task.isCancelled else { return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics) }
                if !officialAliases.isEmpty {
                    meta.aliases = Self.mergeAliases(meta.aliases, officialAliases)
                    var officialPlan = LyricsQueryPlanner.plan(for: meta, manualQuery: queryOverride)
                        .filter { variant in
                            variant.aliasIDs.contains { $0.hasPrefix("spotify-entity-") }
                        }
                    officialPlan = officialPlan.filter { queriedVariants.insert($0.titleQuery + "\u{1F}" + ($0.artistQuery ?? "")).inserted }
                        .prefix(7).map { $0 }
                    let additions = officialPlan.enumerated().map { offset, item in
                        LyricsQueryVariant(rank: variantCursor + offset + 1, strategy: item.strategy,
                            queryKind: item.queryKind, titleQuery: item.titleQuery,
                            artistQuery: item.artistQuery, aliasIDs: item.aliasIDs)
                    }
                    variants.insert(contentsOf: additions, at: variantCursor)

                    var verifiedDecisions: [LyricsMatchDecision] = []
                    for item in evaluatedCandidates {
                        let decision = LyricsSafeMatcher.decide(candidate: item.candidate, metadata: meta,
                            aliasUsed: alias(for: variant), queryVariant: variant)
                        verifiedDecisions.append(decision)
                        if decision.tier != .reject {
                            acceptedCandidates[item.candidate.id] = Self.enrichCandidate(item.candidate,
                                providerName: item.providerName, variant: variant, decision: decision)
                        }
                        if decision.tier == .autoHigh || decision.tier == .autoMedium {
                            automaticAdoptions.append(AutomaticAdoption(document: item.document, decision: decision,
                                timingPriority: Self.timingPriority(of: item.candidate), providerIndex: item.providerIndex,
                                candidateIndex: item.candidateIndex, providerName: item.providerName,
                                cameFromCandidates: item.cameFromCandidates, agreement: nil))
                        }
                    }
                    diagnostics.append(LyricsProviderDiagnostic(provider: "Spotify exact-track aliases",
                        outcome: .match, duration: Date().timeIntervalSince(enrichmentStarted), matchDecisions: verifiedDecisions))
                    LyricsE2ELog.log("SEARCH Spotify aliases titleAndArtists=\(officialAliases.count) rescored=\(verifiedDecisions.count) appendedQueries=\(additions.count)")
                }
            }
            guard !Task.isCancelled else { return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics) }

            rejectedForExplanation.append(contentsOf: evaluatedCandidates.filter { $0.decision.tier == .reject })
            for item in evaluatedCandidates where !collectCandidatesOnly && item.candidate.lines.contains(where: {
                !($0.translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                translationDonors["\(item.providerIndex)\u{1F}\(item.candidate.id)"] = item
            }

            // Two or more sources that independently return the same title,
            // artist and near-identical length describe one recording, even
            // when Spotify's own duration is far from it. A single source
            // keeps the existing review path.
            if !collectCandidatesOnly, automaticAdoptions.isEmpty,
               let agreed = Self.agreementAdoption(in: evaluatedCandidates, metadata: meta) {
                automaticAdoptions.append(agreed)
            }

            if !collectCandidatesOnly, let selected = Self.bestAutomaticAdoption(in: automaticAdoptions) {
                var selectedDocument = selected.document
                // Reuse translations that have already arrived. This never
                // starts another query or delays adoption for a slower source.
                let donors = translationDonors.values.sorted {
                    if $0.providerIndex != $1.providerIndex { return $0.providerIndex < $1.providerIndex }
                    if $0.candidateIndex != $1.candidateIndex { return $0.candidateIndex < $1.candidateIndex }
                    return $0.candidate.id < $1.candidate.id
                }
                for donor in donors where donor.document != selected.document {
                    if let merged = Self.mergingTranslationCompanion(donor.candidate, into: selectedDocument, metadata: meta) {
                        selectedDocument = merged
                        diagnostics.append(LyricsProviderDiagnostic(provider: donor.providerName + "@translation-companion",
                            outcome: .match, duration: 0))
                    }
                }
                // Show the exact recording first. A metadata-only tempo catalog
                // may have the same words plus a translation on its base release.
                // Consult that source once, rather than exhaust every query alias.
                let baseTitle = TrackTextNormalizer.stripVersionMarkers(fromTitle: track.title)
                if meta.versionTags.contains(.spedUp), baseTitle != track.title,
                   selectedDocument.lines.contains(where: {
                       !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           && ($0.translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   }) {
                    let metadataOnlyIndices = Set(probeCache.values.flatMap { $0 }.compactMap { probe -> Int? in
                        if case .failed(.lyricsBodyUnavailable) = probe.result { return probe.index }
                        return nil
                    })
                    let companionProviders = configuredProviders.enumerated().compactMap { index, provider -> IndexedProvider? in
                        guard metadataOnlyIndices.contains(index), provider.executionLane == .network else { return nil }
                        return IndexedProvider(index: index, provider: provider)
                    }.prefix(2)
                    if !companionProviders.isEmpty {
                        let companionTrack = Track(id: track.id, title: baseTitle, artist: track.artist,
                            album: track.album, duration: track.duration)
                        let companions = await withTaskGroup(of: ProviderProbeResult.self) { group in
                            for provider in companionProviders {
                                group.addTask { await Self.probe(provider, track: companionTrack, identity: identity) }
                            }
                            var results: [ProviderProbeResult] = []
                            for await result in group { results.append(result) }
                            return results.sorted { $0.index < $1.index }
                        }
                        guard !Task.isCancelled else { return SearchOutcome(result: .failed(.cancelled), diagnostics: diagnostics) }
                        for probe in companions {
                            diagnostics.append(LyricsProviderDiagnostic(provider: probe.provider.name + "@translation-companion",
                                outcome: Self.diagnosticOutcome(probe.result), duration: probe.duration))
                            let candidates: [LyricsCandidate]
                            switch probe.result {
                            case .candidates(let list): candidates = list
                            case .match(let d): candidates = [LyricsCandidate(id: d.providerSourceID ?? "companion",
                                identity: d.identity, title: d.title ?? "", artist: d.artist ?? "", album: d.album ?? "",
                                duration: d.duration ?? 0, lines: d.lines, isSynchronized: d.isSynchronized,
                                source: d.source, confidence: d.confidence, spotifyTrackID: d.spotifyTrackID, isrc: d.isrc)]
                            default: candidates = []
                            }
                            if let merged = candidates.compactMap({ Self.mergingTranslationCompanion($0, into: selectedDocument, metadata: meta) }).first {
                                selectedDocument = merged
                                LyricsE2ELog.log("SEARCH translation-companion provider=\(probe.provider.name) matchedLines=\(merged.lines.count) timingTransferred=false")
                            }
                        }
                    }
                }
                let enriched = Self.finalizeDocument(selectedDocument, identity: identity)
                let selectionPath = selected.cameFromCandidates ? "from-candidates" : "provider-result"
                let agreementNote = selected.agreement.map {
                    "agreement=\($0.sourceCount)-sources delta=\(Int($0.durationDelta.rounded()))s"
                } ?? "agreement=none"
                LyricsE2ELog.log("MANAGER AUTO_ADOPT \(selectionPath) provider=\(selected.providerName) strategy=\(variant.strategy.rawValue) kind=\(variant.queryKind.rawValue) tier=\(selected.decision.tier) score=\(selected.decision.score) timingPriority=\(selected.timingPriority) \(agreementNote) evidence=\(selected.decision.explanation.joined(separator: ";")) lines=\(enriched.lines.count) sync=\(enriched.isSynchronized)")
                return SearchOutcome(result: .match(enriched), diagnostics: diagnostics,
                    alternatives: LyricsCandidate.removingDuplicateLyrics(
                        acceptedCandidates.values.sorted(by: LyricsCandidate.hasPrecedence)
                    ),
                    automaticDecision: selected.decision,
                    automaticSelection: selected.agreement)
            }
        }

        // Localized release titles may have no literal/reading alias at all.
        // One cross-script result from the same artist and near-identical recording
        // length is useful evidence; do not fabricate an "official" title alias.
        if !collectCandidatesOnly, (queryOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let localized = rejectedForExplanation.filter { item in
                !item.decision.hardReject && !item.decision.versionConflict
                    && item.decision.reasons.contains("titleMismatch")
                    && item.decision.reasons.contains("primaryArtistExact")
                    && track.duration > 0 && item.candidate.duration > 0
                    && abs(track.duration - item.candidate.duration) <= 1
                    && item.candidate.source != .lyricsOVH
                    // Digits/symbols are not evidence of a translated title.
                    && track.title.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                    && item.candidate.title.unicodeScalars.contains { CharacterSet.letters.contains($0) }
                    && ScriptDetector.detect(track.title) != ScriptDetector.detect(item.candidate.title)
                    && item.candidate.lines.contains { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            let titleKeys = Set(localized.map { TrackTextNormalizer.normalize($0.candidate.title) })
            if titleKeys.count == 1, let selected = localized.max(by: {
                let lhs = Self.timingPriority(of: $0.candidate), rhs = Self.timingPriority(of: $1.candidate)
                if lhs != rhs { return lhs < rhs }
                return $0.decision.score < $1.decision.score
            }) {
                let score = max(0.58, selected.decision.score)
                let decision = LyricsMatchDecision(tier: .autoMedium, score: score, versionConflict: false,
                    queryKind: selected.decision.queryKind,
                    reasons: selected.decision.reasons + ["localizedTitleArtistDuration"],
                    evidence: selected.decision.evidence + [LyricsMatchEvidence(code: "localizedTitleArtistDuration", delta: score - selected.decision.score)])
                let document = Self.finalizeDocument(selected.document, identity: identity)
                LyricsE2ELog.log("MANAGER AUTO_ADOPT localized-title provider=\(selected.providerName) durationDelta=\(abs(track.duration - selected.candidate.duration)) lines=\(document.lines.count)")
                return SearchOutcome(result: .match(document), diagnostics: diagnostics,
                    alternatives: [selected.candidate], automaticDecision: decision)
            }
        }

        if !acceptedCandidates.isEmpty {
            let sorted = LyricsCandidate.removingDuplicateLyrics(
                acceptedCandidates.values.sorted(by: LyricsCandidate.hasPrecedence)
            )
            return SearchOutcome(result: .candidates(sorted), diagnostics: diagnostics, alternatives: sorted)
        }

        // Exact catalog metadata without text is distinct from wrong same-title songs.
        // All enabled sources have already had the chance to supply real lyrics.
        if let bodyMissing = diagnostics.compactMap({ diagnostic -> LyricsFailure? in
            if case .failed(let failure) = diagnostic.outcome,
               case .lyricsBodyUnavailable = failure { return failure }
            return nil
        }).first {
            return SearchOutcome(result: .failed(bodyMissing), diagnostics: diagnostics)
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
            if reasons.contains("primaryArtistConflict") && reasons.contains("durationFar") {
                return 0
            }
            if !item.decision.hardReject, reasons.contains("primaryArtistExact"), reasons.contains("durationClose") { return 2 }
            if reasons.contains("titleExact") || reasons.contains("titleReadingExact") || reasons.contains("titleTypographyExact") { return 1 }
            return 0
        }
        let rejected = evaluated.filter { $0.decision.tier == .reject }
        guard let closest = rejected.filter({ relevance($0) > 0 }).max(by: {
            if relevance($0) != relevance($1) { return relevance($0) < relevance($1) }
            return $0.decision.score < $1.decision.score
        }) else {
            let hasSameTitleConflict = rejected.contains { item in
                let reasons = Set(item.decision.reasons)
                return (reasons.contains("titleExact") || reasons.contains("titleReadingExact")
                    || reasons.contains("titleTypographyExact"))
                    && reasons.contains("primaryArtistConflict")
                    && reasons.contains("durationFar")
            }
            return hasSameTitleConflict
                ? "有同名候选，但歌手和时长均与当前歌曲不符，未自动采用。"
                : ""
        }
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

    private static func diagnosticOutcome(_ result: LyricsLookupResult) -> LyricsProviderDiagnostic.Outcome {
        switch result {
        case .match: return .match
        case .candidates(let list): return .candidates(list.count)
        case .noMatch: return .noMatch
        case .noLyrics: return .noLyrics
        case .failed(let failure): return .failed(failure)
        }
    }

    /// Only transfers the translation layer after every target line is found in
    /// order. Provider timestamps, spans, original text and IDs are never copied.
    static func mergingTranslationCompanion(_ donor: LyricsCandidate, into document: LyricsDocument,
                                             metadata: TrackMetadata) -> LyricsDocument? {
        guard donor.identity == document.identity, document.lines.count >= 3,
              donor.lines.contains(where: { !($0.translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              document.lines.contains(where: {
                  !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && ($0.translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return nil }
        let decision = LyricsSafeMatcher.decide(candidate: donor, metadata: metadata)
        let sameRecording = !decision.versionConflict && (decision.tier == .autoHigh || decision.tier == .autoMedium)
        let targetTags = Set(metadata.versionTags)
        let donorTags = Set(TrackTextNormalizer.extractVersionTags(fromTitle: donor.title))
        let tempoCompanion = metadata.versionTags.contains(.spedUp)
            && decision.reasons.contains("primaryArtistExact")
            && decision.reasons.contains("tempoBaseTitleExact")
            && targetTags.symmetricDifference(donorTags).subtracting([.spedUp, .remaster]).isEmpty
        guard !decision.hardReject, sameRecording || tempoCompanion else { return nil }
        func key(_ text: String) -> String {
            let folded = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
            }))
        }
        let donorKeys = donor.lines.map { key($0.originalText) }
        if sameRecording {
            let targetKeys = document.lines.map { key($0.originalText) }.filter { !$0.isEmpty }
            guard targetKeys.count >= 3, targetKeys == donorKeys.filter({ !$0.isEmpty }) else { return nil }
        }
        var cursor = 0
        var translated = 0
        var merged: [LyricLine] = []
        for line in document.lines {
            let wanted = key(line.originalText)
            if wanted.isEmpty { merged.append(line); continue }
            guard let index = donorKeys.indices.dropFirst(cursor).first(where: { donorKeys[$0] == wanted }) else { return nil }
            cursor = index + 1
            var copy = line
            if (copy.translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let translation = donor.lines[index].translationText,
               !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.translationText = translation
                translated += 1
            }
            merged.append(copy)
        }
        guard translated > 0 else { return nil }
        return document.replacingLines(merged)
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

    /// Two sources returning the same title, primary artist and length confirm
    /// the recording itself, not a coincidence with Spotify's duration.
    private static func agreementAdoption(
        in evaluated: [EvaluatedCandidate],
        metadata: TrackMetadata
    ) -> AutomaticAdoption? {
        guard metadata.track.duration.isFinite, metadata.track.duration > 0 else { return nil }
        var bestPerProvider: [String: EvaluatedCandidate] = [:]
        for item in evaluated {
            guard item.candidate.identity == metadata.identity,
                  !item.candidate.requiresTextOnlyPreview,
                  !item.decision.hardReject,
                  !item.decision.versionConflict,
                  item.candidate.lines.contains(where: {
                      !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }),
                  agreesOnExactTitleAndArtist(item.decision),
                  !declaresExcludedVersion(item.candidate) else { continue }
            if let current = bestPerProvider[item.providerName],
               !agreementPrefers(item, over: current) { continue }
            bestPerProvider[item.providerName] = item
        }
        guard bestPerProvider.count >= 2 else { return nil }

        let agreeing = Array(bestPerProvider.values)
        let durations = agreeing.map(\.candidate.duration)
        guard durations.allSatisfy({ $0.isFinite && $0 > 0 }),
              let shortest = durations.min(), let longest = durations.max(),
              longest - shortest <= 5 else { return nil }
        guard let best = agreeing.max(by: { agreementPrefers($1, over: $0) }) else { return nil }

        let selection = LyricsAutomaticSelection(
            sourceCount: agreeing.count,
            durationDelta: abs(metadata.track.duration - best.candidate.duration)
        )
        let base = best.decision
        let decision = LyricsMatchDecision(
            tier: .autoMedium,
            score: base.score,
            versionConflict: false,
            queryKind: base.queryKind,
            reasons: base.reasons + ["multiSourceAgreement"],
            evidence: base.evidence + [
                LyricsMatchEvidence(code: "multiSourceAgreement", delta: 0),
                LyricsMatchEvidence(code: "agreementDurationDelta", delta: 0)
            ],
            hardReject: false
        )
        return AutomaticAdoption(
            document: best.document,
            decision: decision,
            timingPriority: timingPriority(of: best.candidate),
            providerIndex: best.providerIndex,
            candidateIndex: best.candidateIndex,
            providerName: best.providerName,
            cameFromCandidates: best.cameFromCandidates,
            agreement: selection
        )
    }

    private static func agreesOnExactTitleAndArtist(_ decision: LyricsMatchDecision) -> Bool {
        let reasons = Set(decision.reasons)
        guard reasons.contains("titleExact") else { return false }
        return reasons.contains("primaryArtistExact")
            || reasons.contains("primaryArtistReadingExact")
            || reasons.contains("primaryArtistAlias")
            || reasons.contains("spotifyCreditedArtistReadingExact")
    }

    /// A cover, remix or live take is a different recording even when the
    /// title and artist tags look identical.
    private static func declaresExcludedVersion(_ candidate: LyricsCandidate) -> Bool {
        let tags = TrackTextNormalizer.extractVersionTags(fromTitle: candidate.title)
        return tags.contains(.cover) || tags.contains(.remix) || tags.contains(.live)
    }

    /// Timed lyrics first, word-by-word before line timing, then match score.
    private static func agreementPrefers(_ lhs: EvaluatedCandidate, over rhs: EvaluatedCandidate) -> Bool {
        let lhsTiming = timingPriority(of: lhs.candidate)
        let rhsTiming = timingPriority(of: rhs.candidate)
        if lhsTiming != rhsTiming { return lhsTiming > rhsTiming }
        if lhs.decision.score != rhs.decision.score { return lhs.decision.score > rhs.decision.score }
        if lhs.providerIndex != rhs.providerIndex { return lhs.providerIndex < rhs.providerIndex }
        return lhs.candidateIndex < rhs.candidateIndex
    }

    private static func bestAutomaticAdoption(in candidates: [AutomaticAdoption]) -> AutomaticAdoption? {
        candidates.max { lhs, rhs in
            // Every candidate here is already safely matched. Between them a
            // real timeline beats plain text, and word timing beats line timing.
            if lhs.timingPriority != rhs.timingPriority {
                return lhs.timingPriority < rhs.timingPriority
            }
            if lhs.decision.score != rhs.decision.score {
                return lhs.decision.score < rhs.decision.score
            }
            let lhsTier = automaticTierPriority(lhs.decision.tier)
            let rhsTier = automaticTierPriority(rhs.decision.tier)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
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

/// Why an otherwise review-only result was adopted anyway: several sources
/// agreed on one recording whose length differs from Spotify's own duration.
public struct LyricsAutomaticSelection: Equatable, Sendable {
    public let sourceCount: Int
    public let durationDelta: TimeInterval

    public init(sourceCount: Int, durationDelta: TimeInterval) {
        self.sourceCount = sourceCount
        self.durationDelta = durationDelta
    }
}

public struct SearchOutcome {
    public let result: LyricsLookupResult
    public let diagnostics: [LyricsProviderDiagnostic]
    public let alternatives: [LyricsCandidate]
    public let automaticDecision: LyricsMatchDecision?
    /// Present only when the adoption came from multi-source agreement.
    public let automaticSelection: LyricsAutomaticSelection?

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

    public init(result: LyricsLookupResult, diagnostics: [LyricsProviderDiagnostic], alternatives: [LyricsCandidate] = [], automaticDecision: LyricsMatchDecision? = nil, automaticSelection: LyricsAutomaticSelection? = nil) {
        self.result = result
        self.diagnostics = diagnostics
        self.alternatives = alternatives
        self.automaticDecision = automaticDecision
        self.automaticSelection = automaticSelection
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
