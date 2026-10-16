#!/usr/bin/env python3
"""Contract test for V3 Classic backdrop geometry symmetry and overscan clamping."""

from pathlib import Path
import sys

def test_geometry():
    root = Path(__file__).resolve().parent.parent
    backdrop_file = root / "SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift"
    content = backdrop_file.read_text(encoding="utf-8")

    # 1. Verify code markers in AppleMusicImmersiveV3BackdropView.swift
    assert "classicArtworkOffset(for: geometry.size.width, scale: scale, effectiveScale: effectiveScale)" in content, \
        "legacyArtworkLayers must pass scale and effectiveScale to classicArtworkOffset"
    assert "guard scale > 0.8 else { return 0 }" in content, \
        "classicArtworkOffset must center (return 0) at minimum scale (scale <= 0.8)"
    assert "let availableOverscan = max(0, (effectiveScale - 1.0) * width * 0.5)" in content, \
        "classicArtworkOffset must compute overscan dynamically"
    assert "return min(availableOverscan, max(-availableOverscan, requestedOffset))" in content, \
        "classicArtworkOffset must clamp offset to available overscan"

    # Verify that the old asymmetric .mask in Layer 2 was removed
    assert "LinearGradient(\n                            stops: [\n                                .init(color: .black, location: 0.00)," not in content, \
        "Layer 2 must not use asymmetric mask that creates one-sided blank"

    # 2. Mathematical simulation of geometry across 80%, 100%, 140%
    style_artwork_scale = 1.36  # BackdropPresentationID.defaultV1.style.artworkScale
    window_widths = [1000.0, 1200.0, 1579.0, 1920.0, 2560.0]

    for w in window_widths:
        for position in ["left", "center", "right"]:
            # Helper function mimicking Swift classicArtworkOffset
            def calc_offset(scale, effective_scale):
                if scale <= 0.8:
                    return 0.0
                progress = (scale - 0.8) / (1.4 - 0.8)
                target_ratio = 0.10 if position == "right" else (0.0 if position == "center" else -0.10)
                requested = target_ratio * w * progress
                overscan = max(0.0, (effective_scale - 1.0) * w * 0.5)
                return min(overscan, max(-overscan, requested))

            # Test at 80% (scale = 0.8)
            scale_80 = 0.8
            eff_scale_80 = style_artwork_scale * scale_80  # 1.088
            offset_80 = calc_offset(scale_80, eff_scale_80)
            assert offset_80 == 0.0, f"Offset at 80% must be exactly 0, got {offset_80}"

            left_edge_80 = w / 2.0 - (w * eff_scale_80) / 2.0 + offset_80
            right_edge_80 = w / 2.0 + (w * eff_scale_80) / 2.0 + offset_80
            left_margin_80 = -left_edge_80
            right_margin_80 = right_edge_80 - w
            diff_80 = abs(left_margin_80 - right_margin_80)
            assert diff_80 < 1e-9, f"Left/right margin difference at 80% must be 0, got {diff_80}"
            assert left_edge_80 <= 0.0 and right_edge_80 >= w, "Image at 80% must cover full viewport"

            # Test at 100% (scale = 1.0)
            scale_100 = 1.0
            eff_scale_100 = style_artwork_scale * scale_100  # 1.36
            offset_100 = calc_offset(scale_100, eff_scale_100)
            left_edge_100 = w / 2.0 - (w * eff_scale_100) / 2.0 + offset_100
            right_edge_100 = w / 2.0 + (w * eff_scale_100) / 2.0 + offset_100
            assert left_edge_100 <= 0.0 and right_edge_100 >= w, \
                f"Image at 100% must cover full viewport without gaps (pos: {position})"

            # Test at 140% (scale = 1.4)
            scale_140 = 1.4
            eff_scale_140 = style_artwork_scale * scale_140  # 1.904
            offset_140 = calc_offset(scale_140, eff_scale_140)
            left_edge_140 = w / 2.0 - (w * eff_scale_140) / 2.0 + offset_140
            right_edge_140 = w / 2.0 + (w * eff_scale_140) / 2.0 + offset_140
            assert left_edge_140 <= 0.0 and right_edge_140 >= w, \
                f"Image at 140% must cover full viewport without gaps (pos: {position})"

    print("PASS: V3 classic backdrop geometry symmetry at 80% (left/right margin delta = 0) and overscan clamp across 80–140%")

if __name__ == "__main__":
    test_geometry()
