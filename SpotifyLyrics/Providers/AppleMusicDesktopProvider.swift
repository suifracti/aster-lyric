import AppKit
import Darwin
import Foundation

@MainActor
public final class AppleMusicDesktopProvider: PlaybackProvider {
    public let displayName = "Apple Music"

    private static let applicationPath = "/System/Applications/Music.app"
    private static let bundleIdentifier = "com.apple.Music"
    private let fieldSeparator = String(UnicodeScalar(30))
    private let scriptRunner: @Sendable (String, TimeInterval) async throws -> String?
    private let applicationIsInstalled: @MainActor () -> Bool
    private let applicationIsRunning: @MainActor () -> Bool

    private static let refreshScriptTimeout: TimeInterval = 3
    private static let commandScriptTimeout: TimeInterval = 5

    public init() {
        self.applicationIsInstalled = {
            FileManager.default.fileExists(atPath: Self.applicationPath)
        }
        self.applicationIsRunning = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.bundleIdentifier
            ).isEmpty
        }
        self.scriptRunner = { script, timeout in
            try await AppleMusicAppleScriptProcessRunner.shared.run(
                script: script,
                timeout: timeout
            )
        }
    }

    /// Test seam for parser and connection tests.
    init(
        scriptRunner: @escaping @Sendable (String, TimeInterval) async throws -> String?,
        applicationIsInstalled: @escaping @MainActor () -> Bool,
        applicationIsRunning: @escaping @MainActor () -> Bool
    ) {
        self.scriptRunner = scriptRunner
        self.applicationIsInstalled = applicationIsInstalled
        self.applicationIsRunning = applicationIsRunning
    }

    public func refresh() async -> PlaybackSnapshot {
        guard applicationIsInstalled() else {
            return PlaybackSnapshot(
                status: .notInstalled,
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .appleMusic
            )
        }

        guard applicationIsRunning() else {
            return PlaybackSnapshot(
                status: .notRunning,
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .appleMusic
            )
        }

        do {
            guard let result = try await execute(script: readScript) else {
                return PlaybackSnapshot(
                    status: .unavailable("Apple Music 没有返回当前歌曲"),
                    track: nil,
                    position: 0,
                    isPlaying: false,
                    sourceIdentity: .appleMusic
                )
            }
            return await parseSnapshot(result)
        } catch let error as AppleScriptExecutionError {
            return PlaybackSnapshot(
                status: map(error: error),
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .appleMusic
            )
        } catch {
            return PlaybackSnapshot(
                status: .unavailable(error.localizedDescription),
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .appleMusic
            )
        }
    }

    public func play() async throws {
        try await executeCommand("tell application \"Music\" to play")
    }

    public func pause() async throws {
        try await executeCommand("tell application \"Music\" to pause")
    }

    public func previous() async throws {
        try await executeCommand("tell application \"Music\" to previous track")
    }

    public func next() async throws {
        try await executeCommand("tell application \"Music\" to next track")
    }

    public func seek(to position: TimeInterval) async throws {
        let seconds = max(0, position)
        try await executeCommand(
            "tell application \"Music\" to set player position to \(Self.appleScriptNumber(seconds))"
        )
    }

    private var readScript: String {
        """
        tell application "Music"
            set stateText to (player state as text)
            set separator to character id 30
            try
                set currentTrack to current track
                set trackName to (name of currentTrack as text)
                set trackArtist to (artist of currentTrack as text)
                set trackAlbum to (album of currentTrack as text)
                set trackDuration to (duration of currentTrack as text)
                set trackID to (persistent ID of currentTrack as text)
                set hasArtwork to "0"
                if (count of artworks of currentTrack) > 0 then
                    set hasArtwork to "1"
                end if
                set pos to 0
                try
                    set pos to player position
                end try
                return stateText & separator & (pos as text) & separator & trackName & separator & trackArtist & separator & trackAlbum & separator & trackDuration & separator & trackID & separator & hasArtwork
            on error
                return stateText & separator & "0" & separator & separator & separator & separator & separator & separator & "0"
            end try
        end tell
        """
    }

    private func executeCommand(_ script: String) async throws {
        _ = try await execute(script: script, timeout: Self.commandScriptTimeout)
    }

    private func execute(
        script: String,
        timeout: TimeInterval = 3
    ) async throws -> String? {
        try await scriptRunner(script, timeout)
    }

    private func parseSnapshot(_ value: String) async -> PlaybackSnapshot {
        let fields = value.components(separatedBy: fieldSeparator)
        guard fields.count >= 8 else {
            return PlaybackSnapshot(
                status: .unavailable("Apple Music 返回的数据格式无法识别"),
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .appleMusic
            )
        }

        let state = fields[0].lowercased()
        let position = Self.parseNumber(fields[1]) ?? 0
        let title = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Self.normalizedDuration(Self.parseNumber(fields[5]) ?? 0)
        let persistentID = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
        let hasArtwork = fields[7].trimmingCharacters(in: .whitespacesAndNewlines) == "1"

        guard !title.isEmpty, duration > 0 else {
            return PlaybackSnapshot(
                status: .noTrack,
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .appleMusic
            )
        }

        let artworkURL = await resolveArtworkURL(trackID: persistentID, hasArtwork: hasArtwork)

        let trackID = persistentID.isEmpty ? nil : "applemusic:\(persistentID)"
        let track = ProviderTrack(
            id: trackID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            spotifyURL: nil
        )

        let isPlaying = state == "playing"
        let status: PlaybackProviderState = state == "stopped" && title.isEmpty ? .noTrack : .ready
        return PlaybackSnapshot(
            status: status,
            track: track,
            position: min(max(0, position), duration),
            isPlaying: isPlaying,
            sourceIdentity: .appleMusic
        )
    }

    private func resolveArtworkURL(trackID: String, hasArtwork: Bool) async -> URL? {
        guard hasArtwork, !trackID.isEmpty else { return nil }
        let path = artworkFilePath(for: trackID)
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let exportScript = """
        tell application "Music"
            try
                set theArt to artwork 1 of current track
                set theData to raw data of theArt
                set targetPath to POSIX file "\(path)"
                set fileRef to open for access targetPath with write permission
                set eof fileRef to 0
                write theData to fileRef
                close access fileRef
                return "ok"
            on error
                try
                    close access (POSIX file "\(path)")
                end try
                return "error"
            end try
        end tell
        """
        do {
            let res = try await execute(script: exportScript, timeout: 2)
            if res == "ok", FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            // Ignore export failure, track can still display without artwork
        }
        return nil
    }

    private func artworkFilePath(for trackID: String) -> String {
        let sanitized = trackID.filter { $0.isLetter || $0.isNumber }
        let dir = NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("applemusic_artwork_\(sanitized).jpg")
    }

    private func map(error: AppleScriptExecutionError) -> PlaybackProviderState {
        if error.number == -1743 || error.message.localizedCaseInsensitiveContains("not authorized") || error.message.localizedCaseInsensitiveContains("not allowed") || error.message.localizedCaseInsensitiveContains("permission") {
            return .permissionDenied
        }
        if error.number == -600 || error.message.localizedCaseInsensitiveContains("not running") {
            return .notRunning
        }
        return .unavailable(error.message)
    }

    private static func parseNumber(_ value: String) -> TimeInterval? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return TimeInterval(normalized)
    }

    private static func normalizedDuration(_ raw: TimeInterval) -> TimeInterval {
        raw > 10_000 ? raw / 1_000 : raw
    }

    private static func appleScriptNumber(_ value: TimeInterval) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Bounded, serial AppleScript process runner for Music.app.
