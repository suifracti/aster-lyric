import Foundation

public enum LyricsSource: String, CaseIterable, Codable, Sendable {
    case local
    case amll
    case lrclib
    case neteaseExperimental
    case qqExperimental
    case lyricsOVH
    case kuwoExperimental
    case kugouExperimental
    case unknown
    case asrMachineGenerated
    case automaticAlignment
    case manualImport
    case manualCreate
    case manualEdit
    case mock

    public var displayName: String {
        switch self {
        case .local: return "本地 LRC"
        case .amll: return "AMLL 社区排轴"
        case .lrclib: return "LRCLIB"
        case .neteaseExperimental: return "网易云（实验）"
        case .qqExperimental: return "QQ音乐（实验）"
        case .lyricsOVH: return "lyrics.ovh"
        case .kuwoExperimental: return "酷我音乐（实验）"
        case .kugouExperimental: return "酷狗音乐（实验）"
        case .unknown: return "未知来源"
        case .asrMachineGenerated: return "ASR 草稿（待校正）"
        case .automaticAlignment: return "自动排轴"
        case .manualImport: return "手动导入"
        case .manualCreate: return "创建歌词"
        case .manualEdit: return "人工编辑"
        case .mock: return "Mock Preview"
        }
    }
}

public struct LyricsDocument: Equatable, Sendable {
    public let identity: TrackIdentity
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?
    public let lines: [LyricLine]
    public let isSynchronized: Bool
    public let source: LyricsSource
    public let confidence: Double
    /// Provider record identifier used for persistence de-duplication. It is
    /// optional to keep existing Provider/fixture initializers source-compatible.
    public let providerSourceID: String?
    /// Independent provider evidence. This is nil unless a Provider actually
    /// verified the identifier; the request TrackIdentity is not evidence.
    public let spotifyTrackID: String?
    public let isrc: String?
    /// Provider/database language metadata used only to gate Japanese reading
    /// projections. It does not alter the original lyric text.
    public let language: String?
    /// When `isSynchronized` is false, these line indices still carry real
    /// start times that must be persisted (Assist partial timeline).
    /// Nil means legacy behavior: no times stored for unsynced documents.
    public let explicitlyTimedLineIndices: Set<Int>?
    /// Adopted immutable timing version ID when word/syllable spans are present.
    public let timingVersionID: UUID?

    public init(
        identity: TrackIdentity,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        lines: [LyricLine],
        isSynchronized: Bool = true,
        source: LyricsSource,
        confidence: Double = 1,
        providerSourceID: String? = nil,
        spotifyTrackID: String? = nil,
        isrc: String? = nil,
        language: String? = nil,
        explicitlyTimedLineIndices: Set<Int>? = nil,
        timingVersionID: UUID? = nil
    ) {
        self.identity = identity
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.lines = lines
        self.isSynchronized = isSynchronized
        self.source = source
        self.confidence = confidence
        self.providerSourceID = providerSourceID
        self.spotifyTrackID = spotifyTrackID
        self.isrc = isrc
        self.language = language
        self.explicitlyTimedLineIndices = explicitlyTimedLineIndices
        self.timingVersionID = timingVersionID
    }

    /// Rebuilds a display document after a line projection without dropping
    /// its identity, partial-timeline mask, language, or timing attachment.
    public func replacingLines(_ lines: [LyricLine]) -> LyricsDocument {
        replacingLines(lines, language: language)
    }

    /// Variant for a caller that deliberately enriches the language field.
    public func replacingLines(_ lines: [LyricLine], language: String?) -> LyricsDocument {
        copying(lines: lines, language: language, timingVersionID: timingVersionID)
    }

    /// Variant for a repository projection that has just selected the exact
    /// immutable timing attachment used to build `lines`.
    public func replacingLines(_ lines: [LyricLine], timingVersionID: UUID?) -> LyricsDocument {
        copying(lines: lines, language: language, timingVersionID: timingVersionID)
    }

