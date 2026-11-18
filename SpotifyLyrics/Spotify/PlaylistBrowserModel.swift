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
    @Published public private(set) var source: PlaybackSourceIdentity
    @Published public private(set) var queue: [Track] = []
    @Published public private(set) var tracks: [SpotifyPlaylistTrack] = []
    @Published public private(set) var selectedID = queueID
    @Published public private(set) var isLoading = false
    @Published public private(set) var isQueueLoading = false
    @Published public private(set) var hasLoadedQueue = false
    @Published public private(set) var queueNotice: String?
    @Published private var selectionNotice: String?
    public var notice: String? { selectedID == Self.queueID ? queueNotice : selectionNotice }
    public var queueTitle: String { source == .appleMusic ? "歌单顺序" : "接下来播放" }
    public var supportsQueueEdits: Bool { source == .spotifyDesktop }
    public var queueContextName: String? { musicContinuation?.name }
    public var emptyQueueMessage: String {
        if source == .mockPreview { return "预览中的歌曲没有播放队列" }
        if source == .appleMusic {
            return musicContinuation == nil ? "当前歌曲没有可读取的歌单顺序" : "已到这份歌单的末尾"
        }
        return "接下来没有待播歌曲"
    }
    private let service: SpotifyCatalogService
    private let music: AppleMusicPlaylistCatalog
    private var musicContinuation: AppleMusicPlaylistCatalog.Continuation?
    private(set) var sourceGeneration = 0
    private let advanceQueue: @MainActor (Int) -> Void
    private let accessToken: @MainActor (Set<String>) async throws -> String
    private var tracksTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var rawQueue: [Track] = []
    private var currentQueueTrackID: String?
    private var skippedQueueOffsets: Set<Int> = []
    private enum ManualPlaybackIntent { case track(String), previous }
    private var manualPlaybackIntent: ManualPlaybackIntent?

    private func queueKey(_ track: Track) -> String? {
        guard supportsQueueEdits else { return nil }
        return TrackIdentity.spotifyRequestTrackID(track.spotifyId ?? track.spotifyURL?.absoluteString)
    }
    public func skipQueuedTrack(_ item: SpotifyPlaylistTrack) {
        guard rawQueue.indices.contains(item.offset),
              let id = queueKey(item.track), queueKey(rawQueue[item.offset]) == id else { return }
        skippedQueueOffsets.insert(item.offset)
        queue = queueItems.map(\.track)
        syncQueueSelection()
    }
    public func noteManualPlayback(_ track: Track? = nil) {
        guard supportsQueueEdits else { return }
        if let track {
            guard let id = queueKey(track) else { return }
            manualPlaybackIntent = .track(id)
        } else { manualPlaybackIntent = .previous }
    }
    public func cancelManualPlaybackIntent() { manualPlaybackIntent = nil }
    public func finishPreviousPlaybackOnSameTrack() {
        if case .previous = manualPlaybackIntent { manualPlaybackIntent = nil }
    }
    private func consumeManualPlaybackIntent(arrivingAt id: String) -> Bool {
        switch manualPlaybackIntent {
        case .previous:
            manualPlaybackIntent = nil
            return true
        case .track(let requestedID) where requestedID == id:
            manualPlaybackIntent = nil
            return true
        default:
            return false
        }
    }
    public var queueItems: [SpotifyPlaylistTrack] {
        if source == .appleMusic { return musicContinuation?.tracks ?? [] }
        return rawQueue.enumerated().compactMap { offset, track in
            guard !skippedQueueOffsets.contains(offset) else { return nil }
            return SpotifyPlaylistTrack(track: track, offset: offset)
        }
    }
    public func jumpToQueuedTrack(at offset: Int, expecting track: Track? = nil) {
        if let track {
            guard let row = queueItems.first(where: { $0.offset == offset }),
                  let id = PlaybackState.playlistRequestTrackID(for: track, source: source),
                  PlaybackState.playlistRequestTrackID(for: row.track, source: source) == id else { return }
        }
        if source == .appleMusic {
            guard let context = musicContinuation, let item = context.tracks.first(where: { $0.offset == offset }) else { return }
            playInMusic(item, playlistID: context.playlistID, selection: Self.queueID)
            return
        }
        guard supportsQueueEdits, rawQueue.indices.contains(offset) else { return }
        skippedQueueOffsets = skippedQueueOffsets.filter { $0 > offset }
        advanceQueue(offset + 1)
    }
    @discardableResult
    public func currentTrackChanged(to track: Track) -> Bool {
        if source == .appleMusic {
            let shouldRefresh = isQueueLoading || hasLoadedQueue
            queueTask?.cancel()
            queueTask = nil
            isQueueLoading = false
            hasLoadedQueue = false
            currentQueueTrackID = TrackIdentity.playbackID(for: track)
            musicContinuation = nil
            queue = []
            queueNotice = nil
            syncQueueSelection()
            if shouldRefresh { loadQueue() }
            return false
        }
        guard supportsQueueEdits else { return false }
        let id = queueKey(track)
        if let id, currentQueueTrackID == id { return false }
        currentQueueTrackID = id
        let shouldSkip = advanceQueueSnapshot(to: id)
        queue = queueItems.map(\.track)
        syncQueueSelection()
        queueTask?.cancel()
        queueTask = nil
        isQueueLoading = false
        loadQueue()
        return shouldSkip
    }
    private func advanceQueueSnapshot(to id: String?) -> Bool {
        guard let id, !consumeManualPlaybackIntent(arrivingAt: id),
              let index = rawQueue.firstIndex(where: { queueKey($0) == id }) else { return false }
        let shouldSkip = skippedQueueOffsets.contains(index)
        let count = index + 1
        rawQueue.removeFirst(count)
        skippedQueueOffsets = Set(skippedQueueOffsets.filter { $0 >= count }.map { $0 - count })
        return shouldSkip
    }
    private func replaceQueueSnapshot(with upcoming: [Track]) {
        if !skippedQueueOffsets.isEmpty {
            let previousIDs = rawQueue.map(queueKey)
            let nextIDs = upcoming.map(queueKey)
            let prefixCount = zip(previousIDs, nextIDs).prefix { $0.0 == $0.1 }.count
            let onlyTailChanged = prefixCount == min(previousIDs.count, nextIDs.count)
            skippedQueueOffsets = Set(skippedQueueOffsets.compactMap { offset in
                // Spotify identifies the song, so a reordered duplicate has no stable row identity.
                if onlyTailChanged, offset < prefixCount { return offset }
                guard let id = previousIDs[offset], previousIDs.filter({ $0 == id }).count == 1,
                      let nextOffset = nextIDs.firstIndex(of: id), nextIDs.lastIndex(of: id) == nextOffset else { return nil }
                return nextOffset
            })
        }
        rawQueue = upcoming
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
        return selectedID == Self.queueID ? emptyQueueMessage : "歌单里还没有歌曲"
    }

    public init(service: SpotifyCatalogService, picker: PlaylistPickerModel,
                source: PlaybackSourceIdentity = .spotifyDesktop, music: AppleMusicPlaylistCatalog? = nil,
                accessToken: @escaping @MainActor (Set<String>) async throws -> String,
                advanceQueue: @escaping @MainActor (Int) -> Void) {
        self.service = service; self.picker = picker; self.accessToken = accessToken
        self.source = source; self.music = music ?? AppleMusicPlaylistCatalog()
        self.advanceQueue = advanceQueue
    }
    public func updateSource(_ next: PlaybackSourceIdentity) {
        guard source != next else { return }
        sourceGeneration &+= 1
        tracksTask?.cancel()
        playTask?.cancel()
        tracksTask = nil
        selectionNotice = nil
        isLoading = false
        selectedID = Self.queueID
        clearCurrentTrack()
        source = next
        picker.resetForSourceChange()
    }
    func clearCurrentTrack() {
        queueTask?.cancel()
        queueTask = nil
        rawQueue = []
        musicContinuation = nil
        currentQueueTrackID = nil
        skippedQueueOffsets = []
        manualPlaybackIntent = nil
        queue = []
        if selectedID == Self.queueID { tracks = [] }
        queueNotice = nil
        isQueueLoading = false
        hasLoadedQueue = false
    }
    public func open() {
        if source == .appleMusic || supportsQueueEdits { picker.open(); loadQueue() }
    }
    public func refresh() {
        guard source == .appleMusic || supportsQueueEdits else { return }
        picker.load(force: true)
        picker.refreshLikedCount()
        loadQueue()
        select(selectedID)
    }
    public func loadQueue() {
        guard !isQueueLoading, source == .appleMusic || supportsQueueEdits else { return }
        isQueueLoading = true
        queueTask = Task {
            guard !Task.isCancelled else { return }
            defer { if !Task.isCancelled { isQueueLoading = false; queueTask = nil } }
            if source == .appleMusic {
                do {
                    let context = try await music.continuation(after: currentQueueTrackID)
                    try Task.checkCancellation()
                    musicContinuation = context
                    queue = queueItems.map(\.track)
                    hasLoadedQueue = true
                    queueNotice = nil
                    syncQueueSelection()
                } catch { if !Task.isCancelled { queueNotice = error.localizedDescription } }
                return
            }
            for attempt in 0...1 {
                let started = Date()
                do {
                    let token = try await accessToken(SpotifyOAuthConfiguration.playbackScopes)
                    try Task.checkCancellation()
                    let upcoming = try await service.upcomingTracks(accessToken: token, limit: nil)
                    try Task.checkCancellation()
                    var nextQueue = upcoming
                    if let id = currentQueueTrackID, rawQueue.first.flatMap(queueKey) != id {
                        nextQueue.removeFirst(nextQueue.prefix { queueKey($0) == id }.count)
                    }
                    replaceQueueSnapshot(with: nextQueue)
                    queue = queueItems.map(\.track)
                    hasLoadedQueue = true
                    syncQueueSelection()
                    queueNotice = nil
                    LyricsE2ELog.log("QUEUE load seconds=\(String(format: "%.3f", Date().timeIntervalSince(started))) count=\(upcoming.count)")
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    queueNotice = error.localizedDescription
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
        selectionNotice = nil
        if id == Self.queueID {
            isLoading = false
            tracks = queueItems
            return
        }
        guard source == .appleMusic || supportsQueueEdits else {
            tracks = []; isLoading = false
            return
        }
        tracks = []; isLoading = true
        tracksTask = Task {
            guard !Task.isCancelled else { return }
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                let songs: [SpotifyPlaylistTrack]
                if source == .appleMusic {
                    songs = try await music.tracks(in: id)
                } else {
                    let token = try await accessToken(id == Self.likedID ? SpotifyOAuthConfiguration.libraryScopes : SpotifyOAuthConfiguration.playlistScopes)
                    try Task.checkCancellation()
                    songs = id == Self.likedID ? try await service.savedTracks(accessToken: token) : try await service.playlistTracks(id, accessToken: token)
                }
                try Task.checkCancellation()
                tracks = songs
            } catch { if !Task.isCancelled { selectionNotice = error.localizedDescription } }
        }
    }
    public func enqueue(_ track: Track) async throws {
        guard let id = queueKey(track) else { throw CancellationError() }
        let generation = sourceGeneration
        let token = try await accessToken(SpotifyOAuthConfiguration.playbackWriteScopes)
        guard generation == sourceGeneration else { throw CancellationError() }
        try await service.enqueueTrack(id, accessToken: token)
        guard generation == sourceGeneration else { throw CancellationError() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if self?.sourceGeneration == generation { self?.loadQueue() }
        }
    }

    public func play(_ item: SpotifyPlaylistTrack) {
        let context = selectedID
        guard tracks.contains(item) else { return }
        if context == Self.queueID { jumpToQueuedTrack(at: item.offset, expecting: item.track); return }
        if source == .appleMusic { playInMusic(item, playlistID: context, selection: context); return }
        guard supportsQueueEdits else { return }
        let generation = sourceGeneration
        noteManualPlayback(item.track)
        let remainingIDs = tracks.drop(while: { $0.offset != item.offset }).prefix(100)
            .compactMap { TrackIdentity.spotifyRequestTrackID($0.track.spotifyId) }
        playTask?.cancel()
        playTask = Task {
            guard !Task.isCancelled, sourceGeneration == generation else { return }
            do {
                let token = try await accessToken(SpotifyOAuthConfiguration.playbackWriteScopes)
                guard !Task.isCancelled, sourceGeneration == generation else { return }
                if context == Self.likedID {
                    guard !remainingIDs.isEmpty else { return }
                    try await service.playTracks(remainingIDs, accessToken: token)
                } else {
                    try await service.playPlaylist(context, offset: item.offset, accessToken: token)
                }
                if !Task.isCancelled, sourceGeneration == generation, selectedID == context { selectionNotice = "已请求播放" }
            } catch {
                guard !Task.isCancelled, sourceGeneration == generation else { return }
                cancelManualPlaybackIntent()
                if selectedID == context { selectionNotice = (error as? SpotifyCatalogError) == .forbidden ? "需要 Spotify Premium" : error.localizedDescription }
            }
        }
    }
    private func playInMusic(_ item: SpotifyPlaylistTrack, playlistID: String, selection: String) {
        let generation = sourceGeneration
        playTask?.cancel()
        playTask = Task {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            let message: String
            do { try await music.play(item, in: playlistID); message = "已请求播放" }
            catch { message = error.localizedDescription }
            guard !Task.isCancelled, generation == sourceGeneration, selectedID == selection else { return }
            if selection == Self.queueID { queueNotice = message } else { selectionNotice = message }
        }
    }
    deinit { tracksTask?.cancel(); queueTask?.cancel(); playTask?.cancel() }
}
