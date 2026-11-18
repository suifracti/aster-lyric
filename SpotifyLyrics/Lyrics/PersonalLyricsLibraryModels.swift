import Foundation

// MARK: - Personal Lyrics Library Entry (Read Model Projection)

public struct PersonalLyricsLibraryEntry: Identifiable, Equatable, Sendable, Codable {
    public var id: String { trackStableKey }

    public let trackStableKey: String
    public let spotifyTrackID: String?
    public let spotifyURI: String?
    public let isrc: String?
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: Double
    public let artworkURL: URL?

    var libraryTrack: Track {
        Track(id: "library:\(trackStableKey)", title: title, artist: artist, album: album ?? "", duration: duration,
              isrc: isrc, spotifyId: spotifyTrackID, artworkURL: artworkURL,
              spotifyURL: spotifyURI.flatMap(URL.init(string:)))
    }

    public let lyricsVersionCount: Int
    public let translationVersionCount: Int
    public let readingVersionCount: Int
    public let timingVersionCount: Int

    public let hasLockedLyrics: Bool
    public let hasLockedTranslation: Bool
    public let hasManualLyrics: Bool
    public let hasManualTranslation: Bool
    public let hasReading: Bool
    public let hasFineTiming: Bool

    public let lastModifiedAt: Date

    public let activeLyricsVersionID: UUID?
    public let activeTranslationVersionID: UUID?
    public let activeReadingVersionIDs: [String: UUID]
    public let activeTimingVersionID: UUID?
    /// At least one stored version has line timestamps. A song with plain
    /// text only still counts as missing lyrics for singing along.
    public let hasSyncedLyrics: Bool
    /// Another row of the same song already has what this one lacks. Spotify
    /// sometimes reports a wrong length or the previous song's ID for a
    /// moment while the track changes (shion at 150.8 s beside the real
    /// 168 s, two different songs at 240.0 s under one ID). Such a row is not
    /// a song missing lyrics, and searching with its length cannot work.
    public var coveredByAnotherRecording = false

    /// The 缺歌词 filter and 全部补全. Plain text cannot follow the song, so it
    /// still counts as missing unless the user wrote or locked it.
    public var needsLyrics: Bool {
        guard !coveredByAnotherRecording else { return false }
        return lyricsVersionCount == 0 || (!hasSyncedLyrics && !hasManualLyrics && !hasLockedLyrics)
    }

    /// Marks rows covered by another row of the same song.
    /// - Same Spotify ID: covered when the other row has lyrics, or timed
    ///   lyrics when this one already has plain text.
    /// - An ID shared with a differently titled song is not trustworthy; the
    ///   row is covered when a row with the same title and artist has lyrics.
    /// Different IDs with the same title (GIJIKOI and its Korean version) are
    /// different recordings and stay apart.
    public static func markingRowsCoveredElsewhere(_ entries: [PersonalLyricsLibraryEntry],
                                                   among all: [PersonalLyricsLibraryEntry]) -> [PersonalLyricsLibraryEntry] {
        func idKey(_ entry: PersonalLyricsLibraryEntry) -> String? {
            guard entry.trackStableKey.hasPrefix("spotify-id:"),
                  let prefix = entry.trackStableKey.components(separatedBy: "|").first, prefix.count > "spotify-id:".count else { return nil }
            return prefix.lowercased()
        }
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func covers(_ other: PersonalLyricsLibraryEntry, _ entry: PersonalLyricsLibraryEntry) -> Bool {
            other.trackStableKey != entry.trackStableKey
                && (entry.lyricsVersionCount == 0 ? other.lyricsVersionCount > 0 : other.hasSyncedLyrics)
        }
        let byID = Dictionary(grouping: all.filter { idKey($0) != nil }, by: { idKey($0)! })
        return entries.map { entry in
            guard entry.needsLyrics, let key = idKey(entry), let family = byID[key] else { return entry }
            var marked = entry
            let titles = Set(family.map { fold($0.title) })
            if titles.count == 1 {
                marked.coveredByAnotherRecording = family.contains { covers($0, entry) }
            } else {
                marked.coveredByAnotherRecording = all.contains {
                    fold($0.title) == fold(entry.title) && fold($0.artist) == fold(entry.artist) && covers($0, entry)
                }
            }
            return marked
        }
    }

