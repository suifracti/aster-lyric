import Accelerate
import AppKit
import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import SwiftUI

/// 随音乐律动: listens to the Spotify app's sound only (ScreenCaptureKit,
/// application-scoped, no microphone, nothing saved) and keeps three numbers
/// up to date — how loud the bass, mids and treble are right now compared
/// with the song so far — plus an estimate of the tempo.
///
/// The levels follow MilkDrop (butterchurn `audioLevels.js`): bands 20–320,
/// 320–2800 and 2800–11025 Hz; each band's sum over a short average (attack
/// 0.2, release 0.5 per 30 fps frame) and over a long one (0.992). Dividing by
/// the long average makes quiet and loud songs both sit around 1; above 1 is
/// "louder than usual right now".
///
/// Separate from automatic alignment's capture; it only runs while the user
/// has turned it on and Spotify is playing in a visible window.
@MainActor
final class V3MusicPulse: NSObject, ObservableObject {
    static let shared = V3MusicPulse()

    enum Status: Equatable { case off, starting, running, failed(String) }
    @Published private(set) var status: Status = .off

    struct Levels: Sendable {
        var bass = 1.0, mid = 1.0, treble = 1.0
        var bassAverage = 1.0
        var bpm: Double?
        var updatedAt: TimeInterval = 0
        /// 24 log-spaced bands, 50 Hz–12 kHz, each against its own long-term
        /// average and mapped to 0…1 (0.5 = that band's usual level).
        var spectrum: [Float] = []
        /// Seconds of unbroken silence. Spotify's own volume at 0 gives a
        /// stream of zeros: everything that follows the sound stands still.
        var silentSeconds: Double = 0
    }
    /// The stream is arriving but has been silent for a while.
    nonisolated static var hearsSilence: Bool {
        let value = levels
        return ProcessInfo.processInfo.systemUptime - value.updatedAt < 2 && value.silentSeconds > 3
    }

    private static let shared_ = OSAllocatedUnfairLock(initialState: Levels())
    /// Read from any thread, at frame rate, without observing the object.
    nonisolated static var levels: Levels { shared_.withLock { $0 } }
    /// Tempo for motion that should keep time. Spotify's own figure for the
    /// song when its cache has one (exact, the number Spotify shows); else the
    /// estimate from listening; nil when neither.
    nonisolated static var currentBPM: Double? {
        if let bpm = analysis.bpm { return bpm }
        let value = levels
        guard value.bpm != nil, ProcessInfo.processInfo.systemUptime - value.updatedAt < 3 else { return nil }
        return value.bpm
    }

    private static let analysisState = OSAllocatedUnfairLock(initialState: SpotifyTrackAnalysis())
    /// The current song's tempo, key and beats from the Spotify cache, while 随音乐律动 is on.
    nonisolated static var analysis: SpotifyTrackAnalysis { analysisState.withLock { $0 } }
    @Published private(set) var analysisRevision = 0
    private var analysisTrackID: String?
    private var analysisTask: Task<Void, Never>?

