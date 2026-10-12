import Foundation
import Combine
import CoreMedia
import AVFoundation

/// S2: binds ScreenCaptureKit audio samples to Spotify playback position and
/// splits discontinuous capture into `CapturedAudioSegment`s.
///
/// - No ASR / alignment / SQLite lyrics writes.
/// - Observes existing `PlaybackState` publishers (no second Spotify poller).
/// - Local Combine subscriptions are cancelled on stop.
@MainActor
public final class LiveCaptureCoordinator: ObservableObject {
    public static let shared = LiveCaptureCoordinator()

    public enum State: String, Sendable {
        case idle
        case starting
        case running
        case stopping
        case failed
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var completedSessions: [CapturedAudioSession] = []
    @Published public private(set) var activeSession: CapturedAudioSession?

    private weak var playback: PlaybackState?
    private var cancellables = Set<AnyCancellable>()
    private var openSegment: MutableSegment?
    private var lastPosition: TimeInterval = 0
    private var lastHostTime: TimeInterval = 0
    private var lastIsPlaying = false
    private var lastIdentityKey: String?
    private var lastPlaybackSource: PlaybackSourceIdentity = .unknown
    private var lastAudioHostTime: TimeInterval = 0
    private var lastAnchorLogHostTime: TimeInterval = 0
    private var sessionWorkDirectory: URL?
    private var autoStopTask: Task<Void, Never>?
    private var gapWatchTask: Task<Void, Never>?
    private var pendingStartRequestID: UUID?
    private var alignmentGeneration: UInt64 = 0
    private let generationFlag = GenerationFlag()
    private var sampleDeliveryGeneration: UInt64 = 0
    private let sampleGenerationFlag = GenerationFlag()
    private var alignmentTask: Task<Void, Never>?
    @Published public private(set) var lastPartialReport: PartialAlignmentReport?
    /// Generation of the most recently started capture session (Assist handoff).
    public private(set) var lastStartedGeneration: UInt64 = 0
    /// Atomic handoff after stop + optional partial alignment completes.
    /// Assist must only consume a handoff whose `generation` matches `lastStartedGeneration`.
    public private(set) var lastAlignmentHandoff: PartialAlignmentHandoff?

    /// Classifies why Assist could not produce a draft (logs + UI mapping).
    public enum PartialAlignmentFailureKind: String, Sendable, Equatable {
        case startIgnored
        case unsupportedSource
        case captureFailed
        case noCompletedSession
        case noWavSegments
        case noLyrics
        case noPlayback
        case speechFailed
        case alignmentFailed
        case cancelled
        case emptyTranscript
        case insufficientSuggestions
        case unknown
    }

    public struct PartialAlignmentHandoff: Sendable, Equatable {
        public let generation: UInt64
        public let identityDigest: String?
        public let report: PartialAlignmentReport?
        public let failureKind: PartialAlignmentFailureKind?
        public let message: String?

        public var hasReport: Bool { report != nil }
    }

    private init() {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        LiveCaptureCoordinator.scavengeOrphanTemp()
        #if DEBUG
        // Diagnostic harness only — never auto-start on product launch.
        let s3a = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_S3A"] == "1"
        let s2 = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_S2"] == "1" || s3a
        if s2 {
            let defaultSeconds = s3a ? "75" : "55"
            let seconds = Double(ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_S2_SECONDS"]
                ?? ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_S3A_SECONDS"]
                ?? defaultSeconds) ?? 75
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.start(autoStopAfter: max(20, seconds), runPartialAlignment: s3a)
            }
        }
        #endif
    }

    public func bind(playback: PlaybackState) {
        self.playback = playback
        SCKSpikeLog.log("S2 bind playback ok")
    }

    /// Called from PlaybackState when a large position discontinuity is known
    /// (local seek API or Desktop snapshot jump). Safe no-op when idle.
    public func notifyPlaybackPositionJump(
        from previous: TimeInterval,
        to next: TimeInterval,
        isPlaying playing: Bool
    ) {
        guard state == .running, activeSession != nil else { return }
        let host = Date().timeIntervalSince1970
        let reason: SegmentBoundaryReason = next >= previous ? .seekForward : .seekBackward
        endOpenSegment(reason: reason, position: previous)
        if playing {
            beginSegment(reason: reason, position: next, host: host)
        }
        lastPosition = next
        lastHostTime = host
        lastIsPlaying = playing
        SCKSpikeLog.log(
            "S2 SEEK reason=\(reason.rawValue) from=\(fmt(previous)) to=\(fmt(next)) source=playbackNotify"
        )
    }

    // MARK: - Start / stop

    private var shouldRunPartialAlignment = false