    public init(
        trackStableKey: String,
        spotifyTrackID: String?,
        spotifyURI: String? = nil,
        isrc: String? = nil,
        title: String,
        artist: String,
        album: String?,
        duration: Double = 0,
        artworkURL: URL?,
        lyricsVersionCount: Int,
        translationVersionCount: Int,
        readingVersionCount: Int,
        timingVersionCount: Int,
        hasLockedLyrics: Bool,
        hasLockedTranslation: Bool,
        hasManualLyrics: Bool,
        hasManualTranslation: Bool,
        hasReading: Bool,
        hasFineTiming: Bool,
        lastModifiedAt: Date,
        activeLyricsVersionID: UUID?,
        activeTranslationVersionID: UUID?,
        activeReadingVersionIDs: [String: UUID] = [:],
        activeTimingVersionID: UUID? = nil,
        hasSyncedLyrics: Bool = true
    ) {
        self.hasSyncedLyrics = hasSyncedLyrics
        self.trackStableKey = trackStableKey
        self.spotifyTrackID = spotifyTrackID
        self.spotifyURI = spotifyURI
        self.isrc = isrc
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.lyricsVersionCount = lyricsVersionCount
        self.translationVersionCount = translationVersionCount
        self.readingVersionCount = readingVersionCount
        self.timingVersionCount = timingVersionCount
        self.hasLockedLyrics = hasLockedLyrics
        self.hasLockedTranslation = hasLockedTranslation
        self.hasManualLyrics = hasManualLyrics
        self.hasManualTranslation = hasManualTranslation
        self.hasReading = hasReading
        self.hasFineTiming = hasFineTiming
        self.lastModifiedAt = lastModifiedAt
        self.activeLyricsVersionID = activeLyricsVersionID
        self.activeTranslationVersionID = activeTranslationVersionID
        self.activeReadingVersionIDs = activeReadingVersionIDs
        self.activeTimingVersionID = activeTimingVersionID
    }
}

// MARK: - Track Detail Items

public struct PersonalLyricsVersionItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let parentVersionID: UUID?
    public let source: String
    public let providerSourceID: String
    public let language: String
    public let isSynced: Bool
    public let lineCount: Int
    public let isMachineGenerated: Bool
    public let isManuallyEdited: Bool
    public let isLocked: Bool
    public let isCurrent: Bool
    public let confidence: Double
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        parentVersionID: UUID?,
        source: String,
        providerSourceID: String,
        language: String,
        isSynced: Bool,
        lineCount: Int,
        isMachineGenerated: Bool,
        isManuallyEdited: Bool,
        isLocked: Bool,
        isCurrent: Bool,
        confidence: Double,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.parentVersionID = parentVersionID
        self.source = source
        self.providerSourceID = providerSourceID
        self.language = language
        self.isSynced = isSynced
        self.lineCount = lineCount
        self.isMachineGenerated = isMachineGenerated
        self.isManuallyEdited = isManuallyEdited
        self.isLocked = isLocked
        self.isCurrent = isCurrent
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersonalTranslationVersionItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let lyricsVersionID: UUID
    public let parentVersionID: UUID?
    public let sourceKind: String
    public let targetLanguage: String
    public let lineCount: Int
    public let isMachineGenerated: Bool
    public let isManuallyEdited: Bool
    public let isLocked: Bool
    public let isArchived: Bool
    public let isCurrent: Bool
    public let status: String
    public let confidence: Double
    public let engineID: String
    public let createdAt: Date
    public let updatedAt: Date
    private let draft: Bool?

    public var isDraft: Bool { draft == true }

    public init(
        id: UUID,
        lyricsVersionID: UUID,
        parentVersionID: UUID?,
        sourceKind: String,
        targetLanguage: String,
        lineCount: Int,
        isMachineGenerated: Bool,
        isManuallyEdited: Bool,
        isLocked: Bool,
        isArchived: Bool,
        isCurrent: Bool,
        status: String,
        confidence: Double,
        engineID: String,
        createdAt: Date,
        updatedAt: Date,
        draft: Bool? = nil
    ) {
        self.id = id
        self.lyricsVersionID = lyricsVersionID
        self.parentVersionID = parentVersionID
        self.sourceKind = sourceKind
        self.targetLanguage = targetLanguage
        self.lineCount = lineCount
        self.isMachineGenerated = isMachineGenerated
        self.isManuallyEdited = isManuallyEdited
        self.isLocked = isLocked
        self.isArchived = isArchived
        self.isCurrent = isCurrent
        self.status = status
        self.confidence = confidence
        self.engineID = engineID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.draft = draft
    }
}

