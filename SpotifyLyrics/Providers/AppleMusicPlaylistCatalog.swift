import Foundation

/// Apple Music's playlists through Music.app. Local only: no token, no
/// network. Membership is answered one playlist at a time so a big library
/// is never scanned up front.
@MainActor
public final class AppleMusicPlaylistCatalog: PlaylistCataloging {
    public var likedRowTitle: String { "喜爱" }
    public var connectionNotice: String { "需要在系统设置里允许控制「音乐」" }
    public var sourceKey: String { "apple-music" }

    private let runner: @Sendable (String, TimeInterval) async throws -> String?
    private static let fieldSeparator = String(UnicodeScalar(30))
    private static let rowSeparator = String(UnicodeScalar(31))

    public init() {
        self.runner = { script, timeout in
            try await AppleMusicAppleScriptProcessRunner.shared.run(script: script, timeout: timeout)
        }
    }

    init(runner: @escaping @Sendable (String, TimeInterval) async throws -> String?) {
        self.runner = runner
    }

    public func accessToken() async throws -> String { "" }

    public func playlists(accessToken: String) async throws -> [PlaylistSummary] {
        let script = """
        if application "Music" is not running then return ""
        tell application "Music"
            set sep to character id 30
            set rowSep to character id 31
            set out to ""
            repeat with p in user playlists
                set out to out & (persistent ID of p as text) & sep & (name of p as text) & sep & (count of tracks of p as text) & rowSep
            end repeat
            return out
        end tell
        """
        let output = try await run(script, timeout: 8)
        return Self.parsePlaylists(output)
    }

    public func createPrivatePlaylist(named name: String, accessToken: String) async throws -> PlaylistSummary {
        let script = """
        if application "Music" is not running then error "音乐未运行"
        tell application "Music"
            set newPlaylist to make new user playlist with properties {name:"\(Self.appleScriptString(name))"}
            return (persistent ID of newPlaylist as text)
        end tell
        """
        guard let id = try await run(script, timeout: 6), Self.isPersistentID(id) else {
            throw AppleMusicPlaylistError.failed
        }
        return PlaylistSummary(id: id, name: name, trackCount: 0,
                               snapshotID: "count:0", imageURL: nil)
    }

    public func contains(trackID: String, inPlaylist id: String, accessToken: String) async throws -> Bool {
        guard let track = Self.persistentTrackID(trackID), let playlist = Self.persistentPlaylistID(id) else {
            return false
        }
        let script = """
        if application "Music" is not running then return "0"
        tell application "Music"
            set target to missing value
            repeat with p in user playlists
                if (persistent ID of p as text) is "\(playlist)" then set target to contents of p
            end repeat
            if target is missing value then return "0"
            return (count of (tracks of target whose persistent ID is "\(track)")) as text
        end tell
        """
        return (try await run(script, timeout: 6))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    public func add(trackID: String, toPlaylist id: String, accessToken: String) async throws {
        guard let track = Self.persistentTrackID(trackID), let playlist = Self.persistentPlaylistID(id) else {
            throw AppleMusicPlaylistError.failed
        }
        let script = """
        if application "Music" is not running then error "音乐未运行"
        tell application "Music"
            set targetTrack to current track
            if (persistent ID of targetTrack as text) is not "\(track)" then error "歌曲已切换"
            set target to missing value
            repeat with p in user playlists
                if (persistent ID of p as text) is "\(playlist)" then set target to contents of p
            end repeat
            if target is missing value then error "找不到播放列表"
            duplicate targetTrack to target
            return "1"
        end tell
        """
        guard try await run(script, timeout: 8) == "1" else { throw AppleMusicPlaylistError.failed }
    }

    public func remove(trackID: String, fromPlaylist id: String, accessToken: String) async throws {
        guard let track = Self.persistentTrackID(trackID), let playlist = Self.persistentPlaylistID(id) else {
            throw AppleMusicPlaylistError.failed
        }
        let script = """
        if application "Music" is not running then error "音乐未运行"
        tell application "Music"
            set target to missing value
            repeat with p in user playlists
                if (persistent ID of p as text) is "\(playlist)" then set target to contents of p
            end repeat
            if target is missing value then error "找不到播放列表"
            set hits to (tracks of target whose persistent ID is "\(track)")
            repeat with tr in hits
                delete tr
            end repeat
            return "1"
        end tell
        """
        guard try await run(script, timeout: 8) == "1" else { throw AppleMusicPlaylistError.failed }
    }

    private func run(_ script: String, timeout: TimeInterval) async throws -> String? {
        try await runner(script, timeout)
    }

    /// Rows arrive as `id <30> name <30> trackCount <31>`.
    static func parsePlaylists(_ output: String?) -> [PlaylistSummary] {
        guard let output, !output.isEmpty else { return [] }
        return output.components(separatedBy: rowSeparator).compactMap { row in
            let fields = row.components(separatedBy: fieldSeparator)
            guard fields.count >= 3 else { return nil }
            let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPersistentID(id), !name.isEmpty else { return nil }
            let count = Int(fields[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            // Music has no snapshot ID; the track count is the cheap stand-in
            // for "did this list change since we last checked".
            return PlaylistSummary(id: id, name: name, trackCount: count,
                                   snapshotID: "count:\(count)", imageURL: nil)
        }
    }

    static func persistentTrackID(_ id: String) -> String? {
        let prefix = "applemusic:"
        guard id.lowercased().hasPrefix(prefix) else { return nil }
        let value = String(id.dropFirst(prefix.count))
        return isPersistentID(value) ? value : nil
    }

    static func persistentPlaylistID(_ id: String) -> String? {
        isPersistentID(id) ? id : nil
    }

    private static func isPersistentID(_ value: String) -> Bool {
        value.count == 16 && value.allSatisfy(\.isHexDigit)
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

enum AppleMusicPlaylistError: Error {
    case failed
}
