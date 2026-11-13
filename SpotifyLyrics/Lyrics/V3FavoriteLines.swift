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
    }

    static let shared = V3FavoriteLines(fileURL: defaultURL)
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpotifyLyrics", isDirectory: true)
            .appendingPathComponent("favorite-lines.json")
    }

    /// Newest first.
    @Published private(set) var entries: [Entry] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? Self.decoder.decode([Entry].self, from: data) {
            entries = saved
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
                artworkURL: URL?) -> Bool {
        let wanted = Self.key(text)
        guard !wanted.isEmpty else { return false }
        if let index = entries.firstIndex(where: { $0.trackKey == trackKey && Self.key($0.text) == wanted }) {
            entries.remove(at: index); save(); return false
        }
        entries.insert(Entry(text: wanted, translation: translation.map(Self.key).flatMap { $0.isEmpty ? nil : $0 },
                             title: title, artist: artist, trackKey: trackKey, artworkURL: artworkURL), at: 0)
        save()
        return true
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let fileURL, let data = try? Self.encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