private actor AppleMusicAppleScriptProcessRunner {
    static let shared = AppleMusicAppleScriptProcessRunner()

    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(script: String, timeout: TimeInterval) async throws -> String? {
        await acquire()
        defer { release() }

        let processTask = Task.detached(priority: .userInitiated) {
            try Self.runProcess(script: script, timeout: timeout)
        }
        return try await withTaskCancellationHandler(operation: {
            try await processTask.value
        }, onCancel: {
            processTask.cancel()
        })
    }

    private func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
        } else {
            isRunning = false
        }
    }

    private nonisolated static func runProcess(
        script: String,
        timeout: TimeInterval
    ) throws -> String? {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AppleScriptExecutionError(
                number: nil,
                message: "无法启动 osascript：\(error.localizedDescription)"
            )
        }

        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while process.isRunning {
            if Task.isCancelled {
                terminate(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                terminate(process)
                throw AppleScriptExecutionError(
                    number: nil,
                    message: "Apple Music Apple Events 请求超时"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let standardOutput = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let standardError = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            let message = standardError?.isEmpty == false
                ? standardError!
                : "Apple Events 执行失败（\(process.terminationStatus)）"
            throw AppleScriptExecutionError(
                number: parseErrorNumber(from: message),
                message: message
            )
        }
        return standardOutput
    }

    private nonisolated static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private nonisolated static func parseErrorNumber(from message: String) -> Int? {
        guard let open = message.lastIndex(of: "("),
              let close = message[open...].firstIndex(of: ")") else {
            return nil
        }
        let numberStart = message.index(after: open)
        return Int(message[numberStart..<close])
    }
}

private struct AppleScriptExecutionError: Error {
    let number: Int?
    let message: String
}
