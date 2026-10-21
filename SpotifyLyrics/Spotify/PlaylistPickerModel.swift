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
    func trackIDs(inPlaylist id: String, accessToken: String) async throws -> [String]
    func add(trackID: String, toPlaylist id: String, accessToken: String) async throws
    func remove(trackID: String, fromPlaylist id: String, accessToken: String) async throws
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

    public func trackIDs(inPlaylist id: String, accessToken: String) async throws -> [String] {
        try await service.playlistTrackIDs(id, accessToken: accessToken)
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
    @Published public private(set) var isCreatingPlaylist = false
    @Published public var notice: String?

    /// The Liked Songs row is not a playlist, so it uses this fixed identity.
    public static let likedRowID = "liked-songs"

    private let catalog: PlaylistCataloging
    private let trackID: @MainActor () -> String?
    private let likedState: @MainActor () -> Bool?
    private let applyLiked: @MainActor (Bool) async -> Bool?

    private var cachedSnapshots: [String: String] = [:]
    private var stale: Set<String> = []
    private var membershipTasks: [String: Task<Void, Never>] = [:]
    private var loadTask: Task<Void, Never>?

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
    /// player; the playlist list itself is kept for the session.
    public func open() {
        isLiked = likedState() ?? false
        notice = nil
        if case .ready = phase { return }
        load()
    }

    public func load() {
        guard loadTask == nil else { return }
        if case .ready = phase { return }
        phase = .loading
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            do {
                let token = try await self.catalog.accessToken()
                let rows = try await self.catalog.playlists(accessToken: token)
                self.playlists = rows
                self.phase = .ready
            } catch {
                self.phase = .failed(Self.isPermissionError(error) ? "需要重新连接 Spotify" : "无法读取歌单")
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
        guard membershipTasks[playlist.id] == nil else { return }
        if !stale.contains(playlist.id), let cached = cachedSnapshots[playlist.id],
           cached == playlist.snapshotID, membership[playlist.id] != nil {
            return
        }
        checking.insert(playlist.id)
        membershipTasks[playlist.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.membershipTasks[playlist.id] = nil }
            do {
                let token = try await self.catalog.accessToken()
                let ids = try await self.catalog.trackIDs(inPlaylist: playlist.id, accessToken: token)
                self.membership[playlist.id] = Set(ids)
                self.cachedSnapshots[playlist.id] = playlist.snapshotID
                self.stale.remove(playlist.id)
            } catch {
                // A failed check leaves the row unchecked rather than blocking it.
            }
            self.checking.remove(playlist.id)
        }
    }

    public func toggle(_ playlist: PlaylistSummary) {
        guard let track = trackID(), !pending.contains(playlist.id) else { return }
        let wasMember = isMember(playlist)
        pending.insert(playlist.id)
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
                var ids = self.membership[playlist.id] ?? []
                if wasMember { ids.remove(track) } else { ids.insert(track) }
                self.membership[playlist.id] = ids
                // The list changed outside this response, so refetch on reopen.
                self.stale.insert(playlist.id)
                self.cachedSnapshots[playlist.id] = nil
            } catch {
                self.notice = Self.isPermissionError(error) ? "需要重新连接 Spotify" : "添加失败，稍后再试"
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
                self.notice = Self.isPermissionError(error) ? "需要重新连接 Spotify" : "添加失败，稍后再试"
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
