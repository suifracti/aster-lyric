import Foundation
import CryptoKit

public enum DatabaseSourceIdentifier {
    /// User-facing labels are independent from stable storage identifiers.
    /// Unknown historical identifiers remain visible instead of becoming local LRC.
    public static func displayName(for identifier: String) -> String {
        switch identifier {
        case "localLRC", "local": return "本地歌词文件"
        case "localDatabase": return "本地记录（原始来源未记录）"
        case "amll": return "AMLL"
        case "lrclib": return "LRCLIB"
        case "netEaseExperimental", "neteaseExperimental": return "网易云音乐"
        case "qqExperimental": return "QQ音乐"
        case "lyricsOVH": return "Lyrics.ovh"
        case "linkcore": return "LinkCore / TuneCore（发行方）"
        case "kugouExperimental": return "酷狗音乐"
        case "kuwoExperimental": return "酷我音乐"
        case "asrMachineGenerated": return "语音识别草稿"
        case "automaticAlignment": return "自动排轴"
        case "manualImport": return "手动导入"
        case "manualCreate": return "手动创建"
        case "manualEdit": return "人工编辑"
        case "mock": return "示例歌词"
        case "", "unknown": return "未知来源"
        default: return "未知来源（\(identifier)）"
        }
    }

    /// Follows immutable parent links only. A local copy or a provider record
    /// identifier is not evidence of the original provider.
    public static func provenanceDescription(
        source: String,
        parentVersionID: UUID?,
        ancestor: (UUID) -> (source: String, parentVersionID: UUID?)?
    ) -> String {
        guard source == "manualEdit" || source == "automaticAlignment" else {
            return displayName(for: source)
        }
        let operation = displayName(for: source)
        var next = parentVersionID
        var visited = Set<UUID>()
        while let id = next, visited.insert(id).inserted {
            guard let parent = ancestor(id) else { break }
            if parent.source != "manualEdit" && parent.source != "automaticAlignment" {
                return "\(displayName(for: parent.source)) · \(operation)"
            }
            next = parent.parentVersionID
        }
        return "原始来源未知 · \(operation)"
    }

    public static func identifier(for source: LyricsSource) -> String {
        switch source {
        case .unknown: return "unknown"
        case .lyricsOVH: return "lyricsOVH"
        case .linkcore: return "linkcore"
        case .kuwoExperimental: return "kuwoExperimental"
        case .kugouExperimental: return "kugouExperimental"
        case .local: return "localLRC"
        case .amll: return "amll"
        case .lrclib: return "lrclib"
        case .neteaseExperimental: return "netEaseExperimental"
        case .qqExperimental: return "qqExperimental"
        case .asrMachineGenerated: return "asrMachineGenerated"
        case .automaticAlignment: return "automaticAlignment"
        case .manualImport: return "manualImport"
        case .manualCreate: return "manualCreate"
        case .manualEdit: return "manualEdit"
        case .mock: return "mock"
        }
    }

    public static func source(for identifier: String) -> LyricsSource {
        switch identifier {
        case "lyricsOVH": return .lyricsOVH
        case "linkcore": return .linkcore
        case "kuwoExperimental": return .kuwoExperimental
        case "kugouExperimental": return .kugouExperimental
        case "localLRC", "localDatabase", "local": return .local
        case "amll": return .amll
        case "lrclib": return .lrclib
        case "netEaseExperimental", "neteaseExperimental": return .neteaseExperimental
        case "qqExperimental": return .qqExperimental
        case "asrMachineGenerated": return .asrMachineGenerated
        case "automaticAlignment": return .automaticAlignment
        case "manualImport": return .manualImport
        case "manualCreate": return .manualCreate
        case "manualEdit": return .manualEdit
        case "mock": return .mock
        default: return .unknown
        }
    }
}

