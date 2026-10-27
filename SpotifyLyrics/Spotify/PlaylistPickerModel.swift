import Combine
import Foundation

/// One playlist row in the picker. Values are display-only; the Spotify
/// `snapshot_id` decides when a cached membership check is stale.
public struct PlaylistSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let snapshotID: String?
    public let imageURL: URL?

    public init(id: String, name: String, trackCount: Int, snapshotID: String?, imageURL: URL?) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.snapshotID = snapshotID
        self.imageURL = imageURL
    }
}

/// The picker talks to this boundary so the membership rules can be tested
/// without Keychain, network or a live Spotify session.
@MainActor
public protocol PlaylistCataloging: AnyObject {
    func accessToken() async throws -> String
    func playlists(accessToken: String) async throws -> [PlaylistSummary]
    func createPrivatePlaylist(named name: String, accessToken: String) async throws -> PlaylistSummary
    func contains(trackID: String, inPlaylist id: String, accessToken: String) async throws -> Bool
    func add(trackID: String, toPlaylist id: String, accessToken: String) async throws
    func remove(trackID: String, fromPlaylist id: String, accessToken: String) async throws

    /// The first row: Spotify calls it Liked Songs, Music calls it 喜爱.
    var likedRowTitle: String { get }
    /// Total saved songs, or nil when the player cannot answer cheaply.
    func likedTrackCount() async throws -> Int?
    /// Shown when the catalog cannot be reached for a missing permission.
    var connectionNotice: String { get }
    /// Identifies the backing player, so a source switch cannot reuse rows.
    var sourceKey: String { get }
}

public extension PlaylistCataloging {
    var likedRowTitle: String { "已点赞的歌曲" }
    func likedTrackCount() async throws -> Int? { nil }
    var connectionNotice: String { "需要重新连接 Spotify" }
    var sourceKey: String { "spotify" }
}

@MainActor
public final class SpotifyPlaylistCatalog: PlaylistCataloging {
    private let service: SpotifyCatalogService
    private let authorization: SpotifyAuthorizationManager

    public init(service: SpotifyCatalogService = SpotifyCatalogService(),
                authorization: SpotifyAuthorizationManager) {
        self.service = service
        self.authorization = authorization
    }

    public func accessToken() async throws -> String {
        try await authorization.accessToken(requiredScopes: SpotifyOAuthConfiguration.playlistScopes)
    }

    public func playlists(accessToken: String) async throws -> [PlaylistSummary] {
        try await service.currentUserPlaylists(accessToken: accessToken).map(Self.summary)
    }

    public func createPrivatePlaylist(named name: String, accessToken: String) async throws -> PlaylistSummary {
        Self.summary(try await service.createPrivatePlaylist(named: name, accessToken: accessToken))
    }

    public func contains(trackID: String, inPlaylist id: String, accessToken: String) async throws -> Bool {
        try await service.playlistTrackIDs(id, accessToken: accessToken).contains(trackID)
    }

    public func likedTrackCount() async throws -> Int? {
        try await service.savedTracksTotal(accessToken: accessToken())
    }

    public func add(trackID: String, toPlaylist id: String, accessToken: String) async throws {
        try await service.addTrack(trackID, toPlaylist: id, accessToken: accessToken)
    }

    public func remove(trackID: String, fromPlaylist id: String, accessToken: String) async throws {
        try await service.removeTrack(trackID, fromPlaylist: id, accessToken: accessToken)
    }

    private static func summary(_ dto: SpotifyPlaylistDTO) -> PlaylistSummary {
        PlaylistSummary(
            id: dto.id,
            name: dto.name,
            trackCount: dto.trackCount,
            snapshotID: dto.snapshotID,
            imageURL: dto.images?.first.flatMap { URL(string: $0.url) }
        )
    }
}

/// Follows the player: the same popover serves Spotify and Apple Music, and a
/// token remembers which one issued it, so a source switch mid-request cannot
/// send a Spotify token to Music.
@MainActor
public final class RoutingPlaylistCatalog: PlaylistCataloging {
    private let spotify: PlaylistCataloging
    private let appleMusic: PlaylistCataloging
    private let usesAppleMusic: @MainActor () -> Bool

    private static let musicToken = "music:"
    private static let spotifyToken = "spotify:"

    public init(spotify: PlaylistCataloging,
                appleMusic: PlaylistCataloging,
                usesAppleMusic: @escaping @MainActor () -> Bool) {
        self.spotify = spotify
        self.appleMusic = appleMusic
        self.usesAppleMusic = usesAppleMusic
    }

    public var likedRowTitle: String {
        usesAppleMusic() ? appleMusic.likedRowTitle : spotify.likedRowTitle
    }

    public func likedTrackCount() async throws -> Int? {
        if usesAppleMusic() { return try await appleMusic.likedTrackCount() }
        return try await spotify.likedTrackCount()
    }

    public var connectionNotice: String {
        usesAppleMusic() ? appleMusic.connectionNotice : spotify.connectionNotice
    }

    public var sourceKey: String {
        usesAppleMusic() ? appleMusic.sourceKey : spotify.sourceKey
    }

