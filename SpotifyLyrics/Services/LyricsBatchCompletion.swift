import Combine
import Foundation

/// Runs only the caller's free-source search, one song at a time.
@MainActor
public final class LyricsBatchCompletion: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var completed = 0
    @Published public private(set) var total = 0
    private var task: Task<Void, Never>?

    public func start(tracks: [Track], search: @escaping @MainActor (Track) async -> Void) {
        guard !isRunning else { return }
        completed = 0
        total = tracks.count
        isRunning = !tracks.isEmpty
        task = Task {
            defer { isRunning = false; task = nil }
            for track in tracks {
                guard !Task.isCancelled else { break }
                await search(track)
                guard !Task.isCancelled else { break }
                completed += 1
            }
        }
    }
    public func stop() { task?.cancel() }
}