    private func copying(
        lines: [LyricLine],
        language: String?,
        timingVersionID: UUID?
    ) -> LyricsDocument {
        LyricsDocument(
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lines: lines,
            isSynchronized: isSynchronized,
            source: source,
            confidence: confidence,
            providerSourceID: providerSourceID,
            spotifyTrackID: spotifyTrackID,
            isrc: isrc,
            language: language,
            explicitlyTimedLineIndices: explicitlyTimedLineIndices,
            timingVersionID: timingVersionID
        )
    }

    public var hasTimedSpans: Bool {
        lines.contains { $0.hasTimedSpans }
    }

    public var hasFineTiming: Bool {
        hasTimedSpans
    }

    /// Whether line `index` has a meaningful start time for editor / playback.
    public func lineHasExplicitTiming(_ index: Int) -> Bool {
        if isSynchronized { return true }
        return explicitlyTimedLineIndices?.contains(index) == true
    }
}

public struct LyricsCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let identity: TrackIdentity
    public let title: String
    /// Independent aliases declared by the provider catalog, never query echoes.
    public let declaredTitleAliases: [String]
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let lines: [LyricLine]
    public let isSynchronized: Bool
    public let source: LyricsSource
    public let confidence: Double
    public let providerSourceID: String?
    /// These are optional independent identity claims from a Provider. They
    /// must never be populated from the caller's identity just to increase a
    /// match score.
    public let spotifyTrackID: String?
    public let isrc: String?
    /// Provider-declared source language, when available. It is used only by
    /// the projection gate and never replaces the original lyric text.
    public let language: String?
    /// Preserves explicit row-time semantics for unsynchronized partial
    /// timelines while a Provider result is represented as a candidate.
    /// Nil and an empty set retain their distinct legacy meanings.
    public let explicitlyTimedLineIndices: Set<Int>?
    /// Runtime retrieval evidence. These fields are intentionally not part of
    /// persistence and are filled by LyricsSearchManager after SafeMatcher
    /// evaluates a Provider result.
    public let providerName: String?
    public let queryKind: String?
    public let queryTitle: String?
    public let queryArtist: String?
    public let matchScore: Double?
    public let matchExplanation: [String]

    public init(
        id: String,
        identity: TrackIdentity,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        lines: [LyricLine],
        isSynchronized: Bool = true,
        source: LyricsSource,
        confidence: Double,
        providerSourceID: String? = nil,
        spotifyTrackID: String? = nil,
        isrc: String? = nil,
        language: String? = nil,
        explicitlyTimedLineIndices: Set<Int>? = nil,
        providerName: String? = nil,
        queryKind: String? = nil,
        queryTitle: String? = nil,
        queryArtist: String? = nil,
        matchScore: Double? = nil,
        matchExplanation: [String] = [],
        declaredTitleAliases: [String] = []
    ) {
        self.id = id
        self.identity = identity
        self.title = title
        self.declaredTitleAliases = declaredTitleAliases
        self.artist = artist
        self.album = album
        self.duration = duration
        self.lines = lines
        self.isSynchronized = isSynchronized
        self.source = source
        self.confidence = confidence
        self.providerSourceID = providerSourceID
        self.spotifyTrackID = spotifyTrackID
        self.isrc = isrc
        self.language = language
        self.explicitlyTimedLineIndices = explicitlyTimedLineIndices
        self.providerName = providerName
        self.queryKind = queryKind
        self.queryTitle = queryTitle
        self.queryArtist = queryArtist
        self.matchScore = matchScore
        self.matchExplanation = matchExplanation
    }

    public var displayedConfidence: Double { matchScore ?? confidence }

    /// Deterministic candidate precedence comparison ensuring stable total ordering with strict transitivity.
    public static func hasPrecedence(_ a: LyricsCandidate, over b: LyricsCandidate) -> Bool {
        let scoreA = a.displayedConfidence.isFinite ? a.displayedConfidence : 0.0
        let scoreB = b.displayedConfidence.isFinite ? b.displayedConfidence : 0.0
        if scoreA != scoreB {
            return scoreA > scoreB
        }
        if a.isSynchronized != b.isSynchronized {
            return a.isSynchronized && !b.isSynchronized
        }
        let aMatchesQuery = a.queryTitle.map { TrackTextNormalizer.normalize(a.title) == TrackTextNormalizer.normalize($0) } ?? false
        let bMatchesQuery = b.queryTitle.map { TrackTextNormalizer.normalize(b.title) == TrackTextNormalizer.normalize($0) } ?? false
        if aMatchesQuery != bMatchesQuery {
            return aMatchesQuery && !bMatchesQuery
        }
        if a.title != b.title {
            return a.title < b.title
        }
        if a.artist != b.artist {
            return a.artist < b.artist
        }
        if a.source.rawValue != b.source.rawValue {
            return a.source.rawValue < b.source.rawValue
        }
        if let aid = a.providerSourceID, let bid = b.providerSourceID, aid != bid {
            return aid < bid
        }
        return a.id < b.id
    }

    /// Full provider result promoted to a document without rewriting its
    /// source, confidence, independent identity claims or lyric lines.
    public func makeDocument() -> LyricsDocument {
        LyricsDocument(
            identity: identity,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            lines: previewLines,
            isSynchronized: requiresTextOnlyPreview ? false : isSynchronized,
            source: source,
            confidence: confidence,
            providerSourceID: providerSourceID,
            spotifyTrackID: spotifyTrackID,
            isrc: isrc,
            language: language,
            explicitlyTimedLineIndices: requiresTextOnlyPreview ? nil : explicitlyTimedLineIndices
        )
    }

    /// A text confirmation cannot certify timing from another tempo recording.
    public var requiresTextOnlyPreview: Bool {
        matchExplanation.contains { $0.hasPrefix("spedUpConflict ") }
    }

    public var previewLines: [LyricLine] {
        guard requiresTextOnlyPreview else { return lines }
        return lines.map { line in
            var text = line
            text.timestamp = 0
            text.endTime = nil
            text.timedSpans = nil
            return text
        }
    }

    public var arrangementNotice: String? {
        if requiresTextOnlyPreview {
            return "加速版与来源录音不同，仅可核对并采用歌词文本；不使用来源时间轴"
        }
        return matchExplanation.contains { $0.hasPrefix("pianoConflict ") }
            ? "钢琴版与原曲编排可能不同，请预览确认歌词与时间轴" : nil
    }

    public var queryMethodLabel: String {
        switch queryKind {
        case "exactTitleFullArtist": return "精确标题 + 完整艺人"
        case "exactTitlePrimaryArtist": return "精确标题 + 主艺人"
        case "normalizedTitleFullArtist": return "规范化标题 + 完整艺人"
        case "normalizedTitlePrimaryArtist": return "规范化标题 + 主艺人"
        case "normalizedVersionTitleFullArtist": return "去版本标记标题 + 完整艺人"
        case "normalizedVersionTitlePrimaryArtist": return "去版本标记标题 + 主艺人"
        case "kanaAlias": return "假名别名"
        case "romajiAlias": return "罗马音别名"
        case "officialEnglishAlias": return "官方英文别名"
        case "confirmedAlias": return "已确认别名"
        case "manualOverride": return "手动搜索词"
        case "titleOnlyLoose": return "宽松标题查询"
        default: return "标准查询"
        }
    }

    public var timelineLabel: String {
        isSynchronized ? "含逐行时间轴" : "纯文本 / 无时间轴"
    }
}

