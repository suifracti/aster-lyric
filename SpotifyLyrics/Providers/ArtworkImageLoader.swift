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

    func imageInMemory(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    public func cachedImage(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = imageInMemory(for: url) { return cached }
        if url.isFileURL, let image = NSImage(contentsOf: url) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        return nil
    }

    public func image(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let cached = imageInMemory(for: url) { return cached }

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

/// Apple Music exports file-backed artwork, so URLCache cannot account for it.
@MainActor
final class AppleMusicArtworkCache {
    static let shared = AppleMusicArtworkCache(directory: LyricsQStorage.isolatedMediaCacheDirectory?
        .appendingPathComponent("AppleMusicArtwork", isDirectory: true) ?? FileManager.default.temporaryDirectory)

    private static let prefix = "applemusic_artwork_"
    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    private let directory: URL
    private let diskBudget: Int64
    private var generation = 0

    init(directory: URL, diskBudget: Int64 = 64 << 20) {
        self.directory = directory
        self.diskBudget = diskBudget
    }

    func localFile(for trackID: String, export: (URL) async -> Bool) async -> URL? {
        guard Self.isPersistentID(trackID) else { return nil }
        let target = directory.appendingPathComponent(Self.prefix + trackID + ".jpg")
        if let existing = cachedFile(target) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: existing.url.path)
            return existing.url
        }

        // Publish the existing file URL only after Music has finished writing.
        let temporary = directory.appendingPathComponent(".aster-apple-artwork-\(UUID()).partial")
        let started = generation
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard await export(temporary), started == generation, !Task.isCancelled,
                  let exported = cachedFile(temporary), exported.bytes <= diskBudget else { return nil }
            if cachedFile(target) != nil { return target }
            if let empty = cachedFile(target, allowEmpty: true) {
                try FileManager.default.removeItem(at: empty.url)
            }
            try FileManager.default.moveItem(at: temporary, to: target)
            prune(keeping: target)
            return target
        } catch {
            return nil
        }
    }

    func diskBytes() throws -> Int64 { try files().reduce(0) { $0 + $1.bytes } }

    func clearCache() throws {
        generation &+= 1
        for file in try files() { try FileManager.default.removeItem(at: file.url) }
    }

    private struct File {
        let url: URL
        let bytes: Int64
        let date: Date
    }

    private func files() throws -> [File] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(Self.keys),
                                                            options: .skipsHiddenFiles).compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "jpg", name.hasPrefix(Self.prefix),
                  Self.isPersistentID(String(name.dropFirst(Self.prefix.count))) else { return nil }
            return cachedFile(url, allowEmpty: true)
        }
    }

    private func cachedFile(_ url: URL, allowEmpty: Bool = false) -> File? {
        guard let values = try? url.resourceValues(forKeys: Self.keys), values.isRegularFile == true,
              values.isSymbolicLink != true, let bytes = values.fileSize, allowEmpty || bytes > 0 else { return nil }
        return File(url: url, bytes: Int64(bytes), date: values.contentModificationDate ?? .distantPast)
    }

    private func prune(keeping target: URL) {
        guard let files = try? files() else { return }
        var total = files.reduce(0) { $0 + $1.bytes }
        for file in files.sorted(by: { $0.date < $1.date }) where total > diskBudget && file.url != target {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.bytes }
        }
    }

    private static func isPersistentID(_ value: String) -> Bool {
        TrackIdentity.appleMusicPersistentID("applemusic:" + value) == value.lowercased()
    }
}
