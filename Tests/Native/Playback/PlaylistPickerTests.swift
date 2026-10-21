import XCTest
@testable import SpotifyLyrics

@MainActor
private final class FakePlaylistCatalog: PlaylistCataloging {
    var rows: [PlaylistSummary]
    var itemIDs: [String: [String]]
    var tokenError: Error?
    private(set) var itemReads: [String] = []
    private(set) var added: [(playlist: String, track: String)] = []
    private(set) var removed: [(playlist: String, track: String)] = []
    private(set) var createdNames: [String] = []

    init(rows: [PlaylistSummary], itemIDs: [String: [String]] = [:]) {
        self.rows = rows
        self.itemIDs = itemIDs
    }

    func accessToken() async throws -> String {
        if let tokenError { throw tokenError }
        return "token"
    }

    func playlists(accessToken: String) async throws -> [PlaylistSummary] { rows }

    func createPrivatePlaylist(named name: String, accessToken: String) async throws -> PlaylistSummary {
        createdNames.append(name)
        return PlaylistSummary(id: "created-\(createdNames.count)", name: name, trackCount: 0,
                               snapshotID: "created", imageURL: nil)
    }

    func trackIDs(inPlaylist id: String, accessToken: String) async throws -> [String] {
        itemReads.append(id)
        return itemIDs[id] ?? []
    }

    func add(trackID: String, toPlaylist id: String, accessToken: String) async throws {
        added.append((id, trackID))
        itemIDs[id, default: []].append(trackID)
    }

    func remove(trackID: String, fromPlaylist id: String, accessToken: String) async throws {
        removed.append((id, trackID))
        itemIDs[id]?.removeAll { $0 == trackID }
    }
}

@MainActor
final class PlaylistPickerTests: XCTestCase {
    private let track = "4cTnxwbzLd90onQ9bKm9V6"

    private func row(_ id: String, _ name: String, snapshot: String = "s1", count: Int = 3) -> PlaylistSummary {
        PlaylistSummary(id: id, name: name, trackCount: count, snapshotID: snapshot, imageURL: nil)
    }

    private func model(_ catalog: FakePlaylistCatalog, liked: Bool = false,
                       applyLiked: (@MainActor (Bool) async -> Bool?)? = nil) -> PlaylistPickerModel {
        PlaylistPickerModel(catalog: catalog,
                            trackID: { [track] in track },
                            likedState: { liked },
                            applyLiked: applyLiked ?? { $0 })
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("等待状态超时", file: file, line: line)
    }

    func testSearchFiltersByNameAndKeepsSpotifyOrder() async {
        let catalog = FakePlaylistCatalog(rows: [row("1", "夜の歌"), row("2", "Morning"), row("3", "夜行性")])
        let model = model(catalog)
        model.open()
        await waitUntil { model.phase == .ready }
        XCTAssertEqual(model.filteredPlaylists.map(\.id), ["1", "2", "3"])

        model.query = "夜"
        XCTAssertEqual(model.filteredPlaylists.map(\.id), ["1", "3"])

        model.query = "  "
        XCTAssertEqual(model.filteredPlaylists.map(\.id), ["1", "2", "3"])
    }

    func testMembershipIsReadOncePerSnapshotAndAgainAfterItChanges() async {
        let playlist = row("1", "Mix", snapshot: "s1")
        let catalog = FakePlaylistCatalog(rows: [playlist], itemIDs: ["1": [track]])
        let model = model(catalog)

        model.ensureMembership(for: playlist)
        await waitUntil { !model.isChecking(playlist) }
        XCTAssertTrue(model.isMember(playlist))

        model.ensureMembership(for: playlist)
        await waitUntil { !model.isChecking(playlist) }
        XCTAssertEqual(catalog.itemReads, ["1"], "同一 snapshot 不应重复读取")

        let updated = row("1", "Mix", snapshot: "s2")
        model.ensureMembership(for: updated)
        await waitUntil { !model.isChecking(updated) }
        XCTAssertEqual(catalog.itemReads, ["1", "1"])
    }

    func testToggleAddsThenRemovesTheCurrentTrack() async {
        let playlist = row("1", "Mix")
        let catalog = FakePlaylistCatalog(rows: [playlist], itemIDs: ["1": []])
        let model = model(catalog)
        model.ensureMembership(for: playlist)
        await waitUntil { !model.isChecking(playlist) }
        XCTAssertFalse(model.isMember(playlist))

        model.toggle(playlist)
        await waitUntil { !model.isPending(playlist) }
        XCTAssertEqual(catalog.added.map(\.track), [track])
        XCTAssertTrue(model.isMember(playlist))

        // This app changed the playlist, so the next visible row refetches
        // instead of trusting the snapshot it read before.
        model.ensureMembership(for: playlist)
        await waitUntil { !model.isChecking(playlist) }
        XCTAssertEqual(catalog.itemReads, ["1", "1"])

        model.toggle(playlist)
        await waitUntil { !model.isPending(playlist) }
        XCTAssertEqual(catalog.removed.map(\.track), [track])
        XCTAssertFalse(model.isMember(playlist))
    }

    func testCreateUsesTypedNameOrFallbackAndAddsTheSong() async {
        let catalog = FakePlaylistCatalog(rows: [])
        let model = model(catalog)
        model.open()
        await waitUntil { model.phase == .ready }

        model.query = "   "
        XCTAssertEqual(model.newPlaylistName, "新列表")
        model.createPlaylist()
        await waitUntil { !model.isCreatingPlaylist }

        model.query = "夜间驾驶"
        model.createPlaylist()
        await waitUntil { !model.isCreatingPlaylist }

        XCTAssertEqual(catalog.createdNames, ["新列表", "夜间驾驶"])
        XCTAssertEqual(catalog.added.map(\.track), [track, track])
        XCTAssertEqual(model.playlists.first?.name, "夜间驾驶")
        XCTAssertEqual(model.query, "")
    }
}
