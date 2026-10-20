import Foundation

/// Lightweight acceptance trace logger. Writes to /tmp/spotifylyrics-e2e.log
enum LyricsE2ELog {
    private static var path: String {
#if DEBUG
        if NativeTestRuntime.isEnabled {
            return NativeTestRuntime.root.appendingPathComponent("e2e.log").path
        }
        if DebugAcceptanceDataIsolation.isRequested {
            return DebugAcceptanceDataIsolation.configuration.root.appendingPathComponent("logs/e2e.log").path
        }
#endif
        return "/tmp/spotifylyrics-e2e.log"
    }
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: path)
        writeUnlocked("LOG_RESET")
    }

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        writeUnlocked(message)
    }

    private static func writeUnlocked(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
