import Foundation
import CryptoKit

/// Storage-shaped records. These types intentionally do not leak SQLite
/// handles or SQL details into the playback and provider layers.
public struct DatabaseTrackRecord: Equatable, Sendable {
    public let stableKey: String
    public let spotifyID: String?
    public let spotifyURI: String?
    public let isrc: String?
    public let title: String
    public let artistDisplay: String
    public let album: String
    public let duration: TimeInterval
    public let artworkURL: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        stableKey: String,
        spotifyID: String?,
        spotifyURI: String?,
        isrc: String?,
        title: String,
        artistDisplay: String,
        album: String,
        duration: TimeInterval,
        artworkURL: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.stableKey = stableKey
        self.spotifyID = spotifyID
        self.spotifyURI = spotifyURI
        self.isrc = isrc
        self.title = title
        self.artistDisplay = artistDisplay
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DatabaseTrackAliasRecord: Equatable, Sendable {
    public let trackStableKey: String
    public let field: String
    public let kind: String
    public let value: String
    public let language: String?
    public let script: String
    public let source: String
    public let confidence: Double
    public let isOfficial: Bool

    public init(
        trackStableKey: String,
        field: String,
        kind: String,
        value: String,
        language: String?,
        script: String,
        source: String,
        confidence: Double,
        isOfficial: Bool
    ) {
        self.trackStableKey = trackStableKey
        self.field = field
        self.kind = kind
        self.value = value
        self.language = language
        self.script = script
        self.source = source
        self.confidence = confidence
        self.isOfficial = isOfficial
    }
}

public struct DatabaseLyricsVersionRecord: Equatable, Sendable {
    public let id: UUID
    public let trackStableKey: String
    public let parentVersionID: UUID?
    public let source: String
    public let providerSourceID: String
    public let language: String
    public let isSynced: Bool
    public let rawText: String
    public let contentHash: String
    public let createdAt: Date
    public let updatedAt: Date
    public let isMachineGenerated: Bool
    public let isManuallyEdited: Bool
    public let isLocked: Bool
    public let confidence: Double

    public init(
        id: UUID,
        trackStableKey: String,
        parentVersionID: UUID? = nil,
        source: String,
        providerSourceID: String,
        language: String,
        isSynced: Bool,
        rawText: String,
        contentHash: String,
        createdAt: Date,
        updatedAt: Date,
        isMachineGenerated: Bool,
        isManuallyEdited: Bool,
        isLocked: Bool,
        confidence: Double
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isMachineGenerated = isMachineGenerated
        self.isManuallyEdited = isManuallyEdited
        self.isLocked = isLocked
        self.confidence = confidence
    }
}

public struct DatabaseLyricLineRecord: Equatable, Sendable {
    public let lyricsVersionID: UUID
    public let lineIndex: Int
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let originalText: String
    public let kanaText: String?
    public let romajiText: String?
    public let translationText: String?

    public init(
        lyricsVersionID: UUID,
        lineIndex: Int,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        originalText: String,
        kanaText: String? = nil,
        romajiText: String? = nil,
        translationText: String? = nil
    ) {
        self.lyricsVersionID = lyricsVersionID
        self.lineIndex = lineIndex
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
        self.kanaText = kanaText
        self.romajiText = romajiText
        self.translationText = translationText
    }
}

public struct DatabaseLyricsTimingVersionRecord: Equatable, Sendable {
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

public struct LineTimingPayload: Codable, Sendable, Equatable {
    public let lineIndex: Int
    public let performerID: String?
    public let spans: [TimedTextSpan]

    public init(lineIndex: Int, performerID: String? = nil, spans: [TimedTextSpan]) {
        self.lineIndex = lineIndex
        self.performerID = performerID
        self.spans = spans
    }
}

public struct DocumentTimingPayload: Codable, Sendable, Equatable {
    public let lines: [LineTimingPayload]

    public init(lines: [LineTimingPayload]) {
        self.lines = lines
    }

