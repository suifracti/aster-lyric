import Foundation
import Combine
import ScreenCaptureKit
import CoreMedia
import AVFoundation

/// DEBUG-only ScreenCaptureKit spike: capture **Spotify app audio only**,
/// emit PCM statistics, never run ASR/alignment, never write lyrics or
/// open the formal database.
///
/// Entry points:
/// - Debug menu: 「排轴捕获 Spike」
/// - Env: `SPOTIFYLYRICS_SCK_SPIKE=1` (optional duration via
///   `SPOTIFYLYRICS_SCK_SPIKE_SECONDS`, default 20)
///
/// Deletable as a unit: this file + menu wiring + contract grep.
@MainActor
public final class SpotifyScreenCaptureAudioSpike: NSObject, ObservableObject {
    public static let shared = SpotifyScreenCaptureAudioSpike()

    public enum State: String, Sendable {
        case idle
        case discovering
        case capturing
        case stopping
        case failed
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var snapshot = PCMStatsSnapshot()

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.spotifylyrics.sck.spike.audio")
    private let stats = PCMStatsAccumulator()
    private var statsTimer: Timer?
    private var autoStopTask: Task<Void, Never>?
    private var workDirectory: URL?
    private var selectedAppsDescription: String = ""
    private weak var playback: PlaybackState?
    private var playbackCancellables = Set<AnyCancellable>()
    private var activeCaptureGuard: AutomaticLiveCaptureSessionGuard?
    private var captureGeneration: UInt64 = 0
    private let sampleDeliveryGate = CaptureSampleDeliveryGate()

    /// Optional sink for S2 continuity layer. Invoked on the capture queue.
    /// The generation is assigned by the coordinator and is invalidated before
    /// a segment is finalized. It prevents queued samples from being relabeled
    /// as belonging to a later segment.
    nonisolated(unsafe) public var audioSampleHandler: ((CMSampleBuffer, UInt64) -> Void)?

