import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI

/// The song's Spotify Canvas as a local file. The address comes only from the
/// Spotify app's own cache on this Mac (`SpotifyCanvasLocator`); the clip is
/// then fetched from Spotify's public CDN and kept on disk, oldest dropped
/// first beyond the budget.
actor V3CanvasStore {
    static let shared = V3CanvasStore()
    private static let diskBudget: Int64 = 400 << 20

    private var inFlight: [URL: Task<URL?, Never>] = [:]
    private var failedUntil: [URL: Date] = [:]
    private var generation: UInt = 0
    private let directory: URL
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    init(directory: URL? = nil) {
        let caches = LyricsQStorage.isolatedMediaCacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.spotifylyrics.app", isDirectory: true)
        self.directory = directory ?? caches.appendingPathComponent("Canvas", isDirectory: true)
    }

    /// The clip's address for this track, read from the Spotify cache.
    func remoteClip(trackID: String) async -> URL? {
        let lookup = Task.detached(priority: .utility) { SpotifyCanvasLocator.canvasURL(trackID: trackID) }
        return await withTaskCancellationHandler {
            await lookup.value
        } onCancel: {
            lookup.cancel()
        }
    }

    func localFile(for remote: URL) async -> URL? {
        let target = file(for: remote)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        if let until = failedUntil[remote], until > Date() { return nil }
        let currentGeneration = generation
        if let running = inFlight[remote] {
            let result = await running.value
            return currentGeneration == generation ? result : nil
        }
        let task = Task<URL?, Never> { [session, directory] in
            do {
                let (data, response) = try await session.data(from: remote)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1024, data.count < 40 << 20,
                      data.count > 8, Array(data[4..<8]) == Array("ftyp".utf8) else { return nil }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                return target
            } catch {
                return nil
            }
        }
        inFlight[remote] = task
        let result = await task.value
        guard generation == currentGeneration else { return nil }
        inFlight[remote] = nil
        if result == nil { failedUntil[remote] = Date().addingTimeInterval(600) } else { prune() }
        return result
    }

    private func file(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + ".mp4")
    }

    private func cachedClips() throws -> [(URL, Int64, Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        return files.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "mp4", name.utf8.count == 32, name.allSatisfy(\.isHexDigit),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    func diskBytes() throws -> Int64 { try cachedClips().reduce(0) { $0 + $1.1 } }

    func clearCache() throws {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        failedUntil.removeAll()
        for (url, _, _) in try cachedClips() { try FileManager.default.removeItem(at: url) }
    }

    private func prune() {
        guard var entries = try? cachedClips() else { return }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > Self.diskBudget {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

/// The primary artist's photo, the "other cover" Spotify's TV apps show.
/// Artist IDs come from the exact track's public embed page; the photo from
/// Spotify's public oEmbed endpoint. Nothing about the user is sent.
actor V3ArtistImageStore {
    static let shared = V3ArtistImageStore()
    private var cache: [String: URL] = [:]
    /// A failed lookup used to be cached as "no photo" for the whole session, so one
    /// network hiccup hid that artist's photo on every later song. Failures now only
    /// pause retries briefly.
    private var failedAt: [String: Date] = [:]
    static let retryAfter: TimeInterval = 90

    func imageURL(for track: Track) async -> URL? {
        guard let artistID = await SpotifyTrackArtistResolver.shared.artistIDs(for: track).first else { return nil }
        if let known = cache[artistID] { return known }
        if let failed = failedAt[artistID], Date().timeIntervalSince(failed) < Self.retryAfter { return nil }
        for attempt in 0..<2 {
            if let found = await Self.fetch(artistID: artistID) {
                cache[artistID] = found
                failedAt.removeValue(forKey: artistID)
                return found
            }
            guard attempt == 0, !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        if !Task.isCancelled { failedAt[artistID] = Date() }
        return nil
    }

    private static func fetch(artistID: String) async -> URL? {
        var parts = URLComponents(string: "https://open.spotify.com/oembed")!
        parts.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/artist/" + artistID)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumbnail = object["thumbnail_url"] as? String,
              let thumbnailURL = URL(string: thumbnail), thumbnailURL.scheme == "https" else { return nil }
        return larger(thumbnailURL)
    }

    /// oEmbed gives the 320 px image (`ab676161 00005174 …`); the same
    /// picture at 640 px has the size code `0000e5eb`.
    static func larger(_ url: URL) -> URL {
        let text = url.absoluteString
        guard text.contains("/image/ab67616100005174") else { return url }
        return URL(string: text.replacingOccurrences(of: "/image/ab67616100005174", with: "/image/ab6761610000e5eb")) ?? url
    }
}

/// A song's cover from Spotify's public oEmbed, used when Spotify Desktop
/// gives no artwork address. Only the track ID is sent.
enum SpotifyPublicArtwork {
    static func trackID(from raw: String) -> String? {
        let value = raw.hasPrefix("spotify:track:") ? String(raw.dropFirst("spotify:track:".count)) : raw
        return value.count == 22 && value.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
            ? value : nil
    }

    static func coverURL(trackID: String) async -> URL? {
        var parts = URLComponents(string: "https://open.spotify.com/oembed")!
        parts.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/track/" + trackID)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumbnail = (object["thumbnail_url"] as? String).flatMap(URL.init(string:)),
              thumbnail.scheme == "https" else { return nil }
        return larger(thumbnail)
    }

    /// oEmbed gives the 300 px cover (`ab67616d 00001e02 …`); `0000b273` is 640 px.
    static func larger(_ url: URL) -> URL {
        let text = url.absoluteString
        guard text.contains("/image/ab67616d00001e02") else { return url }
        return URL(string: text.replacingOccurrences(of: "/image/ab67616d00001e02", with: "/image/ab67616d0000b273")) ?? url
    }
}

/// A silent looping clip filling its frame. It stops while the song is
/// paused, the window is hidden or the system asks for reduced motion.
struct V3CanvasVideoView: NSViewRepresentable {
    let file: URL
    let playing: Bool
    var blurRadius: Double = 0
    var onReady: () -> Void = {}

    func makeNSView(context: Context) -> V3CanvasVideoNSView { V3CanvasVideoNSView() }
    func updateNSView(_ view: V3CanvasVideoNSView, context: Context) {
        view.onReady = onReady
        view.blurRadius = blurRadius
        view.show(file, playing: playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    static func dismantleNSView(_ view: V3CanvasVideoNSView, coordinator: ()) { view.stop() }
}

final class V3CanvasVideoNSView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var file: URL?
    private var readyObservation: NSKeyValueObservation?
    var onReady: () -> Void = {}
    var blurRadius: Double = 0 {
        didSet {
            guard abs(blurRadius - oldValue) > 0.5 else { return }
            playerLayer.filters = blurRadius > 0.5
                ? [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])].compactMap { $0 } : nil
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A blurred edge would darken; the layer reaches past the frame instead.
        let bleed = CGFloat(blurRadius) * 2
        playerLayer.frame = bounds.insetBy(dx: -bleed, dy: -bleed)
        CATransaction.commit()
    }

    func show(_ next: URL, playing: Bool) {
        if file != next {
            stop()
            file = next
            let item = AVPlayerItem(url: next)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            playerLayer.player = queue
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self?.onReady() }
            }
        }
        if playing { player?.play() } else { player?.pause() }
    }

    func stop() {
        readyObservation = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer.player = nil
        file = nil
    }
}

// MARK: - How bright the picture behind the lyrics really is

/// The cover's brightness says nothing about a Canvas clip playing over it. When
/// a clip is shown, a frame from it is measured once and published here, so
/// reading protection and the lyric colour follow what is actually on screen.
@MainActor
final class V3BackdropBrightness: ObservableObject {
    static let shared = V3BackdropBrightness()
    /// Average luminance (0–1) of the clip on show, nil when no clip is shown.
    @Published private(set) var clipLuminance: Double?
    private var measured: URL?
    /// The cover image's own mean luminance. The colour palette's brightness reads far
    /// lower than the picture (a pale beige cover measured 0.65 here), so the backdrop,
    /// which is that cover blurred, is judged from the image itself.
    @Published private(set) var coverLuminance: (url: URL, value: Double)?
    private var coverMeasured: URL?

    func cover(_ url: URL?) {
        guard url != coverMeasured else { return }
        coverMeasured = url
        guard let url else { coverLuminance = nil; return }
        Task {
            guard let image = await ArtworkImageLoader.shared.image(for: url) else { return }
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let mean = Self.mean(cg), self.coverMeasured == url else { return }
            self.coverLuminance = (url, mean)
        }
    }

    nonisolated static func mean(_ image: CGImage) -> Double? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
        }
        return total / Double(side * side)
    }

    func clip(_ file: URL?) {
        guard file != measured else { return }
        measured = file
        clipLuminance = nil
        guard let file else { return }
        Task.detached(priority: .utility) {
            let value = Self.luminance(of: file)
            await MainActor.run { [weak self] in
                guard let self, self.measured == file else { return }
                LyricsE2ELog.log("BACKDROP clip luminance=\(value.map { String(format: "%.2f", $0) } ?? "-") file=\(file.lastPathComponent)")
                self.clipLuminance = value
            }
        }
    }

    nonisolated static func luminance(of file: URL) -> Double? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        var samples: [Double] = []
        for second in [0.5, 2.0, 4.0] {
            guard let image = try? generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil),
                  let value = average(image) else { continue }
            samples.append(value)
        }
        return samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
    }

    nonisolated static func average(_ image: CGImage) -> Double? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var values: [Double] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            values.append((0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255)
        }
        // Lyrics are unreadable where the picture is brightest, not on average:
        // use the brightness of the brighter quarter.
        values.sort()
        let top = values[(values.count * 3 / 4)...]
        return top.reduce(0, +) / Double(top.count)
    }
}

