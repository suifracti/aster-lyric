from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[1]
s=(r/'SpotifyLyrics/Services/PlaybackState.swift').read_text()
a=s.index('    private func publishTickTime(');b=s.index('\n    private enum LineIndexSource',a)
method=s[a:b].replace('private func','func')
a=s.index('    private func resetPlaybackAnchor(');b=s.index('\n    private var presentationTimeNow:',a)
anchor=s[a:b].replace('private func','func')
view=(r/'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
a=view.index('final class V3PlaybackContentObserver:')
b=view.index('\n@MainActor\n@propertyWrapper',a)
observer='@MainActor\n'+view[a:b]
progress=s[s.index('/// Observed only'):s.index('@MainActor\npublic final class PlaybackState')]
properties=s[s.index('    public let progress ='):s.index('    /// Authoritative seeks')].replace('private(set)', '')
program='''import Foundation
import Observation
import Combine
struct PlaybackTickTimeUpdatePolicy { static func shouldPublish(currentTime:Double,nextTime:Double)->Bool { currentTime != nextTime } }
PROGRESS
@MainActor
final class Probe:ObservableObject {
 PROPERTIES
 @Published var lineIndex = 0
 var isPublishingPlaybackClockTick = false
 enum LineIndexSource { case poll, seek }
 struct Track { var duration:Double=300 }
 var currentTrack=Track()
 var playbackAnchorPosition:Double=0
 var playbackAnchorDate=Date()
 var playbackAnchorMonotonic:Double=0
 var presentationTimeNow:Double { currentTime }
 var boundaryFlags:[Bool]=[]
 func updatePlaybackScheduling() {}
 func syncPublishedLineIndex(source:LineIndexSource,previousTime:Double,incomingTime:Double) { boundaryFlags.append(isPublishingPlaybackClockTick) }
 METHOD
 ANCHOR
}
typealias PlaybackState = Probe
OBSERVER
MainActor.assumeIsolated {
let p=Probe()
var refreshes=0, ticks=0
let a=p.objectWillChange.sink { refreshes += 1 }
let b=p.progress.publisher.dropFirst().sink { _ in ticks += 1 }
var playheadInvalidated = false
withObservationTracking { _ = p.currentTime } onChange: { MainActor.assumeIsolated { playheadInvalidated = true } }
for n in 1...5 { p.publishTickTime(Double(n)/5) }
precondition(playheadInvalidated, "time labels and sliders must still invalidate through Observation")
precondition(ticks == 5 && refreshes == 0, "all clock consumers stay live without rebuilding the large surface")
precondition(!p.isPublishingPlaybackClockTick, "tick scope must end synchronously")
p.lineIndex=1
precondition(refreshes == 1, "lyric boundary still refreshes")
p.currentTime=20
precondition(refreshes == 2 && ticks == 6, "authoritative seek/reset still refreshes both")
p.publishTickTime(20)
precondition(ticks == 6 && refreshes == 2, "unchanged clock remains silent")
p.resetPlaybackAnchor(to:21,source:.poll)
precondition(ticks == 7 && refreshes == 2, "ordinary provider calibration must update time without a broad refresh")
p.resetPlaybackAnchor(to:21,source:.seek)
precondition(ticks == 8 && refreshes == 3, "an explicit seek must refresh even at the same position")
precondition(p.boundaryFlags == [false,false], "lyric boundary synchronization must remain outside clock-only scope")
MainActor.assumeIsolated {
 let controls=V3PlaybackContentObserver(p)
 var updates=0
 let c=controls.objectWillChange.sink { updates += 1 }
 p.publishTickTime(22)
 precondition(updates == 0, "controls must ignore a pure clock tick")
 p.lineIndex=2
 precondition(updates == 1, "controls must still observe content changes")
 withExtendedLifetime(c) {}
}
withExtendedLifetime((a,b)) {}
}
print("PASS: clock consumers stay live; main and control observers skip only pure ticks")
'''.replace('PROGRESS',progress).replace('PROPERTIES',properties).replace('METHOD',method).replace('ANCHOR',anchor).replace('OBSERVER',observer)
with tempfile.TemporaryDirectory(prefix='lyrics-clock-filter-') as d:
 p=Path(d);(p/'main.swift').write_text(program)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
