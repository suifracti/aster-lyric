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
        if application "Music" is not running then error "音乐未运行" number -600
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
        let count = try await run(script, timeout: 6)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (count.flatMap(Int.init) ?? 0) > 0
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

    struct Continuation {
        let playlistID: String
        let name: String
        let tracks: [SpotifyPlaylistTrack]
    }

    func tracks(in playlistID: String) async throws -> [SpotifyPlaylistTrack] {
        let source: String, selection: String
        if playlistID == PlaylistBrowserModel.likedID {
            source = "set sourcePlaylist to library playlist 1"
            selection = "(every track of sourcePlaylist whose favorited is true)"
        } else {
            guard let id = Self.persistentPlaylistID(playlistID) else { throw AppleMusicPlaylistError.failed }
            source = #"set sourcePlaylist to first user playlist whose persistent ID is "\#(id)""#
            selection = "(every track of sourcePlaylist)"
        }
        let script = """
        if application "Music" is not running then error "音乐未运行"
        tell application "Music"
            \(source)
            set startOffset to 0
            \(Self.trackRows(selection))
            return packedText
        end tell
        """
        return Self.parseTracks(try await run(script, timeout: 15) ?? "")
    }

    // Music exposes the current playlist, but does not expose its editable Playing Next queue.
    func continuation(after currentID: String?) async throws -> Continuation? {
        let expectedID = currentID.flatMap(Self.persistentTrackID)
        let check = expectedID.map { #"if currentID is not "\#($0)" then return """# } ?? ""
        let script = """
        if application "Music" is not running then return ""
        tell application "Music"
            try
                set sourcePlaylist to current playlist
                set currentID to persistent ID of current track
                \(check)
                set currentIndex to index of current track
                if currentIndex < 1 or (persistent ID of track currentIndex of sourcePlaylist) is not currentID then return ""
                set headerText to (persistent ID of sourcePlaylist as text) & (character id 30) & (name of sourcePlaylist as text) & (character id 31)
                set trackTotal to count tracks of sourcePlaylist
            on error number -1728
                return ""
            end try
            if currentIndex >= trackTotal then return headerText
            set firstIndex to currentIndex + 1
            set lastIndex to currentIndex + 25
            if lastIndex > trackTotal then set lastIndex to trackTotal
            set startOffset to currentIndex
            \(Self.trackRows("(tracks firstIndex thru lastIndex of sourcePlaylist)"))
            return headerText & packedText
        end tell
        """
        guard let output = try await run(script, timeout: 8), let split = output.range(of: Self.rowSeparator) else { return nil }
        let header = output[..<split.lowerBound].components(separatedBy: Self.fieldSeparator)
        guard header.count == 2, let id = Self.persistentPlaylistID(header[0]) else { return nil }
        return Continuation(playlistID: id, name: header[1], tracks: Self.parseTracks(String(output[split.upperBound...])))
    }

    func play(_ item: SpotifyPlaylistTrack, in playlistID: String) async throws {
        guard let trackID = item.track.spotifyId.flatMap(Self.persistentTrackID), item.offset >= 0 else {
            throw AppleMusicPlaylistError.failed
        }
        let selection: String
        if playlistID == PlaylistBrowserModel.likedID {
            selection = #"set chosenTrack to first track of library playlist 1 whose persistent ID is "\#(trackID)" and favorited is true"#
        } else {
            guard let id = Self.persistentPlaylistID(playlistID) else { throw AppleMusicPlaylistError.failed }
            selection = """
            set sourcePlaylist to first playlist whose persistent ID is "\(id)"
            set chosenTrack to track \(item.offset + 1) of sourcePlaylist
            """
        }
        try await playVerified(trackID: trackID, selection: selection)
    }

    func playFromLibrary(_ track: Track) async throws {
        guard let id = track.spotifyId.flatMap(Self.persistentTrackID) else { throw AppleMusicPlaylistError.failed }
        try await playVerified(trackID: id, selection: #"set chosenTrack to first track of library playlist 1 whose persistent ID is "\#(id)""#)
    }

    private func playVerified(trackID: String, selection: String) async throws {
        let script = """
        if application "Music" is not running then error "音乐未运行"
        tell application "Music"
            \(selection)
            if (persistent ID of chosenTrack as text) is not "\(trackID)" then error "歌单顺序已变，请刷新后重选"
            play chosenTrack once false
            return "1"
        end tell
        """
        guard try await run(script, timeout: 6) == "1" else { throw AppleMusicPlaylistError.failed }
    }

    func searchLibrary(_ query: TrackSearchQuery) async throws -> [Track] {
        let term = [query.text, query.title, query.artist, query.album].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let term else { return [] }
        let script = """
        if application "Music" is not running then return ""
        tell application "Music"
            set hits to search library playlist 1 for "\(Self.appleScriptString(term))"
            if hits is missing value then return ""
            if class of hits is not list then set hits to {hits}
            set hitCount to count hits
            if hitCount > 30 then set hitCount to 30
            set packedRows to {}
            set fieldSep to character id 30
            repeat with n from 1 to hitCount
                try
                    set info to properties of item n of hits
                    set rowArtist to artist of info
                    set rowAlbum to album of info
                    set rowDuration to duration of info
                    if rowArtist is missing value then set rowArtist to ""
                    if rowAlbum is missing value then set rowAlbum to ""
                    if rowDuration is missing value then set rowDuration to 0
                    set end of packedRows to ((n - 1) as text) & fieldSep & (persistent ID of info as text) & fieldSep & (name of info as text) & fieldSep & rowArtist & fieldSep & rowAlbum & fieldSep & (rowDuration as text)
                on error number -1728
                    -- The library may change between the search and reading a result.
                end try
            end repeat
            set AppleScript's text item delimiters to character id 31
            return packedRows as text
        end tell
        """
        return Self.parseTracks(try await run(script, timeout: 8) ?? "").map(\.track)
    }

    // Fetch whole columns in Music, then join rows locally. The original ordinal
    // survives an unreadable row and distinguishes repeated copies of the same song.
    private static func trackRows(_ selection: String) -> String {
        """
        set rowIDs to get persistent ID of \(selection)
        set rowTitles to get name of \(selection)
        set rowArtists to get artist of \(selection)
        set rowAlbums to get album of \(selection)
        set rowDurations to get duration of \(selection)
        set fieldSep to character id 30
        set packedRows to {}
        repeat with n from 1 to count of rowIDs
            set a to item n of rowArtists
            set b to item n of rowAlbums
            set d to item n of rowDurations
            if a is missing value then set a to ""
            if b is missing value then set b to ""
            if d is missing value then set d to 0
            set end of packedRows to ((startOffset + n - 1) as text) & fieldSep & (item n of rowIDs as text) & fieldSep & (item n of rowTitles as text) & fieldSep & a & fieldSep & b & fieldSep & (d as text)
        end repeat
        set AppleScript's text item delimiters to character id 31
        set packedText to packedRows as text
        """
    }

    private static func parseTracks(_ output: String) -> [SpotifyPlaylistTrack] {
        output.components(separatedBy: rowSeparator).compactMap { row in
            let fields = row.components(separatedBy: fieldSeparator)
            guard fields.count == 6, let offset = Int(fields[0]), offset >= 0,
                  isPersistentID(fields[1]), !fields[2].isEmpty else { return nil }
            let id = "applemusic:" + fields[1]
            let duration = Double(fields[5].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0
            return SpotifyPlaylistTrack(track: Track(id: id, title: fields[2], artist: fields[3], album: fields[4],
                                                      duration: duration.isFinite ? max(0, duration) : 0, spotifyId: id), offset: offset)
        }
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

enum AppleMusicPlaylistError: LocalizedError {
    case failed
    var errorDescription: String? { "无法在「音乐」中找到这首歌或歌单" }
}