/// Lyric colour that stays readable: the cover's colour, lightened towards white
/// until it stands clear of the picture behind it (and of a picture in its own hue).
enum V3ReadableAccent {
    static func color(_ accent: Color, background luminance: Double) -> Color {
        let ns = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        func lum(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double { 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) }
        // White text sits on a picture at most this bright; the accent should be at least as clear.
        let needed = min(0.92, max(0.62, luminance + 0.42))
        var mix: CGFloat = 0
        while mix < 1 {
            let r = ns.redComponent + (1 - ns.redComponent) * mix
            let g = ns.greenComponent + (1 - ns.greenComponent) * mix
            let b = ns.blueComponent + (1 - ns.blueComponent) * mix
            if lum(r, g, b) >= needed { return Color(red: Double(r), green: Double(g), blue: Double(b)) }
            mix += 0.05
        }
        return .white
    }

    /// For dark ink over a bright picture: the cover's colour, deepened towards black
    /// until it is clearly darker than the picture behind it.
    static func darkColor(_ accent: Color, background luminance: Double) -> Color {
        let ns = NSColor(accent).usingColorSpace(.sRGB) ?? .black
        func lum(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Double { 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) }
        let ceiling = max(0.08, min(0.3, luminance - 0.42))
        var keep: CGFloat = 1
        while keep > 0 {
            let r = ns.redComponent * keep, g = ns.greenComponent * keep, b = ns.blueComponent * keep
            if lum(r, g, b) <= ceiling { return Color(red: Double(r), green: Double(g), blue: Double(b)) }
            keep -= 0.05
        }
        return Color(white: 0.07)
    }
}
