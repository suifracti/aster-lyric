import Combine
import Foundation

@MainActor
public final class LyricsSessionController: ObservableObject {
    @Published public private(set) var state: LyricsLoadState = .idle
    @Published public private(set) var availableCandidates: [LyricsCandidate] = []
    @Published public private(set) var lyrics: [LyricLine] = []
#if DEBUG
    @Published public private(set) var debugLyricsBindingToken: String?
#endif
    @Published public private(set) var isSynchronized = true
    /// Session-only explicit absence. It never creates or deletes a database
    /// version and invalidates all in-flight Provider work.
    @Published public private(set) var isNoSelection = false
    /// Explicit, session-only user mark; never inferred from missing lyrics or lyric text.
    @Published public private(set) var isMarkedInstrumental = false
    @Published public private(set) var activeIdentity: TrackIdentity?
    @Published public private(set) var activeLyricsVersionID: UUID?
    @Published public private(set) var activeSourceContentHash: String?
    @Published public private(set) var alignmentProvenanceAvailability: AlignmentProvenanceAvailability = .unavailable
    @Published public private(set) var revision: UInt64 = 0
    @Published public private(set) var isSearchInProgress = false
    @Published public private(set) var isSearchingAdditionalVersions = false
    @Published public private(set) var additionalVersionsMessage = ""
    @Published public private(set) var sourceFailureSummary: String?
    @Published public private(set) var persistenceStatusMessage: String?
    @Published public private(set) var activeSearchQuery: String?
    @Published public private(set) var automaticSearchDisabledForCurrentTrack = false

    private let searchManager: LyricsSearchManager
    private let repository: (any LyricsRepository)?
    private let sourceStats: LyricsSourceStats
    private var requestTask: Task<Void, Never>?
    private var manualAdoptionRequestIDs: [TrackIdentity: UUID] = [:]
    private var manualAdoptionRequestRevisions: [TrackIdentity: UInt64] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private let recoveryCooldowns: [TimeInterval]
    private var retryTask: Task<Void, Never>?
    private let sourceRetryDelay: TimeInterval
    private var retriedIdentity: TrackIdentity?
    private var isRecoveryAttempt = false
    private var activeTrack: Track?
    private var searchQueryOverride: String?

    /// Zero-operation automatic alignment reuses the session repository.
    public var repositoryForAutomaticAlignment: (any LyricsRepository)? { repository }

    /// Primary production path: multi-variant LyricsSearchManager (not a dead Orchestrator).
    public init(
        providers: [LyricsProvider],
        name: String = "LyricsSearchManager",
        repository: (any LyricsRepository)? = nil,
        recoveryCooldowns: [TimeInterval] = [2, 5],
        spotifyArtistResolver: SpotifyTrackArtistResolver? = nil,
        sourceStats: LyricsSourceStats = .shared,
        sourceRetryDelay: TimeInterval = 30
    ) {
        self.searchManager = LyricsSearchManager(providers: providers, name: name, spotifyArtistResolver: spotifyArtistResolver)
        self.repository = repository
        self.sourceStats = sourceStats
        self.sourceRetryDelay = max(0, sourceRetryDelay)
        self.recoveryCooldowns = recoveryCooldowns.map { max(0, $0) }
    }

    /// Test/compat wrapper around a single composite provider.
    public convenience init(provider: LyricsProvider) {
        if let composite = provider as? CompositeLyricsProvider {
            self.init(providers: composite.underlyingProviders, name: composite.name)
        } else {
            self.init(providers: [provider], name: provider.name)
        }
    }

    deinit {
        requestTask?.cancel()
        recoveryTask?.cancel()
        retryTask?.cancel()
    }

    public var activeDocument: LyricsDocument? {
        state.document
    }

    public func autoComplete(track: Track, identity: TrackIdentity) {
        begin(track: track, identity: identity, resetQueryOverride: true)
    }

    public func hasAdoptedLyrics(for track: Track) -> Bool {
        guard activeLyricsVersionID != nil, !lyrics.isEmpty, let activeTrack,
              let id = TrackIdentity.playbackID(for: track) else { return false }
        return TrackIdentity.playbackID(for: activeTrack) == id
    }

    public func updateProviders(_ providers: [LyricsProvider]) {
        cancelCurrentRequest()
        revision &+= 1
        searchManager.updateProviders(providers)
    }

