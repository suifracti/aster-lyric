import AppKit
import Foundation

@MainActor
public final class ArtworkImageLoader {
    public static let shared = ArtworkImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlightTasks: [URL: Task<NSImage?, Never>] = [:]
    private var generation: UInt = 0

    private let session: URLSession

    private init() {
        cache.countLimit = 128
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 30.0
        config.requestCachePolicy = .useProtocolCachePolicy
        if let directory = LyricsQStorage.isolatedMediaCacheDirectory {
            config.urlCache = URLCache(memoryCapacity: 50 << 20, diskCapacity: 200 << 20, directory: directory.appendingPathComponent("Artwork"))
        } else {
            config.urlCache = URLCache(memoryCapacity: 50 << 20, diskCapacity: 200 << 20, diskPath: "spotify_lyrics_artwork_cache")
        }
        self.session = URLSession(configuration: config)
    }

    var diskBytes: Int64 { Int64(session.configuration.urlCache?.currentDiskUsage ?? 0) }

    func clearCache() {
        generation &+= 1
        inFlightTasks.values.forEach { $0.cancel() }
        inFlightTasks.removeAll()
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    public func cachedImage(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if url.isFileURL, let image = NSImage(contentsOf: url) {
            cache.setObject(image, forKey: key)
            return image
        }
        return nil
    }

    public func image(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let currentGeneration = generation
        if let existingTask = inFlightTasks[url] {
            let result = await existingTask.value
            return generation == currentGeneration ? result : nil
        }

        let task = Task<NSImage?, Never>.detached { [session] in
            if url.isFileURL {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return NSImage(data: data)
            }
            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let image = NSImage(data: data) else {
                    LyricsE2ELog.log("ARTWORK image rejected host=\(url.host ?? "local") status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data.count)")
                    return nil
                }
                return image
            } catch {
                LyricsE2ELog.log("ARTWORK image failed host=\(url.host ?? "local") error=\(error.localizedDescription)")
                return nil
            }
        }

        inFlightTasks[url] = task
        let image = await task.value
        guard currentGeneration == generation else { return nil }
        if let image { cache.setObject(image, forKey: key) }
        inFlightTasks.removeValue(forKey: url)
        return image
    }
}