    private override init() {
        super.init()
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        Self.scavengeOrphanTempDirectories()
        #if DEBUG
        // Prefer S2 auto-start when both envs are set.
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_S2"] == "1" {
            // LiveCaptureCoordinator owns start sequencing.
        } else if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_SPIKE"] == "1" {
            let seconds = Double(ProcessInfo.processInfo.environment["SPOTIFYLYRICS_SCK_SPIKE_SECONDS"] ?? "20") ?? 20
            Task { @MainActor in
                // Allow the app scene to finish launching.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self.start(autoStopAfter: max(5, seconds))
            }
        }
        #endif
    }

    deinit {
        // Best-effort; MainActor cleanup also runs on stop.
        sampleQueue.sync { }
    }

    // MARK: - Public control

    public func bind(playback: PlaybackState) {
        playbackCancellables.removeAll()
        self.playback = playback
        playback.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluateBoundPlaybackContext()
                }
            }
            .store(in: &playbackCancellables)
    }

    /// Assign the currently open coordinator segment's sample generation.
    /// Zero means that no sample may be forwarded to the coordinator.
    public func setSampleDeliveryGeneration(_ generation: UInt64) {
        sampleDeliveryGate.setGeneration(generation)
    }

    /// Invalidate queued callbacks before a segment is closed or a stream is
    /// replaced. The serial callback queue is drained while the gate is off,
    /// so a callback already queued before the boundary cannot enter the next
    /// segment after it is assigned a new generation.
    public func invalidateSampleDeliveryAndDrain() {
        sampleDeliveryGate.invalidate()
        sampleQueue.sync { }
    }

    public func start(
        autoStopAfter seconds: TimeInterval? = nil,
        sessionGuard: AutomaticLiveCaptureSessionGuard? = nil
    ) async {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        guard state == .idle || state == .failed else {
            SCKSpikeLog.log("start ignored state=\(state.rawValue)")
            return
        }
        guard let playback else {
            lastError = "没有绑定当前播放来源，已拒绝 Spotify discovery"
            SCKSpikeLog.log("SPIKE start rejected reason=no_playback_bound")
            return
        }
        // Keep the existing paused-session behavior for manual/debug entry;
        // automatic alignment gates playing state before reaching here.
        let eligibility = playback.liveCaptureEligibility(requiresPlaying: false)
        guard eligibility.isAllowed else {
            lastError = playback.playbackSourceIdentity == .appleMusic
                ? "当前 Apple Music 播放不支持 Spotify discovery/capture"
                : "当前播放来源不支持 Spotify discovery/capture（\(eligibility.reason)）"
            SCKSpikeLog.log(
                "SPIKE start rejected source=\(playback.playbackSourceIdentity.rawValue) reason=\(eligibility.reason)"
            )
            return
        }
        guard let identityKey = playback.liveTrackIdentity?.stableKey else {
            lastError = "当前播放来源缺少有效歌曲身份，已拒绝 Spotify discovery"
            SCKSpikeLog.log("SPIKE start rejected reason=no_track_identity")
            return
        }
        captureGeneration &+= 1
        let startGuard = sessionGuard ?? AutomaticLiveCaptureSessionGuard(
            source: playback.playbackSourceIdentity,
            identityKey: identityKey,
            generation: captureGeneration
        )
        guard startGuard.source == .spotifyDesktop,
              startGuard.identityKey == identityKey else {
            lastError = "播放来源或歌曲已切换，已拒绝 Spotify discovery"
            SCKSpikeLog.log("SPIKE start rejected reason=stale_start_guard")
            return
        }
        activeCaptureGuard = startGuard
        lastError = nil
        state = .discovering
        stats.reset()
        snapshot = PCMStatsSnapshot()
        SCKSpikeLog.reset()
        SCKSpikeLog.log("SPIKE start formal_db_opened=NO (spike never opens SQLite)")
        SCKSpikeLog.log("SPIKE policy=spotify-app-audio-only no-mic no-screen-save no-asr no-align")

        do {
            let discovery = try await Self.discoverSpotifyApplications()
            guard accepts(startGuard) else {
                await rejectStaleStart(startGuard)
                return
            }
            selectedAppsDescription = discovery.summary
            SCKSpikeLog.log("DISCOVER \(discovery.summary)")
            for line in discovery.detailLines {
                SCKSpikeLog.log("DISCOVER_APP \(line)")
            }
            guard !discovery.captureTargets.isEmpty else {
                throw SpikeError.spotifyNotFound
            }

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard accepts(startGuard) else {
                await rejectStaleStart(startGuard)
                return
            }
            guard let display = content.displays.first else {
                throw SpikeError.noDisplay
            }

            // Application-scoped filter: never fall back to full-display capture.
            let filter = SCContentFilter(
                display: display,
                including: discovery.captureTargets,
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            // Minimal video geometry required by the stream object; we never
            // register a .screen output and never persist frames.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            if #available(macOS 15.0, *) {
                config.captureMicrophone = false
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            // Audio output only — no screen consumer.
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            self.stream = stream
            sampleDeliveryGate.activate(stream: stream)
            SCKSpikeLog.log("STREAM configured capturesAudio=1 screenOutput=0 mic=0 sampleRate=48000 channels=2")

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpotifyLyricsCapture", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            workDirectory = work
            // Marker only — proves temp root; no PCM/WAV payload is written in S1.
            try "s1-spike-no-audio-payload\n".write(
                to: work.appendingPathComponent("README.spike.txt"),
                atomically: true,
                encoding: .utf8
            )
            SCKSpikeLog.log("TEMP dir=\(work.path) (marker only; no audio files)")

            guard accepts(startGuard) else {
                await rejectStaleStart(startGuard)
                return
            }
            try await stream.startCapture()
            guard accepts(startGuard) else {
                await rejectStaleStart(startGuard)
                return
            }
            state = .capturing
            SCKSpikeLog.log("STREAM started")

            statsTimer?.invalidate()
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.publishStats(reason: "tick")
                }
            }

            autoStopTask?.cancel()
            if let seconds {
                autoStopTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    SCKSpikeLog.log("SPIKE auto-stop after \(seconds)s")
                    await self.stop(reason: "auto-stop")
                }
            }
        } catch {
            if !accepts(startGuard) {
                await rejectStaleStart(startGuard)
                return
            }
            activeCaptureGuard = nil
            let message = (error as? SpikeError)?.errorDescription ?? error.localizedDescription
            lastError = message
            state = .failed
            SCKSpikeLog.log("SPIKE failed error=\(message)")
            await cleanupResources(reason: "start-failed")
        }
    }

    public func stop(reason: String = "user") async {
        guard state == .capturing || state == .discovering || state == .failed else { return }
        activeCaptureGuard = nil
        state = .stopping
        SCKSpikeLog.log("SPIKE stop reason=\(reason)")
        autoStopTask?.cancel()
        autoStopTask = nil
        statsTimer?.invalidate()
        statsTimer = nil
        publishStats(reason: "final")
        await cleanupResources(reason: reason)
        state = .idle
        SCKSpikeLog.log("SPIKE stopped idle")
    }

    private func accepts(_ startGuard: AutomaticLiveCaptureSessionGuard) -> Bool {
        guard activeCaptureGuard == startGuard,
              let playback else { return false }
        return startGuard.accepts(
            source: playback.playbackSourceIdentity,
            identityKey: playback.liveTrackIdentity?.stableKey,
            generation: startGuard.generation,
            providerReady: playback.providerStatus.isReady
                && playback.hasLiveTrack
                && !playback.isMockPreviewMode
        )
    }

    private func rejectStaleStart(_ startGuard: AutomaticLiveCaptureSessionGuard) async {
        guard activeCaptureGuard == startGuard else { return }
        activeCaptureGuard = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        statsTimer?.invalidate()
        statsTimer = nil
        await cleanupResources(reason: "stale-start")
        state = .idle
        SCKSpikeLog.log("SPIKE drop stale startup provenance")
    }

    private func evaluateBoundPlaybackContext() {
        guard activeCaptureGuard != nil,
              state == .discovering || state == .capturing else { return }
        guard let startGuard = activeCaptureGuard, accepts(startGuard) else {
            Task { @MainActor [weak self] in
                await self?.stop(reason: "playback-context-changed")
            }
            return
        }
    }

    // MARK: - Discovery

    private struct Discovery {
        let captureTargets: [SCRunningApplication]
        let summary: String
        let detailLines: [String]
    }

    private static func discoverSpotifyApplications() async throws -> Discovery {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let all = content.applications
        let related = all.filter { app in
            let bid = app.bundleIdentifier.lowercased()
            // Exact Spotify Desktop client, or other com.spotify.* helpers
            // that ScreenCaptureKit exposes. Never match com.spotifylyrics.*.
            if bid == "com.spotify.client" { return true }
            if bid.hasPrefix("com.spotify."), !bid.hasPrefix("com.spotifylyrics") {
                return true
            }
            return false
        }
        let primary = related.filter { $0.bundleIdentifier == "com.spotify.client" }
        // Capture targets: primary client only. Helpers are logged, not assumed
        // to own audio until S1 evidence says otherwise.
        let targets = primary.isEmpty ? [] : primary
        let details = related.map { app in
            "pid=\(app.processID) bundle=\(app.bundleIdentifier) name=\(app.applicationName) captureTarget=\(app.bundleIdentifier == "com.spotify.client")"
        }
        let summary = "related=\(related.count) primary=\(primary.count) captureTargets=\(targets.count)"
        return Discovery(captureTargets: targets, summary: summary, detailLines: details)
    }

    // MARK: - Stats

    private func publishStats(reason: String) {
        let snap = stats.snapshot(selectedApps: selectedAppsDescription)
        snapshot = snap
        SCKSpikeLog.log(
            "PCM reason=\(reason) buffers=\(snap.bufferCount) samples=\(snap.sampleCount) duration_s=\(String(format: "%.3f", snap.capturedDuration)) inRate=\(snap.inputSampleRate) ch=\(snap.channelCount) peak=\(String(format: "%.4f", snap.peak)) rms=\(String(format: "%.4f", snap.rms)) active=\(snap.receivingActiveAudio) videoBuffers=\(snap.videoBufferCount)"
        )
    }

    private func cleanupResources(reason: String) async {
        invalidateSampleDeliveryAndDrain()
        if let stream {
            do {
                try await stream.stopCapture()
                SCKSpikeLog.log("STREAM stopCapture ok reason=\(reason)")
            } catch {
                SCKSpikeLog.log("STREAM stopCapture error=\(error.localizedDescription)")
            }
            try? stream.removeStreamOutput(self, type: .audio)
        }
        self.stream = nil
        sampleDeliveryGate.invalidate()

        if let workDirectory {
            let path = workDirectory.path
            try? FileManager.default.removeItem(at: workDirectory)
            let exists = FileManager.default.fileExists(atPath: path)
            SCKSpikeLog.log("TEMP cleanup path=\(path) exists_after=\(exists)")
        }
        workDirectory = nil
        Self.scavengeOrphanTempDirectories()
    }

    private static func scavengeOrphanTempDirectories() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotifyLyricsCapture", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for child in children {
            try? FileManager.default.removeItem(at: child)
            SCKSpikeLog.log("TEMP scavenge removed=\(child.lastPathComponent)")
        }
    }
}

