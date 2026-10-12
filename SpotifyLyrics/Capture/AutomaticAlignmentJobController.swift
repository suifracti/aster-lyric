import Foundation
import Combine

/// Product-level zero-operation automatic alignment controller.
/// Observes playback; does not control Spotify. Reuses LiveCaptureCoordinator + S4 chain.
@MainActor
public final class AutomaticAlignmentJobController: ObservableObject {
    public static let shared = AutomaticAlignmentJobController()

    /// Presentation-only copy for the existing automatic-alignment status row.
    /// It does not add a new alignment state or alter the capture pipeline.
    public struct UserFacingStatus: Equatable, Sendable {
        public let title: String
        public let recoveryHint: String

        public init(title: String, recoveryHint: String) {
            self.title = title
            self.recoveryHint = recoveryHint
        }
    }

    public enum State: String, Sendable, Equatable {
        case idle
        case waitingForPlayback
        case capturing
        case paused
        case aligning
        case evaluating
        case accumulating
        case completed
        case failed
        case canceled
        case deferred
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastDecision: String?
    @Published public private(set) var activeIdentityKey: String?
    @Published public private(set) var userFacingStatus: UserFacingStatus?

    private weak var playback: PlaybackState?
    private var jobTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var activeSessionGuard: AutomaticLiveCaptureSessionGuard?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    private static let engineUnavailableStatus = UserFacingStatus(
        title: "识别引擎或模型不可用",
        recoveryHint: "请检查并准备识别引擎或模型后重试。"
    )

    private static let persistenceFailureStatus = UserFacingStatus(
        title: "自动排轴结果未能保存",
        recoveryHint: "当前歌词没有被自动覆盖；请稍后重试。"
    )

    private static let unsupportedSourceStatus = UserFacingStatus(
        title: "当前播放来源不支持自动捕获",
        recoveryHint: "自动 live capture 目前只接受 Spotify Desktop；本地音频排轴仍可独立使用。"
    )

    private static func statusForCaptureFailure(
        kind: LiveCaptureCoordinator.PartialAlignmentFailureKind?,
        message: String?,
        fallback: String
    ) -> UserFacingStatus {
        let source = [message, fallback]
            .compactMap { $0 }
            .joined(separator: " ")

        if kind == .speechFailed,
           source.contains("权限") || source.contains("授权") {
            return UserFacingStatus(
                title: "语音识别权限不足",
                recoveryHint: "请前往系统设置允许语音识别权限后重试。"
            )
        }

        if kind == .speechFailed,
           source.contains("不可用") || source.contains("识别引擎") || source.contains("模型") {
            return Self.engineUnavailableStatus
        }

        switch kind {
        case .unsupportedSource:
            return Self.unsupportedSourceStatus
        case .captureFailed, .noCompletedSession, .noWavSegments:
            return UserFacingStatus(
                title: "音频捕获失败",
                recoveryHint: "请确认系统音频捕获条件和 Spotify 正在播放后重试。"
            )
        case .speechFailed, .emptyTranscript:
            return UserFacingStatus(
                title: "语音识别失败",
                recoveryHint: "请继续播放清晰人声片段，或稍后重试。"
            )
        case .alignmentFailed:
            return UserFacingStatus(
                title: "自动排轴未收敛",
                recoveryHint: "当前结果可靠性不足，不会自动采用；请继续播放收集更多证据或重试。"
            )
        case .insufficientSuggestions:
            return UserFacingStatus(
                title: "可靠建议不足",
                recoveryHint: "请继续播放收集更多证据；未完成结果不会自动采用。"
            )
        case .noLyrics:
            return UserFacingStatus(
                title: "没有可对齐的歌词",
                recoveryHint: "请先获取或导入纯文本歌词，再重试。"
            )
        case .noPlayback:
            return UserFacingStatus(
                title: "没有可用的播放会话",
                recoveryHint: "请确认 Spotify 正在播放后重试。"
            )
        case .startIgnored:
            return UserFacingStatus(
                title: "捕获仍在进行中",
                recoveryHint: "请等待当前任务结束后再重试。"
            )
        case .cancelled:
            return UserFacingStatus(
                title: "自动排轴已取消",
                recoveryHint: "可在当前歌曲上重新尝试。"
            )
        case .unknown, .none:
            return UserFacingStatus(
                title: "自动排轴未完成",
                recoveryHint: "请继续播放收集更多证据，或重试。"
            )
        }
    }

