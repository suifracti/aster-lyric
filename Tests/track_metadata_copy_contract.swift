import AppKit

@main
struct TrackMetadataCopyContract {
    static func main() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SpotifyLyrics.TrackMetadataCopy.Contract"))

        precondition(
            TrackMetadataCopy.copy("アーカイブ - Piano Ver.", to: pasteboard),
            "copying the title should write to the pasteboard"
        )
        precondition(
            pasteboard.string(forType: .string) == "アーカイブ - Piano Ver.",
            "the copied title must remain unchanged"
        )

        precondition(
            TrackMetadataCopy.copy("stb", to: pasteboard),
            "copying the artist should write to the pasteboard"
        )
        precondition(
            pasteboard.string(forType: .string) == "stb",
            "the artist copy should replace the previous title"
        )

        let album = "夜行紀事 (Deluxe Edition)"
        precondition(TrackMetadataCopy.copy(album, to: pasteboard))
        precondition(pasteboard.string(forType: .string) == album,
                     "album copy must preserve its edition and original script")
        let summary = TrackMetadataCopy.summary(title: "百日草", artist: "A, B", album: album)
        precondition(summary == "百日草\nA, B\n夜行紀事 (Deluxe Edition)",
                     "song info must keep title, all artists and album as separate lines")
        precondition(TrackMetadataCopy.summary(title: "Song", artist: "Artist", album: "  ") == "Song\nArtist",
                     "missing album metadata must not add a blank or invented album")
        precondition(TrackMetadataCopy.copy(summary, to: pasteboard))
        precondition(pasteboard.string(forType: .string) == summary)
        precondition(!TrackMetadataCopy.copy("", to: pasteboard))
        precondition(pasteboard.string(forType: .string) == summary,
                     "empty metadata must not clear the clipboard")
    }
}
