from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[1]
s=(r/'SpotifyLyrics/Services/PlaybackState.swift').read_text()
a=s.index('    private func publishTickTime(');b=s.index('\n    private enum LineIndexSource',a)
method=s[a:b].replace('private func','func')
view=(r/'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
a=view.index('final class V3PlaybackContentObserver:')
b=view.index('\n@MainActor\n@propertyWrapper',a)
observer='@MainActor\n'+view[a:b]
program='''import Foundation
import Combine
struct PlaybackTickTimeUpdatePolicy { static func shouldPublish(currentTime:Double,nextTime:Double)->Bool { currentTime != nextTime } }
final class Probe:ObservableObject {
 @Published var currentTime:Double = 0
 @Published var lineIndex = 0
 var isPublishingPlaybackClockTick = false
 METHOD
}
typealias PlaybackState = Probe
OBSERVER
let p=Probe()
var refreshes=0, ticks=0
let a=p.objectWillChange.sink { if !p.isPublishingPlaybackClockTick { refreshes += 1 } }
let b=p.$currentTime.dropFirst().sink { _ in ticks += 1 }
for n in 1...5 { p.publishTickTime(Double(n)/5) }
precondition(ticks == 5 && refreshes == 0, "all clock consumers stay live without rebuilding the large surface")
precondition(!p.isPublishingPlaybackClockTick, "tick scope must end synchronously")
p.lineIndex=1
precondition(refreshes == 1, "lyric boundary still refreshes")
p.currentTime=20
precondition(refreshes == 2 && ticks == 6, "authoritative seek/reset still refreshes both")
p.publishTickTime(20)
precondition(ticks == 6 && refreshes == 2, "unchanged clock remains silent")
MainActor.assumeIsolated {
 let controls=V3PlaybackContentObserver(p)
 var updates=0
 let c=controls.objectWillChange.sink { updates += 1 }
 p.publishTickTime(21)
 precondition(updates == 0, "controls must ignore a pure clock tick")
 p.lineIndex=2
 precondition(updates == 1, "controls must still observe content changes")
 withExtendedLifetime(c) {}
}
print("PASS: clock consumers stay live; main and control observers skip only pure ticks")
'''.replace('METHOD',method).replace('OBSERVER',observer)
with tempfile.TemporaryDirectory(prefix='lyrics-clock-filter-') as d:
 p=Path(d);(p/'main.swift').write_text(program)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
