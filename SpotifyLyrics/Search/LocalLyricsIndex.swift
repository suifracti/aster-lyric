import Foundation

/// Shared read-only index over user-provided local `.lrc` files.
/// Scans configured directories at most once per instance, never writes or mutates user files.
public final class LocalLyricsIndex: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let fileURL: URL
        public let title: String
        public let artist: String
        public let album: String
        public let duration: TimeInterval?
        public let content: String

        public var resultID: String { "local:\(fileURL.path)" }

        public var track: Track {
            Track(
                id: resultID,
                title: title,
                artist: artist,
                album: album,
                duration: duration ?? 0,
                artworkName: "music.note"
            )
        }
    }

    public static let shared = LocalLyricsIndex()

    private let searchDirectories: [URL]
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedEntries: [Entry]?
    private var didScan = false

    public init(searchDirectories: [URL]? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let searchDirectories {
            self.searchDirectories = searchDirectories
        } else {
            self.searchDirectories = Self.defaultSearchDirectories()
        }
    }

    public static func defaultSearchDirectories(
        home: URL = LyricsQStorage.homeDirectory,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> [URL] {
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested {
            DebugAcceptanceDataIsolation.requireStorage(home)
            return [home.appendingPathComponent("Music/SpotifyLyrics/Lyrics"),
                    home.appendingPathComponent("Library/Application Support/SpotifyLyrics/Lyrics")]
        }
#endif
        var defaults = [
            home.appendingPathComponent("Music/SpotifyLyrics/Lyrics", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/SpotifyLyrics/Lyrics", isDirectory: true)
        ]
        #if DEBUG
        defaults.append(
            URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Lyrics", isDirectory: true)
        )
        #endif
        return defaults
    }

    /// Snapshot of indexed entries. Directory walk happens once unless `forceRescan` is true.
    public func entries(forceRescan: Bool = false) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if forceRescan {
            cachedEntries = nil
            didScan = false
        }
        if let cachedEntries {
            return cachedEntries
        }
        let scanned = scan()
        cachedEntries = scanned
        didScan = true
        return scanned
    }

    public var hasScanned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didScan
    }

    /// Rebuilds the in-memory index only. It never writes, renames, or
    /// deletes any user lyric file.
    @discardableResult
    public func rebuild() -> Int {
        entries(forceRescan: true).count
    }

    public func entry(id: String) -> Entry? {
        entries().first { $0.resultID == id }
    }

    public func document(for entry: Entry, identity: TrackIdentity, confidence: Double = 1) -> LyricsDocument? {
        LRCParser.parse(entry.content, identity: identity, source: .local).map { parsed in
            LyricsDocument(
                identity: identity,
                title: parsed.title ?? entry.title,
                artist: parsed.artist ?? entry.artist,
                album: parsed.album ?? entry.album,
                duration: parsed.duration ?? entry.duration,
                lines: parsed.lines,
                isSynchronized: parsed.isSynchronized,
                source: .local,
                confidence: confidence,
                providerSourceID: entry.resultID
            )
        }
    }

    public func bestMatch(for track: Track, identity: TrackIdentity) -> LyricsDocument? {
        var bestDocument: LyricsDocument?
        var bestScore = 0.0

        for entry in entries() {
            let candidateTrack = entry.track
            let probe = LyricsCandidate(
                id: entry.resultID,
                identity: identity,
                title: candidateTrack.title,
                artist: candidateTrack.artist,
                album: candidateTrack.album,
                duration: candidateTrack.duration,
                lines: [],
                source: .local,
                confidence: 0
            )
            let metadataScore = LyricsMatcher.score(track: track, candidate: probe)
            guard LyricsMatcher.isCandidate(metadataScore) else { continue }
            guard let document = document(for: entry, identity: identity, confidence: metadataScore) else {
                continue
            }
            if document.lines.isEmpty { continue }
            if metadataScore > bestScore {
                bestScore = metadataScore
                bestDocument = document
            }
        }
        return bestDocument
    }

    public func searchTracks(matching query: SongSearchQuery) -> [TrackSearchResult] {
        guard !query.isEmpty else { return [] }
        var results: [TrackSearchResult] = []
        for entry in entries() {
            let track = entry.track
            let score = SongSearchScoring.score(track: track, query: query)
            guard score >= 0.20 else { continue }
            results.append(
                TrackSearchResult(
                    id: entry.resultID,
                    source: .local,
                    track: track,
                    confidence: score,
                    artworkURL: nil
                )
            )
        }
        return results.sorted {
            if $0.confidence == $1.confidence { return $0.track.title < $1.track.title }
            return $0.confidence > $1.confidence
        }
    }

    /// Verifies indexed files still match on-disk bytes (read-only integrity check).
    public func fileBytesUnchanged(relativeTo originalContents: [URL: Data]) -> Bool {
        for (url, original) in originalContents {
            guard let current = try? Data(contentsOf: url), current == original else {
                return false
            }
        }
        return true
    }

    private func scan() -> [Entry] {
        var files: [URL] = []
        for directory in searchDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            files.append(contentsOf: entries.filter {
                $0.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame
            })
        }

        var result: [Entry] = []
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fallbackTitle = file.deletingPathExtension().lastPathComponent
            let fallbackTrack = Track(
                id: "local:\(file.path)",
                title: fallbackTitle,
                artist: "",
                album: "",
                duration: 0
            )
            let fallbackIdentity = TrackIdentity(track: fallbackTrack)
            guard let document = LRCParser.parse(content, identity: fallbackIdentity, source: .local) else {
                continue
            }
            result.append(
                Entry(
                    fileURL: file,
                    title: document.title?.isEmpty == false ? document.title! : fallbackTitle,
                    artist: document.artist ?? "",
                    album: document.album ?? "",
                    duration: document.duration,
                    content: content
                )
            )
        }
        return result
    }
}
