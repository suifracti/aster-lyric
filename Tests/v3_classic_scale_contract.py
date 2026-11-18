#!/usr/bin/env python3
"""Exercise framing migration using the real settings store and private defaults."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
raise SystemExit(subprocess.call([
    'bash', str(root / 'Scripts/test-native.sh'),
    '-only-testing:SpotifyLyricsTests/V3SceneLayerTests/testClassicBackdropMigrationKeepsTheExistingFramingAcrossScenesAndRestart',
    *sys.argv[1:],
]))
