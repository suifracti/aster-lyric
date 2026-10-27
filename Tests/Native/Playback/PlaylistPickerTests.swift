import XCTest
@testable import SpotifyLyrics

@MainActor
private final class FakePlaylistCatalog: PlaylistCataloging {
    var rows: [PlaylistSummary]
    var itemIDs: [String: [String]]
    var tokenError: Error?
    var membershipCheck: ((String, String) async throws -> Bool)?
    var likedRowTitle = "已点赞的歌曲"
    var likedCountValue: Int?
    var sourceKey = "spotify"

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

    func likedTrackCount() async throws -> Int? { likedCountValue }

    func createPrivatePlaylist(named name: String, accessToken: String) async throws -> PlaylistSummary {
        createdNames.append(name)
        return PlaylistSummary(id: "created-\(createdNames.count)", name: name, trackCount: 0,
                               snapshotID: "created", imageURL: nil)
    }

    func contains(trackID: String, inPlaylist id: String, accessToken: String) async throws -> Bool {
        itemReads.append(id)
        if let membershipCheck { return try await membershipCheck(trackID, id) }
        return itemIDs[id]?.contains(trackID) == true
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

private final class PlaylistFixtureURLProtocol: URLProtocol {
    static var response: ((URLRequest) -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.response(request)
        let reply = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class PlaylistSourceFlag {
    var usesAppleMusic = false
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

    func testRelinkedSavedSongsAcrossPlaylistPagesAndFailedCheckStopsSpinning() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistFixtureURLProtocol.self]
        let service = SpotifyCatalogService(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://playlist.test/v1")!)
        let original = track
        PlaylistFixtureURLProtocol.response = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if request.url!.path == "/v1/me/playlists" {
                if query.first(where: { $0.name == "offset" })?.value == "0" {
                    return (200, ["items": [["id": "songs", "name": "歌曲", "snapshot_id": "s1"]],
                                  "next": "https://playlist.test/v1/me/playlists?offset=1"])
                }
                return (200, ["items": [["id": "folder-song", "name": "04 · J-R&B / City Pop"],
                                        ["id": "failed", "name": "Unavailable"]]])
            }
            XCTAssertEqual(query.first(where: { $0.name == "market" })?.value, "from_token")
            if request.url!.path.contains("/failed/") { return (500, ["error": ["status": 500]]) }
            let field = request.url!.path.contains("/songs/") ? "item" : "track"
            return (200, ["items": [[field: ["id": "replacement", "linked_from": ["id": original]]]]])
        }
        defer { PlaylistFixtureURLProtocol.response = nil }
        let rows = try await service.currentUserPlaylists(accessToken: "fixture")
        XCTAssertEqual(rows.map(\.name), ["歌曲", "04 · J-R&B / City Pop", "Unavailable"])
        let catalog = FakePlaylistCatalog(rows: rows.map {
            PlaylistSummary(id: $0.id, name: $0.name, trackCount: 1, snapshotID: $0.snapshotID, imageURL: nil)
        })
        catalog.membershipCheck = { track, playlist in
            try await service.playlistTrackIDs(playlist, accessToken: "fixture").contains(track)
        }
        let playing = Track(title: "Light source", artist: "kyiku", album: "Even if it was a small prayer",
                            duration: 246.49, spotifyId: "spotify:track:" + original)
        let requestID = PlaybackState.playlistRequestTrackID(for: playing, source: .spotifyDesktop)
        XCTAssertEqual(requestID, original, "The player's mixed-case ID must reach the playlist API unchanged")
        XCTAssertEqual(TrackIdentity(track: playing).spotifyTrackID, original.lowercased(), "Storage identity stays unchanged")
        let model = PlaylistPickerModel(catalog: catalog, trackID: { requestID },
                                         likedState: { false }, applyLiked: { $0 })
        for row in catalog.rows { model.ensureMembership(for: row) }
        await waitUntil { model.checking.isEmpty }
        XCTAssertTrue(model.isMember(catalog.rows[0]))
        XCTAssertTrue(model.isMember(catalog.rows[1]))
        XCTAssertFalse(model.isMember(catalog.rows[2]))
        let noTrack = PlaylistPickerModel(catalog: catalog, trackID: { nil },
                                         likedState: { false }, applyLiked: { $0 })
        noTrack.ensureMembership(for: catalog.rows[0])
        await waitUntil { noTrack.checking.isEmpty }
    }

    func testPlaylistBrowserPlaysTrackInPlaylistContext() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistFixtureURLProtocol.self]
        let service = SpotifyCatalogService(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://playlist.test/v1")!)
        let playRequest = expectation(description: "playlist-context playback request")
        PlaylistFixtureURLProtocol.response = { request in
            if request.url?.path == "/v1/playlists/playlist-3/items" {
                let items: [[String: Any]] = (1...3).map { position in
                    let artist = ["id": "artist-\(position)", "name": "Artist \(position)",
                                  "uri": "spotify:artist:artist-\(position)"]
                    return ["item": [
                        "id": "track-\(position)",
                        "name": "Track \(position)",
                        "uri": "spotify:track:track-\(position)",
                        "duration_ms": 180_000,
                        "explicit": false,
                        "artists": [artist],
                        "album": ["name": "Album \(position)", "images": []]
                    ]]
                }
                return (200, ["items": items, "next": NSNull(), "total": 3])
            }
            if request.url?.path == "/v1/me/player/play" {
                XCTAssertEqual(request.httpMethod, "PUT")
                var payload = request.httpBody ?? Data()
                if payload.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        payload.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
                XCTAssertEqual(body?["context_uri"] as? String, "spotify:playlist:playlist-3")
                let offset = body?["offset"] as? [String: Any]
                XCTAssertEqual(offset?["position"] as? Int, 2)
                playRequest.fulfill()
                return (204, ["ok": true])
            }
            XCTFail("Unexpected playlist browser request: \(request.url?.path ?? "<missing>")")
            return (404, [:])
        }
        defer { PlaylistFixtureURLProtocol.response = nil }

        let picker = model(FakePlaylistCatalog(rows: [row("playlist-3", "Mix")]))
        let browser = PlaylistBrowserModel(service: service, picker: picker, accessToken: { _ in "fixture" })
        browser.select("playlist-3")
        await waitUntil { browser.tracks.count == 3 && !browser.isLoading }

        guard browser.tracks.count == 3 else { return XCTFail("Fixture playlist did not load three tracks") }
        browser.play(browser.tracks[2])
        await fulfillment(of: [playRequest], timeout: 2)
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

    func testAppleMusicNamesTheFirstRowAndOmitsItsCount() async {
        let catalog = FakePlaylistCatalog(rows: [row("1", "Mix")])
        catalog.likedRowTitle = "喜爱"
        catalog.sourceKey = "apple-music"
        let model = model(catalog)
        model.open()
        await waitUntil { model.phase == .ready }
        XCTAssertEqual(model.likedRowTitle, "喜爱")
        XCTAssertNil(model.likedCount)
    }

    func testLikedCountIsReadOncePerOpening() async {
        let catalog = FakePlaylistCatalog(rows: [])
        catalog.likedCountValue = 248
        let model = model(catalog)
        model.open()
        await waitUntil { model.likedCount == 248 }

        catalog.likedCountValue = 249
        model.open()
        await waitUntil { model.likedCount == 249 }
    }

    func testSourceSwitchDropsRowsFromTheOtherPlayer() async {
        let catalog = FakePlaylistCatalog(rows: [row("1", "Spotify Mix")], itemIDs: ["1": [track]])
        let model = model(catalog)
        model.open()
        await waitUntil { model.phase == .ready }
        model.ensureMembership(for: model.playlists[0])
        await waitUntil { !model.isChecking(model.playlists[0]) }
        XCTAssertTrue(model.isMember(model.playlists[0]))

        catalog.sourceKey = "apple-music"
        catalog.rows = [row("2", "本地列表")]
        model.open()

        XCTAssertTrue(model.playlists.isEmpty, "切换播放器后不能沿用上一个账号的歌单")
        await waitUntil { model.phase == .ready }
        XCTAssertEqual(model.playlists.map(\.id), ["2"])
        XCTAssertFalse(model.isMember(model.playlists[0]))
    }

    func testRoutingSendsEachTokenToItsOwnPlayer() async throws {
        let spotify = FakePlaylistCatalog(rows: [row("s", "Spotify")])
        let music = FakePlaylistCatalog(rows: [row("m", "Music")])
        music.sourceKey = "apple-music"
        music.likedRowTitle = "喜爱"
        music.likedCountValue = nil
        let source = PlaylistSourceFlag()
        let routing = RoutingPlaylistCatalog(spotify: spotify, appleMusic: music,
                                             usesAppleMusic: { source.usesAppleMusic })

        let spotifyToken = try await routing.accessToken()
        let spotifyRows = try await routing.playlists(accessToken: spotifyToken)
        XCTAssertEqual(spotifyRows.map(\.id), ["s"])
        XCTAssertEqual(routing.likedRowTitle, "已点赞的歌曲")

        source.usesAppleMusic = true
        let musicToken = try await routing.accessToken()
        let musicRows = try await routing.playlists(accessToken: musicToken)
        XCTAssertEqual(musicRows.map(\.id), ["m"])
        XCTAssertEqual(routing.likedRowTitle, "喜爱")
    }

    func testAppleMusicRowParsingUsesIDSeparatorsAndCount() {
        let raw = "9BEC9B1282CB0D2F\u{1e}夜间驾驶\u{1e}12\u{1f}ABCDEF0123456789\u{1e}Mix\u{1e}0\u{1f}"
        let rows = AppleMusicPlaylistCatalog.parsePlaylists(raw)
        XCTAssertEqual(rows.map(\.id), ["9BEC9B1282CB0D2F", "ABCDEF0123456789"])
        XCTAssertEqual(rows.map(\.name), ["夜间驾驶", "Mix"])
        XCTAssertEqual(rows.first?.trackCount, 12)
        XCTAssertEqual(rows.first?.snapshotID, "count:12")
        XCTAssertTrue(AppleMusicPlaylistCatalog.parsePlaylists("").isEmpty)
    }
}
