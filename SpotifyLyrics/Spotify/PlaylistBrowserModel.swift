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
    @Published public private(set) var hasLoadedQueue = false
    @Published public private(set) var notice: String?
    private let service: SpotifyCatalogService
    private let advanceQueue: @MainActor (Int) -> Void
    private let accessToken: @MainActor (Set<String>) async throws -> String
    private var tracksTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var rawQueue: [Track] = []
    private var currentQueueTrackID: String?
    private var queueSkipCounts: [String: Int] = [:]
    private enum ManualPlaybackIntent { case track(String), previous, queueJump(String) }
    private var manualPlaybackIntent: ManualPlaybackIntent?

    private func queueKey(_ track: Track) -> String? {
        TrackIdentity.spotifyRequestTrackID(track.spotifyId ?? track.spotifyURL?.absoluteString)
    }
    public func skipQueuedTrack(_ track: Track) {
        guard let id = queueKey(track) else { return }
        if id == currentQueueTrackID {
            queueSkipCounts.removeValue(forKey: id)
            manualPlaybackIntent = nil
            advanceQueue(1)
            return
        }
        queueSkipCounts[id, default: 0] += 1
        queue = queueItems.map(\.track)
        syncQueueSelection()
    }
    public func noteManualPlayback(_ track: Track? = nil) {
        if let track {
            guard let id = queueKey(track) else { return }
            manualPlaybackIntent = .track(id)
        } else { manualPlaybackIntent = .previous }
    }
    public func cancelManualPlaybackIntent() { manualPlaybackIntent = nil }
    public func finishPreviousPlaybackOnSameTrack() {
        if case .previous = manualPlaybackIntent { manualPlaybackIntent = nil }
    }
    public func consumeQueueSkip(for track: Track) -> Bool {
        guard let id = queueKey(track) else { return false }
        switch manualPlaybackIntent {
        case .queueJump(let targetID):
            if id == targetID { manualPlaybackIntent = nil }
            return false
        case .previous:
            manualPlaybackIntent = nil
            return false
        case .track(let requestedID) where requestedID == id:
            manualPlaybackIntent = nil
            return false
        default: break
        }
        guard let count = queueSkipCounts[id], count > 0 else { return false }
        if count == 1 { queueSkipCounts.removeValue(forKey: id) }
        else { queueSkipCounts[id] = count - 1 }
        return true
    }
    public var queueItems: [SpotifyPlaylistTrack] {
        var remaining = queueSkipCounts
        return rawQueue.enumerated().compactMap { offset, track in
            if let id = queueKey(track), let count = remaining[id], count > 0 {
                remaining[id] = count - 1
                return nil
            }
            return SpotifyPlaylistTrack(track: track, offset: offset)
        }
    }
    public func jumpToQueuedTrack(at offset: Int) {
        guard rawQueue.indices.contains(offset), let targetID = queueKey(rawQueue[offset]) else { return }
        for track in rawQueue.prefix(offset + 1) {
            guard let id = queueKey(track), let count = queueSkipCounts[id] else { continue }
            if count == 1 { queueSkipCounts.removeValue(forKey: id) }
            else { queueSkipCounts[id] = count - 1 }
        }
        manualPlaybackIntent = .queueJump(targetID)
        advanceQueue(offset + 1)
    }
    public func currentTrackChanged(to track: Track) {
        currentQueueTrackID = queueKey(track)
        trimQueueThroughCurrentTrack()
        queue = queueItems.map(\.track)
        syncQueueSelection()
        loadQueue()
    }
    private func trimQueueThroughCurrentTrack() {
        guard let id = currentQueueTrackID,
              let index = rawQueue.firstIndex(where: { queueKey($0) == id }) else { return }
        rawQueue.removeFirst(index + 1)
    }
    private func syncQueueSelection() {
        if selectedID == Self.queueID { tracks = queueItems }
    }


    public var showsQueueLoading: Bool { isQueueLoading && !hasLoadedQueue }

    public var selectedTracksAreLoading: Bool {
        selectedID == Self.queueID ? showsQueueLoading : isLoading
    }
    public var emptyMessage: String? {
        guard tracks.isEmpty, !selectedTracksAreLoading, notice == nil else { return nil }
        return selectedID == Self.queueID ? "接下来没有待播歌曲" : "歌单里还没有歌曲"
    }

    public init(service: SpotifyCatalogService, picker: PlaylistPickerModel,
                accessToken: @escaping @MainActor (Set<String>) async throws -> String,
                advanceQueue: @escaping @MainActor (Int) -> Void) {
        self.service = service; self.picker = picker; self.accessToken = accessToken
        self.advanceQueue = advanceQueue
    }
    public func open() { picker.open(); loadQueue() }
    public func loadQueue() {
        guard !isQueueLoading else { return }
        isQueueLoading = true
        queueTask = Task {
            defer { isQueueLoading = false; queueTask = nil }
            for attempt in 0...1 {
                let started = Date()
                do {
                    let token = try await accessToken(SpotifyOAuthConfiguration.playbackScopes)
                    let upcoming = try await service.upcomingTracks(accessToken: token, limit: nil)
                    rawQueue = upcoming
                    trimQueueThroughCurrentTrack()
                    queue = queueItems.map(\.track)
                    hasLoadedQueue = true
                    syncQueueSelection()
                    notice = nil
                    LyricsE2ELog.log("QUEUE load seconds=\(String(format: "%.3f", Date().timeIntervalSince(started))) count=\(upcoming.count)")
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    notice = error.localizedDescription
                    LyricsE2ELog.log("QUEUE load seconds=\(String(format: "%.3f", Date().timeIntervalSince(started))) count=0 error=\(error.localizedDescription)")
                    if attempt == 0 {
                        do { try await Task.sleep(for: .seconds(2)) }
                        catch { return }
                    }
                }
            }
        }
    }
    public func select(_ id: String) {
        tracksTask?.cancel()
        selectedID = id
        notice = nil
        if id == Self.queueID {
            isLoading = false
            tracks = queueItems
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
    public func enqueue(_ track: Track) async throws {
        guard let id = TrackIdentity.spotifyRequestTrackID(track.spotifyId ?? track.spotifyURL?.absoluteString) else { return }
        let token = try await accessToken(SpotifyOAuthConfiguration.playbackWriteScopes)
        try await service.enqueueTrack(id, accessToken: token)
        queueSkipCounts.removeValue(forKey: id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.loadQueue()
        }
    }

    public func play(_ item: SpotifyPlaylistTrack) {
        let context = selectedID
        if context == Self.queueID { jumpToQueuedTrack(at: item.offset); return }
        noteManualPlayback(item.track)
        let remainingIDs = tracks.drop(while: { $0.offset != item.offset }).prefix(100)
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
            } catch SpotifyCatalogError.forbidden { cancelManualPlaybackIntent(); notice = "需要 Spotify Premium" }
            catch { cancelManualPlaybackIntent(); notice = error.localizedDescription }
        }
    }
    deinit { tracksTask?.cancel(); queueTask?.cancel() }
}
