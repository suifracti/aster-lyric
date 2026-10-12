#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROVIDER="$ROOT_DIR/SpotifyLyrics/Providers/SpotifyDesktopProvider.swift"
PLAYBACK="$ROOT_DIR/SpotifyLyrics/Providers/PlaybackProvider.swift"
STATE="$ROOT_DIR/SpotifyLyrics/Services/PlaybackState.swift"

test -f "$PROVIDER"
test -f "$PLAYBACK"
test -f "$STATE"

# The desktop bridge must be bounded and single-flight. A raw NSAppleScript
# call has no dependable cancellation and previously left the app stale after
# Apple Events stalled.
grep -q 'private actor SpotifyAppleScriptProcessRunner' "$PROVIDER"
grep -q '/usr/bin/osascript' "$PROVIDER"
grep -q 'Spotify Apple Events 请求超时' "$PROVIDER"
grep -q 'process.terminate()' "$PROVIDER"
grep -q 'SIGKILL' "$PROVIDER"
grep -q 'private let scriptRunner' "$PROVIDER"
grep -q 'defer {' "$STATE"
grep -q 'lastProviderRefreshDate = Date()' "$STATE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

@main
@MainActor
struct SpotifyConnectionContract {
    static func main() async {
        let separator = String(UnicodeScalar(30))
        let provider = SpotifyDesktopProvider { script, timeout in
            if script.contains("current track") {
                precondition(timeout == 3)
                return [
                    "playing", "12.5", "Track", "Artist", "Album", "180000",
                    "", "spotify:track:test", "spotify:track:test"
                ].joined(separator: separator)
            }
            precondition(timeout == 5)
            return ""
        }

        let snapshot = await provider.refresh()
        precondition(snapshot.status == .ready)
        precondition(snapshot.track?.title == "Track")
        precondition(snapshot.track?.duration == 180)
        precondition(snapshot.isPlaying)
        precondition(snapshot.sourceIdentity == .spotifyDesktop)

        try? await provider.pause()
        print("Spotify connection contract passed")
    }
}
SWIFT

swiftc -parse-as-library \
    "$PLAYBACK" \
    "$PROVIDER" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/spotify-connection-contract"
"$TMP_DIR/spotify-connection-contract"