public struct PersonalReadingVersionItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let lyricsVersionID: UUID
    public let parentVersionID: UUID?
    public let representationID: String
    public let sourceKind: String
    public let language: String
    public let lineCount: Int
    public let isMachineGenerated: Bool
    public let isManuallyEdited: Bool
    public let isCurrent: Bool
    public let isLocked: Bool
    public let isArchived: Bool
    public let engineID: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        lyricsVersionID: UUID,
        parentVersionID: UUID?,
        representationID: String,
        sourceKind: String,
        language: String,
        lineCount: Int,
        isMachineGenerated: Bool,
        isManuallyEdited: Bool,
        isCurrent: Bool,
        isLocked: Bool,
        isArchived: Bool,
        engineID: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.lyricsVersionID = lyricsVersionID
        self.parentVersionID = parentVersionID
        self.representationID = representationID
        self.sourceKind = sourceKind
        self.language = language
        self.lineCount = lineCount
        self.isMachineGenerated = isMachineGenerated
        self.isManuallyEdited = isManuallyEdited
        self.isCurrent = isCurrent
        self.isLocked = isLocked
        self.isArchived = isArchived
        self.engineID = engineID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersonalTimingVersionItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let lyricsVersionID: UUID
    public let source: String
    public let granularity: String
    public let isCurrent: Bool
    public let createdAt: Date

    public init(
        id: UUID,
        lyricsVersionID: UUID,
        source: String,
        granularity: String,
        isCurrent: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.lyricsVersionID = lyricsVersionID
        self.source = source
        self.granularity = granularity
        self.isCurrent = isCurrent
        self.createdAt = createdAt
    }
}

public struct PersonalLyricsLibraryTrackDetail: Equatable, Sendable, Codable {
    public let entry: PersonalLyricsLibraryEntry
    public let lyricsVersions: [PersonalLyricsVersionItem]
    public let translationVersions: [PersonalTranslationVersionItem]
    public let readingVersions: [PersonalReadingVersionItem]
    public let timingVersions: [PersonalTimingVersionItem]

    public init(
        entry: PersonalLyricsLibraryEntry,
        lyricsVersions: [PersonalLyricsVersionItem],
        translationVersions: [PersonalTranslationVersionItem],
        readingVersions: [PersonalReadingVersionItem],
        timingVersions: [PersonalTimingVersionItem]
    ) {
        self.entry = entry
        self.lyricsVersions = lyricsVersions
        self.translationVersions = translationVersions
        self.readingVersions = readingVersions
        self.timingVersions = timingVersions
    }
}

// MARK: - Export / Import Package Specification v1

public struct PersonalLyricsLibraryPackage: Equatable, Sendable, Codable {
    public static let formatVersion = 1
    public static let appVersion = "1.0"

    public struct Manifest: Equatable, Sendable, Codable {
        public let formatVersion: Int
        public let appVersion: String
        public let exportedAt: Date
        public let packageType: String // "track_single" or "library_export"

        public init(
            formatVersion: Int = PersonalLyricsLibraryPackage.formatVersion,
            appVersion: String = PersonalLyricsLibraryPackage.appVersion,
            exportedAt: Date = Date(),
            packageType: String = "track_single"
        ) {
            self.formatVersion = formatVersion
            self.appVersion = appVersion
            self.exportedAt = exportedAt
            self.packageType = packageType
        }
    }

    public struct PackageTrack: Equatable, Sendable, Codable {
        public let stableKey: String
        public let spotifyID: String?
        public let spotifyURI: String?
        public let isrc: String?
        public let title: String
        public let artist: String
        public let album: String
        public let duration: Double
        public let artworkURL: String?

        public init(
            stableKey: String,
            spotifyID: String?,
            spotifyURI: String?,
            isrc: String?,
            title: String,
            artist: String,
            album: String,
            duration: Double,
            artworkURL: String?
        ) {
            self.stableKey = stableKey
            self.spotifyID = spotifyID
            self.spotifyURI = spotifyURI
            self.isrc = isrc
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.artworkURL = artworkURL
        }
    }

