"""Build an isolated native test host without editing the formal app entry point."""
from pathlib import Path
import hashlib, json, shutil, subprocess
ROOT = Path(__file__).resolve().parents[2]
OUT = Path('/tmp/lyrics-experience-visual-host')
SOURCE = OUT / 'source'
SOURCE.mkdir(parents=True, exist_ok=True)
manifest = {}
for folder in ('SpotifyLyrics', 'SpotifyLyrics.xcodeproj'):
    dest = SOURCE / folder
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(ROOT / folder, dest)
    for p in (ROOT / folder).rglob('*'):
        if p.is_file():
            manifest[str(p.relative_to(ROOT))] = hashlib.sha256(p.read_bytes()).hexdigest()
main = SOURCE / 'SpotifyLyrics/Main.swift'
entry = main.read_text()
# The native XCTest host introduced a lightweight enum entry point. The
# visual host supplies its own @main, so disable either production spelling.
entry = entry.replace('@main\nenum SpotifyLyricsEntryPoint', 'enum SpotifyLyricsEntryPoint', 1)
entry = entry.replace('@main\nstruct SpotifyLyricsApp', 'struct SpotifyLyricsApp', 1)
main.write_text(entry + '\n' + (ROOT / 'Tools/experience_visual_host/VisualHost.swift').read_text())
(OUT / 'source-manifest.json').write_text(json.dumps({'head': subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(), 'files': manifest}, indent=2))
command=['xcodebuild','-project',str(SOURCE/'SpotifyLyrics.xcodeproj'),'-scheme','SpotifyLyrics','-configuration','Debug','-derivedDataPath',str(OUT/'DerivedData'),'CODE_SIGNING_ALLOWED=NO','PRODUCT_BUNDLE_IDENTIFIER=com.lyricsq.experience-visual-host','build']
(OUT/'command.json').write_text(json.dumps(command))
with (OUT/'build.log').open('w') as log:
    result=subprocess.run(command, cwd=SOURCE, stdout=log, stderr=subprocess.STDOUT)
print('Build log:',OUT/'build.log')
if result.returncode: raise SystemExit(result.returncode)
print(OUT/'DerivedData/Build/Products/Debug/SpotifyLyrics.app/Contents/MacOS/SpotifyLyrics')