    public func accessToken() async throws -> String {
        if usesAppleMusic() { return Self.musicToken }
        return Self.spotifyToken + (try await spotify.accessToken())
    }

    public func playlists(accessToken: String) async throws -> [PlaylistSummary] {
        let (catalog, token) = route(accessToken)
        return try await catalog.playlists(accessToken: token)
    }

    public func createPrivatePlaylist(named name: String, accessToken: String) async throws -> PlaylistSummary {
        let (catalog, token) = route(accessToken)
        return try await catalog.createPrivatePlaylist(named: name, accessToken: token)
    }

    public func contains(trackID: String, inPlaylist id: String, accessToken: String) async throws -> Bool {
        let (catalog, token) = route(accessToken)
        return try await catalog.contains(trackID: trackID, inPlaylist: id, accessToken: token)
    }

    public func add(trackID: String, toPlaylist id: String, accessToken: String) async throws {
        let (catalog, token) = route(accessToken)
        try await catalog.add(trackID: trackID, toPlaylist: id, accessToken: token)
    }

    public func remove(trackID: String, fromPlaylist id: String, accessToken: String) async throws {
        let (catalog, token) = route(accessToken)
        try await catalog.remove(trackID: trackID, fromPlaylist: id, accessToken: token)
    }

    private func route(_ token: String) -> (PlaylistCataloging, String) {
        if token.hasPrefix(Self.musicToken) {
            return (appleMusic, String(token.dropFirst(Self.musicToken.count)))
        }
        if token.hasPrefix(Self.spotifyToken) {
            return (spotify, String(token.dropFirst(Self.spotifyToken.count)))
        }
        return (spotify, token)
    }
}