public enum LyricsFailure: Error, Equatable, Sendable {
    case networkUnavailable
    case timedOut
    case rateLimited(TimeInterval?)
    case serverError(Int)
    case parseFailure
    case cancelled
    case identityUnconfirmed(Int, String)
    case unknown(String)

    public var userFacingTitle: String {
        if case .identityUnconfirmed = self { return "歌词身份待确认" }
        return "歌词暂不可用"
    }

    /// Presentation keeps an identity refusal distinct from transport errors.
    /// The underlying failure remains available for recovery and diagnostics.
    public var recoveryMessage: String {
        switch self {
        case .identityUnconfirmed(_, let sourceError):
            return "搜索结果未能确认与当前歌曲一致，可查找更多版本或手动搜索核对。"
                + (sourceError.isEmpty ? "" : "部分来源同时失败：" + sourceError)
        case .networkUnavailable: return "网络暂时不可用，请检查连接后重试。"
        case .timedOut: return "歌词服务响应超时，可以稍后重试。"
        case .rateLimited: return "歌词服务限流，请稍后重试。"
        case .serverError: return "歌词服务暂时不可用，请稍后重试。"
        case .parseFailure: return "返回内容无法识别，可以重新搜索其他来源。"
        case .cancelled: return "这次搜索已取消，可以重新搜索。"
        case .unknown: return "歌词服务暂时不可用，请稍后重试。"
        }
    }