    /// Reads Spotify's analysis for the song. Beats are prepared by Spotify
    /// a little after a song starts, so a song without them is read again once.
    func setTrack(_ trackID: String?, enabled: Bool) {
        let wanted = enabled ? trackID : nil
        guard wanted != analysisTrackID else { return }
        analysisTrackID = wanted
        analysisTask?.cancel()
        Self.analysisState.withLock { $0 = SpotifyTrackAnalysis() }
        analysisRevision &+= 1
        guard let id = wanted else { return }
        analysisTask = Task { [weak self] in
            // Spotify keeps tempo and beats only for songs it has shown in a
            // list with the BPM column; it may fetch them mid-song. Look again
            // every 30 s for three minutes.
            for attempt in 0..<7 {
                let found = await Task.detached(priority: .utility) { SpotifyTrackAnalysis.load(trackID: id) }.value
                guard !Task.isCancelled, let self, self.analysisTrackID == id else { return }
                Self.analysisState.withLock { $0 = found }
                self.analysisRevision &+= 1
                LyricsE2ELog.log("PULSE analysis id=\(id) bpm=\(found.bpm.map { String($0) } ?? "-") key=\(found.key ?? "-") beats=\(found.beats.count)")
                if found.bpm != nil && !found.beats.isEmpty { return }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private var stream: SCStream?
    private var stopTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.spotifylyrics.music-pulse", qos: .userInitiated)
    nonisolated(unsafe) private var analyzer = PulseAnalyzer()

    /// Turns listening on or off. Stopping waits a moment so a short pause
    /// or a window switch does not restart the stream.
    func setWanted(_ wanted: Bool) {
        if wanted {
            stopTask?.cancel(); stopTask = nil
            guard stream == nil, status != .starting else { return }
            Task { await start() }
        } else if stream != nil, stopTask == nil {
            stopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.stop()
            }
        } else if stream == nil, case .failed = status {
            // Leave the message until the switch is turned on again.
        } else if stream == nil {
            status = .off
        }
    }

    private func start() async {
        status = .starting
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let spotify = content.applications.filter { $0.bundleIdentifier.hasPrefix("com.spotify.client") }
            guard !spotify.isEmpty else { status = .failed("没有找到正在运行的 Spotify"); return }
            guard let display = content.displays.first else { status = .failed("没有可用的显示器"); return }
            let filter = SCContentFilter(display: display, including: spotify, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            if #available(macOS 15.0, *) { configuration.captureMicrophone = false }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            analyzer = PulseAnalyzer()
            try await stream.startCapture()
            self.stream = stream
            status = .running
            LyricsE2ELog.log("PULSE started")
        } catch {
            stream = nil
            status = .failed("需要在“系统设置 › 隐私与安全性 › 屏幕与系统录音”里允许本 App")
            LyricsE2ELog.log("PULSE failed \(error.localizedDescription)")
        }
    }

    private func stop() async {
        stopTask = nil
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        Self.shared_.withLock { $0 = Levels() }
        status = .off
        LyricsE2ELog.log("PULSE stopped")
    }

    fileprivate nonisolated static func publish(_ levels: Levels) {
        shared_.withLock { $0 = levels }
    }
}

extension V3MusicPulse: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid else { return }
        analyzer.ingest(buffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.status = .failed("Spotify 声音中断，切歌或重开 Spotify 后会再试")
            LyricsE2ELog.log("PULSE stopped error=\(error.localizedDescription)")
        }
    }
}

/// Runs on the capture queue only.
struct PulseAnalyzer {
    static let frameSize = 1024
    static let hop = 512
    static let sampleRate = 48_000.0
    static var framesPerSecond: Double { sampleRate / Double(hop) }

