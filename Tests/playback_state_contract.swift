import Foundation

/// The playback slice contract does not compile the capture/alignment graph.
/// Keep a protocol-shaped stand-in so PlaybackState can still be tested in
/// isolation when it notifies the product controller.
@MainActor
final class AutomaticAlignmentJobController {
    static let shared = AutomaticAlignmentJobController()

    func bind(playback: PlaybackState) {}
    func notePlaybackContextChanged() {}
    func notifySeek(from: TimeInterval, to: TimeInterval) {}
    func notifyTrackChanged(previousKey: String?, nextKey: String) {}
    func notifyPlaybackSourceChanged(previous: PlaybackSourceIdentity, next: PlaybackSourceIdentity) {}
}

/// The playback contract does not exercise audio capture. Keep its unrelated
/// Assist collaborator isolated so this focused slice does not compile or run
/// the ScreenCaptureKit pipeline.
struct PartialAlignmentReport {
    struct Candidate {
        let captureSessionID: UUID
    }

    let candidate: Candidate
}

@MainActor
final class LiveCaptureCoordinator {
    enum State { case idle, running, stopping, failed }
    enum PartialAlignmentFailureKind: String {
        case startIgnored, unsupportedSource, captureFailed, noCompletedSession
        case noWavSegments, noLyrics, noPlayback, speechFailed, alignmentFailed
        case cancelled, emptyTranscript, insufficientSuggestions, unknown
    }
    enum StopReason { case userStop, trackChanged }

    struct PartialAlignmentHandoff {
        let generation: UInt64
        let report: PartialAlignmentReport?
        let failureKind: PartialAlignmentFailureKind?
        let message: String?
    }

    static let shared = LiveCaptureCoordinator()
    var state: State = .idle
    var lastError: String?
    var lastStartedGeneration: UInt64 = 0
    var lastAlignmentHandoff: PartialAlignmentHandoff?
    var lastPartialReport: PartialAlignmentReport?

    func bind(playback: PlaybackState) {}
    func start(autoStopAfter: TimeInterval, runPartialAlignment: Bool) async {}
    func waitUntilIdle(timeoutSeconds: TimeInterval) async {}
    func stop(reason: StopReason) async {}
}

enum AssistedCandidateMerger {
    static func merge(report: PartialAlignmentReport, plainLines: [LyricLine]) -> AssistedAlignmentDraft {
        AssistedAlignmentDraft(
            trackIdentityDigest: "",
            captureSessionID: report.candidate.captureSessionID,
            plainLineCount: plainLines.count,
            lines: [],
            usedConstrainedAlignment: false,
            s3bFallbackReason: nil,
            judgment: "not exercised by playback state contract"
        )
    }
}

@MainActor
private final class ScriptedPlaybackProvider: PlaybackProvider {
    let displayName = "scripted-playback"
    private(set) var commandLog: [String] = []
    private(set) var refreshCalls = 0
    var snapshot: PlaybackSnapshot

    init(snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
    }

    func refresh() async -> PlaybackSnapshot {
        refreshCalls += 1
        return snapshot
    }

    func play() async throws {
        commandLog.append("play")
        snapshot = PlaybackSnapshot(
            status: snapshot.status,
            track: snapshot.track,
            position: snapshot.position,
            isPlaying: true
        )
    }

    func pause() async throws {
        commandLog.append("pause")
        snapshot = PlaybackSnapshot(
            status: snapshot.status,
            track: snapshot.track,
            position: snapshot.position,
            isPlaying: false
        )
    }

    func previous() async throws {
        commandLog.append("previous")
    }

    func next() async throws {
        commandLog.append("next")
    }

    func seek(to position: TimeInterval) async throws {
        commandLog.append("seek:\(Int(position))")
        snapshot = PlaybackSnapshot(
            status: snapshot.status,
            track: snapshot.track,
            position: position,
            isPlaying: snapshot.isPlaying
        )
    }
}

private actor CountingLyricsProvider: LyricsProvider {
    nonisolated let name = "counting-lyrics-test"
    private(set) var lookupCalls = 0
    private let lookupStartedStream: AsyncStream<Void>
    private let lookupStartedContinuation: AsyncStream<Void>.Continuation

    init() {
        let lookupStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.lookupStartedStream = lookupStarted.stream
        self.lookupStartedContinuation = lookupStarted.continuation
    }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        lookupCalls += 1
        lookupStartedContinuation.yield(())
        lookupStartedContinuation.finish()
        return .noLyrics
    }

    func waitForLookup(timeoutNanoseconds: UInt64) async -> Bool {
        let stream = lookupStartedStream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                } catch {
                    return false
                }
            }

            let didLookupStart = await group.next() ?? false
            group.cancelAll()
            return didLookupStart
        }
    }
}