    public func start(autoStopAfter seconds: TimeInterval? = nil, runPartialAlignment: Bool = false) async {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        guard state == .idle || state == .failed else {
            SCKSpikeLog.log("S2 start ignored state=\(state.rawValue)")
            // Do not clear an in-flight handoff; surface explicit start-ignored.
            lastAlignmentHandoff = PartialAlignmentHandoff(
                generation: lastStartedGeneration,
                identityDigest: playback?.currentTrackIdentity?.stableKey,
                report: nil,
                failureKind: .startIgnored,
                message: "捕获仍在进行中，请稍后再试"
            )
            return
        }
        guard let playback else {
            let message = "没有绑定当前播放来源，已拒绝 live capture"
            lastError = message
            publishHandoff(
                generation: lastStartedGeneration,
                report: nil,
                failureKind: .unsupportedSource,
                message: message
            )
            SCKSpikeLog.log("S2 start rejected reason=no_playback_bound")
            return
        }
        // The automatic controller requires active playback before it calls
        // this entry point. The coordinator itself historically supports a
        // paused Spotify session and waits for resume before opening a
        // segment, so source containment must not remove that behavior.
        let eligibility = playback.liveCaptureEligibility(requiresPlaying: false)
        guard eligibility.isAllowed else {
            let message: String
            if playback.playbackSourceIdentity == .appleMusic {
                message = "当前 Apple Music 播放不支持 Spotify live capture"
            } else {
                message = "当前播放来源不支持 live capture（\(eligibility.reason)）"
            }
            lastError = message
            publishHandoff(
                generation: lastStartedGeneration,
                report: nil,
                failureKind: .unsupportedSource,
                message: message
            )
            SCKSpikeLog.log(
                "S2 start rejected source=\(playback.playbackSourceIdentity.rawValue) reason=\(eligibility.reason)"
            )
            return
        }
        guard let startIdentityKey = playback.liveTrackIdentity?.stableKey else {
            let message = "当前播放来源缺少有效歌曲身份，已拒绝 live capture"
            lastError = message
            publishHandoff(
                generation: lastStartedGeneration,
                report: nil,
                failureKind: .unsupportedSource,
                message: message
            )
            return
        }
        lastError = nil
        lastPartialReport = nil
        lastAlignmentHandoff = nil
        completedSessions = []
        activeSession = nil
        openSegment = nil
        invalidateSampleDelivery()
        shouldRunPartialAlignment = runPartialAlignment
            || ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_S3A"] == "1"
        alignmentGeneration &+= 1
        generationFlag.value = alignmentGeneration
        lastStartedGeneration = alignmentGeneration
        let startGuard = AutomaticLiveCaptureSessionGuard(
            source: playback.playbackSourceIdentity,
            identityKey: startIdentityKey,
            generation: alignmentGeneration
        )
        let startRequestID = UUID()
        pendingStartRequestID = startRequestID
        alignmentTask?.cancel()
        SCKSpikeLog.log(
            "S2 SESSION_BOOT formal_db_opened=NO partial=\(shouldRunPartialAlignment) gen=\(alignmentGeneration)"
        )

        // Ensure low-level capture is running and samples are forwarded here.
        SpotifyScreenCaptureAudioSpike.shared.bind(playback: playback)
        SpotifyScreenCaptureAudioSpike.shared.audioSampleHandler = { [weak self] buffer, sampleGeneration in
            // Append PCM on the capture queue path first (writer is thread-safe).
            self?.appendPCM(buffer, sampleGeneration: sampleGeneration)
            self?.handleAudioSample(buffer, sampleGeneration: sampleGeneration)
        }

        state = .starting
        installPlaybackObservers()

        if SpotifyScreenCaptureAudioSpike.shared.state != .capturing {
            await SpotifyScreenCaptureAudioSpike.shared.start(
                autoStopAfter: nil,
                sessionGuard: startGuard
            )
        }
        guard pendingStartRequestID == startRequestID,
              accepts(startGuard, playback: playback) else {
            if SpotifyScreenCaptureAudioSpike.shared.state == .discovering
                || SpotifyScreenCaptureAudioSpike.shared.state == .capturing
                || SpotifyScreenCaptureAudioSpike.shared.state == .failed {
                await SpotifyScreenCaptureAudioSpike.shared.stop(reason: "s2-stale-start")
            }
            if pendingStartRequestID == startRequestID {
                pendingStartRequestID = nil
                cancellables.removeAll()
                SpotifyScreenCaptureAudioSpike.shared.audioSampleHandler = nil
                state = .idle
            }
            SCKSpikeLog.log("S2 drop stale startup provenance")
            return
        }
        guard SpotifyScreenCaptureAudioSpike.shared.state == .capturing else {
            pendingStartRequestID = nil
            cancellables.removeAll()
            SpotifyScreenCaptureAudioSpike.shared.audioSampleHandler = nil
            lastError = SpotifyScreenCaptureAudioSpike.shared.lastError ?? "capture failed"
            state = .failed
            SCKSpikeLog.log("S2 failed to start underlying spike error=\(lastError ?? "")")
            // Assist must observe a generation-matched handoff, not idle+nil.
            publishHandoff(
                generation: lastStartedGeneration,
                report: nil,
                failureKind: .captureFailed,
                message: lastError
            )
            return
        }

        pendingStartRequestID = nil
        state = .running

        if let identity = playback.liveTrackIdentity, playback.hasLiveTrack {
            beginSession(identity: identity, trackDuration: playback.currentTrack.duration, reason: .initial)
        } else {
            SCKSpikeLog.log("S2 waiting for live track before first session")
        }

        autoStopTask?.cancel()
        if let seconds {
            autoStopTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Spawn a fresh task so cancelling `autoStopTask` inside stop()
                // cannot cancel Speech/alignment work.
                Task { @MainActor in
                    await self.stop(reason: .autoStop)
                }
            }
        }