    public static func encode(_ lines: [LyricLine]) -> String? {
        var payloads: [LineTimingPayload] = []
        for (idx, line) in lines.enumerated() {
            if let spans = line.timedSpans, !spans.isEmpty {
                payloads.append(LineTimingPayload(lineIndex: idx, performerID: line.performerID, spans: spans))
            }
        }
        guard !payloads.isEmpty else { return nil }
        let doc = DocumentTimingPayload(lines: payloads)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(doc) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String) -> [Int: (performerID: String?, spans: [TimedTextSpan])]? {
        guard let data = json.data(using: .utf8),
              let doc = try? JSONDecoder().decode(DocumentTimingPayload.self, from: data) else {
            return nil
        }
        var result: [Int: (performerID: String?, spans: [TimedTextSpan])] = [:]
        for line in doc.lines {
            guard line.lineIndex >= 0,
                  !line.spans.isEmpty,
                  result[line.lineIndex] == nil else {
                return nil
            }
            result[line.lineIndex] = (line.performerID, line.spans)
        }
        return result
    }
}

/// Fingerprint of the exact lyric source that a translation belongs to. The
/// translation text itself is deliberately excluded so translating the same
/// source again produces a new version without invalidating source matching.
public enum LyricsSourceContentHasher {
    private struct LinePayload: Encodable {
        let index: Int
        let startTime: TimeInterval?
        let endTime: TimeInterval?
        let originalText: String
        let kanaText: String?
        let romajiText: String?
    }

    private struct Payload: Encodable {
        let isSynchronized: Bool
        let lines: [LinePayload]
    }