    public var userFacingMessage: String {
        switch self {
        case .networkUnavailable:
            return "网络不可用"
        case .timedOut:
            return "歌词请求超时"
        case .rateLimited:
            return "歌词服务限流，请稍后重试"
        case .serverError(let statusCode):
            return "歌词服务错误（HTTP \(statusCode)）"
        case .parseFailure:
            return "歌词解析失败"
        case .cancelled:
            return "歌词请求已取消"
        case .identityUnconfirmed(let count, let sourceError):
            return "搜索累计有\(count)次候选判定未确认身份（可能重复，不代表可用歌词）。"
                + (sourceError.isEmpty ? "" : "部分来源同时失败：" + sourceError)
        case .unknown(let message):
            return message.isEmpty ? "未知歌词错误" : message
        }
    }
}

public enum LyricsLookupResult: Sendable {
    case match(LyricsDocument)
    case candidates([LyricsCandidate])
    case noLyrics
    case noMatch
    case failed(LyricsFailure)
}

public enum LyricsProviderExecutionLane: Equatable, Sendable {
    case local
    case network
}

public protocol LyricsProvider: Sendable {
    var name: String { get }
    var executionLane: LyricsProviderExecutionLane { get }
    var timeoutInterval: TimeInterval { get }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult
}

public extension LyricsProvider {
    var executionLane: LyricsProviderExecutionLane { .network }
    var timeoutInterval: TimeInterval { 8 }
}

public enum LyricsLoadState: Equatable {
    case idle
    case loading(TrackIdentity)
    case loaded(LyricsDocument)
    /// Lyrics body available but without a trustworthy timeline (no fake sync).
    case alignmentQueued(TrackIdentity, LyricsDocument)
    /// Force-align in progress; keep plain document for identity.
    case alignmentRunning(TrackIdentity, LyricsDocument, Double)
    /// Preview timed result before user confirms (does not replace locked lyrics until confirm).
    case alignmentPreview(TrackIdentity, plain: LyricsDocument, timed: LyricsDocument, report: AlignmentReport)
    case noLyrics(TrackIdentity)
    /// The user explicitly chose no current lyric version. This is session
    /// state, not a Provider failure and not a persisted empty version.
    case noSelection(TrackIdentity)
    case noMatch(TrackIdentity)
    case candidates(TrackIdentity, [LyricsCandidate])
    case failed(TrackIdentity, LyricsFailure)
    case mockPreview

    public var identity: TrackIdentity? {
        switch self {
        case .idle, .mockPreview:
            return nil
        case .loading(let identity), .noLyrics(let identity), .noSelection(let identity), .noMatch(let identity), .failed(let identity, _):
            return identity
        case .loaded(let document), .alignmentQueued(_, let document), .alignmentRunning(_, let document, _):
            return document.identity
        case .alignmentPreview(let identity, _, _, _):
            return identity
        case .candidates(let identity, _):
            return identity
        }
    }

    public var lines: [LyricLine] {
        switch self {
        case .loaded(let document), .alignmentQueued(_, let document), .alignmentRunning(_, let document, _):
            return document.lines
        case .alignmentPreview(_, _, let timed, _):
            return timed.lines
        case .mockPreview:
            return []
        default:
            return []
        }
    }

    public var document: LyricsDocument? {
        switch self {
        case .loaded(let document), .alignmentQueued(_, let document), .alignmentRunning(_, let document, _):
            return document
        case .alignmentPreview(_, _, let timed, _):
            return timed
        default:
            return nil
        }
    }