@MainActor
private final class DelayedRefreshProvider: PlaybackProvider {
    let displayName = "delayed-refresh"
    let staleSnapshot: PlaybackSnapshot
    var latestSnapshot: PlaybackSnapshot
    private var refreshCount = 0

    init(staleSnapshot: PlaybackSnapshot, latestSnapshot: PlaybackSnapshot) {
        self.staleSnapshot = staleSnapshot
        self.latestSnapshot = latestSnapshot
    }

    func refresh() async -> PlaybackSnapshot {
        refreshCount += 1
        if refreshCount == 1 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return staleSnapshot
        }
        return latestSnapshot
    }

    func play() async throws {}
    func pause() async throws {}
    func previous() async throws {}
    func next() async throws {}
    func seek(to position: TimeInterval) async throws {}
}

private struct NoLyricsProvider: LyricsProvider {
    var name: String { "no-lyrics-test" }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        .noLyrics
    }
}

private struct NetworkFailureLyricsProvider: LyricsProvider {
    var name: String { "network-failure-test" }

    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        .failed(.networkUnavailable)
    }
}

private actor PreviewFixtureProvider: LyricsProvider {
    nonisolated let name = "preview-isolated-fixture"
    var scenario = "noLyrics"
    func setScenario(_ value: String) { scenario = value }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        switch scenario {
        case "noMatch": return .noMatch
        case "failed": return .failed(.networkUnavailable)
        case "candidates":
            return .candidates([LyricsCandidate(id: "uncertain-preview-guest", identity: identity,
                title: track.title + " feat Unverified", artist: track.artist, album: track.album,
                duration: track.duration, lines: [LyricLine(timestamp: 0, originalText: "Self-authored preview text")],
                source: .lrclib, confidence: 0.3)])
        default: return .noLyrics
        }
    }
}

