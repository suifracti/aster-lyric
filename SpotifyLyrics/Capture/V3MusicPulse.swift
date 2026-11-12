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
    }

    private static let shared_ = OSAllocatedUnfairLock(initialState: Levels())
    /// Read from any thread, at frame rate, without observing the object.
    nonisolated static var levels: Levels { shared_.withLock { $0 } }
    /// Tempo for motion that should keep time; nil when not listening or unsure.
    nonisolated static var currentBPM: Double? {
        let value = levels
        guard value.bpm != nil, ProcessInfo.processInfo.systemUptime - value.updatedAt < 3 else { return nil }
        return value.bpm
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
        if flux.count > Int(fps * 8) { flux.removeFirst(flux.count - Int(fps * 8)) }
        if frameCount % Int(fps * 2) == 0, flux.count >= Int(fps * 6), let estimate = Self.tempo(flux, fps: fps) {
            tempoCandidates.append(estimate)
            if tempoCandidates.count > 3 { tempoCandidates.removeFirst() }
            bpm = tempoCandidates.sorted()[tempoCandidates.count / 2]
        }

        func ratio(_ band: Int, _ value: Double) -> Double { longAverage[band] < 0.001 ? 1 : value / longAverage[band] }
        loudestBass = max(loudestBass, ratio(0, now[0]))
        if frameCount % Int(fps * 5) == 0 {
            LyricsE2ELog.log("PULSE levels bassPeak=\(String(format: "%.2f", loudestBass)) bpm=\(bpm.map { String(format: "%.0f", $0) } ?? "-")")
            loudestBass = 0
        }
        V3MusicPulse.publish(V3MusicPulse.Levels(
            bass: ratio(0, now[0]), mid: ratio(1, now[1]), treble: ratio(2, now[2]),
            bassAverage: ratio(0, average[0]), bpm: bpm,
            updatedAt: ProcessInfo.processInfo.systemUptime))
    }

    /// Autocorrelation of the onset curve over 60–180 BPM, leaning gently
    /// toward 120 so a half or double tempo does not win on a tie.
    static func tempo(_ flux: [Double], fps: Double) -> Double? {
        let mean = flux.reduce(0, +) / Double(flux.count)
        let centred = flux.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }
        let shortest = Int((60 / 180 * fps).rounded(.down)), longest = Int((60 / 60 * fps).rounded(.up))
        var best: (lag: Int, score: Double, raw: Double)?
        var scores: [Int: Double] = [:]
        for lag in shortest...longest where lag < centred.count {
            var sum = 0.0
            for index in lag..<centred.count { sum += centred[index] * centred[index - lag] }
            let raw = sum / energy
            scores[lag] = raw
            let bpm = 60 * fps / Double(lag)
            let octaves = log2(bpm / 120)
            let score = raw * exp(-0.5 * (octaves / 0.9) * (octaves / 0.9))
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

    func makeNSView(context: Context) -> V3MusicPulseLightView { V3MusicPulseLightView() }
    func updateNSView(_ view: V3MusicPulseLightView, context: Context) {
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
        let light = (color.usingColorSpace(.sRGB) ?? color).blended(withFraction: 0.35, of: .white) ?? color
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
            envelope = 0; steady = 0
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
        // A beat: the bass right now above its usual level. Quiet songs sit
        // near 1.0, so the trigger starts just above it.
        let hit = fresh ? min(1, max(0, (levels.bass - 1.0) / 0.55)) : 0
        envelope = max(hit, envelope * exp(-elapsed / 0.22))
        // The song's overall energy, slow: the halo never goes fully dark mid-song.
        let energy = fresh ? min(1, max(0, (levels.bassAverage - 0.6) / 0.8)) : 0
        steady += (energy - steady) * min(1, elapsed / 0.8)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.opacity = fresh ? Float(0.12 + 0.18 * steady + 0.55 * envelope) : 0
        let scale = 1 + 0.10 * envelope
        halo.transform = CATransform3DMakeScale(scale, scale, 1)
        wash.opacity = fresh ? Float(0.07 * envelope) : 0
        CATransaction.commit()
    }
}