    private static func statusForQualityGate(reason: String) -> UserFacingStatus {
        let title: String
        switch reason {
        case "weak_interpolation_present":
            title = "可靠性检查拒绝了弱推断结果"
        case "capture_or_occurrence_violation":
            title = "可靠性检查拒绝了捕获范围结果"
        case "non_monotonic":
            title = "可靠性检查拒绝了不连续时间轴"
        default:
            title = "可靠性检查未通过"
        }
        return UserFacingStatus(
            title: title,
            recoveryHint: "当前结果可靠性不足，不会自动采用；请继续播放收集更多证据或重试。"
        )
    }

    private static func statusForInsufficientEvidence(reason: String) -> UserFacingStatus {
        let title: String
        switch reason {
        case "no_suggestions":
            title = "尚未获得可靠时间建议"
        case "insufficient_evidence":
            title = "证据不足，等待更多片段"
        default:
            title = "等待更多排轴证据"
        }
        return UserFacingStatus(
            title: title,
            recoveryHint: "请继续播放；已有可靠部分会保留，未完成结果不会自动采用。"
        )
    }

    public func bind(playback: PlaybackState) {
        self.playback = playback
        cancellables.removeAll()
        // Re-evaluate when playback publishes changes (track / play state).
        playback.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleEvaluate()
            }
            .store(in: &cancellables)
        AppSettingsStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleEvaluate()
            }
            .store(in: &cancellables)
        scheduleEvaluate()
    }

    public func cancelCurrentJob(userInitiated: Bool = true) {
        jobTask?.cancel()
        jobTask = nil
        generation &+= 1
        activeSessionGuard = nil
        Task { @MainActor in
            let st = LiveCaptureCoordinator.shared.state
            if st == .starting || st == .running || st == .stopping {
                await LiveCaptureCoordinator.shared.stop(reason: .userStop)
            }
        }
        state = userInitiated ? .canceled : .idle
        statusMessage = userInitiated ? "已停止本次自动排轴" : ""
        activeIdentityKey = nil
        userFacingStatus = nil
        LyricsE2ELog.log("AUTO_ALIGN cancel user=\(userInitiated)")
    }

    public func retry() {
        cancelCurrentJob(userInitiated: false)
        state = .idle
        statusMessage = "准备重新尝试…"
        userFacingStatus = nil
        scheduleEvaluate()
    }

    /// Product surfaces call this after session/lyrics settle (in addition to Combine).
    public func notePlaybackContextChanged() {
        scheduleEvaluate()
    }

    private var evaluateWorkItem: DispatchWorkItem?
    /// Throttle (not debounce): PlaybackState publishes `currentTime` every
    /// ~0.2s while playing. Debounce-after-silence never fires during playback.
    private var lastEvaluateScheduledAt: Date = .distantPast
    private let evaluateMinInterval: TimeInterval = 0.4

    private func scheduleEvaluate() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEvaluateScheduledAt)
        if elapsed >= evaluateMinInterval {
            lastEvaluateScheduledAt = now
            evaluateWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.evaluateTrigger() }
            }
            evaluateWorkItem = item
            DispatchQueue.main.async(execute: item)
            return
        }
        // Coalesce: ensure one trailing evaluate after the quiet gap.
        if evaluateWorkItem != nil { return }
        let delay = evaluateMinInterval - elapsed
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.lastEvaluateScheduledAt = Date()
                self?.evaluateWorkItem = nil
                self?.evaluateTrigger()
            }
        }
        evaluateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func evaluateTrigger() {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        // Re-read UserDefaults so CLI `defaults write` and Settings UI stay consistent.
        let defaultsEnabled = UserDefaults.lyricsQ.object(forKey: AppSettingsStore.Key.automaticAlignmentEnabled) as? Bool
        let settings = AppSettingsStore.shared
        if let defaultsEnabled, settings.automaticAlignmentEnabled != defaultsEnabled {
            settings.automaticAlignmentEnabled = defaultsEnabled
        }
        guard settings.automaticAlignmentEnabled else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=switch_off stored=\(String(describing: defaultsEnabled))")
            if state != .idle && state != .canceled && state != .completed {
                cancelCurrentJob(userInitiated: false)
            }
            if state != .capturing && state != .aligning && state != .evaluating {
                state = .idle
                userFacingStatus = nil
                if statusMessage.isEmpty == false && lastDecision == nil {
                    statusMessage = ""
                }
            }
            return
        }
        guard let playback else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=no_playback_bound")
            return
        }
        // Never hijack manual assist capture.
        #if DEBUG
        if playback.assistPhase == .capturing || playback.assistPhase == .merging || playback.assistPhase == .explaining {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=assist_active phase=\(playback.assistPhase)")
            return
        }
        #endif
        guard playback.hasLiveTrack, !playback.isMockPreviewMode else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=no_live_track hasLive=\(playback.hasLiveTrack) mock=\(playback.isMockPreviewMode)")
            if jobTask == nil { state = .waitingForPlayback; statusMessage = "等待播放" }
            return
        }
        let sourceEligibility = playback.liveCaptureEligibility(requiresPlaying: false)
        if !sourceEligibility.isAllowed && sourceEligibility.isUnsupportedSource {
            LyricsE2ELog.log(
                "AUTO_ALIGN gate=false reason=unsupported_source source=\(playback.playbackSourceIdentity.rawValue)"
            )
            if jobTask != nil {
                cancelCurrentJob(userInitiated: false)
            }
            state = .deferred
            statusMessage = "当前播放来源不支持自动捕获"
            userFacingStatus = Self.unsupportedSourceStatus
            return
        }
        guard let identity = playback.currentTrackIdentity else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=no_track_identity")
            return
        }
        guard playback.isPlaying else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=not_playing state=\(state.rawValue)")
            if state == .capturing || state == .aligning {
                // Pause: stop accumulating new audio; keep job/progress for resume.
                let captureState = LiveCaptureCoordinator.shared.state
                if captureState == .running || captureState == .stopping {
                    Task { @MainActor in
                        await LiveCaptureCoordinator.shared.stop(reason: .userStop)
                    }
                }
                state = .paused
                statusMessage = "已暂停，进度已保留"
            } else if jobTask == nil {
                state = .waitingForPlayback
                statusMessage = "等待播放"
            }
            return
        }
        guard playback.liveCaptureEligibility().isAllowed else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=source_or_playback_unavailable")
            if jobTask == nil {
                state = .waitingForPlayback
                statusMessage = "等待可用播放来源"
            }
            return
        }

        // Eligibility: plain lyrics, not full sync, not locked, has version id
        guard let plain = playback.lyricsSession.state.plainDocument ?? playback.lyricsSession.state.document,
              !plain.isSynchronized else {
            let doc = playback.lyricsSession.state.document
            LyricsE2ELog.log(
                "AUTO_ALIGN gate=false reason=no_plain_or_already_synced hasDoc=\(doc != nil) sync=\(doc?.isSynchronized ?? playback.lyricsSession.isSynchronized) sessionSync=\(playback.lyricsSession.isSynchronized)"
            )
            if jobTask == nil {
                state = .idle
                statusMessage = ""
                userFacingStatus = nil
            }
            return
        }
        guard plain.lines.contains(where: {
            !$0.originalText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        }) else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=empty_lyrics")
            return
        }
        guard let parentVersionID = playback.lyricsSession.activeLyricsVersionID else {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=no_active_version_id")
            return
        }
        // Locked sync versions already excluded by !isSynchronized path for plain; also skip if active is locked synced
        if playback.lyricsSession.isSynchronized {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=session_marked_synchronized")
            return
        }

        let key = identity.stableKey
        if let active = activeIdentityKey, active != key, jobTask != nil {
            LyricsE2ELog.log("AUTO_ALIGN gate=false reason=identity_mismatch_inflight")
            // track change handled by cancel in playback invalidate
            return
        }
        if jobTask != nil, activeIdentityKey == key {
            LyricsE2ELog.log("AUTO_ALIGN gate=skip reason=job_already_running key=\(key.prefix(24))")
            return // already running for this song
        }
        if state == .completed, activeIdentityKey == key {
            LyricsE2ELog.log("AUTO_ALIGN gate=skip reason=already_completed key=\(key.prefix(24))")
            return
        }

        LyricsE2ELog.log(
            "AUTO_ALIGN gate=true identity=\(key.prefix(32)) version=\(parentVersionID.uuidString.prefix(8)) lines=\(plain.lines.count) playing=\(playback.isPlaying)"
        )
        startJob(
            playback: playback,
            identity: identity,
            plain: plain,
            parentVersionID: parentVersionID
        )
    }

    private func startJob(
        playback: PlaybackState,
        identity: TrackIdentity,
        plain: LyricsDocument,
        parentVersionID: UUID
    ) {
        guard playback.liveCaptureEligibility().isAllowed else {
            state = .deferred
            statusMessage = "当前播放来源不支持自动捕获"
            userFacingStatus = Self.unsupportedSourceStatus
            return
        }
        generation &+= 1
        let gen = generation
        let sessionGuard = AutomaticLiveCaptureSessionGuard(
            source: playback.playbackSourceIdentity,
            identityKey: identity.stableKey,
            generation: gen
        )
        activeSessionGuard = sessionGuard
        activeIdentityKey = identity.stableKey
        lastError = nil
        lastDecision = nil
        userFacingStatus = nil
        state = .capturing
        statusMessage = "正在生成时间轴"
        LyricsE2ELog.log("AUTO_ALIGN start identity=\(identity.stableKey.prefix(32))")

        // Prefer Whisper experimental for product MVP when available.
        let whisper = WhisperCLISpeechEngine()
        if whisper.isAvailable {
            UserDefaults.lyricsQ.set(
                SpeechEngineID.whisperCLI.rawValue,
                forKey: SpeechEngineRegistry.userDefaultsKey
            )
        }

        jobTask?.cancel()
        jobTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let sourceHash = playback.lyricsSession.activeSourceContentHash
                ?? LyricsPersistenceMapper.sourceContentHash(document: plain)
            LiveCaptureCoordinator.shared.bind(playback: playback)

            // Capture a segment of the currently playing song (user already playing).
            let seconds = Double(
                ProcessInfo.processInfo.environment["SPOTIFYLYRICS_AUTO_ALIGN_SECONDS"] ?? "55"
            ) ?? 55
            let coordinator = LiveCaptureCoordinator.shared
            let generationBeforeStart = coordinator.lastStartedGeneration
            await coordinator.start(
                autoStopAfter: max(25, seconds),
                runPartialAlignment: true
            )
            let startedGeneration = coordinator.lastStartedGeneration
            guard gen == self.generation,
                  startedGeneration != generationBeforeStart,
                  !Task.isCancelled,
                  self.accepts(sessionGuard, playback: playback) else {
                self.markStaleJobCancelled()
                return
            }

            await coordinator.waitUntilIdle(timeoutSeconds: 240)
            guard gen == self.generation,
                  coordinator.lastStartedGeneration == startedGeneration,
                  !Task.isCancelled,
                  self.accepts(sessionGuard, playback: playback) else {
                self.markStaleJobCancelled()
                return
            }

            // Identity still matches?
            guard playback.currentTrackIdentity?.stableKey == identity.stableKey else {
                self.markStaleJobCancelled(message: "歌曲或播放来源已切换，任务已取消")
                return
            }

            self.state = .aligning
            self.statusMessage = "正在整理时间建议…"

            guard self.accepts(sessionGuard, playback: playback) else {
                self.markStaleJobCancelled()
                return
            }

            guard let handoff = coordinator.lastAlignmentHandoff,
                  handoff.generation == startedGeneration else {
                self.markStaleJobCancelled(message: "捕获结果不属于本次自动任务，已丢弃")
                return
            }
            guard let report = handoff.report else {
                let kind = handoff.failureKind
                let engine = SpeechEngineRegistry.resolve()
                if kind == .cancelled || Task.isCancelled {
                    self.state = .canceled
                    self.statusMessage = "已取消"
                    self.userFacingStatus = Self.statusForCaptureFailure(
                        kind: .cancelled,
                        message: handoff.message,
                        fallback: "已取消"
                    )
                } else if !engine.isAvailable {
                    self.state = .deferred
                    self.statusMessage = "自动排轴引擎尚未准备好"
                    self.lastError = "engine unavailable (\(SpeechEngineRegistry.activeEngineID.rawValue))"
                    self.userFacingStatus = Self.engineUnavailableStatus
                    LyricsE2ELog.log("AUTO_ALIGN engine unavailable id=\(SpeechEngineRegistry.activeEngineID.rawValue)")
                } else {
                    self.state = .deferred
                    self.statusMessage = "本次证据不足，等待继续播放"
                    self.lastDecision = "deferred"
                    self.lastError = handoff.message ?? kind?.rawValue
                    self.userFacingStatus = Self.statusForCaptureFailure(
                        kind: kind,
                        message: handoff.message,
                        fallback: "未能生成建议时间"
                    )
                }
                self.jobTask = nil
                LyricsE2ELog.log("AUTO_ALIGN no report kind=\(kind?.rawValue ?? "nil")")
                return
            }

            self.state = .evaluating
            let draft = AssistedCandidateMerger.merge(report: report, plainLines: plain.lines)
            let force = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_AUTO_ALIGN_FORCE_COMPLETE"] == "1"
            let engineOK = SpeechEngineRegistry.resolve().isAvailable
            let gate = AutomaticAlignmentQualityGate.evaluate(
                draft: draft,
                plainLines: plain.lines,
                trackDuration: playback.currentTrack.duration,
                engineAvailable: engineOK,
                forceComplete: force
            )
            self.lastDecision = gate.decision.rawValue
            LyricsE2ELog.log(
                "AUTO_ALIGN gate=\(gate.decision.rawValue) reason=\(gate.reason) timed=\(gate.timedLineCount)/\(gate.requiredLineCount)"
            )

            let progress = AutomaticAlignmentProgressStore.merge(
                existing: AutomaticAlignmentProgressStore.load(
                    identityKey: identity.stableKey,
                    sourceHash: sourceHash
                ),
                identityKey: identity.stableKey,
                parentVersionID: parentVersionID,
                sourceHash: sourceHash,
                engineID: SpeechEngineRegistry.activeEngineID.rawValue,
                draft: draft,
                decision: gate.decision.rawValue,
                reason: gate.reason
            )
            try? AutomaticAlignmentProgressStore.save(progress)

            switch gate.decision {
            case .completeAndAdopt:
                guard self.accepts(sessionGuard, playback: playback) else {
                    self.markStaleJobCancelled()
                    return
                }
                await self.completeAndAdopt(
                    playback: playback,
                    identity: identity,
                    plain: plain,
                    parentVersionID: parentVersionID,
                    sourceHash: sourceHash,
                    draft: draft,
                    report: report,
                    progress: progress,
                    sessionGuard: sessionGuard
                )
            case .accumulate:
                self.state = .accumulating
                self.statusMessage = "已保存部分进度"
                self.userFacingStatus = UserFacingStatus(
                    title: "已保留部分可靠进度",
                    recoveryHint: "请继续播放以收集更多证据；未完成结果不会自动采用。"
                )
                // Merge progress into session as partial explicit times (not full sync)
                let partialDoc = AutomaticAlignmentProgressStore.applyProgress(progress, to: plain)
                // Do not adopt as synchronized; only keep progress file for next run.
                _ = partialDoc
                LyricsE2ELog.log("AUTO_ALIGN accumulate timed=\(progress.timedLines.count)")
            case .reject:
                self.state = .failed
                self.statusMessage = "本次无法可靠完成"
                self.lastError = gate.reason
                self.userFacingStatus = Self.statusForQualityGate(reason: gate.reason)
            case .deferred:
                self.state = .deferred
                self.statusMessage = "等待继续播放"
                self.userFacingStatus = Self.statusForInsufficientEvidence(reason: gate.reason)
            }

            self.jobTask = nil
        }
    }

    private func accepts(
        _ sessionGuard: AutomaticLiveCaptureSessionGuard,
        playback: PlaybackState
    ) -> Bool {
        sessionGuard.accepts(
            source: playback.playbackSourceIdentity,
            identityKey: playback.liveTrackIdentity?.stableKey,
            generation: generation,
            providerReady: playback.providerStatus.isReady
                && playback.hasLiveTrack
                && !playback.isMockPreviewMode
        )
    }

    private func markStaleJobCancelled(message: String = "歌曲或播放来源已切换，任务已取消") {
        state = .canceled
        statusMessage = message
        jobTask = nil
        activeIdentityKey = nil
        activeSessionGuard = nil
        userFacingStatus = nil
        LyricsE2ELog.log("AUTO_ALIGN drop stale job reason=source_or_identity")
    }

    private func completeAndAdopt(
        playback: PlaybackState,
        identity: TrackIdentity,
        plain: LyricsDocument,
        parentVersionID: UUID,
        sourceHash: String,
        draft: AssistedAlignmentDraft,
        report: PartialAlignmentReport,
        progress: AutomaticAlignmentProgressStore.ProgressDocument,
        sessionGuard: AutomaticLiveCaptureSessionGuard
    ) async {
        guard accepts(sessionGuard, playback: playback) else {
            markStaleJobCancelled()
            return
        }
        // Build full synchronized document from progress + draft
        var lines = plain.lines
        let map = Dictionary(uniqueKeysWithValues: progress.timedLines.map { ($0.lyricLineIndex, $0) })
        for i in lines.indices {
            if let rec = map[i] {
                lines[i].timestamp = rec.startTime
                lines[i].endTime = rec.endTime
            }
        }
        // Fill any remaining gaps (empty lines / force-complete harness) monotonically.
        var lastT: TimeInterval = 0
        for i in lines.indices {
            if lines[i].timestamp.isFinite && lines[i].timestamp >= 0 {
                lastT = max(lastT, lines[i].timestamp)
            } else {
                lines[i].timestamp = lastT
            }
        }
        let maxStart = lines.map(\.timestamp).max() ?? 0
        let trackDur = max(playback.currentTrack.duration, plain.duration ?? 0)
        // saveAlignedVersion requires times ≤ audioDuration; use full track span.
        let audioDuration = max(trackDur, maxStart + 1.0, report.candidate.capturedDuration)
        let conf = max(0.5, min(1.0, report.candidate.overallConfidence))
        let document = LyricsDocument(
            identity: identity,
            title: plain.title,
            artist: plain.artist,
            album: plain.album,
            duration: trackDur > 0 ? trackDur : audioDuration,
            lines: lines,
            isSynchronized: true,
            source: .automaticAlignment,
            confidence: conf,
            providerSourceID: plain.providerSourceID,
            language: plain.language
        )

        // Build AlignmentReport for saveAlignedVersion
        let alignedLines: [AlignedLyricLine] = lines.map { line in
            AlignedLyricLine(
                id: line.id,
                originalText: line.originalText,
                kanaText: line.kanaText,
                romajiText: line.romajiText,
                translationText: line.translationText,
                rubyTokens: line.rubyTokens,
                startTime: line.timestamp,
                endTime: line.endTime,
                confidence: conf,
                status: .aligned,
                evidence: AlignmentLineEvidence(kind: .directSpeech, matchScore: conf, note: "auto-mvp1")
            )
        }
        let alignmentReport = AlignmentReport(
            identity: identity,
            lines: alignedLines,
            audioDuration: audioDuration,
            audioSHA256: "auto-\(sourceHash.prefix(12))",
            modelID: SpeechEngineRegistry.activeEngineID.rawValue,
            usedVocalsStem: false,
            overallConfidence: conf,
            sourceVersionID: parentVersionID,
            sourceContentHash: sourceHash,
            parameters: AlignmentParameters(
                algorithmVersion: "auto-align-mvp1",
                recognizerID: SpeechEngineRegistry.activeEngineID.rawValue
            )
        )

        guard let repository = playback.lyricsSession.repositoryForAutomaticAlignment else {
            state = .failed
            statusMessage = "无法保存自动排轴结果"
            lastError = "repository_unavailable"
            userFacingStatus = Self.persistenceFailureStatus
            return
        }

        do {
            guard accepts(sessionGuard, playback: playback) else {
                markStaleJobCancelled()
                return
            }
            let saved = try await repository.saveAlignedVersion(
                AlignmentPersistenceRequest(
                    track: playback.currentTrack,
                    identity: identity,
                    parentVersionID: parentVersionID,
                    parentSourceContentHash: sourceHash,
                    document: document,
                    report: alignmentReport,
                    lockResult: false
                )
            )
            guard let versionID = saved.versionID else {
                state = .failed
                statusMessage = "本次无法可靠完成"
                lastError = "save_\(saved.disposition)"
                userFacingStatus = Self.persistenceFailureStatus
                LyricsE2ELog.log("AUTO_ALIGN save rejected disposition=\(saved.disposition)")
                return
            }
            switch saved.disposition {
            case .inserted, .duplicate:
                break
            default:
                state = .failed
                statusMessage = "本次无法可靠完成"
                lastError = "save_\(saved.disposition)"
                userFacingStatus = Self.persistenceFailureStatus
                LyricsE2ELog.log("AUTO_ALIGN save rejected disposition=\(saved.disposition)")
                return
            }
            guard accepts(sessionGuard, playback: playback) else {
                markStaleJobCancelled()
                return
            }
            let hash = saved.sourceContentHash ?? LyricsPersistenceMapper.sourceContentHash(document: document)
            playback.lyricsSession.adoptPersisted(
                document: document,
                versionID: versionID,
                sourceContentHash: hash
            )
            state = .completed
            statusMessage = "已完成"
            userFacingStatus = nil
            LyricsE2ELog.log("AUTO_ALIGN completeAndAdopt version=\(versionID.uuidString.prefix(8))")
        } catch {
            if Task.isCancelled {
                return
            }
            guard accepts(sessionGuard, playback: playback) else {
                self.markStaleJobCancelled()
                return
            }
            state = .failed
            statusMessage = "本次无法可靠完成"
            lastError = error.localizedDescription
            userFacingStatus = Self.persistenceFailureStatus
            LyricsE2ELog.log("AUTO_ALIGN save error=\(error.localizedDescription)")
        }
    }

    /// Called on track change from PlaybackState.
    public func notifyTrackChanged(previousKey: String?, nextKey: String?) {
        guard let prev = previousKey, let next = nextKey, prev != next else { return }
        if jobTask != nil || (state != .idle && state != .completed && state != .canceled) {
            LyricsE2ELog.log("AUTO_ALIGN trackChanged cancel prev=\(prev.prefix(16))")
            cancelCurrentJob(userInitiated: false)
            state = .idle
            statusMessage = ""
        }
        activeIdentityKey = nil
        activeSessionGuard = nil
        userFacingStatus = nil
        scheduleEvaluate()
    }

    /// Called when the provider reports a different active source. A running
    /// Spotify capture is never allowed to continue into Music/unknown, and a
    /// late report from the old source cannot be adopted.
    public func notifyPlaybackSourceChanged(
        previous: PlaybackSourceIdentity,
        next: PlaybackSourceIdentity
    ) {
        guard previous != next else { return }
        if jobTask != nil || state == .capturing || state == .aligning || state == .evaluating {
            cancelCurrentJob(userInitiated: false)
            state = .idle
            statusMessage = ""
        }
        activeIdentityKey = nil
        activeSessionGuard = nil
        userFacingStatus = nil
        LyricsE2ELog.log(
            "AUTO_ALIGN sourceChanged previous=\(previous.rawValue) next=\(next.rawValue)"
        )
        scheduleEvaluate()
    }

    public func notifySeek(from: TimeInterval, to: TimeInterval) {
        LiveCaptureCoordinator.shared.notifyPlaybackPositionJump(
            from: from,
            to: to,
            isPlaying: playback?.isPlaying ?? false
        )
    }
}