// MARK: - Stream callbacks

extension SpotifyScreenCaptureAudioSpike: SCStreamDelegate, SCStreamOutput {
    nonisolated public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        if type == .screen {
            // Must never happen if we only registered .audio; count if it does.
            stats.noteVideoBuffer()
            return
        }
        guard type == .audio else { return }
        guard sampleDeliveryGate.matches(stream: stream) else { return }
        stats.ingestAudio(sampleBuffer)
        if let generation = sampleDeliveryGate.generation(for: stream) {
            audioSampleHandler?(sampleBuffer, generation)
        }
    }

    nonisolated public func stream(_ stream: SCStream, didStopWithError error: Error) {
        SCKSpikeLog.log("STREAM didStopWithError=\(error.localizedDescription)")
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.state = .failed
            await self.cleanupResources(reason: "stream-error")
        }
    }
}

/// Thread-safe provenance for ScreenCaptureKit callbacks. A stream identity
/// prevents a callback from an old stream being re-labeled after restart;
/// generation is controlled by the coordinator at segment boundaries.
private final class CaptureSampleDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeStreamID: ObjectIdentifier?
    private var activeGeneration: UInt64 = 0

    func activate(stream: SCStream) {
        lock.lock()
        defer { lock.unlock() }
        activeStreamID = ObjectIdentifier(stream)
        activeGeneration = 0
    }

    func setGeneration(_ generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard activeStreamID != nil else { return }
        activeGeneration = generation
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        activeStreamID = nil
        activeGeneration = 0
    }

    func generation(for stream: SCStream) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard activeStreamID == ObjectIdentifier(stream), activeGeneration != 0 else {
            return nil
        }
        return activeGeneration
    }

    func matches(stream: SCStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeStreamID == ObjectIdentifier(stream)
    }
}

