"""Exercise the real V3 slider callbacks without a window or Spotify process."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
source = source.split('private struct AppleMusicImmersiveV3PlaybackProgress: View {', 1)[1]
source = source.split('private struct AppleMusicImmersiveV3TransportControls:', 1)[0]

assert 'state.presentationClock.playbackTime(' in source, \
    'V3 transport must use the playback-domain clock projection'
assert 'state.presentationClock.presentationTime(' not in source, \
    'V3 transport must not consume lyric presentation time'
full_v3_source = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
assert 'V3TransportClockLabel' in full_v3_source
assert 'clock.playbackTime(at: ProcessInfo.processInfo.systemUptime)' in full_v3_source
assert 'if !slider.isTrackingInteraction { slider.doubleValue = value }' in full_v3_source

def block(signature, text=source):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end].replace('private ', '')

fields = '\n'.join(re.findall(r'@State private (var (?:isEditing|draftPosition)[^\n]*)', source))
setter = re.search(r'set: \{ (draftPosition = [^\n]+) \}', source).group(1).replace('$0', 'value')
coordinator = block('final class Coordinator')
probe = '''import Foundation
final class FakePlaybackState {
    let presentationClock: LyricsPresentationClock
    var currentTime: Double = 18
    var seeks: [Double] = []
    init() {
        let anchor = ProcessInfo.processInfo.systemUptime
        presentationClock = LyricsPresentationClock(
            authoritativePosition: 18,
            receivedAtMonotonicTime: anchor,
            isPlaying: false,
            trackID: "contract-track",
            trackDuration: 240,
            presentationOffset: 2
        )
    }
    func seek(to value: Double, source: String) { seeks.append(value) }
}
struct V3PlaybackInputSlider {
    var value: Double
    let onEditingChanged: (Bool) -> Void
}
final class V3PlaybackNativeSlider: NSObject {
    var isTrackingInteraction = false
    var doubleValue: Double = 0
}
COORDINATOR
final class ProgressProbe {
    let state = FakePlaybackState()
    var interactionChanged: (Bool) -> Void = { _ in }
    let duration: Double = 240
FIELDS
    func write(_ value: Double) { SETTER }
VISIBLE
EDITING
}
let valueFirst = ProgressProbe()
valueFirst.write(120)
precondition(valueFirst.playbackPosition == 120, "A click target must become visible before begin-edit arrives")
valueFirst.handleEditingChanged(true)
valueFirst.handleEditingChanged(false)
precondition(valueFirst.state.seeks == [120], "Begin-edit must not replace the click target with old playback position")
valueFirst.handleEditingChanged(false)
precondition(valueFirst.state.seeks == [120], "Duplicate editing-end must not send another seek")
let beginFirst = ProgressProbe()
beginFirst.handleEditingChanged(true)
beginFirst.write(120)
beginFirst.state.currentTime = 19
precondition(beginFirst.playbackPosition == 120, "Live refresh must not overwrite a drag target")
beginFirst.handleEditingChanged(false)
precondition(beginFirst.state.seeks == [120])
let unchanged = ProgressProbe()
unchanged.handleEditingChanged(true)
unchanged.handleEditingChanged(false)
precondition(unchanged.state.seeks.isEmpty, "A tracking callback without a value change must not seek")
let clamped = ProgressProbe()
clamped.write(400)
clamped.handleEditingChanged(false)
precondition(clamped.state.seeks == [240])
precondition(clamped.playbackPosition == 18, "An ended draft must release the display to live playback")
var callbackEvents: [Bool] = []
let coordinator = Coordinator(parent: V3PlaybackInputSlider(
    value: 10,
    onEditingChanged: { callbackEvents.append($0) }
))
let keyboardSender = V3PlaybackNativeSlider()
keyboardSender.doubleValue = 11
coordinator.changed(keyboardSender)
precondition(coordinator.parent.value == 11, "keyboard/AX callback must write the raw slider value")
precondition(callbackEvents == [true, false], "standalone keyboard/AX callback must bracket one edit")
callbackEvents.removeAll()
keyboardSender.isTrackingInteraction = true
keyboardSender.doubleValue = 12
coordinator.changed(keyboardSender)
precondition(coordinator.parent.value == 12)
precondition(callbackEvents.isEmpty, "tracked pointer updates must not create standalone edit callbacks")
print("V3 seek draft contract: PASS (both callback orders, tracking without a value, duplicate end, refresh, clamp)")
'''
probe = probe.replace('COORDINATOR', coordinator).replace('FIELDS', fields).replace('SETTER', setter).replace('VISIBLE', block('private var playbackPosition: Double')).replace('EDITING', block('private func handleEditingChanged'))
with tempfile.TemporaryDirectory(prefix='lyrics-v3-seek-draft-') as temp:
    script = Path(temp) / 'main.swift'
    script.write_text(probe)
    binary = Path(temp) / 'contract'
    subprocess.run([
        'swiftc', str(root / 'SpotifyLyrics/Models/Models.swift'),
        str(script), '-o', str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)

fullscreen = (root / 'SpotifyLyrics/Views/Fullscreen/FullScreenLyricsView.swift').read_text()
# Fullscreen now embeds this exact player instead of maintaining independent
# callbacks. The real shared callbacks were exercised above in both event orders.
assert 'AppleMusicImmersiveV3WindowView(' in fullscreen
assert 'liveOnly: true' in fullscreen
assert not re.search(r'\b(?:Slider|seekBinding|seekEditingChanged|draftSeekTime)\b', fullscreen), \
    "Fullscreen must not reintroduce a separate seek implementation"
print("Fullscreen shared V3 seek contract: PASS")
