import Foundation

/// Time windows supported by the local observed-playback statistics.
public enum ListeningStatisticsTimeRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case last7Days
    case last30Days
    case allTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .last7Days: return "最近 7 天"
        case .last30Days: return "最近 30 天"
        case .allTime: return "全部时间"
        }
    }

    /// Statistics use `last_observed_at` as the session's time-range anchor.
    public var lowerBound: Date {
        switch self {
        case .last7Days:
            return Date().addingTimeInterval(-7 * 24 * 60 * 60)
        case .last30Days:
            return Date().addingTimeInterval(-30 * 24 * 60 * 60)
        case .allTime:
            return Date(timeIntervalSince1970: 0)
        }
    }
}

struct ListeningStatisticsLoad {
    var statistics: ListeningStatistics?
    var isLoading = false
    var error: String?
}

public struct ListeningStatisticsDailyCount: Identifiable, Equatable, Sendable {
    public let date: Date
    public let dayLabel: String
    public let count: Int

    public var id: String { dayLabel }

    public init(date: Date, dayLabel: String, count: Int) {
        self.date = date
        self.dayLabel = dayLabel
        self.count = count
    }
}

public struct ListeningStatisticsSong: Identifiable, Equatable, Sendable {
    public let stableKey: String
    public let artworkURL: URL?
    public let title: String
    public let artist: String
    public let observedListeningTime: TimeInterval
    public let sessionCount: Int

    public var id: String { stableKey }

    public init(stableKey: String, title: String, artist: String, observedListeningTime: TimeInterval, sessionCount: Int, artworkURL: URL? = nil) {
        self.artworkURL = artworkURL
        self.stableKey = stableKey
        self.title = title
        self.artist = artist
        self.observedListeningTime = observedListeningTime
        self.sessionCount = sessionCount
    }
}

public struct ListeningStatisticsArtist: Identifiable, Equatable, Sendable {
    public let artist: String
    public let observedListeningTime: TimeInterval
    public let sessionCount: Int

    public var id: String { artist }

    public init(artist: String, observedListeningTime: TimeInterval, sessionCount: Int) {
        self.artist = artist
        self.observedListeningTime = observedListeningTime
        self.sessionCount = sessionCount
    }
}

public struct ListeningStatistics: Equatable, Sendable {
    public let timeRange: ListeningStatisticsTimeRange
    public let totalListeningTime: TimeInterval
    public let sessionCount: Int
    public let uniqueSongCount: Int
    public let topSongs: [ListeningStatisticsSong]
    public let topArtists: [ListeningStatisticsArtist]
    public let dailyPlayCounts: [ListeningStatisticsDailyCount]

    public var isEmpty: Bool { sessionCount == 0 }

    public init(
        timeRange: ListeningStatisticsTimeRange,
        totalListeningTime: TimeInterval,
        sessionCount: Int,
        uniqueSongCount: Int,
        topSongs: [ListeningStatisticsSong],
        topArtists: [ListeningStatisticsArtist],
        dailyPlayCounts: [ListeningStatisticsDailyCount]
    ) {
        self.timeRange = timeRange
        self.totalListeningTime = totalListeningTime
        self.sessionCount = sessionCount
        self.uniqueSongCount = uniqueSongCount
        self.topSongs = topSongs
        self.topArtists = topArtists
        self.dailyPlayCounts = dailyPlayCounts
    }

    public static func empty(for timeRange: ListeningStatisticsTimeRange) -> ListeningStatistics {
        ListeningStatistics(
            timeRange: timeRange,
            totalListeningTime: 0,
            sessionCount: 0,
            uniqueSongCount: 0,
            topSongs: [],
            topArtists: [],
            dailyPlayCounts: []
        )
    }
}
