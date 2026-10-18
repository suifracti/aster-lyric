#!/usr/bin/env python3
"""Run the actual row equality predicate against clock-only transport changes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift").read_text()
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
equality = block(source, "static func == (lhs: AppleMusicImmersiveV3LyricRowContent,")
equality = equality.replace("AppleMusicImmersiveV3LyricRowContent", "Row")
program = "import Foundation\n" + clock + "\n" + r'''
struct Line: Equatable { var timedSpans: [Int]? = [1] }
struct Row: Equatable {
    var line = Line()
    var isActive = true
    var isAdjacent = false
    var isNearActive = true
    var isSynchronized = true
    var availableWidth = 600
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
}
func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}
let original = Row()
var changed = original
changed.presentationClock = LyricsPresentationClock(authoritativePosition: 11,
    receivedAtMonotonicTime: 101, isPlaying: false, trackID: "track", trackDuration: 240)
expect(original != changed, "same-line pause must refresh active timed row")
changed.presentationClock = LyricsPresentationClock(authoritativePosition: 13,
    receivedAtMonotonicTime: 101, isPlaying: true, trackID: "track", trackDuration: 240)
expect(original != changed, "same-line seek must refresh active timed row")
changed.presentationClock = original.presentationClock.withPresentationOffset(1)
expect(original != changed, "lyric offset must refresh active timed row")
var staticRow = original
staticRow.line.timedSpans = nil
changed = staticRow
changed.presentationClock = original.presentationClock.withPresentationOffset(1)
expect(staticRow == changed, "static ruby must not re-layout for clock-only changes")
var inactiveRow = original
inactiveRow.isActive = false
changed = inactiveRow
changed.presentationClock = original.presentationClock.withPresentationOffset(1)
expect(inactiveRow == changed, "inactive timed rows must not re-layout for clock-only changes")
print("PASS: active timed rows follow pause/seek/offset; static and inactive rows stay stable")
'''.replace("EQUALITY", equality)
with tempfile.TemporaryDirectory(prefix="lyricsq-row-clock-") as folder:
    path = Path(folder)
    (path / "main.swift").write_text(program)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "contract")], check=True)
    subprocess.run([str(path / "contract")], check=True)
