import CryptoKit
import Foundation

enum LocalLyricsFileKind: String, CaseIterable, Sendable {
    case txt, lrc, ttml
}

/// A file can be read before the user chooses any recording or opens the library.
struct LocalLyricsFile: Sendable {
    let kind: LocalLyricsFileKind
    let content: LyricsDocument
    let locked: Bool
    private let fingerprint: String
    var lines: [LyricLine] { content.lines }

    init(data: Data, kind: LocalLyricsFileKind, preferredLanguage: String) throws {
        self.kind = kind
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let emptyTrack = Track(title: "", artist: "", album: "", duration: 0)
        let identity = TrackIdentity(track: emptyTrack)
        switch kind {
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
    }

    func document(for track: Track) -> LyricsDocument {
        LyricsDocument(identity: TrackIdentity(track: track), title: track.title, artist: track.artist,
                       album: track.album, duration: track.duration > 0 ? track.duration : content.duration,
                       lines: lines, isSynchronized: content.isSynchronized, source: .manualImport,
                       providerSourceID: LyricsPersistenceMapper.lyricFileSourcePrefix + fingerprint, language: content.language,
                       explicitlyTimedLineIndices: content.explicitlyTimedLineIndices)
    }
}

extension SQLiteLyricsRepository {
    func importLyricFile(_ file: LocalLyricsFile, into track: Track, archiveKey: String? = nil) throws -> LibraryPassageTarget {
        let document = file.document(for: track)
        let result = try storeImportedFile(track: track, document: document, locked: file.locked, archiveKey: archiveKey)
        guard let id = result.versionID else {
            if case let .rejected(reason) = result.disposition { throw LyricsEditingRepositoryError.invalidDocument(reason) }
            throw LyricsEditingRepositoryError.sourceNotFound
        }
        return LibraryPassageTarget(trackKey: try resolveStableKey(archiveKey ?? document.identity.stableKey), source: .original(id))
    }
}
