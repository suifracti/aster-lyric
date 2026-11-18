#!/usr/bin/env python3
"""Run playback reliability checks against the app module and an isolated store."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
target = 'SpotifyLyricsTests/DesktopPlaybackEventTests'
raise SystemExit(subprocess.call([
    'bash', str(root / 'Scripts/test-native.sh'),
    f'-only-testing:{target}/testAdoptingAPreviewCandidateLeavesThePlayingSongUntouched',
    f'-only-testing:{target}/testListeningViewsRetainTheLastGoodResultAndRecoverAfterUnlock',
    *sys.argv[1:],
]))
