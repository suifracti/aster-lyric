#!/usr/bin/env python3
"""Exercise the actual canvas geometry without launching SwiftUI or playback."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
source = (root / "SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift").read_text()
geometry = source[source.index("enum V3BackdropArtworkGeometry {"):source.index("/// The V3 backdrop is deliberately")]
program = "import Foundation\nimport CoreGraphics\n" + geometry + r"""
for canvas in [CGSize(width: 1579, height: 1027), CGSize(width: 700, height: 1100)] {
    for artwork in [CGSize(width: 1000, height: 1000), CGSize(width: 1600, height: 900)] {
        for scale in [0.8, 1.0, 1.4] {
            let fill = V3BackdropArtworkGeometry.rect(canvas: canvas, artwork: artwork, scale: scale, complete: false)
            let complete = V3BackdropArtworkGeometry.rect(canvas: canvas, artwork: artwork, scale: scale, complete: true)
            for rect in [fill, complete] {
                precondition(abs(rect.midX - canvas.width / 2) < 0.001)
                precondition(abs(rect.midY - canvas.height / 2) < 0.001)
                precondition(abs(rect.width / rect.height - artwork.width / artwork.height) < 0.001)
            }
            precondition(complete.width <= fill.width + 0.001, "more-complete framing crops less")
            precondition(complete.height <= fill.height + 0.001)
        }
    }
}
print("PASS: framing preserves aspect ratio and centers both axes at every scale")
"""
with tempfile.TemporaryDirectory(prefix="lyricsq-framing-") as folder:
    path = Path(folder)
    (path / "main.swift").write_text(program)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "contract")], check=True)
    subprocess.run([str(path / "contract")], check=True)
