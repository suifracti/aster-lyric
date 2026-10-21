import AppKit
import Darwin
import Foundation

@MainActor
public final class SpotifyDesktopProvider: PlaybackProvider {
    public let displayName = "Spotify Desktop"

    private static let applicationPath = "/Applications/Spotify.app"
    private static let bundleIdentifier = "com.spotify.client"
    private let fieldSeparator = String(UnicodeScalar(30))
    private let scriptRunner: @Sendable (String, TimeInterval) async throws -> String?
    private var lastDesktopSnapshot: PlaybackSnapshot?
    private let applicationIsInstalled: @MainActor () -> Bool
    private let applicationIsRunning: @MainActor () -> Bool

    private static let refreshScriptTimeout: TimeInterval = 3
    private static let commandScriptTimeout: TimeInterval = 5

    public convenience init() {
        self.init(scriptRunner: { script, timeout in
            try await SpotifyAppleScriptProcessRunner.shared.run(
                script: script,
                timeout: timeout
            )
        })
    }

    /// Test seam for the parser and connection state contract. Production
    /// calls use the bounded, serial AppleScript process runner above.
    init(scriptRunner: @escaping @Sendable (String, TimeInterval) async throws -> String?,
         applicationIsInstalled: (@MainActor () -> Bool)? = nil,
         applicationIsRunning: (@MainActor () -> Bool)? = nil) {
        self.scriptRunner = scriptRunner
        self.applicationIsInstalled = applicationIsInstalled ?? { FileManager.default.fileExists(atPath: Self.applicationPath) }
        self.applicationIsRunning = applicationIsRunning ?? { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty }
    }

    public func refresh() async -> PlaybackSnapshot {
        let snapshot = await readSnapshot()
        acceptDesktopSnapshot(snapshot)
        return snapshot
    }

    func acceptDesktopSnapshot(_ snapshot: PlaybackSnapshot) {
        lastDesktopSnapshot = snapshot.status.isReady ? snapshot : nil
    }

    /// One asset read after a track notification, never a status polling loop.
    public func artworkURL(for track: ProviderTrack, source: PlaybackSourceIdentity) async -> URL? {
        guard source == .spotifyDesktop, isRunning, let id = track.id else { return nil }
        let script = """
        if application "Spotify" is not running then return ""
        tell application "Spotify"
            return (id of current track as text) & (character id 30) & (artwork url of current track as text)
        end tell
        """
        guard let raw = try? await execute(script: script),
              !Task.isCancelled else { return nil }
        let fields = raw.components(separatedBy: fieldSeparator)
        guard fields.count == 2, fields[0] == id else { return nil }
        return Self.parseURL(fields[1])
    }

    public func calibratePosition() async -> PlaybackSnapshot {
        guard isRunning else {
            return PlaybackSnapshot(status: .notRunning, track: nil, position: 0, isPlaying: false, sourceIdentity: .spotifyDesktop)
        }
        guard let cached = lastDesktopSnapshot, let track = cached.track else {
            return PlaybackSnapshot(status: .noTrack, track: nil, position: 0, isPlaying: false, sourceIdentity: .spotifyDesktop)
        }
        guard cached.isPlaying else { return cached }
        do {
            let script = """
            if application "Spotify" is not running then return ""
            tell application "Spotify"
                return (player state as text) & (character id 30) & (player position as text) & (character id 30) & (id of current track as text)
            end tell
            """
            let fields = (try await execute(script: script) ?? "").components(separatedBy: fieldSeparator)
            guard fields.count == 3, fields[2] == track.id,
                  let position = Self.parseNumber(fields[1]), position.isFinite else {
                return PlaybackSnapshot(status: .unavailable("等待 Spotify 歌曲通知"), track: nil, position: 0, isPlaying: false, sourceIdentity: .spotifyDesktop)
            }
            return PlaybackSnapshot(status: .ready, track: track, position: min(max(0, position), track.duration),
                                    isPlaying: fields[0].lowercased() == "playing", sourceIdentity: .spotifyDesktop)
        } catch {
            return PlaybackSnapshot(status: .unavailable(error.localizedDescription), track: nil, position: 0, isPlaying: false, sourceIdentity: .spotifyDesktop)
        }
    }

    private func readSnapshot() async -> PlaybackSnapshot {
        guard applicationIsInstalled() else {
            return PlaybackSnapshot(
                status: .notInstalled,
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .spotifyDesktop
            )
        }

        guard isRunning else {
            return PlaybackSnapshot(
                status: .notRunning,
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .spotifyDesktop
            )
        }

        do {
            guard let result = try await execute(script: readScript) else {
                return PlaybackSnapshot(
                    status: .unavailable("Spotify 没有返回当前歌曲"),
                    track: nil,
                    position: 0,
                    isPlaying: false,
                    sourceIdentity: .spotifyDesktop
                )
            }
            return parseSnapshot(result)
        } catch let error as AppleScriptExecutionError {
            return PlaybackSnapshot(
                status: map(error: error),
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .spotifyDesktop
            )
        } catch {
            return PlaybackSnapshot(
                status: .unavailable(error.localizedDescription),
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .spotifyDesktop
            )
        }
    }