/// State for the heart's playlist picker. Membership is fetched only for rows
/// that are on screen and reused while the playlist's snapshot is unchanged.
@MainActor
public final class PlaylistPickerModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var playlists: [PlaylistSummary] = []
    @Published public var query: String = ""
    @Published public private(set) var membership: [String: Set<String>] = [:]
    @Published public private(set) var checking: Set<String> = []
    @Published public private(set) var pending: Set<String> = []
    @Published public private(set) var isLiked = false
    @Published public private(set) var likedCount: Int?
    @Published public private(set) var isCreatingPlaylist = false
    @Published public var notice: String?

    /// The Liked Songs row is not a playlist, so it uses this fixed identity.
    public static let likedRowID = "liked-songs"

    private let catalog: PlaylistCataloging
    private let trackID: @MainActor () -> String?
    private let likedState: @MainActor () -> Bool?
    private let applyLiked: @MainActor (Bool) async -> Bool?

    private var cachedSnapshots: [String: String] = [:]
    private var membershipTracks: [String: String] = [:]
    private var stale: Set<String> = []
    private var membershipTasks: [String: Task<Void, Never>] = [:]
    private var loadTask: Task<Void, Never>?
    private var likedCountTask: Task<Void, Never>?
    private var loadedSourceKey: String?

    public var likedRowTitle: String { catalog.likedRowTitle }

    public init(catalog: PlaylistCataloging,
                trackID: @escaping @MainActor () -> String?,
                likedState: @escaping @MainActor () -> Bool?,
                applyLiked: @escaping @MainActor (Bool) async -> Bool?) {
        self.catalog = catalog
        self.trackID = trackID
        self.likedState = likedState
        self.applyLiked = applyLiked
    }

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var newPlaylistName: String {
        trimmedQuery.isEmpty ? "新列表" : trimmedQuery
    }

    public var filteredPlaylists: [PlaylistSummary] {
        let needle = trimmedQuery.lowercased()
        guard !needle.isEmpty else { return playlists }
        return playlists.filter { $0.name.lowercased().contains(needle) }
    }

    /// Called every time the popover opens. Liked state is re-read from the
    /// player; the playlist list itself is kept for the session, unless the
    /// player changed and the rows would belong to the other account.
    public func open() {
        isLiked = likedState() ?? false
        notice = nil
        if loadedSourceKey != catalog.sourceKey {
            loadedSourceKey = catalog.sourceKey
            playlists = []
            membership = [:]
            cachedSnapshots = [:]
            membershipTracks = [:]
            stale = []
            checking = []
            phase = .idle
        }
        refreshLikedCount()
        if case .ready = phase { return }
        load()
    }

    /// The row's track count is read once per opening, not on every redraw.
    public func refreshLikedCount() {
        likedCountTask?.cancel()
        likedCount = nil
        let sourceKey = catalog.sourceKey
        likedCountTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let value = try? await self.catalog.likedTrackCount()
            guard self.catalog.sourceKey == sourceKey else { return }
            self.likedCount = value
        }
    }

    public func load() {
        guard loadTask == nil else { return }
        if case .ready = phase { return }
        phase = .loading
        let sourceKey = catalog.sourceKey
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            do {
                let token = try await self.catalog.accessToken()
                let rows = try await self.catalog.playlists(accessToken: token)
                guard self.catalog.sourceKey == sourceKey else { return }
                self.playlists = rows
                self.phase = .ready
            } catch {
                guard self.catalog.sourceKey == sourceKey else { return }
                self.phase = .failed(Self.isPermissionError(error) ? self.catalog.connectionNotice : "无法读取歌单")
            }
        }
    }

    public func isMember(_ playlist: PlaylistSummary) -> Bool {
        guard let track = trackID() else { return false }
        return membership[playlist.id]?.contains(track) == true
    }

    public func isChecking(_ playlist: PlaylistSummary) -> Bool {
        checking.contains(playlist.id)
    }

    public func isPending(_ playlist: PlaylistSummary) -> Bool {
        pending.contains(playlist.id)
    }

    /// Lazily fills a row's checkmark. A cached answer is reused until the
    /// playlist's snapshot changes or this app modifies that playlist.
    public func ensureMembership(for playlist: PlaylistSummary) {
        guard let track = trackID(), membershipTasks[playlist.id] == nil else { return }
        if membershipTracks[playlist.id] == track, !stale.contains(playlist.id), let cached = cachedSnapshots[playlist.id],
           cached == playlist.snapshotID, membership[playlist.id] != nil {
            return
        }
        checking.insert(playlist.id)
        let sourceKey = catalog.sourceKey
        membershipTasks[playlist.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            defer {
                self.membershipTasks[playlist.id] = nil
                self.checking.remove(playlist.id)
            }
            guard let track = self.trackID() else {
                LyricsE2ELog.log("PLAYLIST check skipped id=\(playlist.id) no-current-track")
                return
            }
            do {
                let token = try await self.catalog.accessToken()
                let isMember = try await self.catalog.contains(trackID: track, inPlaylist: playlist.id, accessToken: token)
                guard self.catalog.sourceKey == sourceKey else {
                    self.checking.remove(playlist.id)
                    return
                }
                self.membership[playlist.id] = isMember ? [track] : []
                self.membershipTracks[playlist.id] = track
                self.cachedSnapshots[playlist.id] = playlist.snapshotID
                self.stale.remove(playlist.id)
                LyricsE2ELog.log("PLAYLIST check finished id=\(playlist.id) member=\(isMember) seconds=\(Date().timeIntervalSince(started))")
            } catch {
                self.membership[playlist.id] = []
                LyricsE2ELog.log("PLAYLIST check failed id=\(playlist.id) seconds=\(Date().timeIntervalSince(started)) error=\(error.localizedDescription)")
            }
        }
    }

    public func toggle(_ playlist: PlaylistSummary) {
        guard let track = trackID(), !pending.contains(playlist.id) else { return }
        let wasMember = isMember(playlist)
        pending.insert(playlist.id)
        let sourceKey = catalog.sourceKey
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pending.remove(playlist.id) }
            do {
                let token = try await self.catalog.accessToken()
                if wasMember {
                    try await self.catalog.remove(trackID: track, fromPlaylist: playlist.id, accessToken: token)
                } else {
                    try await self.catalog.add(trackID: track, toPlaylist: playlist.id, accessToken: token)
                }
                guard self.catalog.sourceKey == sourceKey else { return }
                var ids = self.membership[playlist.id] ?? []
                if wasMember { ids.remove(track) } else { ids.insert(track) }
                self.membership[playlist.id] = ids
                // The list changed outside this response, so refetch on reopen.
                self.stale.insert(playlist.id)
                self.cachedSnapshots[playlist.id] = nil
            } catch {
                self.notice = Self.isPermissionError(error) ? self.catalog.connectionNotice : "添加失败，稍后再试"
            }
        }
    }

    public func toggleLikedSongs() {
        guard trackID() != nil, !pending.contains(Self.likedRowID) else { return }
        let target = !isLiked
        pending.insert(Self.likedRowID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pending.remove(Self.likedRowID) }
            if let applied = await self.applyLiked(target) {
                self.isLiked = applied
            } else {
                self.notice = "添加失败，稍后再试"
            }
        }
    }

    public func createPlaylist() {
        guard let track = trackID(), !isCreatingPlaylist else { return }
        let name = newPlaylistName
        isCreatingPlaylist = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCreatingPlaylist = false }
            do {
                let token = try await self.catalog.accessToken()
                let created = try await self.catalog.createPrivatePlaylist(named: name, accessToken: token)
                try await self.catalog.add(trackID: track, toPlaylist: created.id, accessToken: token)
                let row = PlaylistSummary(id: created.id, name: created.name,
                                          trackCount: created.trackCount + 1,
                                          snapshotID: created.snapshotID,
                                          imageURL: created.imageURL)
                self.playlists.removeAll { $0.id == row.id }
                self.playlists.insert(row, at: 0)
                self.membership[row.id] = [track]
                self.stale.insert(row.id)
                self.cachedSnapshots[row.id] = nil
                self.query = ""
            } catch {
                self.notice = Self.isPermissionError(error) ? self.catalog.connectionNotice : "添加失败，稍后再试"
            }
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        if error is SpotifyAuthorizationError { return true }
        if let catalogError = error as? SpotifyCatalogError {
            return catalogError == .unauthorized || catalogError == .forbidden
        }
        return false
    }
}
