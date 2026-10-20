#!/usr/bin/env python3
"""Run only the opt-in cached playback resource probe from an xctestrun."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


TEST_TARGET = "SpotifyLyricsTests"
ONLY_TESTING = (
    "SpotifyLyricsTests/PlaybackResourceProbeTests/testCachedPlaybackResourceProbe"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run the isolated cached-song CPU/RSS probe from a build-for-testing "
            "xctestrun without building or launching the daily app."
        )
    )
    parser.add_argument("--xctestrun", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="Raw probe JSON output path")
    return parser.parse_args()


def load_xctestrun(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"xctestrun not found: {path}")
    with path.open("rb") as source:
        contents = plistlib.load(source)
    if not isinstance(contents, dict):
        raise ValueError("xctestrun root must be a plist dictionary")

    target = contents.get(TEST_TARGET)
    if not isinstance(target, dict):
        raise ValueError(f"xctestrun has no {TEST_TARGET} target")
    if target.get("BlueprintName") != TEST_TARGET or not target.get("IsAppHostedTestBundle"):
        raise ValueError("xctestrun is not the expected hosted SpotifyLyrics native test target")
    if not target.get("TestHostPath") or not target.get("TestBundlePath"):
        raise ValueError("xctestrun is missing its built test host or test bundle")
    return contents


def configure_environment(target: dict[str, Any], output_path: Path) -> None:
    additions = {
        "LYRICSQ_NATIVE_TESTS": "1",
        "SPOTIFYLYRICS_DISABLE_KEYCHAIN": "1",
        "LYRICSQ_PROBE_OUTPUT": str(output_path),
    }
    for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
        environment = target.setdefault(key, {})
        if not isinstance(environment, dict):
            raise ValueError(f"xctestrun {key} must be a plist dictionary")
        # The probe's host must never inherit a Spotify client ID from a prior run.
        environment.pop("SPOTIFY_CLIENT_ID", None)
        environment.update(additions)


def verify_report(output_path: Path) -> None:
    if not output_path.is_file():
        raise RuntimeError(
            "xcodebuild finished without a probe JSON file; the test may have skipped"
        )
    try:
        report = json.loads(output_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"probe JSON could not be read: {error}") from error
    if report.get("schema") != "lyricsq-playback-resource-probe-v1":
        raise RuntimeError("probe JSON has an unexpected schema")
    if len(report.get("samples", [])) != 31 or report.get("measurementSeconds", 0) < 29.5:
        raise RuntimeError("probe JSON does not contain the complete 30-second sample set")


def main() -> int:
    args = parse_args()
    source_path = args.xctestrun.expanduser().resolve()
    output_path = args.output.expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        raise ValueError(f"refusing to overwrite existing probe output: {output_path}")

    document = load_xctestrun(source_path)
    target = document[TEST_TARGET]
    configure_environment(target, output_path)

    # Keep __TESTROOT__ relative paths valid by placing the temporary xctestrun
    # alongside the build-for-testing product, and leave the original untouched.
    fd, temporary_name = tempfile.mkstemp(
        prefix=".lyricsq-playback-probe-", suffix=".xctestrun", dir=source_path.parent
    )
    os.close(fd)
    temporary_path = Path(temporary_name)
    try:
        with temporary_path.open("wb") as destination:
            plistlib.dump(document, destination, sort_keys=False)

        command = [
            "xcodebuild",
            "test-without-building",
            "-xctestrun",
            str(temporary_path),
            "-destination",
            "platform=macOS",
            f"-only-testing:{ONLY_TESTING}",
            "-parallel-testing-enabled",
            "NO",
            "CODE_SIGNING_ALLOWED=NO",
        ]
        environment = os.environ.copy()
        environment.pop("SPOTIFY_CLIENT_ID", None)
        print("Running only:", ONLY_TESTING, flush=True)
        completed = subprocess.run(command, env=environment, check=False)
        if completed.returncode != 0:
            return completed.returncode
        verify_report(output_path)
        print(f"Raw resource samples: {output_path}")
        return 0
    finally:
        temporary_path.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
        print(f"measure-playback-resources: {error}", file=sys.stderr)
        raise SystemExit(2)