    public struct PackageLyricsVersion: Equatable, Sendable, Codable {
        public let id: UUID
        public let trackStableKey: String
        public let parentVersionID: UUID?
        public let source: String
        public let providerSourceID: String
        public let language: String
        public let isSynced: Bool
        public let rawText: String
        public let contentHash: String
        public let isMachineGenerated: Bool
        public let isManuallyEdited: Bool
        public let isLocked: Bool
        public let confidence: Double
        public let createdAt: Date
        public let updatedAt: Date
        public let lines: [PackageLyricLine]

        public init(
            id: UUID,
            trackStableKey: String,
            parentVersionID: UUID?,
            source: String,
            providerSourceID: String,
            language: String,
            isSynced: Bool,
            rawText: String,
            contentHash: String,
            isMachineGenerated: Bool,
            isManuallyEdited: Bool,
            isLocked: Bool,
            confidence: Double,
            createdAt: Date,
            updatedAt: Date,
            lines: [PackageLyricLine]
        ) {
            self.id = id
            self.trackStableKey = trackStableKey
            self.parentVersionID = parentVersionID
            self.source = source
            self.providerSourceID = providerSourceID
            self.language = language
            self.isSynced = isSynced
            self.rawText = rawText
            self.contentHash = contentHash
            self.isMachineGenerated = isMachineGenerated
            self.isManuallyEdited = isManuallyEdited
            self.isLocked = isLocked
            self.confidence = confidence
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.lines = lines
        }
    }

    public struct PackageLyricLine: Equatable, Sendable, Codable {
        public let lineIndex: Int
        public let startTime: Double?
        public let endTime: Double?
        public let originalText: String
        public let kanaText: String?
        public let romajiText: String?
        public let translationText: String?
        public let performerID: String?
        public let backgroundText: String?

        public init(
            lineIndex: Int,
            startTime: Double?,
            endTime: Double?,
            originalText: String,
            kanaText: String?,
            romajiText: String?,
            translationText: String?,
            performerID: String? = nil,
            backgroundText: String? = nil
        ) {
            self.lineIndex = lineIndex
            self.startTime = startTime
            self.endTime = endTime
            self.originalText = originalText
            self.kanaText = kanaText
            self.romajiText = romajiText
            self.translationText = translationText
            self.performerID = performerID
            self.backgroundText = backgroundText
        }
    }

    public struct PackageTranslationVersion: Equatable, Sendable, Codable {
        public let id: UUID
        public let lyricsVersionID: UUID
        public let parentVersionID: UUID?
        public let sourceKind: String
        public let targetLanguage: String
        public let model: String
        public let sourceContentHash: String
        public let isMachineGenerated: Bool
        public let isManuallyEdited: Bool
        public let isLocked: Bool
        public let isArchived: Bool
        public let status: String
        public let confidence: Double
        public let engineID: String
        public let promptPresetID: String
        public let createdAt: Date
        public let updatedAt: Date
        public let lines: [PackageTranslationLine]

        public init(
            id: UUID,
            lyricsVersionID: UUID,
            parentVersionID: UUID?,
            sourceKind: String,
            targetLanguage: String,
            model: String,
            sourceContentHash: String,
            isMachineGenerated: Bool,
            isManuallyEdited: Bool,
            isLocked: Bool,
            isArchived: Bool,
            status: String,
            confidence: Double,
            engineID: String,
            promptPresetID: String,
            createdAt: Date,
            updatedAt: Date,
            lines: [PackageTranslationLine]
        ) {
            self.id = id
            self.lyricsVersionID = lyricsVersionID
            self.parentVersionID = parentVersionID
            self.sourceKind = sourceKind
            self.targetLanguage = targetLanguage
            self.model = model
            self.sourceContentHash = sourceContentHash
            self.isMachineGenerated = isMachineGenerated
            self.isManuallyEdited = isManuallyEdited
            self.isLocked = isLocked
            self.isArchived = isArchived
            self.status = status
            self.confidence = confidence
            self.engineID = engineID
            self.promptPresetID = promptPresetID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.lines = lines
        }
    }

    public struct PackageTranslationLine: Equatable, Sendable, Codable {
        public let lineIndex: Int
        public let translatedText: String

        public init(lineIndex: Int, translatedText: String) {
            self.lineIndex = lineIndex
            self.translatedText = translatedText
        }
    }

