import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A personal, portable edition. A book remains readable when the source
/// database, its chosen version, or the current Mac changes.
struct LyricBook: FileDocument, Codable, Equatable, Sendable {
    static let bookType = UTType(exportedAs: "com.suifracti.aster-lyric.songbook", conformingTo: .json)
    static let readableContentTypes = [bookType]

    struct Line: Codable, Equatable, Sendable {
        var original: String
        var translation: String?
        var reading: String?
        var background: String?
        var romanization: String?
        var performer: String?

        var mainText: String {
            [original, translation, reading, romanization, background].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }

        func text(for options: LyricBook) -> (main: String, reading: String?, translation: String?, background: String?) {
            let main = mainText
            let guide = [reading, romanization].compactMap { $0 }.first { !$0.isEmpty && $0 != main }
            return (main, options.showsReading ? guide : nil,
                    options.showsTranslation && translation != main ? translation : nil, background != main ? background : nil)
        }
    }

    struct Chapter: Identifiable, Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case song, quote }
        var id = UUID()
        let kind: Kind
        let title: String
        let artist: String
        let album: String
        let edition: String
        let origin: LibraryPassageTarget
        var lines: [Line]
        var note = ""

        init(page: LibraryPassagePage, source: LibraryPassageSource, excerpt: LibraryPassagePage.Line? = nil) {
            kind = excerpt == nil ? .song : .quote
            title = page.entry.title; artist = page.entry.artist; album = page.entry.album ?? ""
            edition = excerpt == nil ? page.edition : "摘句 · " + page.edition
            let rows = excerpt.map { [$0] } ?? page.lines
            lines = rows.map {
                Line(original: $0.original, translation: $0.translation, reading: $0.reading,
                     background: $0.background, romanization: $0.romanization, performer: $0.performerID)
            }
            let exact: LibraryPassageSource
            switch source {
            case .reading, .attached: exact = source
            default: exact = page.translationVersionID.map(LibraryPassageSource.translation) ?? .original(page.originalVersionID)
            }
            let kept = excerpt.flatMap { row in
                !row.original.isEmpty && page.matchesOriginalVersion
                    ? LibraryPassageTarget.SavedQuote(originalVersionID: page.originalVersionID, translation: row.translation) : nil
            }
            origin = LibraryPassageTarget(trackKey: page.entry.trackStableKey, source: exact,
                                          find: excerpt == nil ? "" : lines.first?.mainText ?? "",
                                          lineIndex: excerpt?.id, savedQuote: kept)
        }

        init(quote: V3FavoriteLines.Entry) {
            kind = .quote; title = quote.title; artist = quote.artist; album = ""; edition = "摘句"
            origin = quote.passage
            lines = [Line(original: quote.text, translation: quote.translation)]
        }

        var titleInContents: String {
            if kind == .quote, let first = lines.first, !first.mainText.isEmpty { return first.mainText }
            return title
        }

        var byline: String {
            let fields = kind == .quote ? [title, artist] : [artist, album]
            return fields.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private let format: Int
    var title: String
    var author: String
    var introduction: String
    var chapters: [Chapter]
    var showsTranslation: Bool
    var showsReading: Bool

    init(title: String = "", author: String = "", chapters: [Chapter] = []) {
        self.format = 1; self.title = title; self.author = author
        self.introduction = ""; self.chapters = chapters; self.showsTranslation = true; self.showsReading = false
    }

    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我的歌本" : title }

    @discardableResult
    mutating func add(_ chapter: Chapter) -> UUID {
        if let existing = chapters.first(where: { $0.kind == chapter.kind && $0.origin == chapter.origin && $0.lines == chapter.lines }) { return existing.id }
        chapters.append(chapter)
        return chapter.id
    }

    mutating func move(_ id: UUID, by step: Int) {
        guard let index = chapters.firstIndex(where: { $0.id == id }), chapters.indices.contains(index + step) else { return }
        chapters.insert(chapters.remove(at: index), at: index + step)
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard format == 1, Set(chapters.map(\.id)).count == chapters.count else { throw CocoaError(.fileReadCorruptFile) }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(regularFileWithContents: encoded()) }
}