@main
@MainActor
struct PlaybackStateContract {
    static func previewOperationContract(root: URL, providerTrack: ProviderTrack) async throws {
        let suite = "LyricsQPreviewSafety-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        settings.aiTranslationConfiguration.autoTranslateNewLyrics = false
        settings.playbackSourceMode = .spotify
        settings.autoSearchLyricsOnTrackChange = false
        let repo = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("preview.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("preview-provenance"))
        try await repo.prepare()
        let provider = ScriptedPlaybackProvider(snapshot: PlaybackSnapshot(status: .ready,
            track: providerTrack, position: 11, isPlaying: false))
        let fixture = PreviewFixtureProvider()
        let state = PlaybackState(provider: provider, lyricsProvider: fixture, lyricsRepository: repo, settings: settings)
        state.startProvider(connectSpotify: false); state.reconnectSpotify()
        let deadline = Date().addingTimeInterval(2)
        while !state.hasLiveTrack && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(state.hasLiveTrack)
        let live = state.currentTrack, identity = state.currentTrackIdentity!
        let candidate = LyricsCandidate(id: "old-live-sheet", identity: identity, title: live.title,
            artist: live.artist, album: live.album, duration: live.duration,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored live candidate")],
            source: .manualImport, confidence: 1)
        let preview = Track(title: "Preview only", artist: "Fixture", album: "Synthetic", duration: 60, spotifyId: "preview-only")
        for scenario in ["noLyrics", "noMatch", "failed", "candidates"] {
            await fixture.setScenario(scenario)
            let previewTrack = Track(title: preview.title, artist: preview.artist, album: preview.album,
                duration: preview.duration, spotifyId: "preview-" + scenario)
            state.loadSearchResult(SongSearchResult(id: "preview-" + scenario, source: .local, track: previewTrack, confidence: 1))
            let waiting = Date().addingTimeInterval(2)
            var observed = "loading"
            while Date() < waiting {
                switch state.lyricsState {
                case .noLyrics: observed = "noLyrics"
                case .noMatch: observed = "noMatch"
                case .failed: observed = "failed"
                case .candidates: observed = "candidates"
                default: break
                }
                if observed == scenario { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(observed == scenario, "fixture expected \(scenario), got \(observed)")
            precondition(state.isShowingSearchPreview && state.displayedTrack == previewTrack)
            let before = try await repo.loadEditableVersions(track: live, identity: identity)
            let revision = state.liveLyricsSessionRevision
            state.markCurrentTrackAsInstrumental()
            state.clearCurrentInstrumentalMark()
            precondition(!state.liveTrackIsMarkedInstrumental && state.liveLyricsSessionRevision == revision,
                "search preview must not mark or clear the live track as instrumental")
            let rejected = try await state.adoptLyricsCandidate(candidate)
            precondition(rejected.versionID == nil, "old live candidate callback during preview must not write live")
            let after = try await repo.loadEditableVersions(track: live, identity: identity)
            precondition(after.count == before.count && state.liveLyricsSessionRevision == revision)
            precondition(state.currentTrack == live && provider.commandLog.isEmpty)
            precondition(!settings.aiTranslationConfiguration.isConfigured && !settings.aiTranslationConfiguration.autoTranslateNewLyrics)
            print("PASS preview \(scenario): stale live candidate rejected; synthetic live rows/revision/playback unchanged; paid requests=0")
        }
        state.clearSearchPreview()
        let accepted = try await state.adoptLyricsCandidate(candidate)
        precondition(accepted.versionID != nil, "live candidate action must recover after ending preview")
        try await repo.markLyricsVersionLocked(versionID: accepted.versionID!, locked: true)
        let replacement = LyricsCandidate(id: "locked-live-confirmation", identity: identity, title: live.title,
            artist: live.artist, album: live.album, duration: live.duration,
            lines: [LyricLine(timestamp: 0, originalText: "Self-authored replacement candidate")],
            source: .manualImport, confidence: 1)
        let conflict = try await state.adoptLyricsCandidate(replacement)
        guard case .lockedConflict = conflict.disposition else { fatalError("private locked conflict required") }
        state.loadSearchResult(SongSearchResult(id: "pending-preview", source: .local, track: preview, confidence: 1))
        let countBefore = try await repo.loadEditableVersions(track: live, identity: identity).count
        let revisionBefore = state.liveLyricsSessionRevision
        let blockedConfirmation = try await state.confirmPendingManualLyricsAdoption()
        precondition(blockedConfirmation == nil, "old live locked confirmation must not commit while preview is shown")
        let countAfter = try await repo.loadEditableVersions(track: live, identity: identity).count
        precondition(countAfter == countBefore && state.liveLyricsSessionRevision == revisionBefore)
        state.clearSearchPreview()
        let confirmed = try await state.confirmPendingManualLyricsAdoption()
        precondition(confirmed?.versionID != nil, "explicit live locked confirmation restores after preview")
        let oldLocked = try await repo.loadEditableVersion(versionID: accepted.versionID!, track: live, identity: identity)
        precondition(oldLocked?.document.lines.map(\.originalText) == candidate.lines.map(\.originalText))
        precondition(oldLocked?.record.isLocked == true, "protected old locked original retained")
        print("PASS pending live locked confirmation: preview blocked before write; after preview explicit confirm restores; old locked original retained")
        let beforeSearchRevision = state.liveLyricsSessionRevision
        await state.songSearchManager.search(query: SongSearchQuery(text: "Self-authored replacement"))?.value
        guard case .results(_, let savedResults) = state.songSearchManager.state else { fatalError("saved lyrics must be searchable without Spotify Client ID") }
        precondition(savedResults.contains { $0.id.hasPrefix("library:") && $0.track.title == live.title && $0.lyrics == nil })
        precondition(!state.isShowingSearchPreview && state.liveLyricsSessionRevision == beforeSearchRevision && provider.commandLog.isEmpty,
            "search alone must not change current selection, preview or playback")
        print("PASS PlaybackState saved-library search works without Spotify configuration and only returns metadata")
        state.selectNoLyricsVersion()
        precondition(state.isLyricsSelectionEmpty && state.canCreateManualLyrics)
        precondition(state.prepareBlankLyricsEditor(), "manual creation must restore for live empty state")
        state.markCurrentTrackAsInstrumental()
        precondition(state.liveTrackIsMarkedInstrumental && state.liveLyricsVersionID == nil
            && state.liveLyrics.first?.originalText == "此歌曲为没有填词的纯音乐，请您欣赏")
        state.clearCurrentInstrumentalMark()
        for _ in 0..<200 where state.lyricsSession.isSearchInProgress { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(!state.liveTrackIsMarkedInstrumental && state.liveLyricsVersionID == confirmed?.versionID,
            "undo instrumental mark must restore the previously selected saved version")
        state.selectNoLyricsVersion()
        precondition(state.isLyricsSelectionEmpty)
        print("PASS preview ended: live candidate/none/manual editor/instrumental actions restore; no App/player/paid engine")

        let previewIdentity = TrackIdentity(track: preview)
        let previewDocument = LyricsDocument(identity: previewIdentity, title: preview.title, artist: preview.artist,
            album: preview.album, duration: preview.duration,
            lines: [LyricLine(timestamp: 2, originalText: "Self-authored explicit preview adoption")],
            source: .manualImport, confidence: 1, providerSourceID: "explicit-preview-fixture")
        _ = try await repo.save(track: preview, identity: previewIdentity, document: previewDocument)
        let previewResult = SongSearchResult(id: "explicit-preview-fixture", source: .local, track: preview, confidence: 1)
        func openReadyPreview() async throws {
            state.loadSearchResult(previewResult)
            for _ in 0..<200 {
                if state.lyricsState.document?.lines.first?.originalText == previewDocument.lines.first?.originalText { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            preconditionFailure("stored explicit preview did not load")
        }
        for staleContext in ["new-preview-generation", "preview-closed", "live-track-changed"] {
            try await openReadyPreview()
            let pendingPreview = try await state.adoptSearchPreviewLyrics()
            precondition(pendingPreview?.disposition == .lockedConflict, "preview-to-live must require explicit lock confirmation")
            let versionsBefore = try await repo.loadEditableVersions(track: live, identity: identity).map(\.record.id)
            let selectionBefore = try await repo.loadBestStored(track: live, identity: identity)?.versionID
            switch staleContext {
            case "new-preview-generation": state.loadSearchResult(previewResult)
            case "preview-closed": state.clearSearchPreview()
            default:
                provider.snapshot = PlaybackSnapshot(status: .ready,
                    track: ProviderTrack(id: "different-live-fixture", title: "Other Live", artist: "Other", album: "Fixture", duration: 90),
                    position: 3, isPlaying: false)
                state.reconnectSpotify()
                for _ in 0..<200 where state.currentTrack.title != "Other Live" { try await Task.sleep(nanoseconds: 5_000_000) }
                precondition(state.currentTrack.title == "Other Live")
            }
            let rejected = try await state.confirmPendingManualLyricsAdoption()
            precondition(rejected == nil, "stale preview-to-live confirmation must be rejected: \(staleContext)")
            let versionsAfter = try await repo.loadEditableVersions(track: live, identity: identity).map(\.record.id)
            let selectionAfter = try await repo.loadBestStored(track: live, identity: identity)?.versionID
            precondition(versionsAfter == versionsBefore && selectionAfter == selectionBefore,
                "stale confirmation changed stored assets or selection")
            state.cancelPendingManualLyricsAdoption()
            state.clearSearchPreview()
            if staleContext == "live-track-changed" {
                provider.snapshot = PlaybackSnapshot(status: .ready, track: providerTrack, position: 11, isPlaying: false)
                state.reconnectSpotify()
                for _ in 0..<200 where state.currentTrackIdentity != identity { try await Task.sleep(nanoseconds: 5_000_000) }
                precondition(state.currentTrackIdentity == identity)
            }
        }
        try await openReadyPreview()
        let previewConflict = try await state.adoptSearchPreviewLyrics()
        precondition(previewConflict?.disposition == .lockedConflict, "expected current preview lock conflict")
        let previewConfirmed = try await state.confirmPendingManualLyricsAdoption()
        precondition(previewConfirmed?.versionID != nil && !state.isShowingSearchPreview,
            "explicit confirmation must adopt the current preview and return to live")
        precondition(state.liveLyricsVersionID == previewConfirmed?.versionID
            && state.liveLyrics.first?.originalText == previewDocument.lines.first?.originalText,
            "confirmed preview lyrics did not enter the live session")
        let retainedLock = try await repo.loadEditableVersion(versionID: accepted.versionID!, track: live, identity: identity)
        precondition(retainedLock?.record.isLocked == true && retainedLock?.document.lines.map(\.originalText) == candidate.lines.map(\.originalText))
        let reopened = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("preview.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("preview-provenance"))
        try await reopened.prepare()
        let reopenedChoice = try await reopened.loadBestStored(track: live, identity: identity)
        precondition(reopenedChoice?.versionID == previewConfirmed?.versionID && provider.commandLog.isEmpty)
        print("PASS current preview-to-live lock confirmation adopts, returns live and survives reopen; old live/new preview/closed preview/changed live blocked; prior locked asset retained")
    }

    static func selectionDefaultsContract(root: URL, providerTrack: ProviderTrack) async throws {
        let suite = "LyricsQPlaybackSelection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        precondition(defaults.persistentDomain(forName: suite) == nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        precondition(settings.translationSelectionDefaults === defaults, "must reuse injected defaults object")
        settings.aiTranslationConfiguration.autoTranslateNewLyrics = false
        settings.playbackSourceMode = .spotify
        settings.autoSearchLyricsOnTrackChange = false
        precondition(!settings.aiTranslationConfiguration.autoTranslateNewLyrics && !settings.aiTranslationConfiguration.isConfigured)
        let url = root.appendingPathComponent("selection.sqlite3")
        precondition(!FileManager.default.fileExists(atPath: url.path))
        let provenance = root.appendingPathComponent("selection-provenance")
        let repo = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await repo.prepare()
        func makeState(_ repository: SQLiteLyricsRepository, _ store: AppSettingsStore) async throws -> PlaybackState {
            let provider = ScriptedPlaybackProvider(snapshot: PlaybackSnapshot(status: .ready,
                track: providerTrack, position: 0, isPlaying: false))
            let state = PlaybackState(provider: provider, lyricsProvider: NoLyricsProvider(), lyricsRepository: repository, settings: store)
            state.startProvider(connectSpotify: false)
            state.reconnectSpotify()
            let deadline = Date().addingTimeInterval(2)
            while !state.hasLiveTrack && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(state.hasLiveTrack && state.currentTrackIdentity != nil)
            return state
        }
        let first = try await makeState(repo, settings)
        let track = first.currentTrack, identity = first.currentTrackIdentity!
        let document = LyricsDocument(identity: identity, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, lines: [LyricLine(timestamp: 0, originalText: "synthetic original")],
            isSynchronized: true, source: .lrclib, confidence: 1, providerSourceID: "selection-fixture")
        let source = try await repo.save(track: track, identity: identity, document: document)
        let versionID = source.versionID!, hash = source.sourceContentHash!
        let language = settings.aiTranslationConfiguration.targetLanguage
        func save(_ text: String, manual: Bool) async throws -> StoredTranslationVersion {
            let draft = AITranslationDraft(lines: [AITranslationLine(index: 0, translation: text)],
                targetLanguage: language, model: "fixture", baseURLHost: "fixture", promptHash: text,
                sourceContentHash: hash, sourceKind: manual ? .manualEdit : .ai,
                isMachineGenerated: !manual, isManuallyEdited: manual)
            let value = try await repo.saveTranslation(lyricsVersionID: versionID, sourceContentHash: hash,
                originalLines: document.lines.map(\.originalText), draft: draft, forceNewVersion: true)
            try await repo.adoptTranslation(versionID: value.record.id)
            return value
        }
        let protected = try await save("protected manual", manual: true)
        try await repo.markTranslationLocked(versionID: protected.record.id, locked: true)
        let alternate = try await save("alternate", manual: false)
        func load(_ state: PlaybackState) async throws {
            state.lyricsSession.adoptPersisted(document: document, versionID: versionID, sourceContentHash: hash)
            let deadline = Date().addingTimeInterval(2)
            while state.translationVersions.count != 2 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(state.translationVersions.count == 2)
        }
        try await load(first)
        precondition(first.selectedTranslation?.record.id == protected.record.id)
        let key = TranslationSessionController.selectionPreferenceKey(trackStableKey: identity.stableKey,
            versionID: versionID, sourceHash: hash, targetLanguage: language)
        first.selectNoTranslationVersion()
        precondition(first.isTranslationSelectionEmpty && defaults.string(forKey: key) == "none")
        let reopened = SQLiteLyricsRepository(databaseURL: url, alignmentProvenanceDirectory: provenance)
        try await reopened.prepare()
        let secondSettings = AppSettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let second = try await makeState(reopened, secondSettings)
        try await load(second)
        precondition(second.isTranslationSelectionEmpty && second.selectedTranslation == nil, "formal controller reconstruction lost none")
        second.selectTranslation(versionID: alternate.record.id)
        precondition(second.selectedTranslation?.record.id == alternate.record.id)
        precondition(defaults.string(forKey: key) == alternate.record.id.uuidString, "formal selection did not persist in injected suite")
        second.restoreRecommendedTranslation()
        let deadline = Date().addingTimeInterval(2)
        while second.selectedTranslation?.record.id != protected.record.id && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(second.selectedTranslation?.record.id == protected.record.id && !second.isTranslationSelectionEmpty)
        precondition(defaults.object(forKey: key) == nil && defaults.object(forKey: "ai.libraryTranslationSelection.v1." + identity.stableKey) == nil)
        precondition(second.translationVersions.contains { $0.record.id == protected.record.id && $0.record.isLocked && $0.record.isManuallyEdited })
        first.cancelTranslation(); second.cancelTranslation()
        print("PASS formal PlaybackState defaults injection: same settings suite; two instances; none/explicit version/recommended clearing; synthetic SQLite/manual locked retained; unconfigured auto=false")
    }

    static func main() async {
        guard let rootPath = ProcessInfo.processInfo.environment["LYRICSQ_M1_PLAYBACK_ROOT"] else {
            fatalError("task-private playback root required")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        precondition(root.lastPathComponent.hasPrefix("lyricsq-m1-playback-"))
        precondition(FileManager.default.fileExists(atPath: root.path))
        precondition(home == root.appendingPathComponent("home"), "preferences must be task isolated")
        let actualDatabase = SQLiteLyricsRepository.defaultDatabaseURL
        let actualParent = actualDatabase.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let normalizedDatabase = actualParent.appendingPathComponent(actualDatabase.lastPathComponent, isDirectory: false)
        let expectedDatabase = root.appendingPathComponent("contract.sqlite3", isDirectory: false)
        let rootAttributes = try! FileManager.default.attributesOfItem(atPath: root.path)
        let homeAttributes = try! FileManager.default.attributesOfItem(atPath: home.path)
#if DEBUG
        print("PREFLIGHT DEBUG=true overrideSet=\(ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DATABASE_PATH"] != nil)")
#else
        fatalError("playback isolation requires DEBUG")
#endif
        print("PREFLIGHT actualRaw=\(actualDatabase.path) actualNormalized=\(normalizedDatabase.path) expectedNormalized=\(expectedDatabase.path) home=\(home.path) rootUID=\(rootAttributes[.ownerAccountID]!)")
        precondition((rootAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        precondition((homeAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        precondition((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition((homeAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        precondition(actualParent.pathComponents == root.pathComponents && normalizedDatabase.pathComponents == expectedDatabase.pathComponents)
        precondition(!FileManager.default.fileExists(atPath: actualDatabase.path), "contract requires a fresh task database")
        precondition(normalizedDatabase.pathComponents != DebugDatabaseSafety.status().formalDatabaseURL.standardizedFileURL.pathComponents)
        precondition(SpotifyOAuthConfiguration.resolved().clientID == nil, "OAuth must be unconfigured before auth initialization")
        print("PASS playback isolation preflight: private home/database; OAuth unconfigured, no token loading")
        let aiDefaultsSuite = "LyricsQAIPrimaryDefaults-\(UUID().uuidString)"
        let aiDefaults = UserDefaults(suiteName: aiDefaultsSuite)!
        precondition(aiDefaults.persistentDomain(forName: aiDefaultsSuite) == nil)
        let freshAISettings = AppSettingsStore(defaults: aiDefaults)
        precondition(freshAISettings.aiTranslationConfiguration.autoTranslateNewLyrics,
            "new settings should automatically translate instead of defaulting to provider Chinese")
        precondition(!freshAISettings.aiTranslationConfiguration.isConfigured,
            "enabling the preference must not invent provider credentials")
        freshAISettings.aiTranslationConfiguration.autoTranslateNewLyrics = false
        let preservedOff = AppSettingsStore(defaults: UserDefaults(suiteName: aiDefaultsSuite)!)
        precondition(!preservedOff.aiTranslationConfiguration.autoTranslateNewLyrics,
            "an explicit off preference must survive reconstruction")
        aiDefaults.removePersistentDomain(forName: aiDefaultsSuite)
        print("PASS AI-first defaults: new auto enabled, explicit off retained, no provider configured")
        let trackA = ProviderTrack(
            id: "spotify:track:a",
            title: "Track A",
            artist: "Artist A",
            album: "Album A",
            duration: 240,
            artworkURL: URL(string: "https://example.test/a.jpg")
        )
        let trackB = ProviderTrack(
            id: "spotify:track:b",
            title: "Track B",
            artist: "Artist B",
            album: "Album B",
            duration: 300,
            artworkURL: URL(string: "https://example.test/b.jpg")
        )

        try! await previewOperationContract(root: root, providerTrack: trackA)
        try! await selectionDefaultsContract(root: root, providerTrack: trackA)

        let startupSuite = ProcessInfo.processInfo.environment["LYRICSQ_PLAYBACK_CONTRACT_SUITE"]
            ?? "LyricsQPlaybackStateContract-\(UUID().uuidString)"
        let startupDefaults = UserDefaults(suiteName: startupSuite)!
        let startupSettings = AppSettingsStore(defaults: startupDefaults)
        startupSettings.playbackSourceMode = .spotify
        startupSettings.autoSearchLyricsOnTrackChange = true
        let startupLyricsProvider = CountingLyricsProvider()
        let startupProvider = ScriptedPlaybackProvider(
            snapshot: PlaybackSnapshot(status: .ready, track: trackA, position: 12, isPlaying: true)
        )
        let startupState = PlaybackState(
            provider: startupProvider,
            lyricsProvider: startupLyricsProvider,
            settings: startupSettings
        )
        startupState.startProvider(connectSpotify: false)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        precondition(startupProvider.refreshCalls == 0, "disabled Spotify startup must not refresh on timer ticks")
        precondition(!startupState.hasLiveTrack, "disabled Spotify startup must not adopt a live track")
        precondition(startupState.currentTrackIdentity == nil, "disabled Spotify startup must not create a live identity")
        let startupLookupCalls = await startupLyricsProvider.lookupCalls
        precondition(startupLookupCalls == 0, "disabled Spotify startup must not query lyrics")

        startupState.reconnectSpotify()
        for _ in 0..<50 {
            if startupProvider.refreshCalls > 0, startupState.hasLiveTrack {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(startupProvider.refreshCalls > 0, "explicit reconnect must refresh the provider")
        precondition(startupState.hasLiveTrack, "explicit reconnect must adopt the authorized track")
        precondition(startupState.currentTrack.title == "Track A")
        precondition(
            startupState.currentTrackIdentity?.stableKey.contains("spotify-id:a") == true,
            "explicit reconnect must adopt Track A identity"
        )
        let lookupStarted = await startupLyricsProvider.waitForLookup(timeoutNanoseconds: 3_000_000_000)
        let reconnectLookupCalls = await startupLyricsProvider.lookupCalls
        let reconnectIdentity = startupState.currentTrackIdentity?.stableKey ?? "none"
        precondition(
            lookupStarted,
            "stage=explicit-reconnect.await-fake-lookup-entry timeout=3s lookupCalls=\(reconnectLookupCalls) " +
                "refreshCalls=\(startupProvider.refreshCalls) hasLiveTrack=\(startupState.hasLiveTrack) " +
                "track=\(startupState.currentTrack.title) identity=\(reconnectIdentity) " +
                "sessionRevision=\(startupState.lyricsSession.revision) " +
                "sessionState=\(String(describing: startupState.lyricsSession.state)) " +
                "autoSearch=\(startupSettings.autoSearchLyricsOnTrackChange) " +
                "activeLyricsDocument=\(startupState.lyricsSession.activeDocument != nil) " +
                "database=isolated-fresh-SQLite generation=not-publicly-exposed"
        )
        precondition(reconnectLookupCalls > 0, "explicit reconnect must preserve automatic lyrics search")
        startupDefaults.removePersistentDomain(forName: startupSuite)

        for sourceMode in [PlaybackSourceMode.auto, .appleMusic] {
            let suite = "LyricsQPlaybackStateContract-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let settings = AppSettingsStore(defaults: defaults)
            settings.playbackSourceMode = sourceMode
            let sourceIdentity: PlaybackSourceIdentity = sourceMode == .appleMusic ? .appleMusic : .spotifyDesktop
            let modeProvider = ScriptedPlaybackProvider(
                snapshot: PlaybackSnapshot(
                    status: .ready,
                    track: trackA,
                    position: 12,
                    isPlaying: true,
                    sourceIdentity: sourceIdentity
                )
            )
            let modeState = PlaybackState(
                provider: modeProvider,
                lyricsProvider: NoLyricsProvider(),
                settings: settings
            )
            modeState.startProvider(connectSpotify: false)
            for _ in 0..<90 {
                if modeProvider.refreshCalls > 0, modeState.hasLiveTrack {
                    break
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            precondition(modeProvider.refreshCalls > 0, "\(sourceMode.rawValue) startup must retain provider discovery")
            precondition(modeState.hasLiveTrack, "\(sourceMode.rawValue) startup must retain track adoption")
            defaults.removePersistentDomain(forName: suite)
        }

        let provider = ScriptedPlaybackProvider(
            snapshot: PlaybackSnapshot(status: .ready, track: trackA, position: 12, isPlaying: true)
        )
        let state = PlaybackState(provider: provider, lyricsProvider: NoLyricsProvider())
        state.startProvider()
        try? await Task.sleep(nanoseconds: 60_000_000)

        precondition(state.hasLiveTrack)
        precondition(state.currentTrack.title == "Track A")
        precondition(state.currentTrackIdentity?.stableKey.contains("spotify-id:a") == true)
        precondition(state.currentTime >= 12)

        state.togglePlayPause()
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("pause"))
        precondition(!state.isPlaying)

        state.togglePlayPause()
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("play"))
        precondition(state.isPlaying)

        state.seek(to: 88)
        try? await Task.sleep(nanoseconds: 320_000_000)
        precondition(provider.commandLog.contains("seek:88"))
        precondition(abs(state.currentTime - 88) < 2)

        let timeBeforeInvalidSeek = state.currentTime
        state.seek(to: .nan, source: "invalid-test")
        state.seek(to: 999, source: "invalid-test")
        try? await Task.sleep(nanoseconds: 120_000_000)
        precondition(abs(state.currentTime - timeBeforeInvalidSeek) < 1)

        let recoveryState = PlaybackState(provider: provider, lyricsProvider: NetworkFailureLyricsProvider())
        recoveryState.startProvider()
        try? await Task.sleep(nanoseconds: 80_000_000)
        let recoveryTime = recoveryState.currentTime
        precondition(recoveryState.lyricsState.identity == recoveryState.currentTrackIdentity)
        recoveryState.retryLyrics()
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(abs(recoveryState.currentTime - recoveryTime) < 1)

        provider.snapshot = PlaybackSnapshot(status: .ready, track: trackB, position: 4, isPlaying: false)
        state.nextTrack()
        let nextTrackDeadline = Date().addingTimeInterval(2)
        while state.currentTrack.title != "Track B" && Date() < nextTrackDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(provider.commandLog.contains("next"))
        precondition(state.currentTrack.title == "Track B")
        precondition(state.currentTrackIdentity?.stableKey.contains("spotify-id:b") == true)
        precondition(state.currentTime == 4)
        precondition(state.lyrics.isEmpty)

        provider.snapshot = PlaybackSnapshot(status: .ready, track: trackA, position: 3, isPlaying: false)
        state.previousTrack()
        let previousTrackDeadline = Date().addingTimeInterval(2)
        while state.currentTrack.title != "Track A" && Date() < previousTrackDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(provider.commandLog.contains("previous"))
        precondition(state.currentTrack.title == "Track A")

        provider.snapshot = PlaybackSnapshot(status: .notRunning, track: nil, position: 0, isPlaying: false)
        state.reconnectSpotify()
        precondition(!state.hasLiveTrack)
        precondition(state.lyrics.isEmpty)
        try? await Task.sleep(nanoseconds: 80_000_000)
        precondition(!state.hasLiveTrack)
        precondition(state.lyrics.isEmpty)

        provider.snapshot = PlaybackSnapshot(status: .ready, track: trackB, position: 9, isPlaying: true)
        state.reconnectSpotify()
        try? await Task.sleep(nanoseconds: 80_000_000)
        precondition(state.hasLiveTrack)
        precondition(state.currentTrack.title == "Track B")
        precondition(state.currentTime >= 9)

        let raceProvider = DelayedRefreshProvider(
            staleSnapshot: PlaybackSnapshot(status: .ready, track: trackA, position: 1, isPlaying: false),
            latestSnapshot: PlaybackSnapshot(status: .ready, track: trackB, position: 7, isPlaying: false)
        )
        let raceState = PlaybackState(provider: raceProvider, lyricsProvider: NoLyricsProvider())
        raceState.startProvider()
        try? await Task.sleep(nanoseconds: 20_000_000)
        raceProvider.latestSnapshot = PlaybackSnapshot(status: .ready, track: trackB, position: 7, isPlaying: false)
        raceState.reconnectSpotify()
        try? await Task.sleep(nanoseconds: 450_000_000)
        precondition(raceState.currentTrack.title == "Track B")
        precondition(raceState.currentTime == 7)

        print("playback state contract passed")
    }
}