    public struct PackageReadingVersion: Equatable, Sendable, Codable {
        public let id: UUID
        public let lyricsVersionID: UUID
        public let parentVersionID: UUID?
        public let sourceContentHash: String
        public let engineID: String
        public let representationID: String
        public let sourceKind: String
        public let language: String
        public let isMachineGenerated: Bool
        public let isManuallyEdited: Bool
        public let isCurrent: Bool
        public let isLocked: Bool
        public let isArchived: Bool
        public let confidence: Double
        public let createdAt: Date
        public let updatedAt: Date
        public let lines: [PackageReadingLine]

        public init(
            id: UUID,
            lyricsVersionID: UUID,
            parentVersionID: UUID?,
            sourceContentHash: String,
            engineID: String,
            representationID: String,
            sourceKind: String,
            language: String,
            isMachineGenerated: Bool,
            isManuallyEdited: Bool,
            isCurrent: Bool,
            isLocked: Bool,
            isArchived: Bool,
            confidence: Double,
            createdAt: Date,
            updatedAt: Date,
            lines: [PackageReadingLine]
        ) {
            self.id = id
            self.lyricsVersionID = lyricsVersionID
            self.parentVersionID = parentVersionID
            self.sourceContentHash = sourceContentHash
            self.engineID = engineID
            self.representationID = representationID
            self.sourceKind = sourceKind
            self.language = language
            self.isMachineGenerated = isMachineGenerated
            self.isManuallyEdited = isManuallyEdited
            self.isCurrent = isCurrent
            self.isLocked = isLocked
            self.isArchived = isArchived
            self.confidence = confidence
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.lines = lines
        }
    }

    public struct PackageReadingLine: Equatable, Sendable, Codable {
        public let lineIndex: Int
        public let originalText: String
        public let readingText: String?
        public let tokensJSON: String
        public let language: String
        public let source: String

        public init(
            lineIndex: Int,
            originalText: String,
            readingText: String?,
            tokensJSON: String,
            language: String,
            source: String
        ) {
            self.lineIndex = lineIndex
            self.originalText = originalText
            self.readingText = readingText
            self.tokensJSON = tokensJSON
            self.language = language
            self.source = source
        }
    }

    public struct PackageTimingVersion: Equatable, Sendable, Codable {
        public let id: UUID
        public let lyricsVersionID: UUID
        public let source: String
        public let granularity: String
        public let sourceContentHash: String
        public let spansPayload: String
        public let createdAt: Date

        public init(
            id: UUID,
            lyricsVersionID: UUID,
            source: String,
            granularity: String,
            sourceContentHash: String,
            spansPayload: String,
            createdAt: Date
        ) {
            self.id = id
            self.lyricsVersionID = lyricsVersionID
            self.source = source
            self.granularity = granularity
            self.sourceContentHash = sourceContentHash
            self.spansPayload = spansPayload
            self.createdAt = createdAt
        }
    }

    public let preferredLyricsVersionID: UUID?
    public let manifest: Manifest
    public let track: PackageTrack
    public let lyricsVersions: [PackageLyricsVersion]
    public let translationVersions: [PackageTranslationVersion]
    public let readingVersions: [PackageReadingVersion]
    public let timingVersions: [PackageTimingVersion]

    public init(
        manifest: Manifest = Manifest(),
        track: PackageTrack,
        lyricsVersions: [PackageLyricsVersion],
        translationVersions: [PackageTranslationVersion],
        readingVersions: [PackageReadingVersion],
        timingVersions: [PackageTimingVersion],
        preferredLyricsVersionID: UUID? = nil
    ) {
        self.preferredLyricsVersionID = preferredLyricsVersionID
        self.manifest = manifest
        self.track = track
        self.lyricsVersions = lyricsVersions
        self.translationVersions = translationVersions
        self.readingVersions = readingVersions
        self.timingVersions = timingVersions
    }
}

// MARK: - Import Preview Model

public struct PersonalLibraryImportPreview: Equatable, Sendable, Codable {
    public let trackTitle: String
    public let trackArtist: String
    public let trackStableKey: String

    public let lyricsToAdd: Int
    public let lyricsToSkip: Int
    public let lyricsConflicts: [String]

    public let translationsToAdd: Int
    public let translationsToSkip: Int
    public let translationsConflicts: [String]

    public let readingsToAdd: Int
    public let readingsToSkip: Int
    public let readingsConflicts: [String]

    public let timingsToAdd: Int
    public let timingsToSkip: Int
    public let timingsConflicts: [String]

