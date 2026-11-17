import Foundation

/// 金句: single lyric lines the listener chose to keep. A small JSON file
/// beside the database; the lyric database itself is not touched.
@MainActor
final class V3FavoriteLines: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var translation: String?
        var title: String
        var artist: String
        var trackKey: String
        var artworkURL: URL?
        var addedAt = Date()
        var lyricsVersionID: UUID? = nil
        var lineIndex: Int? = nil

        var passage: LibraryPassageTarget {
            LibraryPassageTarget(trackKey: trackKey, source: lyricsVersionID.map(LibraryPassageSource.original) ?? .selected,
                                 find: text, lineIndex: lineIndex)
        }
    }

    static let shared = V3FavoriteLines(fileURL: defaultURL)
    static var defaultURL: URL? {
#if DEBUG
        // Test and fixture runs move the database; the kept lines move with it,
        // so a fixture never reads or writes the listener's own file.
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DATABASE_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override).deletingLastPathComponent().appendingPathComponent("favorite-lines.json")
        }
#endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpotifyLyrics", isDirectory: true)
            .appendingPathComponent("favorite-lines.json")
    }

    /// Newest first.
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var errorMessage: String?
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        reload()
    }

    func reload() {
        do {
            entries = try storedEntries()
            errorMessage = nil
        } catch {
            errorMessage = "暂时读不到本机收藏。"
        }
    }

    private func storedEntries() throws -> [Entry] {
        guard let fileURL else { return entries }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decoder.decode([Entry].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    private static func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func contains(text: String, trackKey: String) -> Bool {
        let wanted = Self.key(text)
        return entries.contains { $0.trackKey == trackKey && Self.key($0.text) == wanted }
    }

    /// Adds the line, or removes it when it is already kept. Returns true when it is kept afterwards.
    @discardableResult
    func toggle(text: String, translation: String?, title: String, artist: String, trackKey: String,
                artworkURL: URL?, lyricsVersionID: UUID? = nil, lineIndex: Int? = nil) -> Bool {
        let wanted = Self.key(text)
        guard !wanted.isEmpty else { return false }
        var kept = false
        let written = update { next in
            if let index = next.firstIndex(where: { $0.trackKey == trackKey && Self.key($0.text) == wanted }) {
                next.remove(at: index)
            } else {
                next.insert(Entry(text: wanted, translation: translation.map(Self.key).flatMap { $0.isEmpty ? nil : $0 },
                                  title: title, artist: artist, trackKey: trackKey, artworkURL: artworkURL,
                                  lyricsVersionID: lyricsVersionID, lineIndex: lineIndex), at: 0)
                kept = true
            }
        }
        return written ? kept : contains(text: wanted, trackKey: trackKey)
    }

    func remove(_ id: UUID) {
        _ = update { $0.removeAll { $0.id == id } }
    }

    private func update(_ change: (inout [Entry]) -> Void) -> Bool {
        do {
            var next = try storedEntries()
            change(&next)
            if let fileURL {
                let data = try Self.encoder.encode(next)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            }
            entries = next
            errorMessage = nil
            return true
        } catch {
            errorMessage = "暂时无法更新本机收藏，原来的文件已保留。"
            return false
        }
    }
}
