import Combine
import Foundation

/// Runs only the caller's free-source search, one song at a time.
@MainActor
public final class LyricsBatchCompletion: ObservableObject {
    enum Outcome: String {
        case timedSaved = "已存同步歌词"
        case plainSaved = "已存纯文本"
        case review = "需要核对"
        case unchanged = "无新增"
        case noMatch = "未找到歌词"
        case failed = "未能补全"
    }

    struct Result: Identifiable {
        let id: String
        let title: String
        let artist: String
        let outcome: Outcome
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var total = 0
    @Published private(set) var results: [Result] = []
    @Published private(set) var currentTitle: String?
    @Published private(set) var wasStopped = false
    public var completed: Int { results.count }
    private var task: Task<Void, Never>?

    func start(entries: [PersonalLyricsLibraryEntry], search: @escaping @MainActor (Track) async -> Outcome?) {
        guard !isRunning else { return }
        var seen = Set<String>()
        let pending = entries.filter {
            $0.needsLyrics && !$0.hasManualLyrics && !$0.hasLockedLyrics && seen.insert($0.trackStableKey).inserted
        }
        guard !pending.isEmpty else { return }
        results = []
        total = pending.count
        wasStopped = false
        isRunning = true
        task = Task { [weak self] in
            defer {
                self?.currentTitle = nil
                self?.task = nil
                self?.isRunning = false
            }
            for entry in pending {
                guard !Task.isCancelled else { break }
                self?.currentTitle = entry.title
                if let outcome = await search(entry.libraryTrack) {
                    self?.results.append(.init(id: entry.trackStableKey, title: entry.title, artist: entry.artist, outcome: outcome))
                }
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        wasStopped = true
        task?.cancel()
    }

    deinit { task?.cancel() }
}