    public func begin(
        track: Track,
        identity: TrackIdentity,
        automaticallySearch: Bool = true,
        forceRefresh: Bool = false,
        queryOverride: String? = nil,
        resetQueryOverride: Bool = false
    ) {
        // Keep the current projection while checking the persisted refresh boundary.
        let retainsCurrentProjection = forceRefresh && activeIdentity == identity && activeLyricsVersionID != nil && !lyrics.isEmpty
        cancelCurrentRequest()
        revision &+= 1
        let requestRevision = revision
        if activeIdentity != identity { retriedIdentity = nil }
        if resetQueryOverride || activeIdentity != identity {
            searchQueryOverride = Self.normalizedQuery(queryOverride)
        } else if let queryOverride {
            searchQueryOverride = Self.normalizedQuery(queryOverride)
        }
        if !isRecoveryAttempt { recoveryAttempts = 0 }
        sourceFailureSummary = nil
        activeIdentity = identity
        activeTrack = track
        isMarkedInstrumental = false
        if !retainsCurrentProjection {
            activeLyricsVersionID = nil
            activeSourceContentHash = nil
            alignmentProvenanceAvailability = .unavailable
        }
        persistenceStatusMessage = nil
        activeSearchQuery = searchQueryOverride
        automaticSearchDisabledForCurrentTrack = !automaticallySearch
        if !retainsCurrentProjection { lyrics = [] }
        availableCandidates = []
#if DEBUG
        if !retainsCurrentProjection { debugLyricsBindingToken = nil }
#endif
        if !retainsCurrentProjection {
            isSynchronized = true
            isNoSelection = false
            state = .loading(identity)
        }
        isSearchInProgress = true
        let queryOverrideSnapshot = searchQueryOverride

        LyricsE2ELog.log(
            "SESSION begin rev=\(requestRevision) identity=\(identity.stableKey) title=\(track.title) artist=\(track.artist) duration=\(track.duration) spotifyId=\(track.spotifyId ?? "")"
        )

        let sourceStats = sourceStats
        requestTask = Task { [weak self, searchManager, repository, sourceStats] in
            defer {
                if let self, self.activeIdentity == identity, self.revision == requestRevision { self.isSearchInProgress = false }
            }
            var outcome: SearchOutcome?
            var searchDuration: TimeInterval?
            var cachedReference: StoredLyricsDocument?
            var persistenceError: String?
            var repositoryReady = false
            var storedAliases: [TrackAlias] = []
            var reviewOnly = false

            if let repository {
                do {
                    try await repository.prepare()
                    repositoryReady = true
                    do {
                        reviewOnly = try await repository.isLyricsSelectionRevoked(identity: identity)
                    } catch {
                        await MainActor.run { [weak self] in
                            guard let self, self.activeIdentity == identity, self.revision == requestRevision else { return }
                            self.persistenceStatusMessage = error.localizedDescription
                            self.apply(.failed(.unknown("无法读取采用状态，停止自动搜索以保护已有选择")), identity: identity, requestRevision: requestRevision)
                        }
                        return
                    }
                    if reviewOnly, !forceRefresh {
                        await MainActor.run { [weak self] in
                            guard let self, self.activeIdentity == identity, self.revision == requestRevision else { return }
                            self.selectNoVersion(identity: identity)
                            self.persistenceStatusMessage = "已取消采用；歌词资产保留，可重新选择或搜索同步歌词"
                        }
                        return
                    }
                    storedAliases = (try? await repository.loadAliases(stableKey: identity.stableKey)) ?? []
                    if let cached = try await repository.loadBestStored(track: track, identity: identity),
                       !forceRefresh || (!reviewOnly && cached.isUserProtected) {
                        cachedReference = cached
                        LyricsE2ELog.log(
                            "SESSION persistence hit rev=\(requestRevision) source=\(cached.document.source) provider=\(cached.document.providerSourceID ?? "") lines=\(cached.document.lines.count) sync=\(cached.document.isSynchronized)"
                        )
                        if forceRefresh && cached.isUserProtected {
                            await MainActor.run { [weak self] in
                                guard let self, self.activeIdentity == identity, self.revision == requestRevision else { return }
                                self.apply(.match(cached.document), identity: identity, requestRevision: requestRevision, sourceContentHash: cached.sourceContentHash)
                                self.activeLyricsVersionID = cached.versionID
                                self.activeSourceContentHash = cached.sourceContentHash
                                self.alignmentProvenanceAvailability = cached.alignmentProvenanceAvailability
                            }
                            // Continue searching, but only into alternatives until explicit adoption.
                        } else if automaticallySearch && !cached.document.isSynchronized && !cached.isUserProtected {
                            await MainActor.run { [weak self] in
                                guard let self, self.activeIdentity == identity, self.revision == requestRevision else { return }
                                self.apply(.match(cached.document), identity: identity, requestRevision: requestRevision)
                                // Keep translation pending until this bounded synchronization search settles.
                            }
                        } else {
                            outcome = SearchOutcome(result: .match(cached.document), diagnostics: [])
                        }
                    } else {
                        LyricsE2ELog.log("SESSION persistence miss rev=\(requestRevision) identity=\(identity.stableKey)")
                    }
                } catch {
                    persistenceError = error.localizedDescription
                    LyricsE2ELog.log("PERSISTENCE prepare/load failed rev=\(requestRevision) error=\(error.localizedDescription)")
                    if retainsCurrentProjection {
                        if let self, self.activeIdentity == identity, self.revision == requestRevision {
                            self.persistenceStatusMessage = persistenceError
                        }
                        return
                    }
                    // A failed stored-version read is not a cache miss. Keep
                    // automatic search from replacing a choice we could not load.
                    if repositoryReady {
                        if let self, self.activeIdentity == identity, self.revision == requestRevision {
                            self.persistenceStatusMessage = persistenceError
                            self.apply(.failed(.unknown("无法读取已存歌词，停止自动搜索以保护已有选择")), identity: identity, requestRevision: requestRevision)
                        }
                        return
                    }
                }
            }

            if outcome == nil, !Task.isCancelled {
                if automaticallySearch {
                    let protectsRefresh = forceRefresh && cachedReference?.isUserProtected == true
                    let suppressProvisional = reviewOnly || protectsRefresh
                    let retainsPlainCache = cachedReference?.document.isSynchronized == false
                    let searchStartedAt = Date()
                    let searched = await searchManager.search(
                        track: track,
                        identity: identity,
                        queryOverride: queryOverrideSnapshot,
                        forceRefresh: forceRefresh,
                        aliases: storedAliases,
                        onProvisional: { [weak self] document in
                            await MainActor.run { [weak self] in
                                guard !suppressProvisional, !Task.isCancelled, let self, self.activeIdentity == identity, self.revision == requestRevision,
                                      !retainsPlainCache || document.isSynchronized,
                                      self.activeLyricsVersionID == nil else { return }
                                self.apply(.match(document), identity: identity, requestRevision: requestRevision)
                            }
                        },
                        onCandidates: { [weak self] candidates in
                            await MainActor.run { [weak self] in
                                guard let self, self.activeIdentity == identity, self.revision == requestRevision,
                                      !Task.isCancelled else { return }
                                var previews = Dictionary(self.availableCandidates.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                                for candidate in candidates where candidate.identity == identity { previews[candidate.id] = candidate }
                                let sorted = previews.values.sorted(by: LyricsCandidate.hasPrecedence)
                                let isManual = reviewOnly || (queryOverrideSnapshot != nil && !queryOverrideSnapshot!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if isManual && self.lyrics.isEmpty {
                                    self.apply(.candidates(sorted), identity: identity, requestRevision: requestRevision)
                                }
                                self.availableCandidates = sorted
                            }
                        }
                    )
                    searchDuration = Date().timeIntervalSince(searchStartedAt)
                    if protectsRefresh, let cached = cachedReference {
                        var alternatives = searched.alternatives
                        if alternatives.isEmpty, case .match(let document) = searched.result {
                            alternatives = [LyricsCandidate(id: document.providerSourceID ?? UUID().uuidString,
                                identity: identity, title: document.title ?? track.title, artist: document.artist ?? track.artist,
                                album: document.album ?? track.album, duration: document.duration ?? track.duration, lines: document.lines,
                                isSynchronized: document.isSynchronized, source: document.source, confidence: document.confidence,
                                providerSourceID: document.providerSourceID, spotifyTrackID: document.spotifyTrackID,
                                isrc: document.isrc, explicitlyTimedLineIndices: document.explicitlyTimedLineIndices)]
                        }
                        outcome = SearchOutcome(result: .match(cached.document), diagnostics: searched.diagnostics, alternatives: alternatives)
                    } else if reviewOnly, case .match(let document) = searched.result {
                        let candidate = LyricsCandidate(id: document.providerSourceID ?? UUID().uuidString,
                            identity: identity, title: document.title ?? track.title, artist: document.artist ?? track.artist,
                            album: document.album ?? track.album, duration: document.duration ?? track.duration, lines: document.lines,
                            isSynchronized: document.isSynchronized, source: document.source, confidence: document.confidence,
                            providerSourceID: document.providerSourceID, spotifyTrackID: document.spotifyTrackID,
                            isrc: document.isrc, explicitlyTimedLineIndices: document.explicitlyTimedLineIndices)
                        let alternatives = searched.alternatives.isEmpty ? [candidate] : searched.alternatives
                        outcome = SearchOutcome(result: .candidates(alternatives), diagnostics: searched.diagnostics, alternatives: alternatives)
                    } else if let cached = cachedReference {
                        if case .match(let document) = searched.result, document.isSynchronized {
                            cachedReference = nil
                            outcome = searched
                        } else {
                            outcome = SearchOutcome(result: .match(cached.document), diagnostics: searched.diagnostics,
                                alternatives: searched.alternatives)
                        }
                    } else { outcome = searched }
                } else {
                    await MainActor.run { [weak self] in
                        guard let self,
                              self.activeIdentity == identity,
                              self.revision == requestRevision else { return }
                        self.persistenceStatusMessage = persistenceError
                        self.state = .idle
                        LyricsE2ELog.log("SESSION automatic search disabled; stored lyrics absent identity=\(identity.stableKey)")
                    }
                    return
                }
            }

            guard let outcome else { return }
            guard !Task.isCancelled else {
                LyricsE2ELog.log("SESSION cancelled before apply rev=\(requestRevision)")
                return
            }
            LyricsE2ELog.log("SESSION search finished rev=\(requestRevision) result=\(Self.describe(outcome.result)) diag=\(outcome.diagnostics.count)")
            for d in outcome.diagnostics {
                LyricsE2ELog.log("  DIAG \(d.provider) \(Self.describeDiag(d.outcome)) \(String(format: "%.2f", d.duration))s")
            }
            if let searchDuration {
                sourceStats.record(
                    spotifyID: identity.spotifyTrackID,
                    totalSeconds: searchDuration,
                    result: outcome.result,
                    retry: false,
                    diagnostics: outcome.diagnostics
                )
            }
            let didApply = await MainActor.run { [weak self] () -> Bool in
                guard let self,
                      self.activeIdentity == identity,
                      self.revision == requestRevision else {
                    let currentRevision = self?.revision.description ?? "none"
                    LyricsE2ELog.log("SESSION drop stale result rev=\(requestRevision) current=\(currentRevision)")
                    return false
                }
                self.sourceFailureSummary = outcome.sourceFailureSummary
                self.persistenceStatusMessage = persistenceError
                self.availableCandidates = outcome.alternatives.filter { $0.identity == identity }
                self.apply(
                    outcome.result,
                    identity: identity,
                    requestRevision: requestRevision,
                    sourceContentHash: cachedReference?.sourceContentHash
                )
                if let cachedReference {
                    self.activeLyricsVersionID = cachedReference.versionID
                    self.activeSourceContentHash = cachedReference.sourceContentHash
                    self.alignmentProvenanceAvailability = cachedReference.alignmentProvenanceAvailability
                }
                return true
            }

            // Loading an already persisted choice is read-only. Do not send it
            // back through the automatic-save path when track search is off.
            if !automaticallySearch, cachedReference != nil {
                return
            }

            // Persist only after the current Session has accepted the match.
            // This prevents a late result from a cancelled track request from
            // being written as if it belonged to the next playback session.
            if didApply,
               repositoryReady,
               case .match(let document) = outcome.result,
               !Task.isCancelled,
               document.identity == identity,
               !document.lines.isEmpty,
               cachedReference == nil,
               outcome.automaticDecision != nil || LyricsMatcher.isHighConfidence(document.confidence) {
                do {
                    let saved: LyricsPersistenceSaveResult?
                    if let decision = outcome.automaticDecision {
                        saved = try await repository?.saveAutomaticallySelected(track: track, identity: identity, document: document, decision: LyricsAutomaticSelectionEvidence(identity: identity, tier: decision.tier.rawValue, hardReject: decision.hardReject, versionConflict: decision.versionConflict))
                    } else {
                        saved = try await repository?.save(track: track, identity: identity, document: document)
                    }
                    LyricsE2ELog.log(
                        "SESSION persistence save rev=\(requestRevision) disposition=\(String(describing: saved?.disposition)) lines=\(document.lines.count)"
                    )
                    if let saved, saved.versionID != nil {
                        await MainActor.run { [weak self] in
                            guard let self, self.activeIdentity == identity, self.revision == requestRevision else { return }
                            self.activeLyricsVersionID = saved.versionID
                            self.activeSourceContentHash = saved.sourceContentHash
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    LyricsE2ELog.log("PERSISTENCE save failed rev=\(requestRevision) error=\(message)")
                    await MainActor.run { [weak self] in
                        guard let self, self.activeIdentity == identity, self.revision == requestRevision else { return }
                        self.persistenceStatusMessage = message
                    }
                }
            }

            if didApply,
               !Task.isCancelled,
               !reviewOnly,
               cachedReference?.isUserProtected != true,
               Self.shouldRetrySourceFailures(outcome.result) {
                let providers = Self.retryableProviders(in: outcome.diagnostics)
                if !providers.isEmpty {
                    await MainActor.run { [weak self] in
                        self?.scheduleSourceRetry(
                            track: track,
                            identity: identity,
                            revision: requestRevision,
                            providers: providers,
                            queryOverride: queryOverrideSnapshot,
                            aliases: storedAliases
                        )
                    }
                }
            }
        }
    }

    public func beginLoadingPlaceholder(identity: TrackIdentity, message: String = "") {
        cancelCurrentRequest()
        revision &+= 1
        activeIdentity = identity
        activeLyricsVersionID = nil
        activeSourceContentHash = nil
        alignmentProvenanceAvailability = .unavailable
        automaticSearchDisabledForCurrentTrack = false
        lyrics = []
        availableCandidates = []
        isSynchronized = true
        isMarkedInstrumental = false
        isNoSelection = false
        state = .loading(identity)
        LyricsE2ELog.log("SESSION placeholder identity=\(identity.stableKey) msg=\(message)")
    }

    public func fail(identity: TrackIdentity, failure: LyricsFailure) {
        guard activeIdentity == identity else { return }
        cancelCurrentRequest()
        revision &+= 1
        lyrics = []
        availableCandidates = []
        isSynchronized = true
        isMarkedInstrumental = false
        isNoSelection = false
        state = .failed(identity, failure)
        LyricsE2ELog.log("SESSION fail identity=\(identity.stableKey) \(failure)")
    }

    public func retry(track: Track, identity: TrackIdentity) {
        retry(track: track, identity: identity, queryOverride: nil)
    }

    /// Explicit browsing changes only the candidate list. The current lyrics,
    /// saved selection, and session-only absence/instrumental mark stay intact.
    public func searchAdditionalVersions(track: Track, identity: TrackIdentity) {
        guard activeIdentity == identity, TrackIdentity(track: track) == identity else { return }
        cancelCurrentRequest()
        revision &+= 1
        let requestRevision = revision
        availableCandidates = []
        isSearchingAdditionalVersions = true
        additionalVersionsMessage = "正在查找更多歌词版本…"
        requestTask = Task { [weak self, searchManager, repository] in
            defer {
                if let self, self.activeIdentity == identity, self.revision == requestRevision {
                    self.isSearchingAdditionalVersions = false
                }
            }
            let aliases = (try? await repository?.loadAliases(stableKey: identity.stableKey)) ?? []
            guard !Task.isCancelled else { return }
            let outcome = await searchManager.search(track: track, identity: identity,
                forceRefresh: true, aliases: aliases, collectCandidatesOnly: true,
                onCandidates: { [weak self] candidates in
                    await MainActor.run { [weak self] in
                        guard !Task.isCancelled, let self, self.activeIdentity == identity,
                              self.revision == requestRevision else { return }
                        var merged = Dictionary(self.availableCandidates.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
                        for candidate in candidates where candidate.identity == identity { merged[candidate.id] = candidate }
                        self.availableCandidates = merged.values.sorted(by: LyricsCandidate.hasPrecedence)
                    }
                })
            guard !Task.isCancelled, let self, self.activeIdentity == identity,
                  self.revision == requestRevision else { return }
            switch outcome.result {
            case .candidates(let candidates):
                self.availableCandidates = candidates.filter { $0.identity == identity }
                self.additionalVersionsMessage = "找到 \(self.availableCandidates.count) 个候选；预览后可采用。"
                if let summary = outcome.sourceFailureSummary { self.additionalVersionsMessage += " \(summary)" }
            case .failed(let failure):
                self.additionalVersionsMessage = failure.userFacingMessage
            case .noLyrics, .noMatch:
                self.additionalVersionsMessage = "暂未找到其他歌词版本，可以稍后重试。"
            case .match:
                // Candidate-only searches must never enter a persistence path.
                self.additionalVersionsMessage = "未取得可预览的候选，请重新查找。"
            }
            // Browsing can interrupt the initial automatic load. With no
            // existing projection, finish its loading indicator as a review
            // state; do not start automatic recovery or save a selection.
            if self.lyrics.isEmpty, self.activeLyricsVersionID == nil, case .loading = self.state {
                switch outcome.result {
                case .candidates: self.state = .candidates(identity, self.availableCandidates)
                case .noLyrics: self.state = .noLyrics(identity)
                case .noMatch: self.state = .noMatch(identity)
                case .failed(let failure): self.state = .failed(identity, failure)
                case .match: break
                }
            }
        }
    }

    public func retry(
        track: Track,
        identity: TrackIdentity,
        queryOverride: String?
    ) {
        begin(
            track: track,
            identity: identity,
            automaticallySearch: true,
            forceRefresh: true,
            queryOverride: queryOverride
        )
    }

    public func clearSearchQueryOverride() {
        searchQueryOverride = nil
        activeSearchQuery = nil
    }

    @discardableResult
    public func retryAfterNetworkRecovery(track: Track, identity: TrackIdentity) -> Bool {
        guard activeIdentity == identity,
              case .failed(let failedIdentity, .networkUnavailable) = state,
              failedIdentity == identity,
              !automaticSearchDisabledForCurrentTrack, !isNoSelection,
              recoveryTask == nil, recoveryAttempts < recoveryCooldowns.count else {
            return false
        }
        scheduleRecovery(track: track, identity: identity, revision: revision)
        return true
    }

    public func clear() {
        sourceFailureSummary = nil
        cancelCurrentRequest()
        revision &+= 1
        activeIdentity = nil
        activeLyricsVersionID = nil
        activeSourceContentHash = nil
        alignmentProvenanceAvailability = .unavailable
        activeTrack = nil
        recoveryAttempts = 0
        automaticSearchDisabledForCurrentTrack = false
        searchQueryOverride = nil
        activeSearchQuery = nil
        lyrics = []
        availableCandidates = []
        isSynchronized = true
        isMarkedInstrumental = false
        isNoSelection = false
        state = .idle
        LyricsE2ELog.log("SESSION clear")
    }

    /// Keeps the live TrackIdentity while explicitly selecting no lyric
    /// version. This is intentionally not a noMatch/failed state and is not
    /// persisted as an empty LyricsVersion.
    @discardableResult
    public func revokeCurrentVersion(identity: TrackIdentity, versionID: UUID) async throws -> Bool {
        guard activeIdentity == identity, activeLyricsVersionID == versionID, let repository else { return false }
        cancelCurrentRequest()
        revision &+= 1
        let expectedRevision = revision
        manualAdoptionRequestIDs.removeValue(forKey: identity)
        manualAdoptionRequestRevisions.removeValue(forKey: identity)
        try await repository.revokeLyricsVersionSelection(trackStableKey: identity.stableKey, lyricsVersionID: versionID)
        guard activeIdentity == identity, revision == expectedRevision else { return false }
        selectNoVersion(identity: identity)
        persistenceStatusMessage = "已取消采用；保留原词、时间轴及关联资产"
        return true
    }

    public func selectNoVersion(identity: TrackIdentity? = nil) {
        guard let activeIdentity,
              identity == nil || identity == activeIdentity else { return }
        if let pending = manualAdoptionRequestIDs[activeIdentity] {
            cancelManualAdoptionRequest(identity: activeIdentity, requestID: pending)
        }
        cancelCurrentRequest()
        revision &+= 1
        activeLyricsVersionID = nil
        activeSourceContentHash = nil
        alignmentProvenanceAvailability = .unavailable
        recoveryAttempts = 0
        persistenceStatusMessage = nil
        lyrics = []
        availableCandidates = []
        isSynchronized = true
        isMarkedInstrumental = false
        isNoSelection = true
        state = .noSelection(activeIdentity)
        LyricsE2ELog.log("SESSION explicit no-selection identity=\(activeIdentity.stableKey)")
    }

    public func enterMockPreview(lines: [LyricLine]) {
        cancelCurrentRequest()
        revision &+= 1
        activeIdentity = nil
        activeLyricsVersionID = nil
        activeSourceContentHash = nil
        alignmentProvenanceAvailability = .unavailable
        activeTrack = nil
        recoveryAttempts = 0
        lyrics = lines
        isSynchronized = true
        isMarkedInstrumental = false
        isNoSelection = false
        state = .mockPreview
        LyricsE2ELog.log("SESSION mockPreview lines=\(lines.count)")
    }

    public func markAsInstrumental(identity: TrackIdentity) {
        guard activeIdentity == identity, activeTrack != nil else { return }
        selectNoVersion(identity: identity)
        isMarkedInstrumental = true
        let line = LyricLine(timestamp: 0, originalText: "此歌曲为没有填词的纯音乐，请您欣赏")
        lyrics = [line]
        isSynchronized = false
        isNoSelection = false
        let doc = LyricsDocument(
            identity: identity,
            title: activeTrack?.title,
            artist: activeTrack?.artist,
            album: activeTrack?.album,
            duration: 0,
            lines: [line],
            isSynchronized: false,
            source: .manualImport,
            confidence: 1.0
        )
        state = .loaded(doc)
        LyricsE2ELog.log("SESSION markAsInstrumental identity=\(identity.stableKey)")
    }

    public func clearInstrumentalMark(identity: TrackIdentity) {
        guard isMarkedInstrumental, activeIdentity == identity, let activeTrack else { return }
        // The mark never changes stored selection. Restore it without asking a provider.
        begin(track: activeTrack, identity: identity, automaticallySearch: false)
    }

    /// Registers one explicit adoption before any async repository work starts.
    /// A later adoption for the same identity replaces this request token;
    /// switching to another identity leaves this operation bound to its source.
    @discardableResult
    public func beginManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws -> Bool {
        guard activeIdentity == identity else {
            LyricsE2ELog.log("SESSION manual adoption REJECT stale identity")
            return false
        }
        cancelCurrentRequest()
        revision &+= 1
        manualAdoptionRequestIDs[identity] = requestID
        manualAdoptionRequestRevisions[identity] = revision
        do {
            try await repository?.registerManualAdoptionRequest(identity: identity, requestID: requestID)
        } catch {
            if manualAdoptionRequestIDs[identity] == requestID {
                manualAdoptionRequestIDs.removeValue(forKey: identity)
                manualAdoptionRequestRevisions.removeValue(forKey: identity)
            }
            throw error
        }
        return manualAdoptionRequestIDs[identity] == requestID
    }

    public func cancelManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) {
        guard manualAdoptionRequestIDs[identity] == requestID else { return }
        manualAdoptionRequestIDs.removeValue(forKey: identity)
        manualAdoptionRequestRevisions.removeValue(forKey: identity)
        guard let repository else { return }
        Task {
            try? await repository.cancelManualAdoptionRequest(identity: identity, requestID: requestID)
        }
    }

    /// Persists a user-confirmed document and selects it only after the
    /// repository commits its asset, timing and preferred-selection rows.
    /// The Track is captured by the caller at the start of the interaction so
    /// an A→B switch cannot redirect A's late persistence to B.
    public func adoptManually(
        document: LyricsDocument,
        track: Track,
        requestID: UUID,
        confirmedLockedVersionIDs: [UUID]? = nil
    ) async throws -> LyricsPersistenceSaveResult {
        let identity = document.identity
        guard manualAdoptionRequestIDs[identity] == requestID,
              let requestRevision = manualAdoptionRequestRevisions[identity] else {
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("歌词采用请求已被更新或取消")
            )
        }
        guard TrackIdentity(track: track) == identity else {
            manualAdoptionRequestIDs.removeValue(forKey: identity)
            manualAdoptionRequestRevisions.removeValue(forKey: identity)
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("歌词身份与当前歌曲不一致")
            )
        }
        guard let repository else {
            manualAdoptionRequestIDs.removeValue(forKey: identity)
            manualAdoptionRequestRevisions.removeValue(forKey: identity)
            return LyricsPersistenceSaveResult(
                versionID: nil,
                disposition: .rejected("歌词仓库不可用，候选仅保留为预览")
            )
        }
        guard !Task.isCancelled else {
            manualAdoptionRequestIDs.removeValue(forKey: identity)
            manualAdoptionRequestRevisions.removeValue(forKey: identity)
            throw CancellationError()
        }

        do {
            let result = try await repository.saveAndAdoptManually(
                track: track,
                identity: identity,
                document: document,
                requestID: requestID,
                confirmedLockedVersionIDs: confirmedLockedVersionIDs
            )
            LyricsE2ELog.log(
                "SESSION manual adoption disposition=\(String(describing: result.disposition)) source=\(document.source) confidence=\(document.confidence) lines=\(document.lines.count)"
            )
            switch result.disposition {
            case .inserted, .duplicate:
                guard let versionID = result.versionID,
                      let sourceContentHash = result.sourceContentHash else {
                    if manualAdoptionRequestIDs[identity] == requestID {
                        manualAdoptionRequestIDs.removeValue(forKey: identity)
                        manualAdoptionRequestRevisions.removeValue(forKey: identity)
                    }
                    return LyricsPersistenceSaveResult(
                        versionID: nil,
                        disposition: .rejected("歌词已保存，但缺少持久版本身份")
                    )
                }
                if manualAdoptionRequestIDs[identity] == requestID {
                    if activeIdentity == identity, revision == requestRevision {
                        activeLyricsVersionID = versionID
                        let committedDocument = document.replacingLines(
                            document.lines,
                            timingVersionID: result.timingVersionID
                        )
                        applyLoadedDocument(committedDocument, identity: identity, sourceContentHash: sourceContentHash)
                        activeSourceContentHash = sourceContentHash
                        alignmentProvenanceAvailability = committedDocument.source == .automaticAlignment ? .available : .unavailable
                        persistenceStatusMessage = nil
                    }
                    manualAdoptionRequestIDs.removeValue(forKey: identity)
                    manualAdoptionRequestRevisions.removeValue(forKey: identity)
                }
            case .lockedConflict:
                if activeIdentity == identity, revision == requestRevision,
                   manualAdoptionRequestIDs[identity] == requestID {
                    persistenceStatusMessage = "存在锁定歌词版本，需要确认后才能切换当前版本"
                }
            case .rejected(let message):
                if manualAdoptionRequestIDs[identity] == requestID {
                    if activeIdentity == identity, revision == requestRevision { persistenceStatusMessage = message }
                    manualAdoptionRequestIDs.removeValue(forKey: identity)
                    manualAdoptionRequestRevisions.removeValue(forKey: identity)
                }
            case .skippedLocked:
                if manualAdoptionRequestIDs[identity] == requestID {
                    if activeIdentity == identity, revision == requestRevision { persistenceStatusMessage = "歌词版本仍受锁定保护，未采用" }
                    manualAdoptionRequestIDs.removeValue(forKey: identity)
                    manualAdoptionRequestRevisions.removeValue(forKey: identity)
                }
            }
            return result
        } catch {
            if manualAdoptionRequestIDs[identity] == requestID {
                if activeIdentity == identity, revision == requestRevision { persistenceStatusMessage = error.localizedDescription }
                manualAdoptionRequestIDs.removeValue(forKey: identity)
                manualAdoptionRequestRevisions.removeValue(forKey: identity)
            }
            LyricsE2ELog.log("PERSISTENCE manual adoption failed error=\(error.localizedDescription)")
            throw error
        }
    }

    public func adopt(document: LyricsDocument) {
        guard activeIdentity == document.identity else {
            LyricsE2ELog.log("SESSION adopt document REJECT identity mismatch")
            return
        }
        cancelCurrentRequest()
        revision &+= 1
        applyLoadedDocument(document, identity: document.identity)
        persistAdoptedDocument(document)
    }

    /// Applies a version that has already been committed by the editing
    /// repository. Unlike `adopt(document:)`, this does not write the same
    /// document back again; it only refreshes the live session's identity,
    /// version id and source fingerprint.
    public func adoptPersisted(
        document: LyricsDocument,
        versionID: UUID,
        sourceContentHash: String
    ) {
        guard activeIdentity == document.identity else {
            LyricsE2ELog.log("SESSION adopt persisted REJECT identity mismatch")
            return
        }
        cancelCurrentRequest()
        revision &+= 1
        activeLyricsVersionID = versionID
        applyLoadedDocument(document, identity: document.identity, sourceContentHash: sourceContentHash)
        activeSourceContentHash = sourceContentHash
        alignmentProvenanceAvailability = document.source == .automaticAlignment ? .available : .unavailable
        LyricsE2ELog.log("SESSION adopt persisted version=\(versionID.uuidString) source=\(document.source)")
    }


    /// Keep plain lyrics visible while alignment runs.
    public func beginAlignment(identity: TrackIdentity, plain: LyricsDocument) {
        guard activeIdentity == identity else { return }
        cancelCurrentRequest()
        revision &+= 1
        lyrics = plain.lines
        isSynchronized = false
        isNoSelection = false
        state = .alignmentRunning(identity, plain, 0)
        LyricsE2ELog.log("SESSION alignmentRunning start lines=\(plain.lines.count)")
    }

    public func updateAlignmentProgress(identity: TrackIdentity, plain: LyricsDocument, progress: Double) {
        guard activeIdentity == identity else { return }
        if case .alignmentRunning = state {
            state = .alignmentRunning(identity, plain, min(1, max(0, progress)))
        }
    }

    /// Preview timed lyrics without committing as final locked/synced state.
    public func presentAlignmentPreview(
        identity: TrackIdentity,
        plain: LyricsDocument,
        timed: LyricsDocument,
        report: AlignmentReport
    ) {
        guard activeIdentity == identity else { return }
        cancelCurrentRequest()
        revision &+= 1
        lyrics = timed.lines
        isSynchronized = true // allow scrub preview; still marked as preview in state
        isNoSelection = false
        state = .alignmentPreview(identity, plain: plain, timed: timed, report: report)
        LyricsE2ELog.log("SESSION alignmentPreview lines=\(timed.lines.count) overall=\(report.overallConfidence) low=\(report.lowConfidenceCount)")
    }

    public func cancelAlignmentPreview(identity: TrackIdentity, plain: LyricsDocument) {
        guard activeIdentity == identity else { return }
        cancelCurrentRequest()
        revision &+= 1
        applyLoadedDocument(plain, identity: identity)
        LyricsE2ELog.log("SESSION alignmentPreview cancelled -> plain")
    }

    public func confirmAlignment(
        identity: TrackIdentity,
        timed: LyricsDocument,
        report: AlignmentReport,
        saveLocal: Bool
    ) async throws -> URL? {
        guard activeIdentity == identity else { throw AlignmentError.identityMismatch }
        guard case .alignmentPreview = state else { throw AlignmentError.failed("排轴预览已经失效") }
        cancelCurrentRequest()
        let confirmed = LyricsDocument(
            identity: timed.identity,
            title: timed.title,
            artist: timed.artist,
            album: timed.album,
            duration: timed.duration,
            lines: timed.lines,
            isSynchronized: true,
            source: .automaticAlignment,
            confidence: report.overallConfidence,
            providerSourceID: timed.providerSourceID
        )

        guard let repository else {
            throw LyricsRepositoryError.unavailable("排轴确认需要可用的 SQLite 歌词仓库")
        }
        guard let activeTrack else {
            throw AlignmentError.identityMismatch
        }
        guard let parentVersionID = report.sourceVersionID ?? activeLyricsVersionID,
              let parentSourceHash = report.sourceContentHash ?? activeSourceContentHash,
              !parentSourceHash.isEmpty else {
            throw LyricsRepositoryError.invalidData("排轴缺少父歌词版本或源内容指纹")
        }

        let saved = try await repository.saveAlignedVersion(
            AlignmentPersistenceRequest(
                track: activeTrack,
                identity: identity,
                parentVersionID: parentVersionID,
                parentSourceContentHash: parentSourceHash,
                document: confirmed,
                report: report,
                lockResult: false
            )
        )
        guard let versionID = saved.versionID else {
            throw LyricsRepositoryError.invalidData("排轴版本未写入：\(saved.disposition)")
        }
        switch saved.disposition {
        case .inserted, .duplicate:
            break
        default:
            throw LyricsRepositoryError.invalidData("排轴版本未写入：\(saved.disposition)")
        }
        let savedVersionID = versionID
        let savedSourceHash = saved.sourceContentHash ?? LyricsPersistenceMapper.sourceContentHash(document: confirmed)
        let savedProvenanceAvailability = await repository.alignmentProvenanceAvailability(versionID: savedVersionID)

        guard activeIdentity == identity else { throw AlignmentError.identityMismatch }
        revision &+= 1
        activeLyricsVersionID = savedVersionID
        activeSourceContentHash = savedSourceHash
        alignmentProvenanceAvailability = savedProvenanceAvailability
        lyrics = confirmed.lines
        isSynchronized = true
        isNoSelection = false
        state = .loaded(confirmed)
        LyricsE2ELog.log("SESSION alignment confirmed lines=\(confirmed.lines.count) version=\(savedVersionID.uuidString)")
        guard saveLocal else { return nil }
        return try LocalAlignedLyricsStore.save(
            document: confirmed,
            report: report,
            manuallyCorrected: false,
            versionID: savedVersionID
        )
    }

    private func applyLoadedDocument(
        _ document: LyricsDocument,
        identity: TrackIdentity,
        sourceContentHash: String? = nil
    ) {
        isNoSelection = false
        isMarkedInstrumental = false
        let enrichedLines = LyricsLayerEnricher.enrich(lines: document.lines)
        let inferredLanguage = document.language ?? LyricsLanguageGate.inferredLanguage(
            text: enrichedLines.map(\.originalText).joined(separator: "\n")
        )
        let enriched = document.replacingLines(enrichedLines, language: inferredLanguage)
        lyrics = enriched.lines
        let bindingToken = sourceContentHash ?? LyricsPersistenceMapper.sourceContentHash(document: document)
#if DEBUG
        debugLyricsBindingToken = bindingToken
#endif
        isSynchronized = enriched.isSynchronized
        activeSourceContentHash = bindingToken
        if enriched.lines.isEmpty {
#if DEBUG
            debugLyricsBindingToken = nil
#endif
            state = .noLyrics(identity)
            LyricsE2ELog.log("SESSION apply empty -> noLyrics source=\(enriched.source)")
        } else if enriched.isSynchronized {
            state = .loaded(enriched)
            LyricsE2ELog.log("SESSION apply loaded source=\(enriched.source) lines=\(enriched.lines.count) first=\(enriched.lines.first?.originalText ?? "")")
        } else {
            // Plain text: show full lyrics, never fake synced scrolling.
            state = .alignmentQueued(identity, enriched)
            LyricsE2ELog.log("SESSION apply alignmentQueued source=\(enriched.source) lines=\(enriched.lines.count) first=\(enriched.lines.first?.originalText ?? "")")
        }
#if DEBUG
        let nowIso = ISO8601DateFormatter().string(from: Date())
        let reqSid = TrackIdentity.canonicalSpotifyTrackID(identity.spotifyTrackID) ?? identity.spotifyTrackID ?? "none"
        let docSid = TrackIdentity.canonicalSpotifyTrackID(enriched.spotifyTrackID) ?? enriched.spotifyTrackID ?? "none"
        let docBindingToken = debugLyricsBindingToken ?? "none"
        let verId = activeLyricsVersionID?.uuidString ?? "none"
        var totalSpans = 0
        for l in enriched.lines {
            totalSpans += l.timedSpans?.count ?? 0
        }
        print("[RuntimeLyricsAdopted] timestamp=\(nowIso) sessionGeneration=\(revision) requestSpotifyTrackID=\(reqSid) requestLyricsIdentity=\(identity.stableKey) adoptedDocumentSpotifyTrackID=\(docSid) adoptedDocumentBindingToken=\(docBindingToken) lyricsVersionID=\(verId) source=\(enriched.source.rawValue) lineCount=\(enriched.lines.count) timedSpanCount=\(totalSpans)")
#endif
    }

    private func apply(
        _ result: LyricsLookupResult,
        identity: TrackIdentity,
        requestRevision: UInt64,
        sourceContentHash: String? = nil
    ) {
        guard activeIdentity == identity, revision == requestRevision else {
            LyricsE2ELog.log("SESSION drop stale result rev=\(requestRevision) current=\(revision)")
            return
        }

        switch result {
        case .match(let document):
            guard document.identity == identity else {
                lyrics = []
        availableCandidates = []
#if DEBUG
                debugLyricsBindingToken = nil
#endif
                state = .failed(identity, .unknown("歌词身份与当前歌曲不一致"))
                LyricsE2ELog.log("SESSION match identity mismatch")
                return
            }
            applyLoadedDocument(document, identity: identity, sourceContentHash: sourceContentHash)
        case .candidates(let candidates):
            lyrics = []
            availableCandidates = candidates
#if DEBUG
            debugLyricsBindingToken = nil
#endif
            isSynchronized = true
            state = .candidates(identity, candidates)
            LyricsE2ELog.log("SESSION candidates count=\(candidates.count)")
#if DEBUG
            let nowIso = ISO8601DateFormatter().string(from: Date())
            let reqSid = TrackIdentity.canonicalSpotifyTrackID(identity.spotifyTrackID) ?? identity.spotifyTrackID ?? "none"
            print("[RuntimeLyricsEmpty] timestamp=\(nowIso) sessionGeneration=\(revision) requestSpotifyTrackID=\(reqSid) requestLyricsIdentity=\(identity.stableKey) reason=candidates(\(candidates.count))")
#endif
        case .noLyrics:
            lyrics = []
        availableCandidates = []
#if DEBUG
            debugLyricsBindingToken = nil
#endif
            isSynchronized = true
            state = .noLyrics(identity)
            LyricsE2ELog.log("SESSION noLyrics")
#if DEBUG
            let nowIso = ISO8601DateFormatter().string(from: Date())
            let reqSid = TrackIdentity.canonicalSpotifyTrackID(identity.spotifyTrackID) ?? identity.spotifyTrackID ?? "none"
            print("[RuntimeLyricsEmpty] timestamp=\(nowIso) sessionGeneration=\(revision) requestSpotifyTrackID=\(reqSid) requestLyricsIdentity=\(identity.stableKey) reason=noLyrics")
#endif
        case .noMatch:
            lyrics = []
        availableCandidates = []
#if DEBUG
            debugLyricsBindingToken = nil
#endif
            isSynchronized = true
            state = .noMatch(identity)
            LyricsE2ELog.log("SESSION noMatch")
#if DEBUG
            let nowIso = ISO8601DateFormatter().string(from: Date())
            let reqSid = TrackIdentity.canonicalSpotifyTrackID(identity.spotifyTrackID) ?? identity.spotifyTrackID ?? "none"
            print("[RuntimeLyricsEmpty] timestamp=\(nowIso) sessionGeneration=\(revision) requestSpotifyTrackID=\(reqSid) requestLyricsIdentity=\(identity.stableKey) reason=noMatch")
#endif
        case .failed(let failure):
            lyrics = []
        availableCandidates = []
#if DEBUG
            debugLyricsBindingToken = nil
#endif
            isSynchronized = true
            state = .failed(identity, failure)
            LyricsE2ELog.log("SESSION failed \(failure)")
            if !automaticSearchDisabledForCurrentTrack, !isNoSelection, let activeTrack {
                switch failure {
                case .timedOut: scheduleRecovery(track: activeTrack, identity: identity, revision: requestRevision)
                case .serverError(let code) where (500...599).contains(code):
                    scheduleRecovery(track: activeTrack, identity: identity, revision: requestRevision)
                default: break // Offline waits for NWPath; identity/no lyrics never retry.
                }
            }
#if DEBUG
            let nowIso = ISO8601DateFormatter().string(from: Date())
            let reqSid = TrackIdentity.canonicalSpotifyTrackID(identity.spotifyTrackID) ?? identity.spotifyTrackID ?? "none"
            print("[RuntimeLyricsEmpty] timestamp=\(nowIso) sessionGeneration=\(revision) requestSpotifyTrackID=\(reqSid) requestLyricsIdentity=\(identity.stableKey) reason=failed")
#endif
        }
    }

    private func cancelCurrentRequest() {
        isSearchInProgress = false
        isSearchingAdditionalVersions = false
        additionalVersionsMessage = ""
        requestTask?.cancel()
        requestTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private static func shouldRetrySourceFailures(_ result: LyricsLookupResult) -> Bool {
        switch result {
        case .candidates, .noLyrics, .noMatch: return true
        case .match, .failed: return false
        }
    }

    private static func retryableProviders(in diagnostics: [LyricsProviderDiagnostic]) -> Set<String> {
        var providers = Set<String>()
        for diagnostic in diagnostics {
            guard case .failed(let failure) = diagnostic.outcome, isRetryable(failure) else { continue }
            providers.insert(diagnostic.provider.components(separatedBy: "@").first ?? diagnostic.provider)
        }
        return providers
    }

    private static func isRetryable(_ failure: LyricsFailure) -> Bool {
        switch failure {
        case .timedOut, .networkUnavailable: return true
        case .serverError(let code): return (500...599).contains(code)
        default: return false
        }
    }

    private var awaitsSourceRetry: Bool {
        switch state {
        case .candidates, .noLyrics, .noMatch: return true
        default: return false
        }
    }

    private func scheduleSourceRetry(
        track: Track,
        identity: TrackIdentity,
        revision expectedRevision: UInt64,
        providers: Set<String>,
        queryOverride: String?,
        aliases: [TrackAlias]
    ) {
        retryTask?.cancel()
        guard retriedIdentity != identity else { return }
        retriedIdentity = identity
        let delay = sourceRetryDelay
        LyricsE2ELog.log("SESSION source retry scheduled delay=\(delay)s providers=\(providers.sorted()) rev=\(expectedRevision)")
        retryTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
            guard let self, !Task.isCancelled,
                  self.activeIdentity == identity,
                  self.revision == expectedRevision,
                  self.activeLyricsVersionID == nil,
                  !self.isSearchInProgress,
                  self.awaitsSourceRetry else { return }

            let started = Date()
            let outcome = await self.searchManager.search(
                track: track,
                identity: identity,
                queryOverride: queryOverride,
                forceRefresh: true,
                aliases: aliases,
                onlyProviders: providers
            )
            let duration = Date().timeIntervalSince(started)
            guard !Task.isCancelled, self.activeIdentity == identity, self.revision == expectedRevision else { return }

            var adopted = false
            switch outcome.result {
            case .match(let document):
                if self.activeLyricsVersionID == nil,
                   self.awaitsSourceRetry,
                   document.identity == identity,
                   !document.lines.isEmpty {
                    self.apply(.match(document), identity: identity, requestRevision: expectedRevision)
                    adopted = true
                    await self.saveRetriedMatch(document, track: track, identity: identity, decision: outcome.automaticDecision)
                }
            case .candidates(let candidates):
                self.mergeRetriedCandidates(candidates, identity: identity)
            case .noLyrics, .noMatch, .failed:
                break
            }

            let outcomeLabel: String
            if case .match = outcome.result {
                outcomeLabel = adopted ? "adopted" : "review"
            } else {
                outcomeLabel = LyricsSourceStats.outcome(for: outcome.result)
            }
            self.sourceStats.record(
                spotifyID: identity.spotifyTrackID,
                totalSeconds: duration,
                result: outcome.result,
                retry: true,
                diagnostics: outcome.diagnostics,
                outcome: outcomeLabel
            )
            self.retryTask = nil
        }
    }

    private func saveRetriedMatch(
        _ document: LyricsDocument,
        track: Track,
        identity: TrackIdentity,
        decision: LyricsMatchDecision?
    ) async {
        guard let repository,
              decision != nil || LyricsMatcher.isHighConfidence(document.confidence) else { return }
        let expectedRevision = revision
        do {
            let saved: LyricsPersistenceSaveResult?
            if let decision {
                saved = try await repository.saveAutomaticallySelected(
                    track: track,
                    identity: identity,
                    document: document,
                    decision: LyricsAutomaticSelectionEvidence(
                        identity: identity,
                        tier: decision.tier.rawValue,
                        hardReject: decision.hardReject,
                        versionConflict: decision.versionConflict
                    )
                )
            } else {
                saved = try await repository.save(track: track, identity: identity, document: document)
            }
            if let saved, saved.versionID != nil,
               activeIdentity == identity, revision == expectedRevision {
                activeLyricsVersionID = saved.versionID
                activeSourceContentHash = saved.sourceContentHash
            }
        } catch {
            LyricsE2ELog.log("SESSION retry persistence failed error=\(error.localizedDescription)")
        }
    }

    private func mergeRetriedCandidates(_ candidates: [LyricsCandidate], identity: TrackIdentity) {
        var merged = Dictionary(availableCandidates.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for candidate in candidates where candidate.identity == identity {
            merged[candidate.id] = candidate
        }
        let sorted = merged.values.sorted(by: LyricsCandidate.hasPrecedence)
        availableCandidates = sorted
        if case .candidates = state {
            state = .candidates(identity, sorted)
        }
    }

    private func scheduleRecovery(track: Track, identity: TrackIdentity, revision expectedRevision: UInt64) {
        guard recoveryTask == nil, recoveryAttempts < recoveryCooldowns.count else { return }
        let delay = recoveryCooldowns[recoveryAttempts]
        LyricsE2ELog.log("SESSION recovery scheduled attempt=\(recoveryAttempts + 1) cooldown=\(delay)s rev=\(expectedRevision)")
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled, self.activeIdentity == identity, self.revision == expectedRevision,
                  !self.automaticSearchDisabledForCurrentTrack, !self.isNoSelection,
                  case .failed(let failedIdentity, let failure) = self.state, failedIdentity == identity else { return }
            switch failure {
            case .timedOut, .networkUnavailable: break
            case .serverError(let code) where (500...599).contains(code): break
            default: return
            }
            self.recoveryTask = nil
            self.recoveryAttempts += 1
            self.isRecoveryAttempt = true
            self.begin(track: track, identity: identity, forceRefresh: true)
            self.isRecoveryAttempt = false
        }
    }

    private static func normalizedQuery(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistAdoptedDocument(_ document: LyricsDocument) {
        guard let repository, let activeTrack,
              activeIdentity == document.identity,
              !document.lines.isEmpty else { return }
        let identity = document.identity
        let expectedRevision = revision
        Task { [weak self] in
            do {
                let result = try await repository.save(
                    track: activeTrack,
                    identity: identity,
                    document: document
                )
                LyricsE2ELog.log(
                    "SESSION adopted persistence disposition=\(String(describing: result.disposition)) source=\(document.source) lines=\(document.lines.count)"
                )
                if let versionID = result.versionID {
                    await MainActor.run { [weak self] in
                        guard let self, self.activeIdentity == identity, self.revision == expectedRevision else { return }
                        self.activeLyricsVersionID = versionID
                        self.activeSourceContentHash = result.sourceContentHash
                    }
                }
            } catch {
                LyricsE2ELog.log("PERSISTENCE adopted save failed error=\(error.localizedDescription)")
                await MainActor.run {
                    guard let self, self.activeIdentity == identity, self.revision == expectedRevision else { return }
                    self.persistenceStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private static func describe(_ result: LyricsLookupResult) -> String {
        switch result {
        case .match(let d): return "match(\(d.source),lines=\(d.lines.count),sync=\(d.isSynchronized))"
        case .candidates(let c): return "candidates(\(c.count))"
        case .noLyrics: return "noLyrics"
        case .noMatch: return "noMatch"
        case .failed(let f): return "failed(\(f))"
        }
    }

    private static func describeDiag(_ o: LyricsProviderDiagnostic.Outcome) -> String {
        switch o {
        case .match: return "match"
        case .candidates(let n): return "candidates(\(n))"
        case .noLyrics: return "noLyrics"
        case .noMatch: return "noMatch"
        case .failed(let f): return "failed(\(f))"
        }
    }
}
