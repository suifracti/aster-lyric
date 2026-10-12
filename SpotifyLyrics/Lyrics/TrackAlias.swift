import Foundation

public enum TrackAliasField: String, Codable, Sendable, CaseIterable {
    case title
    case artist
    case album
}

public enum TrackAliasKind: String, Codable, Sendable, CaseIterable {
    case original
    case kana
    case romaji
    case officialEnglish
    case localizedTitle
    case alternativeTitle
    case providerAlias
    case userAlias
}

public enum TrackAliasScript: String, Codable, Sendable, CaseIterable {
    case kanjiHiraganaKatakana
    case latin
    case mixed
    case unknown
}

public enum TrackAliasSource: String, Codable, Sendable, CaseIterable {
    case spotifyMetadata
    case user
    case provider
    case deterministicTransliteration
    case machineGenerated
    case importedTable
}

public struct TrackAlias: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let field: TrackAliasField
    public let kind: TrackAliasKind
    public let value: String
    public let language: String?
    public let script: TrackAliasScript
    public let source: TrackAliasSource
    public let confidence: Double
    public let isOfficial: Bool
    public let createdAt: Date?

    public init(
        id: String,
        field: TrackAliasField,
        kind: TrackAliasKind,
        value: String,
        language: String? = nil,
        script: TrackAliasScript = .unknown,
        source: TrackAliasSource,
        confidence: Double,
        isOfficial: Bool,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.field = field
        self.kind = kind
        self.value = value
        self.language = language
        self.script = script
        self.source = source
        self.confidence = max(0, min(1, confidence))
        self.isOfficial = isOfficial
        self.createdAt = createdAt
    }

    /// Query / evidence weight ordering (higher is better). Not an auto-adopt gate.
    public var sourceWeight: Int {
        switch source {
        case .user:
            return isOfficial ? 100 : 90
        case .spotifyMetadata:
            return isOfficial ? 95 : 80
        case .provider:
            return isOfficial ? 85 : 60
        case .importedTable:
            return 70
        case .deterministicTransliteration:
            return 50
        case .machineGenerated:
            return 10
        }
    }
}

public enum VersionTag: String, Codable, Sendable, CaseIterable, Hashable {
    case live
    case remix
    case acoustic
    case piano
    case spedUp
    case instrumental
    case karaoke
    case radioEdit
    case demo
    case cover
    case reRecord
    case remaster
    case firstTake
    case movieVersion
    case animeVersion
    case shortVersion
    case other
}