    public static func hash(
        isSynchronized: Bool,
        lines: [DatabaseLyricLineRecord]
    ) -> String {
        let payload = Payload(
            isSynchronized: isSynchronized,
            lines: lines.sorted { $0.lineIndex < $1.lineIndex }.map { line in
                LinePayload(
                    index: line.lineIndex,
                    startTime: isSynchronized ? line.startTime : nil,
                    endTime: isSynchronized ? line.endTime : nil,
                    originalText: line.originalText,
                    kanaText: line.kanaText,
                    romajiText: line.romajiText
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct DatabaseTranslationVersionRecord: Equatable, Sendable {
    public let id: UUID
    public let lyricsVersionID: UUID
    public let parentVersionID: UUID?
    public let sourceKind: AITranslationSourceKind
    public let targetLanguage: String
    public let model: String
    public let baseURLHost: String
    public let promptHash: String
    public let sourceContentHash: String
    public let createdAt: Date
    public let updatedAt: Date
    public let isMachineGenerated: Bool
    public let isManuallyEdited: Bool
    public let isLocked: Bool
    public let status: AITranslationVersionStatus
    public let confidence: Double
    public let engineID: String
    public let promptPresetID: String
    public let profileID: UUID?
    public let profileSnapshot: String
    public let temperature: Double
    public let workflowID: String
    public let fallbackStrategy: TranslationFallbackStrategy
    public let providerExecutionMetadata: AITranslationProviderExecutionMetadata
    public let isDraft: Bool
    public let isArchived: Bool

    /// Label saved provenance, never the currently selected service or a
    /// guessed provider inferred from the model's name.
    public var translationSourceTitle: String {
        if sourceKind != .ai { return sourceKind.displayName }
        let service: String
        switch TranslationEngineID(rawValue: engineID) {
        case .appleSystem: service = "苹果系统翻译"
        case .codexChatGPT: service = "GPT / ChatGPT"
        case .grokBuild: service = "Grok"
        case .geminiCLI: service = "Gemini"
        case .antigravityCLI: service = "Gemini · Antigravity"
        case .deepSeekAPI: service = "DeepSeek"
        case .openAICompatible: service = "兼容 API"
        case nil: service = "译文（来源未记录）"
        }
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = engineID == TranslationEngineID.appleSystem.rawValue || modelName.isEmpty ? "" : " · " + modelName
        return (isManuallyEdited ? "人工修订 · " : "") + service + suffix
    }

    public init(
        id: UUID,
        lyricsVersionID: UUID,
        parentVersionID: UUID? = nil,
        sourceKind: AITranslationSourceKind,
        targetLanguage: String,
        model: String,
        baseURLHost: String,
        promptHash: String,
        sourceContentHash: String,
        createdAt: Date,
        updatedAt: Date,
        isMachineGenerated: Bool,
        isManuallyEdited: Bool,
        isLocked: Bool,
        status: AITranslationVersionStatus,
        confidence: Double,
        engineID: String = "",
        promptPresetID: String = "",
        profileID: UUID? = nil,
        profileSnapshot: String = "",
        temperature: Double = 0.2,
        workflowID: String = TranslationWorkflowID.classicV1.rawValue,
        fallbackStrategy: TranslationFallbackStrategy = .none,
        providerExecutionMetadata: AITranslationProviderExecutionMetadata = AITranslationProviderExecutionMetadata(),
        isDraft: Bool = false,
        isArchived: Bool = false
    ) {
        self.id = id
        self.lyricsVersionID = lyricsVersionID
        self.parentVersionID = parentVersionID
        self.sourceKind = sourceKind
        self.targetLanguage = targetLanguage
        self.model = model
        self.baseURLHost = baseURLHost
        self.promptHash = promptHash
        self.sourceContentHash = sourceContentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isMachineGenerated = isMachineGenerated
        self.isManuallyEdited = isManuallyEdited
        self.isLocked = isLocked
        self.status = status
        self.confidence = confidence
        self.engineID = engineID
        self.promptPresetID = promptPresetID
        self.profileID = profileID
        self.profileSnapshot = profileSnapshot
        self.temperature = temperature
        self.workflowID = workflowID
        self.fallbackStrategy = fallbackStrategy
        self.providerExecutionMetadata = providerExecutionMetadata
        self.isDraft = isDraft
        self.isArchived = isArchived
    }

    public func with(isDraft: Bool? = nil, isArchived: Bool? = nil) -> DatabaseTranslationVersionRecord {
        DatabaseTranslationVersionRecord(
            id: id,
            lyricsVersionID: lyricsVersionID,
            parentVersionID: parentVersionID,
            sourceKind: sourceKind,
            targetLanguage: targetLanguage,
            model: model,
            baseURLHost: baseURLHost,
            promptHash: promptHash,
            sourceContentHash: sourceContentHash,
            createdAt: createdAt,
            updatedAt: Date(),
            isMachineGenerated: isMachineGenerated,
            isManuallyEdited: isManuallyEdited,
            isLocked: isLocked,
            status: status,
            confidence: confidence,
            engineID: engineID,
            promptPresetID: promptPresetID,
            profileID: profileID,
            profileSnapshot: profileSnapshot,
            temperature: temperature,
            workflowID: workflowID,
            fallbackStrategy: fallbackStrategy,
            providerExecutionMetadata: providerExecutionMetadata,
            isDraft: isDraft ?? self.isDraft,
            isArchived: isArchived ?? self.isArchived
        )
    }
}

public struct DatabaseTranslationLineRecord: Equatable, Sendable {
    public let translationVersionID: UUID
    public let lineIndex: Int
    public let translatedText: String

    public init(translationVersionID: UUID, lineIndex: Int, translatedText: String) {
        self.translationVersionID = translationVersionID
        self.lineIndex = lineIndex
        self.translatedText = translatedText
    }
}

public struct DatabaseReadingLayerRecord: Equatable, Sendable {
    public let lyricsVersionID: UUID
    public let lineIndex: Int
    public let kanaText: String?
    public let romajiText: String?
    public let source: String
    public let isLocked: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        lyricsVersionID: UUID,
        lineIndex: Int,
        kanaText: String?,
        romajiText: String?,
        source: String,
        isLocked: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.lyricsVersionID = lyricsVersionID
        self.lineIndex = lineIndex
        self.kanaText = kanaText
        self.romajiText = romajiText
        self.source = source
        self.isLocked = isLocked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
