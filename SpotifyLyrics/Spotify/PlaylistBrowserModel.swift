import Combine
import Foundation

public struct SpotifyPlaylistTrack: Identifiable, Equatable {
    public let track: Track
    public let offset: Int
    public var id: Int { offset }
}

@MainActor
public final class PlaylistBrowserModel: ObservableObject {
    public static let queueID = "up-next"
    public static let likedID = "liked-songs"
    public let picker: PlaylistPickerModel
    @Published public private(set) var queue: [Track] = []
    @Published public private(set) var tracks: [SpotifyPlaylistTrack] = []
    @Published public private(set) var selectedID = queueID
    @Published public private(set) var isLoading = false
    @Published public private(set) var isQueueLoading = false
    @Published public private(set) var notice: String?
    private let service: SpotifyCatalogService
    private let accessToken: @MainActor (Set<String>) async throws -> String
    private var tracksTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?

    public var selectedTracksAreLoading: Bool {
        selectedID == Self.queueID ? isQueueLoading : isLoading
    }
    public var emptyMessage: String? {
        guard tracks.isEmpty, !selectedTracksAreLoading, notice == nil else { return nil }
        return selectedID == Self.queueID ? "接下来没有待播歌曲" : "歌单里还没有歌曲"
    }

    public init(service: SpotifyCatalogService, picker: PlaylistPickerModel,
                accessToken: @escaping @MainActor (Set<String>) async throws -> String) {
        self.service = service; self.picker = picker; self.accessToken = accessToken
    }
    public func open() { picker.open(); loadQueue() }
    public func loadQueue() {
        guard !isQueueLoading else { return }
        isQueueLoading = true
        queueTask = Task {
            defer { isQueueLoading = false; queueTask = nil }
            do {
                let token = try await accessToken(SpotifyOAuthConfiguration.playbackScopes)
                queue = try await service.upcomingTracks(accessToken: token, limit: nil)
                if selectedID == Self.queueID { tracks = queue.enumerated().map { SpotifyPlaylistTrack(track: $0.element, offset: $0.offset) } }
                notice = nil
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    public func select(_ id: String) {
        tracksTask?.cancel()
        selectedID = id
        notice = nil
        if id == Self.queueID {
            isLoading = false
            tracks = queue.enumerated().map { SpotifyPlaylistTrack(track: $0.element, offset: $0.offset) }
            return
        }
        tracks = []; isLoading = true
        tracksTask = Task {
            defer { if selectedID == id { isLoading = false } }
            do {
                let token = try await accessToken(id == Self.likedID ? SpotifyOAuthConfiguration.libraryScopes : SpotifyOAuthConfiguration.playlistScopes)
                let songs = id == Self.likedID
                    ? try await service.savedTracks(accessToken: token)
                    : try await service.playlistTracks(id, accessToken: token)
                guard !Task.isCancelled, selectedID == id else { return }
                tracks = songs
            } catch { if !Task.isCancelled, selectedID == id { notice = error.localizedDescription } }
        }
    }
    public func play(_ item: SpotifyPlaylistTrack) {
        let context = selectedID
        guard context != Self.queueID else { return }
        let remainingIDs = tracks.drop(while: { $0.offset != item.offset })
            .compactMap { TrackIdentity.spotifyRequestTrackID($0.track.spotifyId) }
        Task {
            do {
                let token = try await accessToken(SpotifyOAuthConfiguration.playbackWriteScopes)
                if context == Self.likedID {
                    guard !remainingIDs.isEmpty else { return }
                    try await service.playTracks(remainingIDs, accessToken: token)
                } else {
                    try await service.playPlaylist(context, offset: item.offset, accessToken: token)
                }
                notice = "已请求播放"
            } catch SpotifyCatalogError.forbidden { notice = "需要 Spotify Premium" }
            catch { notice = error.localizedDescription }
        }
    }
    deinit { tracksTask?.cancel(); queueTask?.cancel() }
}