    private var pending: [Float] = []
    private var window = [Float](repeating: 0, count: frameSize)
    private let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(frameSize), .FORWARD)
    private var previousLog = [Float](repeating: 0, count: frameSize / 2)
    private var frameCount = 0
    private var average = [1.0, 1.0, 1.0]
    private var longAverage = [1.0, 1.0, 1.0]
    private var flux: [Double] = []
    private var tempoCandidates: [Double] = []
    private var bpm: Double?
    private var loudestBass = 0.0
    private var spectrumLong = [Double](repeating: 0, count: spectrumBands.count)
    private var silentFrames = 0

    /// 频谱: 24 bands spaced evenly in pitch from 50 Hz to 12 kHz, each at
    /// least one FFT bin wide.
    static let spectrumBands: [(Int, Int)] = {
        let hz = sampleRate / Double(frameSize)
        let count = 24, low = 50.0, high = 12_000.0
        var result: [(Int, Int)] = []
        var start = max(1, Int((low / hz).rounded()))
        for i in 1...count {
            let edge = low * pow(high / low, Double(i) / Double(count))
            let end = max(start + 1, min(frameSize / 2, Int((edge / hz).rounded())))
            result.append((start, end))
            start = end
        }
        return result
    }()

    /// Band edges as FFT bins (46.875 Hz each).
    private static let bands: [(Int, Int)] = {
        let hz = sampleRate / Double(frameSize)
        func bin(_ f: Double) -> Int { max(0, min(frameSize / 2 - 1, Int((f / hz).rounded()) - 1)) }
        return [(bin(20), bin(320)), (bin(320), bin(2800)), (bin(2800), bin(11025))]
    }()

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_NORM))
    }

    mutating func ingest(_ buffer: CMSampleBuffer) {
        // Spotify's sound arrives as two separate channels, so the list holds
        // two buffers: ask for its size first (one AudioBufferList is too small).
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<Int>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let data = first.mData else { return }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let left = data.assumingMemoryBound(to: Float.self)
        if buffers.count > 1, let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            for index in 0..<count { pending.append((left[index] + right[index]) * 0.5) }
        } else if first.mNumberChannels == 2 {
            for index in stride(from: 0, to: count - 1, by: 2) { pending.append((left[index] + left[index + 1]) * 0.5) }
        } else {
            pending.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
        }
        _ = blockBuffer
        while pending.count >= Self.frameSize {
            process(Array(pending[0..<Self.frameSize]))
            pending.removeFirst(Self.hop)
        }
    }

    private mutating func process(_ samples: [Float]) {
        guard let setup else { return }
        var windowed = [Float](repeating: 0, count: Self.frameSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.frameSize))
        let half = Self.frameSize / 2
        var realIn = [Float](repeating: 0, count: half), imagIn = [Float](repeating: 0, count: half)
        for index in 0..<half { realIn[index] = windowed[2 * index]; imagIn[index] = windowed[2 * index + 1] }
        var realOut = [Float](repeating: 0, count: half), imagOut = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)
        imagOut[0] = 0   // Nyquist sits in imag[0] for a real transform.
        var magnitude = [Float](repeating: 0, count: half)
        for index in 0..<half { magnitude[index] = (realOut[index] * realOut[index] + imagOut[index] * imagOut[index]).squareRoot() }

        frameCount += 1
        let fps = Self.framesPerSecond
        func perFrame(_ rate: Double) -> Double { pow(rate, 30.0 / fps) }
        var now = [0.0, 0.0, 0.0]
        for (band, range) in Self.bands.enumerated() {
            now[band] = Double(magnitude[range.0..<max(range.0 + 1, range.1)].reduce(0, +))
            let rate = perFrame(now[band] > average[band] ? 0.2 : 0.5)
            average[band] = average[band] * rate + now[band] * (1 - rate)
            let longRate = perFrame(frameCount < 50 ? 0.9 : 0.992)
            longAverage[band] = longAverage[band] * longRate + now[band] * (1 - longRate)
        }

        // Onset strength: how much the spectrum rose since the last frame.
        var rise = 0.0
        for index in 1..<235 {
            let value = log1p(magnitude[index] * 10)
            rise += Double(max(0, value - previousLog[index]))
            previousLog[index] = value
        }
        flux.append(rise)
        if flux.count > Int(fps * 10) { flux.removeFirst(flux.count - Int(fps * 10)) }
        // From 4 s of sound on, once a second. A new tempo replaces the shown
        // one only when two estimates in a row agree, so it does not flicker.
        if frameCount % Int(fps) == 0, flux.count >= Int(fps * 4), let estimate = Self.tempo(flux, fps: fps) {
            if let last = tempoCandidates.last, abs(last - estimate) / estimate < 0.03 {
                bpm = bpm.map { abs($0 - estimate) / estimate < 0.03 ? $0 * 0.6 + estimate * 0.4 : estimate } ?? estimate
            }
            tempoCandidates.append(estimate)
            if tempoCandidates.count > 3 { tempoCandidates.removeFirst() }
        }

        func ratio(_ band: Int, _ value: Double) -> Double { longAverage[band] < 0.001 ? 1 : value / longAverage[band] }
        loudestBass = max(loudestBass, ratio(0, now[0]))
        if frameCount % Int(fps * 5) == 0 {
            LyricsE2ELog.log("PULSE levels bassPeak=\(String(format: "%.2f", loudestBass)) bpm=\(bpm.map { String(format: "%.0f", $0) } ?? "-")")
            loudestBass = 0
        }
        silentFrames = (now[0] + now[1] + now[2]) < 1e-5 ? silentFrames + 1 : 0
        var spectrum = [Float](repeating: 0, count: Self.spectrumBands.count)
        let longRate = perFrame(frameCount < 50 ? 0.9 : 0.995)
        for (index, range) in Self.spectrumBands.enumerated() {
            let lo = min(range.0, half - 1), hi = min(max(lo + 1, range.1), half)
            let value = Double(magnitude[lo..<hi].reduce(0, +)) / Double(hi - lo)
            spectrumLong[index] = spectrumLong[index] == 0 ? value : spectrumLong[index] * longRate + value * (1 - longRate)
            let r = spectrumLong[index] < 1e-6 ? 0 : value / spectrumLong[index]
            spectrum[index] = Float(min(1, max(0, 0.5 + 0.25 * log2(max(0.01, r)))))
        }
        V3MusicPulse.publish(V3MusicPulse.Levels(
            bass: ratio(0, now[0]), mid: ratio(1, now[1]), treble: ratio(2, now[2]),
            bassAverage: ratio(0, average[0]), bpm: bpm,
            updatedAt: ProcessInfo.processInfo.systemUptime, spectrum: spectrum,
            silentSeconds: Double(silentFrames) / fps))
    }

    /// Autocorrelation of the onset curve over 60–190 BPM. A lag whose half
    /// also repeats strongly is a subdivision's multiple, and is marked down.
    /// A gentle lean toward 120 settles what sound alone cannot (a steady
    /// pulse is as much 75 as 150 BPM).
    static func tempo(_ flux: [Double], fps: Double) -> Double? {
        // A beat rarely falls on a whole frame (150 BPM is 37.5 frames), so the
        // curve is smoothed first; otherwise lags 37 and 38 each catch half
        // the beats and 75 (two beats, a whole number) wins.
        var smooth = flux
        for _ in 0..<2 {
            smooth = smooth.indices.map { i in
                0.25 * smooth[max(0, i - 1)] + 0.5 * smooth[i] + 0.25 * smooth[min(smooth.count - 1, i + 1)]
            }
        }
        let mean = smooth.reduce(0, +) / Double(smooth.count)
        let centred = smooth.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }
        let shortest = Int((60 / 190 * fps).rounded(.down)), longest = Int((60 / 60 * fps).rounded(.up))
        func autocorrelation(_ lag: Int) -> Double {
            guard lag > 0, lag < centred.count else { return 0 }
            var sum = 0.0
            for index in lag..<centred.count { sum += centred[index] * centred[index - lag] }
            return sum / energy
        }
        var best: (lag: Int, score: Double, raw: Double)?
        var scores: [Int: Double] = [:]
        for lag in shortest...longest where lag < centred.count {
            let raw = autocorrelation(lag)
            scores[lag] = raw
            let bpm = 60 * fps / Double(lag)
            let octaves = log2(bpm / 120)
            // Off-beat eighths make half the lag look like a beat; a real
            // beat has little energy halfway between beats.
            let half = lag % 2 == 0 ? max(0, autocorrelation(lag / 2)) : 0
            let score = (raw - 0.35 * half) * exp(-0.5 * (octaves / 0.9) * (octaves / 0.9))
            if best == nil || score > best!.score { best = (lag, score, raw) }
        }
        guard let best, best.raw > 0.08 else { return nil }
        // Parabolic refinement between neighbouring lags.
        var lag = Double(best.lag)
        if let a = scores[best.lag - 1], let b = scores[best.lag + 1] {
            let denominator = a - 2 * best.raw + b
            if abs(denominator) > 1e-9 { lag += 0.5 * (a - b) / denominator }
        }
        return 60 * fps / lag
    }
}