public enum LyricsPersistenceMapper {
    public static func trackRecord(
        track: Track,
        identity: TrackIdentity,
        now: Date
    ) -> DatabaseTrackRecord {
        DatabaseTrackRecord(
            stableKey: identity.stableKey,
            spotifyID: identity.spotifyTrackID ?? track.spotifyId,
            spotifyURI: identity.spotifyURI ?? track.spotifyURL?.absoluteString,
            isrc: identity.isrc ?? track.isrc,
            title: track.title,
            artistDisplay: track.artist,
            album: track.album,
            duration: track.duration,
            artworkURL: track.artworkURL?.absoluteString,
            createdAt: now,
            updatedAt: now
        )
    }

    public static func aliasRecords(
        track: Track,
        identity: TrackIdentity,
        document: LyricsDocument,
        now: Date
    ) -> [DatabaseTrackAliasRecord] {
        let metadata = TrackMetadata.bootstrap(from: track)
        var aliases = metadata.aliases.map {
            DatabaseTrackAliasRecord(
                trackStableKey: identity.stableKey,
                field: $0.field.rawValue,
                kind: $0.kind.rawValue,
                value: $0.value,
                language: $0.language,
                script: $0.script.rawValue,
                source: $0.source.rawValue,
                confidence: $0.confidence,
                isOfficial: $0.isOfficial
            )
        }

        if let title = document.title, !title.isEmpty,
           TrackIdentity.normalizedComponent(title) != TrackIdentity.normalizedComponent(track.title) {
            aliases.append(
                DatabaseTrackAliasRecord(
                    trackStableKey: identity.stableKey,
                    field: TrackAliasField.title.rawValue,
                    kind: TrackAliasKind.providerAlias.rawValue,
                    value: title,
                    language: ScriptDetector.guessLanguage(title),
                    script: ScriptDetector.detect(title).rawValue,
                    source: TrackAliasSource.provider.rawValue,
                    confidence: document.confidence,
                    isOfficial: false
                )
            )
        }
        if let artist = document.artist, !artist.isEmpty,
           TrackIdentity.normalizedComponent(artist) != TrackIdentity.normalizedComponent(track.artist) {
            aliases.append(
                DatabaseTrackAliasRecord(
                    trackStableKey: identity.stableKey,
                    field: TrackAliasField.artist.rawValue,
                    kind: TrackAliasKind.providerAlias.rawValue,
                    value: artist,
                    language: ScriptDetector.guessLanguage(artist),
                    script: ScriptDetector.detect(artist).rawValue,
                    source: TrackAliasSource.provider.rawValue,
                    confidence: document.confidence,
                    isOfficial: false
                )
            )
        }
        _ = now // Kept in the mapper signature for future alias timestamps.
        return aliases
    }

    public static func aliasRecords(
        metadata: TrackMetadata,
        now: Date
    ) -> [DatabaseTrackAliasRecord] {
        _ = now
        return metadata.aliases.map {
            DatabaseTrackAliasRecord(
                trackStableKey: metadata.identity.stableKey,
                field: $0.field.rawValue,
                kind: $0.kind.rawValue,
                value: $0.value,
                language: $0.language,
                script: $0.script.rawValue,
                source: $0.source.rawValue,
                confidence: $0.confidence,
                isOfficial: $0.isOfficial
            )
        }
    }

    public static func versionRecord(
        document: LyricsDocument,
        identity: TrackIdentity,
        versionID: UUID,
        now: Date
    ) -> DatabaseLyricsVersionRecord {
        let source = DatabaseSourceIdentifier.identifier(for: document.source)
        let providerSourceID = document.providerSourceID?.isEmpty == false
            ? document.providerSourceID!
            : source
        return DatabaseLyricsVersionRecord(
            id: versionID,
            trackStableKey: identity.stableKey,
            parentVersionID: nil,
            source: source,
            providerSourceID: providerSourceID,
            language: language(for: document),
            isSynced: document.isSynchronized,
            rawText: document.lines.map(\.originalText).joined(separator: "\n"),
            contentHash: contentHash(document: document, source: source, providerSourceID: providerSourceID),
            createdAt: now,
            updatedAt: now,
            isMachineGenerated: document.source == .asrMachineGenerated || document.source == .automaticAlignment,
            isManuallyEdited: false,
            isLocked: false,
            confidence: document.confidence
        )
    }

