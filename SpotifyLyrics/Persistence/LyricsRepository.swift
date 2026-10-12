import Foundation

public enum AlignmentProvenanceAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
}

public enum LyricsRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case databaseOpenFailed(String)
    case migrationFailed(Int, String)
    case sqlite(String)
    case unsupportedSchema(Int)
    case invalidData(String)
    case unavailable(String)
    case dataIntegrityViolation(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message): return "歌词数据库打开失败：\(message)"
        case .migrationFailed(let version, let message): return "歌词数据库迁移 v\(version) 失败：\(message)"
        case .sqlite(let message): return "歌词数据库错误：\(message)"
        case .unsupportedSchema(let version): return "歌词数据库版本 \(version) 高于当前 App 支持版本"
        case .invalidData(let message): return "歌词数据库数据无效：\(message)"
        case .unavailable(let message): return "歌词数据库不可用：\(message)"
        case .dataIntegrityViolation(let message): return "歌词数据完整性校验失败：\(message)"
        }
    }
}

public enum LyricsPersistenceSaveDisposition: Equatable, Sendable {
    case inserted
    case duplicate
    case skippedLocked
    /// An explicit adoption found a lock which requires a user confirmation.
    case lockedConflict
    case rejected(String)
}

public struct LyricsPersistenceSaveResult: Equatable, Sendable {
    public let versionID: UUID?
    public let disposition: LyricsPersistenceSaveDisposition
    public let sourceContentHash: String?
    public let timingVersionID: UUID?
    public let conflictingLockedVersionIDs: [UUID]

    public init(
        versionID: UUID?,
        disposition: LyricsPersistenceSaveDisposition,
        sourceContentHash: String? = nil,
        timingVersionID: UUID? = nil,
        conflictingLockedVersionIDs: [UUID] = []
    ) {
        self.versionID = versionID
        self.disposition = disposition
        self.sourceContentHash = sourceContentHash
        self.timingVersionID = timingVersionID
        self.conflictingLockedVersionIDs = conflictingLockedVersionIDs
    }
}

public struct StoredLyricsDocument: Equatable, Sendable {
    public let document: LyricsDocument
    public let versionID: UUID?
    public let sourceContentHash: String?
    public let alignmentProvenanceAvailability: AlignmentProvenanceAvailability
    public let isUserProtected: Bool

    public init(
        document: LyricsDocument,
        versionID: UUID?,
        sourceContentHash: String?,
        alignmentProvenanceAvailability: AlignmentProvenanceAvailability = .unavailable,
        isUserProtected: Bool = false
    ) {
        self.document = document
        self.versionID = versionID
        self.sourceContentHash = sourceContentHash
        self.alignmentProvenanceAvailability = alignmentProvenanceAvailability
        self.isUserProtected = isUserProtected
    }
}

/// A confirmed line-level alignment is a child of an existing plain-text
/// LyricsVersion. The DTO keeps SQL and provenance details out of PlaybackState
/// and SwiftUI.
public struct AlignmentPersistenceRequest: Sendable {
    public let track: Track
    public let identity: TrackIdentity
    public let parentVersionID: UUID
    public let parentSourceContentHash: String
    public let document: LyricsDocument
    public let report: AlignmentReport
    public let lockResult: Bool

    public init(
        track: Track,
        identity: TrackIdentity,
        parentVersionID: UUID,
        parentSourceContentHash: String,
        document: LyricsDocument,
        report: AlignmentReport,
        lockResult: Bool = false
    ) {
        self.track = track
        self.identity = identity
        self.parentVersionID = parentVersionID
        self.parentSourceContentHash = parentSourceContentHash
        self.document = document
        self.report = report
        self.lockResult = lockResult
    }
}

public struct LyricsDatabaseStats: Equatable, Sendable {
    public let databaseURL: URL
    public let schemaVersion: Int
    public let trackCount: Int
    public let lyricsVersionCount: Int
    public let lyricLineCount: Int
    public let fileSize: Int64
    public let lastUpdated: Date?

    public init(
        databaseURL: URL,
        schemaVersion: Int,
        trackCount: Int,
        lyricsVersionCount: Int,
        lyricLineCount: Int,
        fileSize: Int64,
        lastUpdated: Date?
    ) {
        self.databaseURL = databaseURL
        self.schemaVersion = schemaVersion
        self.trackCount = trackCount
        self.lyricsVersionCount = lyricsVersionCount
        self.lyricLineCount = lyricLineCount
        self.fileSize = fileSize
        self.lastUpdated = lastUpdated
    }
}

/// Persistence boundary used by the session layer. Implementations must be
/// Resolves only scopes backed by an already-persisted lyrics version. A nil
/// result means the track/version pair is unknown or belongs to another track.
public protocol LyricsOffsetScopeResolving: Sendable {
    func canonicalStableKeyForSavedLyricsVersion(
        trackStableKey: String,
        versionID: UUID
    ) async throws -> String?
}

public extension LyricsOffsetScopeResolving {
    func canonicalStableKeyForSavedLyricsVersion(
        trackStableKey: String,
        versionID: UUID
    ) async throws -> String? {
        _ = trackStableKey
        _ = versionID
        return nil
    }
}