    public func play() async throws {
        try await executeCommand("tell application \"Spotify\" to play")
    }

    public func restartTrack(id: String) async throws -> Bool {
        // Playback IDs are case-sensitive; the library's identity normalizer
        // is for matching saved records, not for sending commands to Spotify.
        let trackID = id.hasPrefix("spotify:track:") ? String(id.dropFirst("spotify:track:".count)) : id
        guard trackID.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil,
              isRunning else { return false }
        let result = try await execute(script: """
        if application "Spotify" is not running then return "false"
        tell application "Spotify"
            considering case
                if (id of current track as text) is not "spotify:track:\(trackID)" then return "false"
            end considering
            set player position to 0
            return "true"
        end tell
        """, timeout: Self.commandScriptTimeout)
        return result?.lowercased() == "true"
    }

    public func playbackModes(shuffle: Bool?, repeatMode: PlayerRepeatMode?) async throws -> PlayerPlaybackModes {
        guard isRunning else { throw PlaybackProviderError.notRunning }
        let shuffleCommand = shuffle.map { "set shuffling to \($0 ? "true" : "false")" } ?? ""
        let repeatCommand = repeatMode.map { "set repeating to \($0 == .off ? "false" : "true")" } ?? ""
        let raw = try await execute(script: """
        if application "Spotify" is not running then return ""
        tell application "Spotify"
            \(shuffleCommand)
            \(repeatCommand)
            return (shuffling as text) & "|" & (repeating as text)
        end tell
        """, timeout: Self.commandScriptTimeout)
        let parts = (raw ?? "").lowercased().components(separatedBy: "|")
        guard parts.count == 2, parts.allSatisfy({ ["true", "false"].contains($0) }) else {
            throw PlaybackProviderError.commandFailed("无法读取 Spotify 随机与循环")
        }
        return PlayerPlaybackModes(shuffle: parts[0] == "true", repeatMode: parts[1] == "true" ? .all : .off)
    }

    public func pause() async throws {
        try await executeCommand("tell application \"Spotify\" to pause")
    }

    public func previous() async throws {
        try await executeCommand("tell application \"Spotify\" to previous track")
    }

    public func next() async throws {
        try await executeCommand("tell application \"Spotify\" to next track")
    }

    public func seek(to position: TimeInterval) async throws {
        let seconds = max(0, position)
        try await executeCommand(
            "tell application \"Spotify\" to set player position to \(Self.appleScriptNumber(seconds))"
        )
    }

    private var isRunning: Bool {
        applicationIsRunning()
    }

    private var readScript: String {
        """
        tell application "Spotify"
            set stateText to (player state as text)
            set separator to character id 30
            try
                set currentTrack to current track
                return stateText & separator & (player position as text) & separator & (name of currentTrack as text) & separator & (artist of currentTrack as text) & separator & (album of currentTrack as text) & separator & (duration of currentTrack as text) & separator & (artwork url of currentTrack as text) & separator & (spotify url of currentTrack as text) & separator & (id of currentTrack as text)
            on error
                return stateText & separator & (player position as text) & separator & separator & separator & separator & separator & separator & separator
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

    private func parseSnapshot(_ value: String) -> PlaybackSnapshot {
        let fields = value.components(separatedBy: fieldSeparator)
        guard fields.count >= 9 else {
            return PlaybackSnapshot(
                status: .unavailable("Spotify 返回的数据格式无法识别"),
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .spotifyDesktop
            )
        }

        let state = fields[0].lowercased()
        let position = Self.parseNumber(fields[1]) ?? 0
        let title = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Self.normalizedDuration(Self.parseNumber(fields[5]) ?? 0)
        let artworkURL = Self.parseURL(fields[6])
        let spotifyURL = Self.parseURL(fields[7])
        let id = fields[8].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, duration > 0 else {
            return PlaybackSnapshot(
                status: .noTrack,
                track: nil,
                position: 0,
                isPlaying: false,
                sourceIdentity: .spotifyDesktop
            )
        }

        let track = ProviderTrack(
            id: id.isEmpty ? nil : id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: artworkURL,
            spotifyURL: spotifyURL
        )

        let isPlaying = state == "playing"
        let status: PlaybackProviderState = state == "stopped" && title.isEmpty ? .noTrack : .ready
        return PlaybackSnapshot(
            status: status,
            track: track,
            position: min(max(0, position), duration),
            isPlaying: isPlaying,
            sourceIdentity: .spotifyDesktop
        )
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
        // Spotify's AppleScript duration is milliseconds, including short tracks.
        raw / 1_000
    }

    private static func parseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private static func appleScriptNumber(_ value: TimeInterval) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// NSAppleScript has no reliable cancellation or timeout once an Apple Event
/// is waiting on Spotify. Running one bounded `/usr/bin/osascript` process at a
/// time lets a stalled event be terminated instead of accumulating detached
/// threads and freezing the current-track stream.
private actor SpotifyAppleScriptProcessRunner {
    static let shared = SpotifyAppleScriptProcessRunner()

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
                    message: "Spotify Apple Events 请求超时"
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