    public static func lineRecords(
        document: LyricsDocument,
        versionID: UUID
    ) -> [DatabaseLyricLineRecord] {
        document.lines.enumerated().map { index, line in
            let hasTiming = document.lineHasExplicitTiming(index)
            let start: TimeInterval? = hasTiming ? line.timestamp : nil
            let end: TimeInterval?
            if hasTiming, let explicitEnd = line.endTime {
                end = explicitEnd
            } else if document.isSynchronized, index + 1 < document.lines.count {
                let next = document.lines[index + 1].timestamp
                end = next > line.timestamp ? next : nil
            } else {
                end = nil
            }
            return DatabaseLyricLineRecord(
                lyricsVersionID: versionID,
                lineIndex: index,
                startTime: start,
                endTime: end,
                originalText: line.originalText,
                kanaText: line.kanaText,
                romajiText: line.romajiText,
                translationText: line.translationText
            )
        }
    }

    public static func sourceContentHash(document: LyricsDocument) -> String {
        let records = lineRecords(document: document, versionID: UUID())
        return LyricsSourceContentHasher.hash(
            isSynchronized: document.isSynchronized,
            lines: records
        )
    }

    public static func document(
        identity: TrackIdentity,
        track: DatabaseTrackRecord,
        version: DatabaseLyricsVersionRecord,
        lines: [DatabaseLyricLineRecord]
    ) -> LyricsDocument {
        let sorted = lines.sorted { $0.lineIndex < $1.lineIndex }
        let lyricLines = sorted.map { line in
            LyricLine(
                timestamp: line.startTime ?? 0,
                originalText: line.originalText,
                endTime: line.endTime,
                translationText: line.translationText,
                romajiText: line.romajiText,
                kanaText: line.kanaText
            )
        }
        // Partial Assist timelines: is_synced=0 but some start_time values present.
        let timedIndices: Set<Int>? = {
            guard !version.isSynced else { return nil }
            let set = Set(sorted.compactMap { $0.startTime != nil ? $0.lineIndex : nil })
            return set.isEmpty ? nil : set
        }()
        return LyricsDocument(
            identity: identity,
            title: track.title,
            artist: track.artistDisplay,
            album: track.album,
            duration: track.duration > 0 ? track.duration : nil,
            lines: lyricLines,
            isSynchronized: version.isSynced,
            source: DatabaseSourceIdentifier.source(for: version.source),
            confidence: version.confidence,
            providerSourceID: version.providerSourceID,
            language: version.language,
            explicitlyTimedLineIndices: timedIndices
        )
    }

    private static func language(for document: LyricsDocument) -> String {
        if let language = document.language, !language.isEmpty {
            return language
        }
        let text = document.lines.map(\.originalText).joined(separator: "\n")
        return LyricsLanguageGate.inferredLanguage(text: text) ?? "und"
    }

    private struct HashLine: Encodable {
        let index: Int
        let start: TimeInterval?
        let end: TimeInterval?
        let original: String
        let kana: String?
        let romaji: String?
        let translation: String?
    }

    private struct HashPayload: Encodable {
        let source: String
        let providerSourceID: String
        let isSynced: Bool
        let lines: [HashLine]
    }

    private static func contentHash(
        document: LyricsDocument,
        source: String,
        providerSourceID: String
    ) -> String {
        let payload = HashPayload(
            source: source,
            providerSourceID: providerSourceID,
            isSynced: document.isSynchronized,
            lines: document.lines.enumerated().map { index, line in
                HashLine(
                    index: index,
                    start: document.isSynchronized ? line.timestamp : nil,
                    end: document.isSynchronized ? line.endTime : nil,
                    original: line.originalText,
                    kana: line.kanaText,
                    romaji: line.romajiText,
                    translation: line.translationText
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
