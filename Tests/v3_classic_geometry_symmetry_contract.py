#!/usr/bin/env python3
"""Exercise the V3 classic geometry used by the renderer."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift").read_text()
geometry = source[source.index("enum V3BackdropArtworkGeometry {"):source.index("/// The V3 backdrop is deliberately")]
classic = source.split("private func classicArtworkLayers", 1)[1].split("private func framedArtwork", 1)[0]
assert re.search(r"classicArtworkOffset\(\s*for: geometry\.size\.width,\s*scale: scale,\s*effectiveScale: effectiveScale", classic)
assert "horizontalOffset: showsCompleteArtwork ? 0 : offset" in classic
assert "V3BackdropArtworkGeometry.horizontalOffset(width: width, scale: scale, effectiveScale: effectiveScale," in source

program = "import Foundation\nimport CoreGraphics\n" + geometry + r"""
for width: CGFloat in [1000, 1579, 2560] {
    for position in ["left", "center", "right"] {
        for scale: CGFloat in [0.8, 1.0, 1.4] {
            let effective = V3BackdropArtworkGeometry.imageScale(requested: scale, complete: false)
            let offset = V3BackdropArtworkGeometry.horizontalOffset(
                width: width, scale: scale, effectiveScale: effective, position: position)
            let overscan = (effective - 1) * width / 2
            if overscan <= 0 {
                precondition(offset == 0, "No overscan: the cover stays centered")
            } else {
                precondition(abs(offset) <= overscan, "The translated cover must still fill both sides")
                let other = position == "left" ? "right" : position == "right" ? "left" : "center"
                let reflected = V3BackdropArtworkGeometry.horizontalOffset(
                    width: width, scale: scale, effectiveScale: effective, position: other)
                precondition(reflected == -offset, "Left and right crop must mirror each other")
            }
        }
    }
}
print("PASS: minimum zoom centers the cover; larger framing keeps mirrored crops inside overscan")
"""
with tempfile.TemporaryDirectory(prefix="lyricsq-classic-geometry-") as folder:
    path = Path(folder)
    (path / "main.swift").write_text(program)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "contract")], check=True)
    subprocess.run([str(path / "contract")], check=True)
