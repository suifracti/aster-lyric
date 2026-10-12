import Foundation
import CryptoKit

/// Independent of translation_versions: an uncertain request is never a usable
/// translation. `dispatching` is conservative (the engine may have sent data).
public enum TranslationRequestPhase: String, Codable, Sendable { case prepared, dispatching, received, saved }
public struct StoredTranslationRequest: Codable, Sendable {
    public let key: String
    public let attemptID: UUID
    public let completionVersionID: UUID?
    public var phase: TranslationRequestPhase
    public var result: AITranslationDraft?
    public var updatedAt: Date
    public init(key: String, attemptID: UUID = UUID(), phase: TranslationRequestPhase = .prepared, result: AITranslationDraft? = nil, updatedAt: Date = Date(), completionVersionID: UUID? = nil) {
        self.key = key; self.attemptID = attemptID; self.completionVersionID = completionVersionID; self.phase = phase; self.result = result; self.updatedAt = updatedAt
    }
}

/// Immutable completion evidence. The key uses the same ordered source/configuration
/// fields as dispatch; no transport or caller-supplied result is trusted here.
public struct TranslationCompletionContext: Sendable {
    public let identity: TrackIdentity
    public let lyricsVersionID: UUID
    public let sourceContentHash: String
    public let originalLines: [String]
    public let targetLanguage: String
    public let providerCacheIdentity: String
    public let configurationPromptHash: String
    public let engineID: String
    public let allowsAppleFallback: Bool

    public init(identity: TrackIdentity, lyricsVersionID: UUID, sourceContentHash: String,
                originalLines: [String], targetLanguage: String, providerCacheIdentity: String,
                configurationPromptHash: String, engineID: String, allowsAppleFallback: Bool) {
        self.identity = identity; self.lyricsVersionID = lyricsVersionID; self.sourceContentHash = sourceContentHash
        self.originalLines = originalLines; self.targetLanguage = targetLanguage; self.providerCacheIdentity = providerCacheIdentity
        self.configurationPromptHash = configurationPromptHash; self.engineID = engineID; self.allowsAppleFallback = allowsAppleFallback
    }
    public func requestKey() throws -> String {
        let fields = ["translation-request-v1", identity.stableKey, lyricsVersionID.uuidString, sourceContentHash,
                      targetLanguage, providerCacheIdentity, configurationPromptHash] + originalLines
        return SHA256.hash(data: try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
    public func accepts(engine: String) -> Bool {
        engine == engineID || (allowsAppleFallback && engineID == TranslationEngineID.openAICompatible.rawValue && engine == TranslationEngineID.appleSystem.rawValue)
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
    func completeTranslationRequest(key: String, attemptID: UUID, context: TranslationCompletionContext) async throws -> StoredTranslationVersion
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
    func completeTranslationRequest(key: String, attemptID: UUID, context: TranslationCompletionContext) async throws -> StoredTranslationVersion {
        throw TranslationRepositoryError.database("当前仓库不支持原子完成；未保存或重发翻译")
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