    public var hasConflicts: Bool {
        !lyricsConflicts.isEmpty || !translationsConflicts.isEmpty || !readingsConflicts.isEmpty || !timingsConflicts.isEmpty
    }

    public var totalNewAssets: Int {
        lyricsToAdd + translationsToAdd + readingsToAdd + timingsToAdd
    }

    public init(
        trackTitle: String,
        trackArtist: String,
        trackStableKey: String,
        lyricsToAdd: Int,
        lyricsToSkip: Int,
        lyricsConflicts: [String],
        translationsToAdd: Int,
        translationsToSkip: Int,
        translationsConflicts: [String],
        readingsToAdd: Int,
        readingsToSkip: Int,
        readingsConflicts: [String],
        timingsToAdd: Int,
        timingsToSkip: Int,
        timingsConflicts: [String]
    ) {
        self.trackTitle = trackTitle
        self.trackArtist = trackArtist
        self.trackStableKey = trackStableKey
        self.lyricsToAdd = lyricsToAdd
        self.lyricsToSkip = lyricsToSkip
        self.lyricsConflicts = lyricsConflicts
        self.translationsToAdd = translationsToAdd
        self.translationsToSkip = translationsToSkip
        self.translationsConflicts = translationsConflicts
        self.readingsToAdd = readingsToAdd
        self.readingsToSkip = readingsToSkip
        self.readingsConflicts = readingsConflicts
        self.timingsToAdd = timingsToAdd
        self.timingsToSkip = timingsToSkip
        self.timingsConflicts = timingsConflicts
    }

    public var allConflicts: [String] {
        lyricsConflicts + translationsConflicts + readingsConflicts + timingsConflicts
    }
}

// MARK: - Standard Personal Data Package v1

public enum PersonalDataPackageError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSchema(Int)
    case invalidPackage(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "个人数据包版本 " + String(version) + " 高于当前 App 支持版本"
        case .invalidPackage(let message):
            return "个人数据包无效：" + message
        }
    }
}

/// Stable, SQLite-independent envelope for transferring all personal lyrics assets.
/// Each nested track package reuses the already-versioned single-track asset model.
public struct PersonalDataPackage: Equatable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public struct Manifest: Equatable, Sendable, Codable {
        public let schemaVersion: Int
        public let createdAt: Date
        public let appVersion: String
        public let packageType: String

        public init(
            schemaVersion: Int = PersonalDataPackage.currentSchemaVersion,
            createdAt: Date = Date(),
            appVersion: String = PersonalLyricsLibraryPackage.appVersion,
            packageType: String = "personal_data"
        ) {
            self.schemaVersion = schemaVersion
            self.createdAt = createdAt
            self.appVersion = appVersion
            self.packageType = packageType
        }
    }

    public let manifest: Manifest
    public let tracks: [PersonalLyricsLibraryPackage]

    public init(
        manifest: Manifest = Manifest(),
        tracks: [PersonalLyricsLibraryPackage]
    ) {
        self.manifest = manifest
        self.tracks = tracks
    }

    public func validate() throws {
        guard manifest.schemaVersion == Self.currentSchemaVersion else {
            if manifest.schemaVersion > Self.currentSchemaVersion {
                throw PersonalDataPackageError.unsupportedSchema(manifest.schemaVersion)
            }
            throw PersonalDataPackageError.invalidPackage("schemaVersion 必须为 " + String(Self.currentSchemaVersion))
        }
        guard manifest.packageType == "personal_data" else {
            throw PersonalDataPackageError.invalidPackage("packageType 不受支持")
        }

        var stableKeys = Set<String>()
        for trackPackage in tracks {
            let stableKey = trackPackage.track.stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stableKey.isEmpty else {
                throw PersonalDataPackageError.invalidPackage("存在缺少 stable key 的歌曲")
            }
            guard stableKeys.insert(stableKey).inserted else {
                throw PersonalDataPackageError.invalidPackage("存在重复的歌曲 stable key")
            }
            guard trackPackage.manifest.formatVersion == PersonalLyricsLibraryPackage.formatVersion else {
                throw PersonalDataPackageError.invalidPackage("嵌套歌曲资产版本不受支持")
            }
        }
    }
}

public struct PersonalDataImportPreview: Equatable, Sendable, Codable {
    public let trackPreviews: [PersonalLibraryImportPreview]

