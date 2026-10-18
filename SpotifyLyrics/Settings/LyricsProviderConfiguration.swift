import Foundation

// MARK: - Source mode (stable product IDs)

/// User-selectable free lyrics source policy. One setting value drives which
/// online providers may run; it does not create a second search stack.
public enum LyricsSourceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Local + SQLite + AMLL + LRCLIB + user import/create. No experimental probes.
    case standardFree = "lyricsSourceMode.standardFree.v1"
    /// Standard free plus NetEase/QQ experimental providers. Not for commercial shipping.
    case experimentalFree = "lyricsSourceMode.experimentalFree.v1"

    public var id: String { rawValue }

    /// This repository is currently a personal-use companion rather than a
    /// commercial distribution build. Keep maintained experimental
    /// providers active by default so cold tracks actually benefit from the
    /// expanded catalog coverage work. The standard mode remains available as an
    /// explicit conservative choice.
    public static let `default` = LyricsSourceMode.experimentalFree

    public var title: String {
        switch self {
        case .standardFree: return "开放来源模式"
        case .experimentalFree: return "扩展免费模式（个人使用推荐）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .standardFree: return "标准免费"
        case .experimentalFree: return "扩展实验"
        }
    }

    public var detail: String {
        switch self {
        case .standardFree:
            return "使用本地歌词、已保存版本、AMLL、LRCLIB、lyrics.ovh 与用户导入/创建。不调用实验接口。"
        case .experimentalFree:
            return "在标准免费能力之上，额外尝试网易云、QQ 音乐、酷我、酷狗及 LinkCore 发行方公开正文。可能失效，不保证覆盖率，不建议正式商业发行。"
        }
    }

    public var isExperimental: Bool {
        self == .experimentalFree
    }

    public var allowsExperimentalProviders: Bool {
        self == .experimentalFree
    }
}

// MARK: - Minimal capability classification

/// Coarse policy class for providers. Not a second architecture — used only to
/// decide mode gating and UI labels.
public enum LyricsProviderCapabilityClass: String, Codable, Sendable {
    case local
    case openFree
    case experimentalFree
    case discoveryOnly
    /// User paste / LRC-TXT import / manual create — not a network provider ID.
    case userContent
}

/// Policy for user-authored content paths (paste, import, manual create).
/// Always allowed in both free modes; never implies a paid source.
public enum LyricsUserContentPolicy {
    public static let policy = LyricsProviderPolicy(
        capabilityClass: .userContent,
        allowsAutomaticSearch: false,
        allowsLyricsBody: true,
        allowsLocalCache: true,
        allowsExport: true,
        outboundOnly: false,
        allowedInStandardFree: true,
        allowedInExperimentalFree: true
    )
}

public struct LyricsProviderPolicy: Equatable, Sendable {
    public let capabilityClass: LyricsProviderCapabilityClass
    public let allowsAutomaticSearch: Bool
    public let allowsLyricsBody: Bool
    public let allowsLocalCache: Bool
    public let allowsExport: Bool
    /// When true, the source may only open external browsers / copy query text.
    public let outboundOnly: Bool
    public let allowedInStandardFree: Bool
    public let allowedInExperimentalFree: Bool

    public func isAllowed(in mode: LyricsSourceMode) -> Bool {
        switch mode {
        case .standardFree: return allowedInStandardFree
        case .experimentalFree: return allowedInExperimentalFree
        }
    }
}

// MARK: - Provider IDs

