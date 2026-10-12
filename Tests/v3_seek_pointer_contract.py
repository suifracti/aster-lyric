"""Check the native V3 input's full-rail coordinate mapping without opening UI."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
start = source.index('static func pointerPosition(')
opening = source.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
mapping = source[start:end]
program = '''import Foundation
struct Pointer { MAPPING }
precondition(Pointer.pointerPosition(x: 0, width: 300, duration: 240) == 0)
precondition(Pointer.pointerPosition(x: 150, width: 300, duration: 240) == 120)
precondition(Pointer.pointerPosition(x: 300, width: 300, duration: 240) == 240)
precondition(Pointer.pointerPosition(x: -40, width: 300, duration: 240) == 0)
precondition(Pointer.pointerPosition(x: 360, width: 300, duration: 240) == 240)
precondition(Pointer.pointerPosition(x: 10, width: 0, duration: 240) == 0)
precondition(Pointer.pointerPosition(x: .nan, width: 300, duration: 240) == 0)
for _ in [0.0, 2.0, -2.0] {
    precondition(Pointer.pointerPosition(x: 150, width: 300, duration: 240) == 120)
}
// Sparse event stream: only down and up. The up coordinate must be enough
// to derive the new seek, in either direction, with no dragged samples.
let forward = [60.0, 270.0].map { Pointer.pointerPosition(x: $0, width: 300, duration: 240) }
let backward = [270.0, 60.0].map { Pointer.pointerPosition(x: $0, width: 300, duration: 240) }
precondition(forward.last == 216 && backward.last == 48)
print("V3 seek pointer mapping: PASS")
'''.replace('MAPPING', mapping)
with tempfile.TemporaryDirectory(prefix='lyrics-v3-seek-pointer-') as temp:
    path = Path(temp) / 'main.swift'
    path.write_text(program)
    binary = Path(temp) / 'contract'
    subprocess.run(['swiftc', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