        gapWatchTask?.cancel()
        gapWatchTask = Task { @MainActor in
            while !Task.isCancelled, self.state == .running {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.evaluateAudioGap()
            }
        }
    }

    public func stop(reason: CaptureTerminalReason = .userStop) async {
        guard state == .starting || state == .running || state == .failed else { return }
        let wasStarting = state == .starting
        pendingStartRequestID = nil
        state = .stopping
        SCKSpikeLog.log("S2 stop reason=\(reason.rawValue)")
        autoStopTask?.cancel()
        autoStopTask = nil
        gapWatchTask?.cancel()
        gapWatchTask = nil
        cancellables.removeAll()

        invalidateSampleDelivery()
        endOpenSegment(reason: boundary(from: reason), position: playback?.currentTime)
        if var session = activeSession {
            session.terminalReason = reason
            finalizeSession(session, reason: reason)
        }
        activeSession = nil

        SpotifyScreenCaptureAudioSpike.shared.audioSampleHandler = nil

        // Align while WAVs still exist; S1 spike stop scavenges capture temp.
        let handoffGen = lastStartedGeneration
        if shouldRunPartialAlignment && !wasStarting {
            await runPartialAlignmentIfNeeded(stopReason: reason)
            // Guarantee Assist never sees idle with a cleared handoff for this gen.
            if lastAlignmentHandoff?.generation != handoffGen {
                if let report = lastPartialReport {
                    publishHandoff(
                        generation: handoffGen,
                        report: report,
                        failureKind: nil,
                        message: nil
                    )
                } else if reason == .userStop || reason == .trackChanged {
                    publishHandoff(
                        generation: handoffGen,
                        report: nil,
                        failureKind: .cancelled,
                        message: reason == .trackChanged ? "切歌导致捕获终止" : "已取消边听边排轴"
                    )
                } else {
                    publishHandoff(
                        generation: handoffGen,
                        report: nil,
                        failureKind: lastAlignmentHandoff?.failureKind ?? .unknown,
                        message: lastError ?? "未能生成建议时间"
                    )
                }
            }
        } else {
            // Capture-only stops still publish a handoff so waiters can unblock.
            publishHandoff(
                generation: handoffGen,
                report: nil,
                failureKind: reason == .userStop || reason == .trackChanged ? .cancelled : nil,
                message: nil
            )
        }

        await SpotifyScreenCaptureAudioSpike.shared.stop(reason: "s2-\(reason.rawValue)")

        // Delete capture WAVs / session sidecars after alignment; keep s3a reports.
        cleanupSessionDirectory()
        LiveCaptureCoordinator.scavengeOrphanTemp()
        state = .idle
        SCKSpikeLog.log(
            "S2 stopped idle sessions=\(completedSessions.count) handoffGen=\(handoffGen) hasReport=\(lastPartialReport != nil)"
        )
        logSummaryTable()
    }

    /// Wait until capture leaves running/stopping. Callers must then read `lastAlignmentHandoff`.
    public func waitUntilIdle(timeoutSeconds: TimeInterval = 180) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while state == .starting || state == .running || state == .stopping {
            if Date() > deadline { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func publishHandoff(
        generation: UInt64,
        report: PartialAlignmentReport?,
        failureKind: PartialAlignmentFailureKind?,
        message: String?
    ) {
        // Never overwrite a newer generation's handoff with a stale one.
        if let existing = lastAlignmentHandoff, existing.generation > generation {
            SCKSpikeLog.log("S2 drop stale handoff gen=\(generation) current=\(existing.generation)")
            return
        }
        let digest = report?.candidate.trackIdentityDigest
            ?? playback?.currentTrackIdentity?.stableKey
        lastAlignmentHandoff = PartialAlignmentHandoff(
            generation: generation,
            identityDigest: digest,
            report: report,
            failureKind: failureKind,
            message: message
        )
        if let report {
            lastPartialReport = report
        }
        if let message, failureKind != nil {
            lastError = message
        }
        SCKSpikeLog.log(
            "S2 HANDOFF gen=\(generation) report=\(report != nil) kind=\(failureKind?.rawValue ?? "ok") msg=\(message ?? "")"
        )
    }

    private func invalidateSampleDelivery() {
        sampleGenerationFlag.value = 0
        SpotifyScreenCaptureAudioSpike.shared.invalidateSampleDeliveryAndDrain()
    }

    private func appendPCM(_ sampleBuffer: CMSampleBuffer, sampleGeneration: UInt64) {
        // Writer is thread-safe. Append synchronously on the capture callback —
        // an async MainActor hop races finalize/finish() and can yield empty WAV
        // plus a nil lastPartialReport handoff.
        guard sampleGenerationFlag.matches(sampleGeneration) else { return }
        openSegment?.wavWriter?.append(sampleBuffer)
    }

    // MARK: - Playback observation (no second Spotify poller)

    private func installPlaybackObservers() {
        cancellables.removeAll()
        guard let playback else {
            SCKSpikeLog.log("S2 no playback bound")
            return
        }

        lastPosition = playback.currentTime
        lastHostTime = Date().timeIntervalSince1970
        lastIsPlaying = playback.isPlaying
        lastIdentityKey = playback.liveTrackIdentity?.stableKey
        lastPlaybackSource = playback.playbackSourceIdentity

        // Reuse PlaybackState's existing timer-driven publishers.
        playback.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                self?.onPosition(position)
            }
            .store(in: &cancellables)

        playback.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                self?.onPlayingChanged(playing)
            }
            .store(in: &cancellables)

        playback.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onPlaybackObjectWillChange()
            }
            .store(in: &cancellables)
    }

    private func onPlaybackObjectWillChange() {
        // Identity is not a separate publisher; re-read after the next main turn.
        Task { @MainActor in
            self.evaluatePlaybackContextChange()
        }
    }

    private func onPlayingChanged(_ playing: Bool) {
        guard state == .running else { return }
        let host = Date().timeIntervalSince1970
        let position = playback?.currentTime ?? lastPosition
        if lastIsPlaying && !playing {
            endOpenSegment(reason: .pause, position: position)
            SCKSpikeLog.log("S2 PLAYBACK paused position=\(fmt(position))")
        } else if !lastIsPlaying && playing {
            if activeSession != nil {
                beginSegment(reason: .resume, position: position, host: host)
            }
            SCKSpikeLog.log("S2 PLAYBACK resumed position=\(fmt(position))")
        }
        lastIsPlaying = playing
        lastPosition = position
        lastHostTime = host
    }

    private func onPosition(_ position: TimeInterval) {
        guard state == .starting || state == .running else { return }
        let host = Date().timeIntervalSince1970
        evaluatePlaybackContextChange()

        guard playback?.playbackSourceIdentity == .spotifyDesktop else { return }

        guard activeSession != nil else {
            lastPosition = position
            lastHostTime = host
            return
        }

        let dtHost = max(0, host - lastHostTime)
        let expected = lastIsPlaying ? lastPosition + dtHost : lastPosition
        let deltaFromExpected = position - expected
        let absJump = abs(position - lastPosition)

        // Primary: raw Spotify position jump (provider refresh after seek).
        // Secondary: deviation from host-clock expected progress (catches
        // jumps that land near a "plausible" interpolated value).
        let looksLikeSeek = absJump > CaptureContinuityPolicy.seekJumpThreshold
            || (lastIsPlaying
                && abs(deltaFromExpected) > CaptureContinuityPolicy.seekJumpThreshold
                && absJump > CaptureContinuityPolicy.positionJitterTolerance)

        if looksLikeSeek, openSegment != nil || lastIsPlaying {
            let reason: SegmentBoundaryReason = position >= lastPosition ? .seekForward : .seekBackward
            endOpenSegment(reason: reason, position: lastPosition)
            if playback?.isPlaying == true {
                beginSegment(reason: reason, position: position, host: host)
            }
            SCKSpikeLog.log(
                "S2 SEEK reason=\(reason.rawValue) from=\(fmt(lastPosition)) to=\(fmt(position)) expected=\(fmt(expected)) jump=\(fmt(absJump)) drift=\(fmt(deltaFromExpected))"
            )
        } else if openSegment != nil, lastIsPlaying {
            openSegment?.spotifyPositionEnd = position
            maybeLogAnchor(position: position, host: host, audioPTS: openSegment?.audioPTSEnd)
        }

        lastPosition = position
        lastHostTime = host
    }

    private func evaluatePlaybackContextChange() {
        guard state == .starting || state == .running else { return }
        let wasStarting = state == .starting
        let source = playback?.playbackSourceIdentity ?? .unknown
        let identity = playback?.liveTrackIdentity
        let key = identity?.stableKey
        if key == lastIdentityKey, source == lastPlaybackSource { return }

        let previous = lastIdentityKey
        let previousSource = lastPlaybackSource
        lastIdentityKey = key
        lastPlaybackSource = source
        SCKSpikeLog.log(
            "S2 CONTEXT previousSource=\(previousSource.rawValue) nextSource=\(source.rawValue) previous=\(short(previous)) next=\(short(key))"
        )

        // Invalidate any in-flight S3A work for the previous song.
        alignmentGeneration &+= 1
        generationFlag.value = alignmentGeneration
        alignmentTask?.cancel()
        SCKSpikeLog.log("S3A cancel gen=\(alignmentGeneration) reason=trackChanged")

        endOpenSegment(reason: .trackChanged, position: lastPosition)
        if var session = activeSession {
            session.terminalReason = .trackChanged
            finalizeSession(session, reason: .trackChanged)
        }
        activeSession = nil

        if wasStarting {
            pendingStartRequestID = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stop(
                    reason: source == .spotifyDesktop ? .trackChanged : .spotifyUnavailable
                )
            }
            return
        }

        if source == .spotifyDesktop, let identity, playback?.hasLiveTrack == true {
            beginSession(
                identity: identity,
                trackDuration: playback?.currentTrack.duration ?? 0,
                reason: .trackChanged
            )
        } else {
            SCKSpikeLog.log("S2 source unsupported or no live track; stopping capture")
            Task { @MainActor [weak self] in
                guard let self, self.state == .running else { return }
                let reason: CaptureTerminalReason = source == .spotifyDesktop ? .noLiveTrack : .spotifyUnavailable
                await self.stop(reason: reason)
            }
        }
    }

    // MARK: - Session / segment

    private func accepts(
        _ startGuard: AutomaticLiveCaptureSessionGuard,
        playback: PlaybackState
    ) -> Bool {
        startGuard.accepts(
            source: playback.playbackSourceIdentity,
            identityKey: playback.liveTrackIdentity?.stableKey,
            generation: alignmentGeneration,
            providerReady: playback.providerStatus.isReady
                && playback.hasLiveTrack
                && !playback.isMockPreviewMode
        )
    }

    private func beginSession(identity: TrackIdentity, trackDuration: TimeInterval, reason: SegmentBoundaryReason) {
        let sessionID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(CaptureContinuityPolicy.temporaryRootName, isDirectory: true)
            .appendingPathComponent(CaptureContinuityPolicy.s2SessionsFolderName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sessionWorkDirectory = root

        var session = CapturedAudioSession(
            sessionID: sessionID,
            trackIdentity: identity,
            trackDuration: trackDuration
        )
        activeSession = session
        SCKSpikeLog.log(
            "SESSION start sessionID=\(sessionID.uuidString) identity=\(session.identityDigest) duration=\(fmt(trackDuration)) source=\(session.captureSource) reason=\(reason.rawValue)"
        )
        // Start a segment only when currently playing; pause waits for resume.
        let host = Date().timeIntervalSince1970
        let position = playback?.currentTime ?? 0
        lastPosition = position
        lastHostTime = host
        lastIsPlaying = playback?.isPlaying ?? false
        if lastIsPlaying {
            beginSegment(reason: reason == .trackChanged ? .initial : reason, position: position, host: host)
        } else {
            SCKSpikeLog.log("SESSION waiting for play position=\(fmt(position))")
        }
        _ = session
    }

    private func beginSegment(reason: SegmentBoundaryReason, position: TimeInterval, host: TimeInterval) {
        guard let session = activeSession else { return }
        if openSegment != nil {
            endOpenSegment(reason: .sessionReplaced, position: position)
        } else {
            invalidateSampleDelivery()
        }
        let continuity = UUID()
        let segmentID = UUID()
        var writer: SegmentWAVWriter?
        if let dir = sessionWorkDirectory {
            writer = try? SegmentWAVWriter(directory: dir, segmentID: segmentID)
        }
        let segment = MutableSegment(
            segmentID: segmentID,
            sessionID: session.sessionID,
            trackIdentity: session.trackIdentity,
            spotifyPositionStart: position,
            hostTimeStart: host,
            continuityID: continuity,
            startReason: reason,
            wavWriter: writer
        )
        openSegment = segment
        sampleDeliveryGeneration &+= 1
        sampleGenerationFlag.value = sampleDeliveryGeneration
        SpotifyScreenCaptureAudioSpike.shared.setSampleDeliveryGeneration(sampleDeliveryGeneration)
        SCKSpikeLog.log(
            "SEGMENT start segmentID=\(segment.segmentID.uuidString) sessionID=\(session.sessionID.uuidString) identity=\(segment.identityDigest) reason=\(reason.rawValue) position=\(fmt(position)) hostTime=\(fmt(host)) continuityID=\(continuity.uuidString) wav=\(writer?.fileURL.lastPathComponent ?? "none")"
        )
    }

    private func endOpenSegment(reason: SegmentBoundaryReason, position: TimeInterval?) {
        invalidateSampleDelivery()
        guard var segment = openSegment else { return }
        openSegment = nil
        let host = Date().timeIntervalSince1970
        segment.hostTimeEnd = host
        segment.spotifyPositionEnd = position ?? segment.spotifyPositionEnd ?? segment.spotifyPositionStart
        segment.endReason = reason
        if segment.sampleRate > 0 {
            segment.duration = Double(segment.sampleCount) / segment.sampleRate
        } else {
            segment.duration = max(0, host - segment.hostTimeStart)
        }
        segment.isContinuous = (reason == .pause || reason == .userStop || reason == .autoStop || reason == .trackChanged)

        // Finalize WAV first so temporaryPCMReference points at audio for S3A.
        if let wavURL = try? segment.wavWriter?.finish() {
            segment.temporaryPCMReference = wavURL.path
            SCKSpikeLog.log("WAV ready path=\(wavURL.path) frames=\(segment.wavWriter?.framesWritten ?? 0)")
        } else {
            segment.wavWriter?.abandon()
            // Fall back to JSON sidecar metadata only.
            segment.temporaryPCMReference = writeSegmentSidecar(segment.frozen())
        }
        // Always write metadata sidecar alongside (when dir exists).
        _ = writeSegmentSidecar(segment.frozen())

        let frozen = segment.frozen()
        if var session = activeSession {
            session.segments.append(frozen)
            activeSession = session
        }
        SCKSpikeLog.log(
            "SEGMENT end segmentID=\(frozen.segmentID.uuidString) sessionID=\(frozen.sessionID.uuidString) identity=\(frozen.identityDigest) reason=\(reason.rawValue) posStart=\(fmt(frozen.spotifyPositionStart)) posEnd=\(fmt(frozen.spotifyPositionEnd ?? -1)) hostStart=\(fmt(frozen.hostTimeStart)) hostEnd=\(fmt(frozen.hostTimeEnd ?? -1)) ptsStart=\(fmt(frozen.audioPTSStart ?? -1)) ptsEnd=\(fmt(frozen.audioPTSEnd ?? -1)) samples=\(frozen.sampleCount) buffers=\(frozen.bufferCount) duration=\(fmt(frozen.duration)) rate=\(frozen.sampleRate) ch=\(frozen.channelCount) continuous=\(frozen.isContinuous) pcm=\(frozen.temporaryPCMReference ?? "none")"
        )
    }

    private func runPartialAlignmentIfNeeded(stopReason: CaptureTerminalReason) async {
        let gen = lastStartedGeneration
        guard isGenerationCurrent(gen) else {
            SCKSpikeLog.log("S3A skip stale generation")
            publishHandoff(
                generation: gen,
                report: nil,
                failureKind: .cancelled,
                message: "会话已失效，已丢弃迟到结果"
            )
            return
        }
        // Prefer the longest completed session with WAV-backed segments.
        let sessions = completedSessions
        guard let session = sessions.max(by: { lhs, rhs in
            lhs.segments.map(\.duration).reduce(0, +) < rhs.segments.map(\.duration).reduce(0, +)
        }) else {
            SCKSpikeLog.log("S3A no completed sessions")
            publishHandoff(
                generation: gen,
                report: nil,
                failureKind: .noCompletedSession,
                message: "没有捕获到有效音频会话"
            )
            return
        }
        let wavSegments = session.segments.filter { ($0.temporaryPCMReference ?? "").hasSuffix(".wav") }
        guard !wavSegments.isEmpty else {
            SCKSpikeLog.log("S3A no wav segments session=\(session.sessionID.uuidString.prefix(8))")
            publishHandoff(
                generation: gen,
                report: nil,
                failureKind: .noWavSegments,
                message: "没有捕获到有效音频文件"
            )
            return
        }

        guard let playback else {
            SCKSpikeLog.log("S3A no playback for lyrics")
            publishHandoff(
                generation: gen,
                report: nil,
                failureKind: .noPlayback,
                message: "当前没有可用的播放会话"
            )
            return
        }
        guard playback.playbackSourceIdentity == .spotifyDesktop,
              playback.liveTrackIdentity?.stableKey == session.trackIdentity.stableKey else {
            SCKSpikeLog.log("S3A drop stale provenance source_or_identity")
            publishHandoff(
                generation: gen,
                report: nil,
                failureKind: .cancelled,
                message: "播放来源或歌曲已切换，已丢弃迟到结果"
            )
            return
        }
        // Held-out: use current synced lyrics times only for evaluation AFTER
        // alignment. Algorithm input always uses plain lines (timestamps zeroed).
        let liveLines = playback.liveLyrics
        guard !liveLines.isEmpty else {
            SCKSpikeLog.log("S3A no lyrics lines")
            publishHandoff(
                generation: gen,
                report: nil,
                failureKind: .noLyrics,
                message: "当前没有可对齐的歌词"
            )
            return
        }
        let plain = liveLines.map {
            LyricLine(
                id: $0.id,
                timestamp: 0,
                originalText: $0.originalText,
                endTime: nil,
                translationText: $0.translationText,
                romajiText: $0.romajiText,
                kanaText: $0.kanaText,
                rubyTokens: $0.rubyTokens
            )
        }
        let groundTruth: [LyricLine]? = playback.liveLyricsAreSynchronized ? liveLines : nil
        if playback.liveLyricsAreSynchronized {
            SCKSpikeLog.log("S3A held_out=enabled lines=\(liveLines.count) (timestamps hidden from aligner)")
        } else {
            SCKSpikeLog.log("S3A held_out=disabled plain_or_unsynced")
        }

        let localeOverride = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_S3A_LOCALE"]
        do {
            SCKSpikeLog.log("S3A align begin session=\(session.sessionID.uuidString.prefix(8)) segments=\(wavSegments.count)")
            let flag = generationFlag
            let report = try await SegmentPartialAlignmentPipeline.align(
                session: session,
                segments: wavSegments,
                plainLines: plain,
                languageHint: playback.liveLyricsLanguage,
                localeOverride: localeOverride,
                groundTruthSyncedLines: groundTruth,
                identity: session.trackIdentity,
                generation: gen,
                isGenerationCurrent: { flag.matches(gen) }
            )
            guard isGenerationCurrent(gen) else {
                SCKSpikeLog.log("S3A drop stale report gen=\(gen)")
                publishHandoff(
                    generation: gen,
                    report: nil,
                    failureKind: .cancelled,
                    message: "切歌或取消导致结果已丢弃"
                )
                return
            }
            lastPartialReport = report
            publishHandoff(
                generation: gen,
                report: report,
                failureKind: nil,
                message: nil
            )
            SCKSpikeLog.log(
                "S3B judgment=\(report.judgment) constrained=\(report.usedConstrainedAlignment) anchors=\(report.acceptedAnchors.count)/rej=\(report.rejectedAnchors.count) fallback=\(report.s3bFallbackReason ?? "none")"
            )
            if let s3a = report.s3aCandidate {
                SCKSpikeLog.log(
                    "S3B AB s3a_cov=\(String(format: "%.3f", s3a.coverageRatio)) s3b_cov=\(String(format: "%.3f", report.candidate.coverageRatio)) s3a_res=\(s3a.resolvedCount) s3b_res=\(report.candidate.resolvedCount)"
                )
            }
        } catch {
            if !isGenerationCurrent(gen) {
                SCKSpikeLog.log("S3A cancelled gen=\(gen)")
                publishHandoff(
                    generation: gen,
                    report: nil,
                    failureKind: .cancelled,
                    message: "切歌或取消导致识别中止"
                )
            } else {
                let message = error.localizedDescription
                SCKSpikeLog.log("S3A failed error=\(message)")
                let kind: PartialAlignmentFailureKind
                if let alignError = error as? AlignmentError {
                    switch alignError {
                    case .noSpeech, .speechPermissionDenied, .recognizerUnavailable:
                        kind = .speechFailed
                    case .invalidAudio:
                        kind = .noWavSegments
                    case .cancelled:
                        kind = .cancelled
                    default:
                        kind = .alignmentFailed
                    }
                } else {
                    kind = .alignmentFailed
                }
                publishHandoff(
                    generation: gen,
                    report: nil,
                    failureKind: kind,
                    message: message
                )
            }
        }
    }

    private func isGenerationCurrent(_ gen: UInt64) -> Bool {
        alignmentGeneration == gen
    }

    private func finalizeSession(_ session: CapturedAudioSession, reason: CaptureTerminalReason) {
        var closed = session
        closed.terminalReason = reason
        completedSessions.append(closed)
        SCKSpikeLog.log(
            "SESSION end sessionID=\(closed.sessionID.uuidString) identity=\(closed.identityDigest) reason=\(reason.rawValue) segments=\(closed.segments.count)"
        )
        writeSessionSidecar(closed)
    }

    // MARK: - Audio samples

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer, sampleGeneration: UInt64) {
        // Called on capture queue via handler; hop to MainActor.
        Task { @MainActor in
            self.ingestOnMain(sampleBuffer, sampleGeneration: sampleGeneration)
        }
    }

    private func ingestOnMain(_ sampleBuffer: CMSampleBuffer, sampleGeneration: UInt64) {
        guard sampleGenerationFlag.matches(sampleGeneration) else { return }
        guard state == .running else { return }
        guard playback?.playbackSourceIdentity == .spotifyDesktop else { return }
        let host = Date().timeIntervalSince1970
        lastAudioHostTime = host

        // Drop late buffers from a previous session/identity.
        guard let session = activeSession else { return }
        if let live = playback?.liveTrackIdentity, live != session.trackIdentity {
            SCKSpikeLog.log("S2 DROP late buffer identity mismatch")
            return
        }

        // While paused, still count stream health but do not invent segments.
        if CaptureContinuityPolicy.ignoreAudioActivityWhilePaused,
           playback?.isPlaying == false,
           openSegment == nil {
            return
        }

        if openSegment == nil, playback?.isPlaying == true {
            beginSegment(reason: .resume, position: playback?.currentTime ?? lastPosition, host: host)
        }
        guard var segment = openSegment else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsSec = pts.isValid ? CMTimeGetSeconds(pts) : Double.nan
        if ptsSec.isFinite {
            if segment.audioPTSStart == nil { segment.audioPTSStart = ptsSec }
            segment.audioPTSEnd = ptsSec
        }

        if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            if asbd.mSampleRate > 0 { segment.sampleRate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { segment.channelCount = Int(asbd.mChannelsPerFrame) }
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        if frames > 0 {
            segment.sampleCount += frames
            segment.bufferCount += 1
        }
        segment.spotifyPositionEnd = playback?.currentTime ?? segment.spotifyPositionEnd
        openSegment = segment
    }

    private func evaluateAudioGap() {
        guard state == .running, openSegment != nil else { return }
        let host = Date().timeIntervalSince1970
        guard lastAudioHostTime > 0 else { return }
        let gap = host - lastAudioHostTime
        guard gap >= CaptureContinuityPolicy.audioGapTimeout else { return }
        if let open = openSegment, (host - open.hostTimeStart) < CaptureContinuityPolicy.minimumSegmentDurationBeforeGapClose {
            return
        }
        // Only gap-close while we believe playback is still running; pause already closed.
        if playback?.isPlaying == true {
            endOpenSegment(reason: .audioGap, position: playback?.currentTime)
            SCKSpikeLog.log("S2 AUDIO_GAP closed segment gap=\(fmt(gap))")
        }
    }

    private func maybeLogAnchor(position: TimeInterval, host: TimeInterval, audioPTS: TimeInterval?) {
        if host - lastAnchorLogHostTime < CaptureContinuityPolicy.anchorLogInterval { return }
        lastAnchorLogHostTime = host
        SCKSpikeLog.log(
            "ANCHOR sessionID=\(activeSession?.sessionID.uuidString ?? "-") segmentID=\(openSegment?.segmentID.uuidString ?? "-") position=\(fmt(position)) hostTime=\(fmt(host)) audioPTS=\(fmt(audioPTS ?? -1)) playing=\(playback?.isPlaying ?? false)"
        )
    }

    // MARK: - Sidecars (no audio payload by default)

    @discardableResult
    private func writeSegmentSidecar(_ segment: CapturedAudioSegment) -> String? {
        guard let dir = sessionWorkDirectory else { return nil }
        let url = dir.appendingPathComponent("seg-\(segment.segmentID.uuidString.prefix(8)).json")
        let payload: [String: Any] = [
            "segmentID": segment.segmentID.uuidString,
            "sessionID": segment.sessionID.uuidString,
            "identityDigest": segment.identityDigest,
            "spotifyPositionStart": segment.spotifyPositionStart,
            "spotifyPositionEnd": segment.spotifyPositionEnd as Any,
            "hostTimeStart": segment.hostTimeStart,
            "hostTimeEnd": segment.hostTimeEnd as Any,
            "audioPTSStart": segment.audioPTSStart as Any,
            "audioPTSEnd": segment.audioPTSEnd as Any,
            "sampleRate": segment.sampleRate,
            "channelCount": segment.channelCount,
            "sampleCount": segment.sampleCount,
            "bufferCount": segment.bufferCount,
            "duration": segment.duration,
            "continuityID": segment.continuityID.uuidString,
            "startReason": segment.startReason.rawValue,
            "endReason": segment.endReason?.rawValue as Any,
            "isContinuous": segment.isContinuous,
            "note": "S2 sidecar metadata only; no PCM payload"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return nil
        }
        try? data.write(to: url, options: .atomic)
        SCKSpikeLog.log("TEMP sidecar path=\(url.path)")
        return url.path
    }

    private func writeSessionSidecar(_ session: CapturedAudioSession) {
        guard let dir = sessionWorkDirectory else { return }
        let url = dir.appendingPathComponent("session.json")
        let payload: [String: Any] = [
            "sessionID": session.sessionID.uuidString,
            "identityDigest": session.identityDigest,
            "trackDuration": session.trackDuration,
            "segmentCount": session.segments.count,
            "terminalReason": session.terminalReason?.rawValue as Any,
            "captureSource": session.captureSource
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
            SCKSpikeLog.log("TEMP session sidecar path=\(url.path)")
        }
    }

    private func cleanupSessionDirectory() {
        if let dir = sessionWorkDirectory {
            try? FileManager.default.removeItem(at: dir)
            let exists = FileManager.default.fileExists(atPath: dir.path)
            SCKSpikeLog.log("CLEANUP sessionDir=\(dir.path) exists_after=\(exists)")
        }
        sessionWorkDirectory = nil
        // Also remove completed session folders under s2-sessions.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(CaptureContinuityPolicy.temporaryRootName, isDirectory: true)
            .appendingPathComponent(CaptureContinuityPolicy.s2SessionsFolderName, isDirectory: true)
        if let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for child in children {
                try? FileManager.default.removeItem(at: child)
                SCKSpikeLog.log("CLEANUP removed=\(child.lastPathComponent)")
            }
        }
    }

    static func scavengeOrphanTemp() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(CaptureContinuityPolicy.temporaryRootName, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children {
            try? FileManager.default.removeItem(at: child)
            SCKSpikeLog.log("TEMP scavenge removed=\(child.lastPathComponent)")
        }
    }

    private func logSummaryTable() {
        SCKSpikeLog.log("SUMMARY sessions=\(completedSessions.count)")
        for session in completedSessions {
            SCKSpikeLog.log(
                "SUMMARY_SESSION id=\(session.sessionID.uuidString.prefix(8)) identity=\(session.identityDigest) terminal=\(session.terminalReason?.rawValue ?? "-") segments=\(session.segments.count)"
            )
            for (i, seg) in session.segments.enumerated() {
                SCKSpikeLog.log(
                    "SUMMARY_SEG i=\(i) id=\(seg.segmentID.uuidString.prefix(8)) start=\(seg.startReason.rawValue) end=\(seg.endReason?.rawValue ?? "-") pos=\(fmt(seg.spotifyPositionStart))->\(fmt(seg.spotifyPositionEnd ?? -1)) dur=\(fmt(seg.duration)) samples=\(seg.sampleCount)"
                )
            }
        }
    }

    private func boundary(from reason: CaptureTerminalReason) -> SegmentBoundaryReason {
        switch reason {
        case .trackChanged: return .trackChanged
        case .userStop: return .userStop
        case .autoStop: return .autoStop
        case .streamError: return .streamInterrupted
        case .spotifyUnavailable: return .spotifyUnavailable
        case .appExit: return .appExit
        case .noLiveTrack: return .trackChanged
        }
    }

    private func fmt(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private func short(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "-" }
        return String(key.prefix(40))
    }
}

