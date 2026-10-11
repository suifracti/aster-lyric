import Foundation

/// Independent of translation_versions: an uncertain request is never a usable
/// translation. `dispatching` is conservative (the engine may have sent data).
public enum TranslationRequestPhase: String, Codable, Sendable { case prepared, dispatching, received, saved }
public struct StoredTranslationRequest: Codable, Sendable {
    public let key: String
    public let attemptID: UUID
    public var phase: TranslationRequestPhase
    public var result: AITranslationDraft?
    public var updatedAt: Date
    public init(key: String, attemptID: UUID = UUID(), phase: TranslationRequestPhase = .prepared, result: AITranslationDraft? = nil, updatedAt: Date = Date()) {
        self.key = key; self.attemptID = attemptID; self.phase = phase; self.result = result; self.updatedAt = updatedAt
    }
}

public struct StoredTranslationVersion: Equatable, Sendable {
    public let record: DatabaseTranslationVersionRecord
    public let lines: [DatabaseTranslationLineRecord]

    public init(record: DatabaseTranslationVersionRecord, lines: [DatabaseTranslationLineRecord]) {
        self.record = record
        self.lines = lines
    }

    public var isComplete: Bool {
        record.status == .complete
    }

    public var isDraft: Bool { record.isDraft }
    public var isArchived: Bool { record.isArchived }

    public func with(record: DatabaseTranslationVersionRecord) -> StoredTranslationVersion {
        StoredTranslationVersion(record: record, lines: lines)
    }
}

public enum TranslationRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case sourceLyricsNotFound
    case sourceContentMismatch
    case invalidLines(String)
    case versionNotFound
    case lockedVersion
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .sourceLyricsNotFound: return "找不到翻译对应的歌词版本"
        case .sourceContentMismatch: return "翻译对应的歌词内容已变化"
        case .invalidLines(let message): return "翻译行校验失败：\(message)"
        case .versionNotFound: return "找不到翻译版本"
        case .lockedVersion: return "翻译版本已锁定"
        case .database(let message): return "翻译数据库错误：\(message)"
        }
    }
}

/// Translation storage remains separate from the legacy lyric_lines column.
/// Implementations must write only complete, validated versions in one
/// transaction. Request phases are separate records, never translation versions.
public protocol TranslationRepository: Sendable {
    func loadTranslationRequest(key: String) async throws -> StoredTranslationRequest?
    func beginTranslationRequest(key: String, explicitRetry: Bool) async throws -> StoredTranslationRequest
    func updateTranslationRequest(_ request: StoredTranslationRequest) async throws
    func loadTranslationVersions(
        lyricsVersionID: UUID,
        targetLanguage: String,
        sourceContentHash: String
    ) async throws -> [StoredTranslationVersion]

    func saveTranslation(
        lyricsVersionID: UUID,
        sourceContentHash: String,
        originalLines: [String],
        draft: AITranslationDraft,
        forceNewVersion: Bool
    ) async throws -> StoredTranslationVersion

    func markTranslationLocked(versionID: UUID, locked: Bool) async throws
    func deleteTranslation(versionID: UUID) async throws
    func adoptTranslation(versionID: UUID) async throws
    func archiveTranslation(versionID: UUID, archived: Bool) async throws
}

// Repositories without a durable request store may still show cached versions,
// but must fail closed before a new dispatch. Tests opt in with their own store.
public extension TranslationRepository {
    func loadTranslationRequest(key: String) async throws -> StoredTranslationRequest? { nil }
    func beginTranslationRequest(key: String, explicitRetry: Bool) async throws -> StoredTranslationRequest {
        throw TranslationRepositoryError.database("请求状态无法可靠保存；未发送翻译")
    }
    func updateTranslationRequest(_ request: StoredTranslationRequest) async throws {
        throw TranslationRepositoryError.database("请求状态无法可靠保存")
    }
}

public actor UnavailableTranslationRepository: TranslationRepository {
    public init() {}

    public func loadTranslationVersions(
        lyricsVersionID: UUID,
        targetLanguage: String,
        sourceContentHash: String
    ) async throws -> [StoredTranslationVersion] {
        _ = lyricsVersionID; _ = targetLanguage; _ = sourceContentHash
        throw TranslationRepositoryError.database("当前仓库不支持翻译持久化")
    }

    public func saveTranslation(
        lyricsVersionID: UUID,
        sourceContentHash: String,
        originalLines: [String],
        draft: AITranslationDraft,
        forceNewVersion: Bool
    ) async throws -> StoredTranslationVersion {
        _ = lyricsVersionID; _ = sourceContentHash; _ = originalLines; _ = draft; _ = forceNewVersion
        throw TranslationRepositoryError.database("当前仓库不支持翻译持久化")
    }

    public func markTranslationLocked(versionID: UUID, locked: Bool) async throws {
        _ = versionID; _ = locked
        throw TranslationRepositoryError.database("当前仓库不支持翻译持久化")
    }

    public func deleteTranslation(versionID: UUID) async throws {
        _ = versionID
        throw TranslationRepositoryError.database("当前仓库不支持翻译持久化")
    }

    public func adoptTranslation(versionID: UUID) async throws {
        _ = versionID
        throw TranslationRepositoryError.database("当前仓库不支持翻译持久化")
    }

    public func archiveTranslation(versionID: UUID, archived: Bool) async throws {
        _ = versionID; _ = archived
        throw TranslationRepositoryError.database("当前仓库不支持翻译持久化")
    }
}
