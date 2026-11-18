import Combine
import Foundation

/// Runs only the caller's free-source search, one song at a time.
@MainActor
public final class LyricsBatchCompletion: ObservableObject {
    enum Outcome: Equatable {
        case timedSaved, plainSaved, unchanged, noMatch, failed
        case review([LyricsCandidate])

        var label: String {
            switch self {
            case .timedSaved: "已存同步歌词"
            case .plainSaved: "已存纯文本"
            case .review: "需要核对"
            case .unchanged: "无新增"
            case .noMatch: "未找到歌词"
            case .failed: "未能补全"
            }
        }
    }

    struct Result: Identifiable {
        let entry: PersonalLyricsLibraryEntry
        let lookupID = UUID()
        var outcome: Outcome
        var id: String { entry.trackStableKey }

        var candidates: [LyricsCandidate] {
            if case .review(let candidates) = outcome { return candidates }
            return []
        }
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var total = 0
    @Published private(set) var results: [Result] = []
    @Published private(set) var currentTitle: String?
    @Published private(set) var wasStopped = false
    @Published private(set) var lastResolvedReview: UUID?
    public var completed: Int { results.count }
    private var task: Task<Void, Never>?
    private var reviewing: Set<UUID> = []

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
                    self?.results.append(.init(entry: entry, outcome: outcome))
                }
            }
        }
    }

    func resolve(_ item: Result, with candidate: LyricsCandidate,
                 save: () async throws -> LyricsPersistenceSaveResult) async throws -> LyricsPersistenceSaveResult {
        guard let current = results.first(where: { $0.lookupID == item.lookupID }),
              current.candidates.contains(candidate), reviewing.insert(item.lookupID).inserted else {
            return .init(versionID: nil, disposition: .rejected("这条补词结果已更新，请打开最新结果。"))
        }
        defer { reviewing.remove(item.lookupID) }
        let saved = try await save()
        if saved.versionID != nil, saved.disposition == .inserted || saved.disposition == .duplicate {
            if let index = results.firstIndex(where: { $0.lookupID == item.lookupID }) {
                results[index].outcome = candidate.isSynchronized && !candidate.requiresTextOnlyPreview ? .timedSaved : .plainSaved
            }
            lastResolvedReview = item.lookupID
        }
        return saved
    }

    public func stop() {
        guard isRunning else { return }
        wasStopped = true
        task?.cancel()
    }

    deinit { task?.cancel() }
}
