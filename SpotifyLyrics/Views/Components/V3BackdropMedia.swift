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
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.spotifylyrics.app", isDirectory: true)
            .appendingPathComponent("Canvas", isDirectory: true)
    }

    /// The clip's address for this track, read from the Spotify cache.
    func remoteClip(trackID: String) async -> URL? {
        await Task.detached(priority: .utility) { SpotifyCanvasLocator.canvasURL(trackID: trackID) }.value
    }

    func localFile(for remote: URL) async -> URL? {
        let target = file(for: remote)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        if let until = failedUntil[remote], until > Date() { return nil }
        if let running = inFlight[remote] { return await running.value }
        let task = Task<URL?, Never> { [session, directory] in
            do {
                let (data, response) = try await session.data(from: remote)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1024, data.count < 40 << 20,
                      data.count > 8, Array(data[4..<8]) == Array("ftyp".utf8) else { return nil }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                return target
            } catch {
                return nil
            }
        }
        inFlight[remote] = task
        let result = await task.value
        inFlight[remote] = nil
        if result == nil { failedUntil[remote] = Date().addingTimeInterval(600) } else { prune() }
        return result
    }

    private func file(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + ".mp4")
    }

    private func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
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
    private var cache: [String: URL?] = [:]

    func imageURL(for track: Track) async -> URL? {
        guard let artistID = await SpotifyTrackArtistResolver.shared.artistIDs(for: track).first else { return nil }
        if let known = cache[artistID] { return known }
        let found = await Self.fetch(artistID: artistID)
        cache[artistID] = found
        return found
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
