import Foundation

/// Appends one JSON line per finished lyrics search to
/// `~/Library/Logs/SpotifyLyrics/source-stats.jsonl`.
///
/// This is deliberately a file, not the database: the log survives the
/// /tmp trace reset and can be read after a week without adding a schema or a
/// setting. At 5 MB the current file becomes `.old` and a new one starts, so
/// only one previous generation is kept.
public final class LyricsSourceStats: @unchecked Sendable {
    public static let shared = LyricsSourceStats(fileURL: defaultFileURL)

    /// Native tests and the visual fixture must stay out of the real file:
    /// their synthetic searches are indistinguishable from listening once
    /// written. Tests write under the isolated test home, the fixture under
    /// its own temporary directory.
    static var defaultFileURL: URL {
#if DEBUG
        if Bundle.main.bundleIdentifier == "com.lyricsq.experience-visual-host" {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("lyricsq-visual-host", isDirectory: true)
                .appendingPathComponent("source-stats.jsonl")
        }
#endif
        return LyricsQStorage.homeDirectory
            .appendingPathComponent("Library/Logs/SpotifyLyrics/source-stats.jsonl")
    }

    private static let maxBytes = 5 * 1024 * 1024

    let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// One call per finished search. `outcome` is `adopted`, `review` or
    /// `none`; a retry reuses the same shape with `retry: true`.
    func record(
        spotifyID: String?,
        totalSeconds: TimeInterval,
        result: LyricsLookupResult,
        retry: Bool,
        preload: Bool = false,
        diagnostics: [LyricsProviderDiagnostic],
        outcome: String? = nil,
        date: Date = Date()
    ) {
        let sources: [[String: Any]] = diagnostics.map { diagnostic in
            [
                "provider": Self.baseProviderName(diagnostic.provider),
                "result": Self.describe(diagnostic.outcome),
                "seconds": Self.rounded(diagnostic.duration)
            ]
        }
        let entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: date),
            "spotifyId": spotifyID ?? NSNull(),
            "totalSeconds": Self.rounded(totalSeconds),
            "outcome": outcome ?? Self.outcome(for: result),
            "retry": retry,
            "preload": preload,
            "sources": sources
        ]
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0A)
        append(line)
    }

    static func outcome(for result: LyricsLookupResult) -> String {
        switch result {
        case .match: return "adopted"
        case .candidates: return "review"
        case .noLyrics, .noMatch, .failed: return "none"
        }
    }

    private static func rounded(_ seconds: TimeInterval) -> Double {
        (seconds * 1000).rounded() / 1000
    }

    private static func baseProviderName(_ provider: String) -> String {
        provider.components(separatedBy: "@").first ?? provider
    }

    private static func describe(_ outcome: LyricsProviderDiagnostic.Outcome) -> String {
        switch outcome {
        case .match: return "match"
        case .candidates(let count): return "candidates(\(count))"
        case .noLyrics: return "noLyrics"
        case .noMatch: return "noMatch"
        case .failed(let failure): return "failed(\(rawReason(failure)))"
        }
    }

    /// Record what actually failed, not the sentence shown to the user:
    /// timedOut, serverError(503), networkUnavailable. Free-form messages are
    /// left out so the exported lines stay stable enough to compare.
    private static func rawReason(_ failure: LyricsFailure) -> String {
        switch failure {
        case .networkUnavailable: return "networkUnavailable"
        case .timedOut: return "timedOut"
        case .rateLimited(let retryAfter):
            return retryAfter.map { "rateLimited(\(number($0)))" } ?? "rateLimited"
        case .serverError(let statusCode): return "serverError(\(statusCode))"
        case .parseFailure: return "parseFailure"
        case .cancelled: return "cancelled"
        case .identityUnconfirmed(let count, _): return "identityUnconfirmed(\(count))"
        case .lyricsBodyUnavailable: return "lyricsBodyUnavailable"
        case .unknown: return "unknown"
        }
    }

    private static func number(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > Self.maxBytes {
            let oldURL = fileURL.appendingPathExtension("old")
            try? fileManager.removeItem(at: oldURL)
            try? fileManager.moveItem(at: fileURL, to: oldURL)
        }

        if fileManager.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
