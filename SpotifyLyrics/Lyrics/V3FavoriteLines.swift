import Foundation

/// 金句: single lyric lines the listener chose to keep. A small JSON file
/// beside the database; the lyric database itself is not touched.
@MainActor
final class V3FavoriteLines: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable, Sendable {
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
        var translationVersionID: UUID? = nil

        var passage: LibraryPassageTarget {
            let source = translationVersionID.map(LibraryPassageSource.translation)
                ?? lyricsVersionID.map(LibraryPassageSource.original) ?? .selected
            return LibraryPassageTarget(trackKey: trackKey, source: source, find: text, lineIndex: lineIndex,
                                        savedQuote: .init(originalVersionID: lyricsVersionID, translation: translation))
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

    private static func matches(_ stored: Entry, _ proposed: Entry) -> Bool {
        guard stored.trackKey == proposed.trackKey, key(stored.text) == key(proposed.text) else { return false }
        let storedHasPosition = stored.lyricsVersionID != nil && stored.lineIndex != nil
        let proposedHasPosition = proposed.lyricsVersionID != nil && proposed.lineIndex != nil
        if storedHasPosition || proposedHasPosition {
            return stored.lyricsVersionID == proposed.lyricsVersionID && stored.lineIndex == proposed.lineIndex
                && stored.translationVersionID == proposed.translationVersionID
        }
        return true
    }

    func contains(_ entry: Entry) -> Bool { entries.contains { Self.matches($0, entry) } }

    func contains(text: String, trackKey: String) -> Bool {
        entries.contains { $0.trackKey == trackKey && Self.key($0.text) == Self.key(text) }
    }

    /// Adds the occurrence, or removes it when that same occurrence is already kept.
    @discardableResult
    func toggle(_ entry: Entry) -> Bool {
        var normalized = entry
        normalized.text = Self.key(entry.text)
        normalized.translation = entry.translation.map(Self.key).flatMap { $0.isEmpty ? nil : $0 }
        guard !normalized.text.isEmpty else { return false }
        var kept = false
        let written = update { next in
            if let index = next.firstIndex(where: { Self.matches($0, normalized) }) {
                next.remove(at: index)
            } else {
                next.insert(normalized, at: 0)
                kept = true
            }
        }
        return written ? kept : contains(normalized)
    }

    @discardableResult
    func toggle(text: String, translation: String?, title: String, artist: String, trackKey: String,
                artworkURL: URL?, lyricsVersionID: UUID? = nil, lineIndex: Int? = nil) -> Bool {
        toggle(Entry(text: text, translation: translation, title: title, artist: artist, trackKey: trackKey,
                     artworkURL: artworkURL, lyricsVersionID: lyricsVersionID, lineIndex: lineIndex))
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
            NotificationCenter.default.post(name: .personalFavoritesDidMutate, object: fileURL?.standardizedFileURL)
            return true
        } catch {
            errorMessage = "暂时无法更新本机收藏，原来的文件已保留。"
            return false
        }
    }
}


extension V3FavoriteLines.Entry {
    init(line: LyricLine, track: Track, trackKey: String, originalVersion: UUID?,
         index: Int?, translationVersion: StoredTranslationVersion?) {
        self.init(text: line.originalText, translation: line.translationText, title: track.title, artist: track.artist,
                  trackKey: trackKey, artworkURL: track.artworkURL, lyricsVersionID: originalVersion, lineIndex: index,
                  translationVersionID: translationVersion?.quoteVersionID(
                    originalID: originalVersion, lineIndex: index, text: line.translationText))
    }
}

extension StoredTranslationVersion {
    /// A selected edition may cover only part of the document. Capture its ID
    /// only when it supplied the translation on the displayed row.
    func quoteVersionID(originalID: UUID?, lineIndex: Int?, text: String?) -> UUID? {
        guard let originalID, record.lyricsVersionID == originalID, let lineIndex, let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, lines.contains(where: {
            $0.lineIndex == lineIndex && $0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }) else { return nil }
        return record.id
    }
}

extension LibraryPassagePage {
    func quote(_ line: Line) -> V3FavoriteLines.Entry {
        .init(text: line.original, translation: line.translation, title: entry.title, artist: entry.artist,
              trackKey: entry.trackStableKey, artworkURL: entry.artworkURL, lyricsVersionID: originalVersionID,
              lineIndex: matchesOriginalVersion ? line.id : nil, translationVersionID: translationVersionID)
    }
}
