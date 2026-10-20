import Foundation
import XCTest
@testable import SpotifyLyrics

final class ListeningStatisticsContractTests: XCTestCase {
    func testStatisticsAggregateHistoryAndHandleEmptyLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotifyLyricsListeningStatisticsContract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("SpotifyLyrics.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance")
        )
        try await repository.prepare()

        try await repository.upsertListeningHistory(entry(
            id: "A1", key: "spotify-id:history-a", title: "Song A", artist: "Artist X", duration: 60, observedAt: 100
        ))
        try await repository.upsertListeningHistory(entry(
            id: "A2", key: "spotify-id:history-a", title: "Song A", artist: "Artist X", duration: 40, observedAt: 110
        ))
        try await repository.upsertListeningHistory(entry(
            id: "B1", key: "spotify-id:history-b", title: "Song B", artist: "Artist X", duration: 80, observedAt: 120
        ))
        try await repository.upsertListeningHistory(entry(
            id: "Y1", key: "spotify-id:history-y", title: "Song Y", artist: "Artist Y", duration: 80, observedAt: 130
        ))

        let statistics = try await repository.loadListeningStatistics(for: .allTime)
        XCTAssertEqual(statistics.totalListeningTime, 260)
        XCTAssertEqual(statistics.sessionCount, 4)
        XCTAssertEqual(statistics.uniqueSongCount, 3)
        XCTAssertEqual(statistics.dailyPlayCounts.count, 7)
        XCTAssertEqual(statistics.dailyPlayCounts.map(\.count), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(statistics.topSongs.map(\.stableKey), [
            "spotify-id:history-a",
            "spotify-id:history-b",
            "spotify-id:history-y"
        ])
        XCTAssertEqual(statistics.topSongs.map(\.sessionCount), [2, 1, 1])
        XCTAssertEqual(statistics.topSongs.map(\.observedListeningTime), [100, 80, 80])
        XCTAssertEqual(statistics.topArtists.map(\.artist), ["Artist X", "Artist Y"])
        XCTAssertEqual(statistics.topArtists.map(\.sessionCount), [3, 1])
        XCTAssertEqual(statistics.topArtists.map(\.observedListeningTime), [180, 80])

        let now = Date().timeIntervalSince1970
        try await repository.upsertListeningHistory(ListeningHistoryEntry(
            sessionID: UUID(),
            stableKey: "spotify-id:today-1",
            title: "Song Today",
            artist: "Artist Today",
            album: "Album",
            startedAt: Date(timeIntervalSince1970: now - 60),
            lastObservedAt: Date(timeIntervalSince1970: now),
            observedPlaybackDuration: 60,
            trackDuration: 180,
            completionRatio: 60.0 / 180.0
        ))
        let updatedStats = try await repository.loadListeningStatistics(for: .allTime)
        XCTAssertEqual(updatedStats.sessionCount, 5)
        XCTAssertEqual(updatedStats.uniqueSongCount, 4)
        XCTAssertEqual(updatedStats.dailyPlayCounts.count, 7)
        XCTAssertEqual(updatedStats.dailyPlayCounts.last?.count, 1)
        XCTAssertTrue(updatedStats.dailyPlayCounts.dropLast().allSatisfy { $0.count == 0 })

        let emptyRepository = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("empty.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("empty-provenance")
        )
        let emptyStatistics = try await emptyRepository.loadListeningStatistics(for: .allTime)
        XCTAssertTrue(emptyStatistics.isEmpty)
        XCTAssertEqual(emptyStatistics.sessionCount, 0)
        XCTAssertEqual(emptyStatistics.uniqueSongCount, 0)
        XCTAssertEqual(emptyStatistics.dailyPlayCounts.count, 7)
        XCTAssertTrue(emptyStatistics.dailyPlayCounts.allSatisfy { $0.count == 0 })
    }

    private func entry(
        id: String,
        key: String,
        title: String,
        artist: String,
        duration: TimeInterval,
        observedAt: TimeInterval
    ) throws -> ListeningHistoryEntry {
        let uuidSuffix: String
        switch id {
        case "A1": uuidSuffix = "0011"
        case "A2": uuidSuffix = "0022"
        case "B1": uuidSuffix = "0033"
        default: uuidSuffix = "0044"
        }
        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000\(uuidSuffix)"))
        return ListeningHistoryEntry(
            sessionID: sessionID,
            stableKey: key,
            title: title,
            artist: artist,
            album: "Album",
            startedAt: Date(timeIntervalSince1970: observedAt - duration),
            lastObservedAt: Date(timeIntervalSince1970: observedAt),
            observedPlaybackDuration: duration,
            trackDuration: 180,
            completionRatio: duration / 180
        )
    }
}
