import Foundation

/// Remembers which online lyrics sources are currently down.
///
/// The source statistics (2026-10-24 … 11-15, 598 searches) show that
/// failures come in runs, not at random: LRCLIB answered 503 fifty times on
/// 10-30, lyrics.ovh timed out ninety times over 11-12/13, QQ and LinkCore
/// had shorter runs of their own. Each new song used to wait 3–5 s for the
/// broken source again.
///
/// A source that fails twice in a row (timeout, no network, rate limit or a
/// 5xx answer) rests for `restInterval`. Resting does not drop it: the search
/// moves it to the supplement lane, so it is still asked whenever the other
/// sources have nothing to adopt. Any answer that is not such a failure ends
/// the rest at once.
public final class LyricsSourceHealth: @unchecked Sendable {
    public static let failuresBeforeRest = 2
    public static let restInterval: TimeInterval = 15 * 60

    private struct State {
        var consecutiveFailures = 0
        var restUntil: Date?
    }

    private var states: [String: State] = [:]
    private let lock = NSLock()

    /// One record for the whole app, shared by the now-playing, preview,
    /// preload and fill-in searches. Tests build their own instances.
    public static let shared = LyricsSourceHealth(seedingFrom: LyricsSourceStats.defaultFileURL)

    public init() {}

    /// Replays the recent tail of the statistics file so a relaunch during an
    /// outage keeps what the previous run learned. Only lines from the last
    /// rest interval matter; anything older has expired anyway.
    public convenience init(seedingFrom statsURL: URL, now: Date = Date()) {
        self.init()
        seed(fromStatsAt: statsURL, now: now)
    }

    public func record(provider: String, result: LyricsLookupResult, at date: Date = Date()) {
        switch Self.classify(result) {
        case .ignore: return
        case .healthy: update(provider) { $0 = State() }
        case .failure:
            update(provider) { state in
                state.consecutiveFailures += 1
                if state.consecutiveFailures >= Self.failuresBeforeRest {
                    state.restUntil = date.addingTimeInterval(Self.restInterval)
                }
            }
        }
    }

    public func isResting(_ provider: String, at date: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = states[provider]?.restUntil else { return false }
        return until > date
    }

    public func restingProviders(at date: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return states.compactMap { name, state in
            (state.restUntil.map { $0 > date } ?? false) ? name : nil
        }.sorted()
    }

    private func update(_ provider: String, _ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = states[provider] ?? State()
        change(&state)
        states[provider] = state
    }

    enum Kind { case healthy, failure, ignore }

    private static func classify(_ result: LyricsLookupResult) -> Kind {
        guard case .failed(let failure) = result else { return .healthy }
        switch failure {
        case .timedOut, .networkUnavailable, .rateLimited: return .failure
        case .serverError(let code) where (500...599).contains(code): return .failure
        case .cancelled: return .ignore
        // A parse problem or an unconfirmed identity still proves the
        // source answered; it is not an outage.
        default: return .healthy
        }
    }

    /// Statistics lines describe results as `failed(timedOut)`,
    /// `failed(serverError(503))`, `noMatch`, `candidates(3)` …
    static func classify(statsResult text: String) -> Kind {
        guard text.hasPrefix("failed(") else { return .healthy }
        if text.hasPrefix("failed(timedOut") || text.hasPrefix("failed(networkUnavailable")
            || text.hasPrefix("failed(rateLimited") || text.hasPrefix("failed(serverError(5") {
            return .failure
        }
        if text.hasPrefix("failed(cancelled") { return .ignore }
        return .healthy
    }

    private func seed(fromStatsAt url: URL, now: Date) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 128 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return }
        let formatter = ISO8601DateFormatter()
        let earliest = now.addingTimeInterval(-Self.restInterval)
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let time = (object["time"] as? String).flatMap(formatter.date(from:)),
                  time >= earliest, time <= now,
                  let sources = object["sources"] as? [[String: Any]] else { continue }
            for source in sources {
                guard let name = source["provider"] as? String,
                      let result = source["result"] as? String,
                      // Reused probes are recorded with zero seconds; they
                      // repeat an earlier answer and must not count twice.
                      (source["seconds"] as? Double ?? 0) > 0 else { continue }
                switch Self.classify(statsResult: result) {
                case .ignore: continue
                case .healthy: update(name) { $0 = State() }
                case .failure:
                    update(name) { state in
                        state.consecutiveFailures += 1
                        if state.consecutiveFailures >= Self.failuresBeforeRest {
                            state.restUntil = time.addingTimeInterval(Self.restInterval)
                        }
                    }
                }
            }
        }
    }
}
