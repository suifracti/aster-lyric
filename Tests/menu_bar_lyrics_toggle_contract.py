"""Compatibility entrypoint for the migrated native XCTest contracts."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
raise SystemExit(subprocess.call(["bash", str(root / "Scripts/test-native.sh"), '-only-testing:SpotifyLyricsTests/MenuBarPresentationTests', '-only-testing:SpotifyLyricsTests/PresentationSourceContractTests'] + sys.argv[1:]))