/// Stable identifiers used by the settings layer. `sqliteDatabase` is a
/// persistence source rather than a LyricsProvider instance, so PlaybackState
/// keeps it ahead of the network providers without constructing a second
/// provider type.
public enum LyricsProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case localFiles
    case sqliteDatabase
    case amll
    case lrclib
    case netEaseExperimental
    case qqExperimental
    case kuwoExperimental
    case kugouExperimental
    case lyricsOVH
    case linkcore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localFiles: return "本地歌词"
        case .sqliteDatabase: return "SQLite 本地数据库"
        case .amll: return "AMLL 社区排轴"
        case .lrclib: return "LRCLIB"
        case .netEaseExperimental: return "网易云实验源"
        case .qqExperimental: return "QQ 音乐实验源"
        case .kuwoExperimental: return "酷我音乐实验源"
        case .kugouExperimental: return "酷狗音乐实验源"
        case .lyricsOVH: return "lyrics.ovh"
        case .linkcore: return "LinkCore 官方发行"
        }
    }

    public var systemImage: String {
        switch self {
        case .localFiles: return "doc.text"
        case .sqliteDatabase: return "internaldrive"
        case .amll: return "waveform.path.ecg"
        case .lrclib: return "network"
        case .netEaseExperimental: return "globe.asia.australia"
        case .qqExperimental: return "bubble.left.and.bubble.right"
        case .kuwoExperimental, .kugouExperimental: return "music.note.list"
        case .lyricsOVH: return "globe"
        case .linkcore: return "person.crop.rectangle.stack"
        }
    }

    public var isLocal: Bool {
        self == .localFiles || self == .sqliteDatabase
    }

    public var isExperimental: Bool {
        [Self.netEaseExperimental, .qqExperimental, .kuwoExperimental, .kugouExperimental, .linkcore].contains(self)
    }

    public var stabilityLabel: String {
        switch self {
        case .localFiles, .sqliteDatabase: return "稳定"
        case .amll, .lrclib, .lyricsOVH, .linkcore: return "在线"
        case .netEaseExperimental, .qqExperimental, .kuwoExperimental, .kugouExperimental: return "实验"
        }
    }

    public var detail: String {
        switch self {
        case .localFiles:
            return "只读扫描用户歌词目录，不修改文件"
        case .sqliteDatabase:
            return "优先恢复已采用的本地歌词版本"
        case .amll:
            return "按 Spotify 曲目 ID 精确读取 AMLL 社区排轴，不进行模糊匹配"
        case .lrclib:
            return "公共在线歌词源，网络失败会隔离"
        case .netEaseExperimental:
            return "实验源；目录命中不代表正文可用；仅扩展免费实验模式可用"
        case .qqExperimental, .kuwoExperimental, .kugouExperimental:
            return "实验源；结果必须经过版本匹配；仅扩展免费实验模式可用"
        case .lyricsOVH:
            return "国际歌曲纯文本补充；没有时间轴，需独立证据或手动核对后采用"
        case .linkcore:
            return "按发行方艺人实体及歌曲目录补查公开正文；非同步歌词，保留原站署名与权利限制"
        }
    }

    public var policy: LyricsProviderPolicy {
        switch self {
        case .localFiles:
            return LyricsProviderPolicy(
                capabilityClass: .local,
                allowsAutomaticSearch: true,
                allowsLyricsBody: true,
                allowsLocalCache: false, // never rewrites user LRC files
                allowsExport: true,
                outboundOnly: false,
                allowedInStandardFree: true,
                allowedInExperimentalFree: true
            )
        case .sqliteDatabase:
            return LyricsProviderPolicy(
                capabilityClass: .local,
                allowsAutomaticSearch: true,
                allowsLyricsBody: true,
                allowsLocalCache: true,
                allowsExport: true,
                outboundOnly: false,
                allowedInStandardFree: true,
                allowedInExperimentalFree: true
            )
        case .amll, .lrclib, .lyricsOVH:
            return LyricsProviderPolicy(
                capabilityClass: .openFree,
                allowsAutomaticSearch: true,
                allowsLyricsBody: true,
                allowsLocalCache: true, // high-confidence Session save only
                allowsExport: true,
                outboundOnly: false,
                allowedInStandardFree: true,
                allowedInExperimentalFree: true
            )
        case .linkcore:
            return LyricsProviderPolicy(capabilityClass: .experimentalFree,
                allowsAutomaticSearch: true, allowsLyricsBody: true, allowsLocalCache: true,
                allowsExport: false, outboundOnly: false,
                allowedInStandardFree: false, allowedInExperimentalFree: true)
        case .netEaseExperimental, .qqExperimental, .kuwoExperimental, .kugouExperimental:
            return LyricsProviderPolicy(
                capabilityClass: .experimentalFree,
                allowsAutomaticSearch: true,
                allowsLyricsBody: true,
                allowsLocalCache: true,
                allowsExport: true,
                outboundOnly: false,
                allowedInStandardFree: false,
                allowedInExperimentalFree: true
            )
        }
    }

    public func isAllowed(in mode: LyricsSourceMode) -> Bool {
        policy.isAllowed(in: mode)
    }
}

// MARK: - External discovery (outbound only; never scrapes lyric body)