/// The beat as light: a halo around the cover (outside it, so the cover
/// does not hide it) that brightens and widens, and a faint lift of the
/// whole picture. Core Animation from a display link; SwiftUI is not
/// redrawn per frame.
struct V3MusicPulseLight: NSViewRepresentable {
    let color: NSColor
    let center: UnitPoint
    let active: Bool
    var clock: LyricsPresentationClock?

    func makeNSView(context: Context) -> V3MusicPulseLightView { V3MusicPulseLightView() }
    func updateNSView(_ view: V3MusicPulseLightView, context: Context) {
        view.clock = clock
        view.configure(color: color, center: center,
                       active: active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    static func dismantleNSView(_ view: V3MusicPulseLightView, coordinator: ()) { view.configure(color: .clear, center: .center, active: false) }
}

final class V3MusicPulseLightView: NSView {
    private let halo = CAGradientLayer()
    private let wash = CALayer()
    private var link: CADisplayLink?
    private var envelope = 0.0
    private var steady = 0.0
    private var lastTime: CFTimeInterval = 0
    private var center = UnitPoint.center
    var clock: LyricsPresentationClock?
    private var lastBeat = -1
    private var lastOnset: TimeInterval = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.opacity = 0
        wash.opacity = 0
        // Screen blending only ever lightens what is under it.
        let screen = CIFilter(name: "CIScreenBlendMode")
        halo.compositingFilter = screen
        wash.compositingFilter = screen
        layer?.addSublayer(wash)
        layer?.addSublayer(halo)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, center: UnitPoint, active: Bool) {
        self.center = center
        // Kept light: on a bright video a darker colour would read as a dark ring.
        let light = (color.usingColorSpace(.sRGB) ?? color).blended(withFraction: 0.7, of: .white) ?? color
        // Clear where the cover sits, brightest just outside it, then fading.
        halo.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, light.withAlphaComponent(0.75).cgColor,
                       light.withAlphaComponent(0.28).cgColor, light.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
        halo.locations = [0, 0.24, 0.40, 0.62, 0.82, 1]
        wash.backgroundColor = light.cgColor
        needsLayout = true
        if active, link == nil {
            let next = displayLink(target: self, selector: #selector(step(_:)))
            next.add(to: .main, forMode: .common)
            link = next
        } else if !active, let current = link {
            current.invalidate(); link = nil
            envelope = 0; steady = 0; lastBeat = -1
            halo.opacity = 0; wash.opacity = 0
        }
    }

    override func layout() {
        super.layout()
        let size = min(bounds.width, bounds.height) * 1.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        // UnitPoint is top-left based; the layer's y grows upward.
        halo.position = CGPoint(x: bounds.width * center.x, y: bounds.height * (1 - center.y))
        wash.frame = bounds
        CATransaction.commit()
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastTime == 0 ? 1.0 / 60 : min(0.1, now - lastTime)
        lastTime = now
        let levels = V3MusicPulse.levels
        let fresh = ProcessInfo.processInfo.systemUptime - levels.updatedAt < 0.5
        let beats = V3MusicPulse.analysis.beats
        var hit = 0.0
        var timed = false
        var voiced = false
        if !beats.isEmpty, let clock, clock.isPlaying {
            // Spotify's own beat grid: light on each beat, the bar's first beat brightest.
            timed = true
            let time = clock.playbackTime(at: ProcessInfo.processInfo.systemUptime)
            var low = 0, high = beats.count
            while low < high { let mid = (low + high) / 2; if beats[mid].time <= time { low = mid + 1 } else { high = mid } }
            let index = low - 1
            if index >= 0, index != lastBeat, time - beats[index].time < 0.12 {
                let loudness = fresh ? min(1.2, max(0.6, levels.bassAverage)) : 1
                hit = (beats[index].positionInBar == 1 ? 1.0 : 0.55) * loudness
            }
            lastBeat = index
        } else if fresh, levels.silentSeconds < 1 {
            // No beat grid: the bass right now above its usual level.
            hit = min(1, max(0, (levels.bass - 1.0) / 0.55))
        } else if let clock, clock.isPlaying {
            // Nothing heard and no beat grid: follow the starts of the sung words.
            let onsets = V3VocalOnsets.current
            if !onsets.isEmpty {
                voiced = true
                let time = clock.presentationTime(at: ProcessInfo.processInfo.systemUptime)
                if let index = V3VocalOnsets.index(at: time, in: onsets), onsets[index] != lastOnset {
                    lastOnset = onsets[index]
                    hit = 0.5
                }
            }
        }
        envelope = min(1, max(hit, envelope * exp(-elapsed / 0.22)))
        let live = fresh || timed || voiced
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Nothing between beats: the light appears only on them.
        halo.opacity = live ? Float(0.65 * envelope) : 0
        let scale = 1 + 0.10 * envelope
        halo.transform = CATransform3DMakeScale(scale, scale, 1)
        wash.opacity = live ? Float(0.06 * envelope) : 0
        CATransaction.commit()
    }
}