/// Sendable and perform blocking storage work away from MainActor.
public protocol LyricsRepository: Sendable, LyricsOffsetScopeResolving {
    func prepare() async throws
    /// Returns persisted aliases for query planning. This is read-only and
    /// never creates a Track or LyricsVersion.
    func loadAliases(stableKey: String) async throws -> [TrackAlias]
    /// Stores non-lyrics catalog metadata/aliases without creating an empty
    /// LyricsVersion. Implementations may use the default no-op for tests or
    /// repositories that do not persist track metadata yet.
    func saveTrackMetadata(_ metadata: TrackMetadata) async throws
    func isLyricsSelectionRevoked(identity: TrackIdentity) async throws -> Bool
    func revokeLyricsVersionSelection(trackStableKey: String, lyricsVersionID: UUID) async throws
    func loadBest(track: Track, identity: TrackIdentity) async throws -> LyricsDocument?
    func loadBestStored(track: Track, identity: TrackIdentity) async throws -> StoredLyricsDocument?
    func upsertListeningHistory(_ entry: ListeningHistoryEntry) async throws
    func loadListeningHistory(limit: Int) async throws -> [ListeningHistoryEntry]
    func loadListeningStatistics(for timeRange: ListeningStatisticsTimeRange) async throws -> ListeningStatistics
    func alignmentProvenanceAvailability(versionID: UUID) async -> AlignmentProvenanceAvailability
    func save(
        track: Track,
        identity: TrackIdentity,
        document: LyricsDocument
    ) async throws -> LyricsPersistenceSaveResult
    /// A SafeMatcher automatic decision is separate from provider confidence.
    /// Keeps ordinary cache-save thresholds unchanged.
    func saveAutomaticallySelected(track: Track, identity: TrackIdentity, document: LyricsDocument, decision: LyricsAutomaticSelectionEvidence) async throws -> LyricsPersistenceSaveResult
    /// Persists a user-confirmed candidate and makes it the preferred version
    /// in the same transaction. Passing confirmed lock IDs is an explicit
    /// approval to select over those versions; newly appearing locks are
    /// returned as a fresh conflict.
    func registerManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws
    func cancelManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws
    func saveAndAdoptManually(
        track: Track,
        identity: TrackIdentity,
        document: LyricsDocument,
        requestID: UUID,
        confirmedLockedVersionIDs: [UUID]?
    ) async throws -> LyricsPersistenceSaveResult
    func saveAlignedVersion(_ request: AlignmentPersistenceRequest) async throws -> LyricsPersistenceSaveResult
    func deleteLyricsVersion(versionID: UUID) async throws
    func markLocked(versionID: UUID, locked: Bool) async throws
    func statistics() async throws -> LyricsDatabaseStats
    func createBackup() async throws -> URL
    func clearLyricsCache() async throws
}

public extension LyricsRepository {
    func isLyricsSelectionRevoked(identity: TrackIdentity) async throws -> Bool { false }
    func revokeLyricsVersionSelection(trackStableKey: String, lyricsVersionID: UUID) async throws {
        throw LyricsRepositoryError.unavailable("当前仓库不支持持久取消采用")
    }
    func saveAutomaticallySelected(track: Track, identity: TrackIdentity, document: LyricsDocument, decision: LyricsAutomaticSelectionEvidence) async throws -> LyricsPersistenceSaveResult {
        try await save(track: track, identity: identity, document: document)
    }
    func loadAliases(stableKey: String) async throws -> [TrackAlias] {
        _ = stableKey
        return []
    }

    func saveAlignedVersion(_ request: AlignmentPersistenceRequest) async throws -> LyricsPersistenceSaveResult {
        _ = request
        throw LyricsRepositoryError.unavailable("当前歌词仓库不支持自动排轴版本")
    }

    func saveAndAdoptManually(
        track: Track,
        identity: TrackIdentity,
        document: LyricsDocument,
        requestID: UUID,
        confirmedLockedVersionIDs: [UUID]?
    ) async throws -> LyricsPersistenceSaveResult {
        _ = track
        _ = identity
        _ = document
        _ = requestID
        _ = confirmedLockedVersionIDs
        return LyricsPersistenceSaveResult(
            versionID: nil,
            disposition: .rejected("当前歌词仓库不支持持久采用")
        )
    }

    func registerManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws {
        _ = identity
        _ = requestID
    }

    func cancelManualAdoptionRequest(identity: TrackIdentity, requestID: UUID) async throws {
        _ = identity
        _ = requestID
    }

    func alignmentProvenanceAvailability(versionID: UUID) async -> AlignmentProvenanceAvailability {
        _ = versionID
        return .unavailable
    }

    func deleteLyricsVersion(versionID: UUID) async throws {
        _ = versionID
        throw LyricsRepositoryError.unavailable("当前歌词仓库不支持删除歌词版本")
    }

    func loadBestStored(track: Track, identity: TrackIdentity) async throws -> StoredLyricsDocument? {
        guard let document = try await loadBest(track: track, identity: identity) else { return nil }
        return StoredLyricsDocument(
            document: document,
            versionID: nil,
            sourceContentHash: LyricsPersistenceMapper.sourceContentHash(document: document),
            alignmentProvenanceAvailability: .unavailable
        )
    }

    func upsertListeningHistory(_ entry: ListeningHistoryEntry) async throws {
        _ = entry
    }

    func loadListeningHistory(limit: Int) async throws -> [ListeningHistoryEntry] {
        _ = limit
        return []
    }

    func loadListeningStatistics(for timeRange: ListeningStatisticsTimeRange) async throws -> ListeningStatistics {
        .empty(for: timeRange)
    }

    func saveTrackMetadata(_ metadata: TrackMetadata) async throws {
        _ = metadata
    }

    func statistics() async throws -> LyricsDatabaseStats {
        throw LyricsRepositoryError.unavailable("当前歌词仓库不支持统计")
    }

    func createBackup() async throws -> URL {
        throw LyricsRepositoryError.unavailable("当前歌词仓库不支持备份")
    }

    func clearLyricsCache() async throws {
        throw LyricsRepositoryError.unavailable("当前歌词仓库不支持清理")
    }
}