// MARK: - Stats types

public struct PCMStatsSnapshot: Equatable, Sendable {
    public var inputSampleRate: Double = 0
    public var channelCount: Int = 0
    public var sampleCount: Int = 0
    public var bufferCount: Int = 0
    public var videoBufferCount: Int = 0
    public var capturedDuration: TimeInterval = 0
    public var peak: Float = 0
    public var rms: Float = 0
    public var receivingActiveAudio: Bool = false
    public var selectedApps: String = ""
}

private final class PCMStatsAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var inputSampleRate: Double = 0
    private var channelCount: Int = 0
    private var sampleCount: Int = 0
    private var bufferCount: Int = 0
    private var videoBufferCount: Int = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var lastActiveHostTime: TimeInterval = 0

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        inputSampleRate = 0
        channelCount = 0
        sampleCount = 0
        bufferCount = 0
        videoBufferCount = 0
        peak = 0
        sumSquares = 0
        lastActiveHostTime = 0
    }

    func noteVideoBuffer() {
        lock.lock()
        videoBufferCount += 1
        lock.unlock()
    }

    func ingestAudio(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee
        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        // Query size first.
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSize > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<Int>.alignment)
        defer { raw.deallocate() }
        let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockOut: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockOut
        )
        guard status == noErr else { return }
        _ = blockOut

        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var framePeak: Float = 0
        var frameSumSquares: Double = 0
        var frames = 0

        for buffer in abl {
            guard let data = buffer.mData else { continue }
            // ScreenCaptureKit typically delivers float32 non-interleaved or int16.
            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                let ptr = data.assumingMemoryBound(to: Float.self)
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                frames = max(frames, n)
                for i in 0..<n {
                    let v = abs(ptr[i])
                    if v > framePeak { framePeak = v }
                    frameSumSquares += Double(ptr[i] * ptr[i])
                }
            } else {
                let ptr = data.assumingMemoryBound(to: Int16.self)
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                frames = max(frames, n)
                for i in 0..<n {
                    let f = Float(ptr[i]) / Float(Int16.max)
                    let v = abs(f)
                    if v > framePeak { framePeak = v }
                    frameSumSquares += Double(f * f)
                }
            }
        }

        // Prefer ASBD frames when available.
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        if numSamples > 0 { frames = numSamples }

        lock.lock()
        bufferCount += 1
        if asbd.mSampleRate > 0 { inputSampleRate = asbd.mSampleRate }
        if asbd.mChannelsPerFrame > 0 { channelCount = Int(asbd.mChannelsPerFrame) }
        sampleCount += max(0, frames)
        if framePeak > peak { peak = framePeak }
        sumSquares += frameSumSquares
        if framePeak > 0.01 {
            lastActiveHostTime = Date().timeIntervalSince1970
        }
        lock.unlock()
    }

    func snapshot(selectedApps: String) -> PCMStatsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snap = PCMStatsSnapshot()
        snap.inputSampleRate = inputSampleRate
        snap.channelCount = channelCount
        snap.sampleCount = sampleCount
        snap.bufferCount = bufferCount
        snap.videoBufferCount = videoBufferCount
        if inputSampleRate > 0 {
            snap.capturedDuration = Double(sampleCount) / inputSampleRate
        }
        snap.peak = peak
        if sampleCount > 0 {
            snap.rms = Float(sqrt(sumSquares / Double(max(sampleCount, 1))))
        }
        snap.receivingActiveAudio = (Date().timeIntervalSince1970 - lastActiveHostTime) < 1.5 && peak > 0.01
        snap.selectedApps = selectedApps
        return snap
    }
}

// MARK: - Errors / log

private enum SpikeError: Error, LocalizedError {
    case spotifyNotFound
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .spotifyNotFound:
            return "未找到 com.spotify.client。Spike 拒绝退化为全屏/其他 App 捕获。"
        case .noDisplay:
            return "没有可用显示器用于 SCContentFilter（仍仅包含 Spotify 应用，不会捕获全桌面意图）。"
        }
    }
}

enum SCKSpikeLog {
    private static var path: String {
#if DEBUG
        if NativeTestRuntime.isEnabled {
            return NativeTestRuntime.root.appendingPathComponent("capture.log").path
        }
        if DebugAcceptanceDataIsolation.isRequested {
            return DebugAcceptanceDataIsolation.configuration.root.appendingPathComponent("logs/capture.log").path
        }
#endif
        return "/tmp/spotifylyrics-sck-spike.log"
    }
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: path)
        writeUnlocked("LOG_RESET")
    }

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        writeUnlocked(message)
    }

    private static func writeUnlocked(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: url, options: .atomic)
        // Also mirror to stderr for launch agents.
        fputs(line, stderr)
    }
}