    public var plainDocument: LyricsDocument? {
        switch self {
        case .alignmentQueued(_, let document), .alignmentRunning(_, let document, _):
            return document
        case .alignmentPreview(_, let plain, _, _):
            return plain
        case .loaded(let document):
            return document
        default:
            return nil
        }
    }

    public var alignmentProgressValue: Double? {
        if case .alignmentRunning(_, _, let p) = self { return p }
        return nil
    }

    public var alignmentReport: AlignmentReport? {
        if case .alignmentPreview(_, _, _, let report) = self { return report }
        return nil
    }

    public var needsAlignment: Bool {
        if case .alignmentQueued = self { return true }
        return false
    }

    public var userFacingMessage: String {
        switch self {
        case .idle:
            return "等待 Spotify 歌曲"
        case .loading:
            return "正在自动补全歌词…"
        case .loaded:
            return ""
        case .alignmentQueued:
            return "已获取歌词，待对齐时间轴"
        case .alignmentRunning:
            return "正在自动排轴…"
        case .alignmentPreview:
            return "排轴预览（未确认）"
        case .noLyrics:
            return "暂未找到歌词"
        case .noSelection:
            return "未选择歌词版本"
        case .noMatch:
            return "自动补全未找到可用歌词"
        case .candidates:
            return "请选择匹配的歌词"
        case .failed(_, let failure):
            return "歌词搜索失败：\(failure.userFacingMessage)"
        case .mockPreview:
            return "Mock Preview"
        }
    }

    public var isShowingRows: Bool {
        switch self {
        case .loaded, .alignmentQueued, .alignmentRunning, .alignmentPreview, .mockPreview:
            return !lines.isEmpty
        default:
            return false
        }
    }
}

public enum LyricsTimeline {
    /// Returns a seek position only for a synchronized row whose timestamp is
    /// finite and inside the current track. Plain-text rows intentionally
    /// return nil because their zero placeholder is not a real seek target.
    public static func validSeekTimestamp(
        for line: LyricLine,
        isSynchronized: Bool,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard isSynchronized,
              duration.isFinite,
              duration > 0,
              line.timestamp.isFinite,
              line.timestamp >= 0,
              line.timestamp <= duration else {
            return nil
        }
        return line.timestamp
    }

    public static func activeLineIndex(
        lines: [LyricLine],
        time: TimeInterval,
        isSynchronized: Bool
    ) -> Int? {
        guard isSynchronized, !lines.isEmpty, time.isFinite else { return nil }

        // Lyrics are ordered by the persisted line index.  A binary search
        // keeps the high-frequency playback tick independent of document
        // length while preserving the existing "last timestamp <= time"
        // semantics, including repeated timestamps.
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].timestamp <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower == 0 ? nil : lower - 1
    }

    /// Timestamp of the next index change after `currentIndex`.
    /// `nil` currentIndex means the playhead is before the first line.
    public static func nextBoundaryTime(
        lines: [LyricLine],
        currentIndex: Int?,
        isSynchronized: Bool
    ) -> TimeInterval? {
        guard isSynchronized, !lines.isEmpty else { return nil }
        return LyricBoundary.nextTime(
            afterIndex: currentIndex,
            timestamps: lines.map(\.timestamp)
        )
    }

    public static func presentationDistance(
        index: Int,
        currentIndex: Int?,
        isSynchronized: Bool
    ) -> Int {
        guard isSynchronized, let currentIndex else { return 0 }
        return abs(index - currentIndex)
    }
}

/// Receipt from the current search decision, distinct from provider confidence.
public struct LyricsAutomaticSelectionEvidence: Sendable {
    public let identity: TrackIdentity
    public let tier: String
    public let hardReject: Bool
    public let versionConflict: Bool
    public init(identity: TrackIdentity, tier: String, hardReject: Bool, versionConflict: Bool) {
        self.identity = identity; self.tier = tier
        self.hardReject = hardReject; self.versionConflict = versionConflict
    }
}
