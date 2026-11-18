import CryptoKit
import Foundation

enum LocalLyricsFileKind: String, CaseIterable, Sendable {
    case txt, lrc, ttml
    case manuscript = "asterdraft"
}

/// A file can be read before the user chooses any recording or opens the library.
struct LocalLyricsFile: Sendable {
    let kind: LocalLyricsFileKind
    private(set) var content: LyricsDocument
    let locked: Bool
    let translationLanguages: [String]
    private(set) var initialTranslationLanguage: String?
    private let fingerprint: String
    private(set) var manuscriptID: UUID?
    private(set) var manuscriptParentID: UUID?
    var lines: [LyricLine] { content.lines }

    init(data: Data, kind: LocalLyricsFileKind, preferredLanguage: String) throws {
        let emptyTrack = Track(title: "", artist: "", album: "", duration: 0)
        let identity = TrackIdentity(track: emptyTrack)
        switch kind {
        case .manuscript:
            self = try LyricManuscript(data: data).lyricFile()
            return
        case .txt:
            let text = try TextLyricsImportParser.parse(data)
            content = text.document(identity: identity, track: emptyTrack)
            locked = false
        case .lrc:
            let text = try TextLyricsImportParser.decode(data).text
            let lrc = try LRCImportParser.parse(text)
            content = lrc.document(identity: identity, track: emptyTrack)
            locked = lrc.metadata.locked
        case .ttml:
            guard let document = TTMLParser.parse(data: data, identity: identity, source: .manualImport,
                                                  preferredTranslationLanguage: preferredLanguage) else {
                throw LyricsEditingRepositoryError.invalidDocument("TTML 文件里没有可读的歌词段落")
            }
            content = document
            locked = false
        }
        self.kind = kind
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        translationLanguages = LyricSourceTranslation.languages(in: content.lines)
        initialTranslationLanguage = LyricSourceTranslation.preferred(translationLanguages, for: preferredLanguage)
    }

    init(manuscript: LyricManuscript) throws {
        let lrc = try? LRCImportParser.parse(manuscript.text)
        let usesLRC = lrc.map { result in
            result.metadata != LRCMetadata() || result.lines.contains { $0.startTime != nil }
        } ?? false
        try self.init(data: Data(manuscript.text.utf8), kind: usesLRC ? .lrc : .txt, preferredLanguage: "und")
        manuscriptID = manuscript.id
        manuscriptParentID = manuscript.filedVersionID
        let parsed = content
        content = LyricsDocument(identity: parsed.identity, title: manuscript.title.isEmpty ? parsed.title : manuscript.title,
            artist: manuscript.artist.isEmpty ? parsed.artist : manuscript.artist, album: manuscript.album.isEmpty ? parsed.album : manuscript.album,
            duration: parsed.duration, lines: parsed.lines, isSynchronized: parsed.isSynchronized, source: .manualCreate,
            language: parsed.language, explicitlyTimedLineIndices: parsed.explicitlyTimedLineIndices)
    }

    func viewing(_ language: String?) -> Self {
        guard let language, language != initialTranslationLanguage, translationLanguages.contains(language) else { return self }
        var copy = self
        copy.content = content.replacingLines(lines.map { original in
            var line = original
            line.translationText = line.sourceTranslation(in: language)
            return line
        })
        copy.initialTranslationLanguage = language
        return copy
    }

    func document(for track: Track) -> LyricsDocument {
        let prefix = manuscriptID.map(LyricManuscript.sourcePrefix) ?? LyricsPersistenceMapper.lyricFileSourcePrefix
        return LyricsDocument(identity: TrackIdentity(track: track), title: track.title, artist: track.artist,
                       album: track.album, duration: track.duration > 0 ? track.duration : content.duration,
                       lines: lines, isSynchronized: content.isSynchronized, source: manuscriptID == nil ? .manualImport : .manualCreate,
                       providerSourceID: prefix + fingerprint, language: content.language,
                       explicitlyTimedLineIndices: content.explicitlyTimedLineIndices)
    }
}

extension SQLiteLyricsRepository {
    func importLyricFile(_ file: LocalLyricsFile, into track: Track, archiveKey: String? = nil) throws -> LibraryPassageTarget {
        let document = file.document(for: track)
        let result = try storeImportedFile(track: track, document: document, locked: file.locked,
                                           archiveKey: archiveKey, manuscriptID: file.manuscriptID, manuscriptParentID: file.manuscriptParentID)
        guard let id = result.versionID else {
            if case let .rejected(reason) = result.disposition { throw LyricsEditingRepositoryError.invalidDocument(reason) }
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        return LibraryPassageTarget(trackKey: try resolveStableKey(archiveKey ?? document.identity.stableKey), source: .original(id))
    }
}