/// Free external sites that may only open a browser or copy a search query.
/// No automatic lyric body extraction.
public enum LyricsDiscoverySite: String, CaseIterable, Identifiable, Sendable {
    case utaNet
    case utaTime
    case awa

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .utaNet: return "Uta-Net"
        case .utaTime: return "UtaTime"
        case .awa: return "AWA"
        }
    }

    public var detail: String {
        switch self {
        case .utaNet:
            return "可能存在日语歌词页面。仅打开浏览器或复制检索词，不自动抓取正文。"
        case .utaTime:
            return "可能存在原文/罗马音页。仅打开浏览器或复制检索词，不自动抓取正文。"
        case .awa:
            return "歌词在 App 内展示；Web 无公开歌词 API。仅打开站点，不抓取正文。"
        }
    }

    public var policy: LyricsProviderPolicy {
        LyricsProviderPolicy(
            capabilityClass: .discoveryOnly,
            allowsAutomaticSearch: false,
            allowsLyricsBody: false,
            allowsLocalCache: false,
            allowsExport: false,
            outboundOnly: true,
            allowedInStandardFree: true,
            allowedInExperimentalFree: true
        )
    }

    /// Best-effort public search or home URL. Failures leave the user in Safari
    /// without embedding or scraping the page.
    public func browserURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .utaNet:
            if trimmed.isEmpty {
                return URL(string: "https://www.uta-net.com/")
            }
            var components = URLComponents(string: "https://www.uta-net.com/search/")
            components?.queryItems = [URLQueryItem(name: "Keyword", value: trimmed)]
            return components?.url
        case .utaTime:
            if trimmed.isEmpty {
                return URL(string: "https://www.utatime.com/")
            }
            // Site search paths change often; open home and let the user paste
            // the copied query rather than scraping a fragile search endpoint.
            return URL(string: "https://www.utatime.com/")
        case .awa:
            return URL(string: "https://awa.fm/")
        }
    }
}

// MARK: - Per-provider enablement / order

public struct LyricsProviderConfiguration: Equatable, Sendable {
    public var enabled: Set<LyricsProviderID>
    public var order: [LyricsProviderID]

    /// Default enablement: local + open free on; experimental IDs remain
    /// listed so switching to experimentalFree can use them without re-toggling,
    /// but `LyricsSourceMode.standardFree` hard-blocks them at runtime.
    public static let `default` = LyricsProviderConfiguration(
        enabled: Set(LyricsProviderID.allCases),
        order: [
            .localFiles,
            .sqliteDatabase,
            .amll,
            .lrclib,
            .netEaseExperimental,
            .qqExperimental,
            .kuwoExperimental,
            .kugouExperimental,
            .linkcore,
            .lyricsOVH
        ]
    )

    public init(
        enabled: Set<LyricsProviderID> = Set(LyricsProviderID.allCases),
        order: [LyricsProviderID] = LyricsProviderConfiguration.default.order
    ) {
        self.enabled = enabled
        self.order = order
        normalize()
    }

    public mutating func normalize() {
        let knewAMLL = order.contains(.amll) || enabled.contains(.amll)
        if !knewAMLL {
            // Migrate configurations saved before the open AMLL provider was
            // introduced. A later explicit user disable remains respected.
            enabled.insert(.amll)
            if let lrclibIndex = order.firstIndex(of: .lrclib) {
                order.insert(.amll, at: lrclibIndex)
            } else {
                order.append(.amll)
            }
        }
        // Missing IDs distinguish pre-expansion preferences from explicit disables.
        for id in [LyricsProviderID.kuwoExperimental, .kugouExperimental, .lyricsOVH, .linkcore]
            where !order.contains(id) && !enabled.contains(id) {
            enabled.insert(id)
            order.append(id)
        }
        let all = Set(LyricsProviderID.allCases)
        enabled.formUnion([.localFiles, .sqliteDatabase])
        enabled = enabled.intersection(all)

        var seen = Set<LyricsProviderID>()
        order = order.filter { all.contains($0) && seen.insert($0).inserted }
        for id in LyricsProviderID.allCases where seen.insert(id).inserted {
            order.append(id)
        }
    }

    /// Preference-level enablement only (ignores mode).
    public var orderedEnabledIDs: [LyricsProviderID] {
        order.filter { enabled.contains($0) }
    }

    /// Runtime chain for a source mode: preference enablement ∩ mode policy.
    public func orderedEnabledIDs(for mode: LyricsSourceMode) -> [LyricsProviderID] {
        order.filter { enabled.contains($0) && $0.isAllowed(in: mode) }
    }
}
