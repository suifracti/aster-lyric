#!/usr/bin/env python3
"""Run the actual row equality predicate against clock-only transport changes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3Lyrics.swift").read_text()
window = (root / "SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift").read_text()
models = (root / "SpotifyLyrics/Models/Models.swift").read_text()

def block(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

clock = block(models, "public struct LyricsPresentationClock:")
outer = block(source, "static func == (lhs: AppleMusicImmersiveV3LyricRow,")
outer = outer.replace("func ==", "func sameOuter").replace("AppleMusicImmersiveV3LyricRow", "Row")
equality = block(source, "static func == (lhs: AppleMusicImmersiveV3LyricRowContent,")
equality = equality.replace("AppleMusicImmersiveV3LyricRowContent", "Row")
relay = block((root / "SpotifyLyrics/Views/Components/ReadingVersionEditorView.swift").read_text(), "final class RubyCorrectionAction:")
interaction = block(window, "final class V3PlaybackInteractionRelay:")
program = "import Foundation\n" + clock + "\n" + relay + "\n" + interaction + "\n" + r'''
struct Line: Equatable { var timedSpans: [Int]? = [1] }
struct Row: Equatable {
    var line = Line()
    var clampedDistance = 0
    var isActive = true
    var isPast = false
    var isAdjacent = false
    var isNearActive = true
    var isSynchronized = true
    var availableWidth = 600
    var bigLineAvailableHeight: Double? = nil
    var compact = false
    var preferences = 0
    var language = "ja"
    var trackStableKey = "track"
    var artistDisplay = "artist"
    var scriptConversion = 0
    var dictionaryRevision = 0
    var presentationScale = 1
    var textAlignment = 0
    var presentationClock = LyricsPresentationClock(authoritativePosition: 10,
        receivedAtMonotonicTime: 100, isPlaying: true, trackID: "track", trackDuration: 240)
EQUALITY
OUTER
}
func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
func expectRows(_ first: Row, _ second: Row, equal: Bool, _ message: String) {
    expect((first == second) == equal && Row.sameOuter(lhs: first, rhs: second) == equal, message)
}
let relay = RubyCorrectionAction()
let stableHandler = relay
expect(relay == stableHandler, "environment callback identity must be stable")
expect(relay != RubyCorrectionAction(), "different document callbacks must not alias")
var corrected = ""
relay.action = { surface, _ in corrected = "A:" + surface }
stableHandler("first", "")
expect(corrected == "A:first", "correction callback must reach original document")
relay.action = { surface, _ in corrected = "B:" + surface }
stableHandler("second", "")
expect(corrected == "B:second", "stable callback must forward to current document, not stale lyrics")
let playbackAction = V3PlaybackInteractionRelay()
let samePlaybackAction = playbackAction
var interacting = false
playbackAction.action = { interacting = $0 }
samePlaybackAction(true)
expect(interacting && playbackAction == samePlaybackAction, "stable playback interaction still reaches the owner")
samePlaybackAction(false)
expect(!interacting, "gesture completion must clear playback interaction")
let original = Row()
var changed = original
changed.presentationClock = LyricsPresentationClock(authoritativePosition: 11,
    receivedAtMonotonicTime: 101, isPlaying: false, trackID: "track", trackDuration: 240)
expectRows(original, changed, equal: false, "same-line pause must refresh active timed row")
changed.presentationClock = LyricsPresentationClock(authoritativePosition: 13,
    receivedAtMonotonicTime: 101, isPlaying: true, trackID: "track", trackDuration: 240)
expectRows(original, changed, equal: false, "same-line seek must refresh active timed row")
changed.presentationClock = original.presentationClock.withPresentationOffset(1)
expectRows(original, changed, equal: false, "lyric offset must refresh active timed row")
var staticRow = original
staticRow.line.timedSpans = nil
changed = staticRow
changed.presentationClock = original.presentationClock.withPresentationOffset(1)
expectRows(staticRow, changed, equal: true, "static ruby must not re-layout for clock-only changes")
var inactiveRow = original
inactiveRow.isActive = false
changed = inactiveRow
changed.presentationClock = original.presentationClock.withPresentationOffset(1)
expectRows(inactiveRow, changed, equal: true, "inactive timed rows must not re-layout for clock-only changes")
print("PASS: active timed rows follow pause/seek/offset; static and inactive rows stay stable")
'''.replace("EQUALITY", equality).replace("OUTER", outer)
with tempfile.TemporaryDirectory(prefix="lyricsq-row-clock-") as folder:
    path = Path(folder)
    (path / "main.swift").write_text(program)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "contract")], check=True)
    subprocess.run([str(path / "contract")], check=True)