    public init(trackPreviews: [PersonalLibraryImportPreview]) {
        self.trackPreviews = trackPreviews
    }

    public var trackCount: Int {
        trackPreviews.count
    }

    public var hasConflicts: Bool {
        trackPreviews.contains { $0.hasConflicts }
    }

    public var totalNewAssets: Int {
        trackPreviews.reduce(0) { $0 + $1.totalNewAssets }
    }
}

enum LibraryPassageSource: Hashable, Codable, Sendable {
    case selected
    case original(UUID)
    case attached(UUID)
    case translation(UUID)
    case reading(UUID)

    var label: String {
        switch self {
        case .selected: return "歌词"
        case .original: return "原词"
        case .attached: return "原词自带的译文或读音"
        case .translation: return "译文"
        case .reading: return "读音"
        }
    }
}

public struct LibraryPassageTarget: Hashable, Identifiable, Codable, Sendable {
    struct SavedQuote: Hashable, Codable, Sendable {
        let originalVersionID: UUID?
        let translation: String?
    }

    struct ReadingPosition: Hashable, Codable, Sendable {
        let find: String
        let lineIndex: Int?
    }

    let trackKey: String
    var source: LibraryPassageSource = .selected
    var find: String = ""
    var lineIndex: Int? = nil
    var recallNextLine = false
    var savedQuote: SavedQuote? = nil
    // The reader can move away from the bookmarked quote without moving its translation snapshot.
    var readingPosition: ReadingPosition? = nil
    public var id: Self { self }
}

struct LibraryPassageHit: Identifiable, Sendable {
    let entry: PersonalLyricsLibraryEntry
    let source: LibraryPassageSource?
    let excerpt: String?
    var matchesMetadata = false
    var id: String { entry.trackStableKey }

    func readingTarget(for term: String) -> LibraryPassageTarget {
        LibraryPassageTarget(trackKey: id, source: source ?? entry.activeLyricsVersionID.map(LibraryPassageSource.original) ?? .selected,
                             find: source == nil ? "" : term)
    }
}

struct LibraryPassagePage: Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let id: Int
        let original: String
        var translation: String?
        var reading: String?
        var background: String?
        var startTime: TimeInterval?
        var endTime: TimeInterval?
        var timedSpans: [TimedTextSpan]?
        var performerID: String?
        var romanization: String?

        func matches(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            if [original, translation, reading, background].compactMap({ $0 }).contains(where: { $0.range(of: text, options: options) != nil }) {
                return true
            }
            guard let reading, text.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) else { return false }
            return JapaneseRomanizer.romanizeConfirmedKana(reading).range(of: text, options: options) != nil
        }
    }

    let entry: PersonalLyricsLibraryEntry
    let originalVersionID: UUID
    let edition: String
    let lines: [Line]
    var matchesOriginalVersion = true
    var language: String?
    var originalSource = ""
    var originalLocked = false
    var translationLanguage: String?
    var translationSource = ""
    var translationLocked = false
    var translationVersionID: UUID? = nil
    var resolvedSource: LibraryPassageSource? = nil

    func originalOccurrence(of text: String, preferred: Int?) -> Int? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        func same(_ line: Line) -> Bool {
            line.original.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(query, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }
        if let preferred, lines.contains(where: { $0.id == preferred && same($0) }) { return preferred }
        return lines.first(where: same)?.id
    }
}

/// An offline phrase at a time from a single saved edition, including repeated lines in their original order.
struct LyricRecallSession {
    private let originals: [LibraryPassagePage.Line]
    private var position: Int
    private var showsAnswer = false

    init?(lines: [LibraryPassagePage.Line], anchor: Int? = nil) {
        let originals = lines.filter { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard originals.count > 1 else { return nil }
        if let anchor {
            guard let index = originals.firstIndex(where: { $0.id == anchor }), index < originals.count - 1 else { return nil }
            position = index
        } else { position = 0 }
        self.originals = originals
    }

    var cue: LibraryPassagePage.Line { originals[position] }
    var revealedAnswer: LibraryPassagePage.Line? { showsAnswer ? originals[position + 1] : nil }
    var canAdvance: Bool { showsAnswer && position + 2 < originals.count }
    var lineNumber: Int { position + 1 }
    var lineCount: Int { originals.count }

    mutating func reveal() { showsAnswer = true }
    mutating func advance() {
        guard canAdvance else { return }
        position += 1
        showsAnswer = false
    }
}
