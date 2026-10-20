import Foundation

/// Local track metadata search backed by the shared read-only lyrics index.
public final class LocalSearchProvider: TrackSearchProvider {
    public let name = "Local Search"
    public let isLocal = true

    private let index: LocalLyricsIndex
    private let savedSearch: ((TrackSearchQuery) async throws -> [TrackSearchResult])?

    public init(searchDirectories: [URL]? = nil, index: LocalLyricsIndex? = nil,
                savedSearch: ((TrackSearchQuery) async throws -> [TrackSearchResult])? = nil) {
        self.savedSearch = savedSearch
        if let index {
            self.index = index
        } else if let searchDirectories {
            self.index = LocalLyricsIndex(searchDirectories: searchDirectories)
        } else {
            self.index = .shared
        }
    }

    public func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] {
        guard !query.isEmpty else { return [] }
        let local = index.searchTracks(matching: query)
        guard let savedSearch else { return local }
        do {
            return local + (try await savedSearch(query))
        } catch {
            // A temporarily unreadable saved library must not hide local LRC results.
            if !local.isEmpty { return local }
            throw error
        }
    }
}

/// Explicit alias for research naming.
public typealias LocalTrackSearchProvider = LocalSearchProvider
