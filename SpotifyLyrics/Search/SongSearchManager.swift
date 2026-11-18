import Combine
import Foundation

/// Compatibility facade over `TrackSearchManager` for existing UI bindings.
/// Track search never attaches lyrics bodies; selection resolves lyrics separately.
@MainActor
public final class SongSearchManager: ObservableObject {
    @Published public private(set) var state: SongSearchState = .idle
    @Published public private(set) var queryText: String?

    public let trackSearchManager: TrackSearchManager
    private var stateObservation: AnyCancellable?

    public init(providers: [TrackSearchProvider]) {
        self.trackSearchManager = TrackSearchManager(providers: providers)
        stateObservation = trackSearchManager.$state.sink { [weak self] in self?.state = $0.songSearchState }
    }

    /// Legacy constructor accepted `SongSearchProvider`. Bridge adapters keep call sites compiling.
    public convenience init(providers: [SongSearchProvider]) {
        self.init(providers: providers.map { SongSearchProviderBridge(provider: $0) })
    }

    @discardableResult
    public func search(
        query: SongSearchQuery,
        debounceNanoseconds: UInt64 = 0
    ) -> Task<Void, Never>? {
        if queryText?.trimmingCharacters(in: .whitespacesAndNewlines) != query.text {
            queryText = query.text
        }
        return trackSearchManager.search(query: query, debounceNanoseconds: debounceNanoseconds)
    }

    @discardableResult
    func editQuery(_ text: String) -> Task<Void, Never>? {
        guard queryText != text else { return nil }
        queryText = text
        let query = SongSearchQuery(text: text)
        guard state.query != query else { return nil }
        return trackSearchManager.search(query: query, debounceNanoseconds: 250_000_000)
    }

    func prepareQuery(suggestedTrack: Track?) {
        if queryText == nil, let suggestedTrack {
            editQuery(SongSearchQuery(track: suggestedTrack).text)
        } else if state.query == nil {
            submitQuery()
        }
    }

    func submitQuery() {
        let query = state.query ?? SongSearchQuery(text: queryText ?? "")
        guard !query.isEmpty else { return }
        search(query: query)
    }

    public func cancel() { trackSearchManager.cancel() }

}

/// Adapts legacy `SongSearchProvider` implementations into metadata-only track search.
private struct SongSearchProviderBridge: TrackSearchProvider {
    let provider: SongSearchProvider
    var name: String { provider.name }

    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult] {
        let results = try await provider.search(query: query)
        return results.map { result in
            // Drop any accidental lyrics payload from legacy providers.
            TrackSearchResult(
                id: result.id,
                source: result.source,
                track: result.track,
                confidence: result.confidence,
                artworkURL: result.artworkURL,
                catalogMetadata: result.catalogMetadata,
                savedLibraryEntry: result.savedLibraryEntry, savedPassage: result.savedPassage
            )
        }
    }
}