// MARK: - Generation flag (Sendable)

private final class GenerationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64 = 0
    var value: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func matches(_ expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _value == expected
    }
}

// MARK: - Mutable open segment

private final class MutableSegment {
    let segmentID: UUID
    let sessionID: UUID
    let trackIdentity: TrackIdentity
    var spotifyPositionStart: TimeInterval
    var spotifyPositionEnd: TimeInterval?
    let hostTimeStart: TimeInterval
    var hostTimeEnd: TimeInterval?
    var audioPTSStart: TimeInterval?
    var audioPTSEnd: TimeInterval?
    var sampleRate: Double = 0
    var channelCount: Int = 0
    var sampleCount: Int = 0
    var bufferCount: Int = 0
    var duration: TimeInterval = 0
    let continuityID: UUID
    let startReason: SegmentBoundaryReason
    var endReason: SegmentBoundaryReason?
    var temporaryPCMReference: String?
    var isContinuous: Bool = true
    let wavWriter: SegmentWAVWriter?

    var identityDigest: String { String(trackIdentity.stableKey.prefix(48)) }

    init(
        segmentID: UUID,
        sessionID: UUID,
        trackIdentity: TrackIdentity,
        spotifyPositionStart: TimeInterval,
        hostTimeStart: TimeInterval,
        continuityID: UUID,
        startReason: SegmentBoundaryReason,
        wavWriter: SegmentWAVWriter? = nil
    ) {
        self.segmentID = segmentID
        self.sessionID = sessionID
        self.trackIdentity = trackIdentity
        self.spotifyPositionStart = spotifyPositionStart
        self.hostTimeStart = hostTimeStart
        self.continuityID = continuityID
        self.startReason = startReason
        self.wavWriter = wavWriter
    }

    func frozen() -> CapturedAudioSegment {
        CapturedAudioSegment(
            segmentID: segmentID,
            sessionID: sessionID,
            trackIdentity: trackIdentity,
            spotifyPositionStart: spotifyPositionStart,
            spotifyPositionEnd: spotifyPositionEnd,
            hostTimeStart: hostTimeStart,
            hostTimeEnd: hostTimeEnd,
            audioPTSStart: audioPTSStart,
            audioPTSEnd: audioPTSEnd,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sampleCount: sampleCount,
            bufferCount: bufferCount,
            duration: duration,
            continuityID: continuityID,
            startReason: startReason,
            endReason: endReason,
            temporaryPCMReference: temporaryPCMReference,
            isContinuous: isContinuous
        )
    }
}
