import Combine
import Foundation

/// Free-text / structured track catalog search. Returns metadata only.
@MainActor
public final class TrackSearchManager: ObservableObject {
    @Published public private(set) var state: TrackSearchState = .idle

    private let providers: [TrackSearchProvider]
    private var requestTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(providers: [TrackSearchProvider]) {
        self.providers = providers
    }

    deinit {
        requestTask?.cancel()
    }

    @discardableResult
    public func search(
        query: TrackSearchQuery,
        debounceNanoseconds: UInt64 = 0
    ) -> Task<Void, Never>? {
        generation &+= 1
        let requestGeneration = generation
        requestTask?.cancel()

        guard !query.isEmpty else {
            state = .idle
            requestTask = nil
            return nil
        }

        state = .searching(query)
        let providers = self.providers.filter(\.isLocal) + self.providers.filter { !$0.isLocal }
        requestTask = Task { [weak self] in
            var results: [TrackSearchResult] = []
            var errors: [String] = []

            var waitedForOnlineDebounce = false
            // Publish each source immediately. Online setup never gates local results.
            for provider in providers {
                guard !Task.isCancelled else { return }
                if !provider.isLocal && !waitedForOnlineDebounce {
                    waitedForOnlineDebounce = true
                    do { try await Task.sleep(nanoseconds: debounceNanoseconds) }
                    catch { return }
                }
                do {
                    results.append(contentsOf: try await provider.search(query: query))
                } catch let error as SongSearchError {
                    // Online catalog setup is optional. Local/current-track
                    // search remains usable before Spotify Web authorization.
                    if error == .notConfigured || error == .unauthorized { continue }
                    errors.append(error.errorDescription ?? provider.name)
                } catch {
                    errors.append(error.localizedDescription)
                }
                guard !Task.isCancelled, let self, self.generation == requestGeneration else { return }
                if !results.isEmpty { self.state = .results(query, Self.merge(results)) }
            }

            guard !Task.isCancelled else { return }
            let merged = Self.merge(results)
            guard let self, self.generation == requestGeneration else { return }

            if !merged.isEmpty {
                self.state = .results(query, merged)
            } else if !errors.isEmpty {
                self.state = .failed(query, errors.joined(separator: "；"))
            } else {
                self.state = .noResults(query)
            }
        }
        return requestTask
    }

    public func cancel() {
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        state = .idle
    }

    private static func merge(_ results: [TrackSearchResult]) -> [TrackSearchResult] {
        var merged: [String: TrackSearchResult] = [:]
        for result in results {
            let key = result.searchMergeKey
            guard let existing = merged[key] else {
                merged[key] = result
                continue
            }
            let best = result.confidence > existing.confidence ? result : existing
            merged[key] = TrackSearchResult(id: best.id, source: best.source, track: best.track,
                confidence: best.confidence, artworkURL: best.artworkURL, catalogMetadata: best.catalogMetadata,
                savedLibraryEntry: best.savedLibraryEntry ?? result.savedLibraryEntry ?? existing.savedLibraryEntry)
        }
        return merged.values.sorted {
            if $0.confidence == $1.confidence { return $0.track.title < $1.track.title }
            return $0.confidence > $1.confidence
        }
    }
}
