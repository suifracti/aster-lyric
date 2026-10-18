#!/usr/bin/env python3
"""Compile and exercise the exact Foundation-only reducer in the production file.

This is NOT a macOS GUI, frame-time, CPU, memory or WindowServer benchmark.
Run from any directory: python3 Tests/v3_edge_pointer_state_contract.py
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'SpotifyLyrics/Views/MainWindow/V3WindowEdgePlaybackOverlay.swift'
text = SOURCE.read_text(encoding='utf-8')
start = '// BEGIN EDGE INTERACTION PURE CORE'
end = '// END EDGE INTERACTION PURE CORE'
assert text.count(start) == text.count(end) == 1
core = text.split(start, 1)[1].split(end, 1)[0]
# High-rate input must not turn into a new global/animation update source.
for banned in ('@Published', 'Timer.', 'TimelineView', 'DispatchQueue', 'Task {', 'URLSession', 'NotificationCenter'):
    assert banned not in core, banned
assert 'if next != edgeInteraction { edgeInteraction = next }' in text
assert 'edgeInteraction.layout(size: size, fallbackExitPoint: exitPoint)' in text
assert 'updatePointer(point, size: size, dragging: draftFraction != nil)' in text
assert 'updatePointer(point, size: size, dragging: false)' in text
assert '.activeAlways' in text
assert 'override func hitTest(_ point: NSPoint) -> NSView? { nil }' in text
assert '.strokedPath(StrokeStyle(lineWidth: 22))' in text  # Seek band not widened.
assert 'dragTrackKey == state.currentTrackIdentity?.stableKey' in text
assert '.animation(reduceMotion ? nil : .easeOut(duration: 0.16)' in text

TESTS = r'''
private typealias State = V3WindowEdgeInteractionState
private typealias Edge = V3WindowEdgeControlPositioner.Edge
private let canvas = CGSize(width: 1210, height: 820)
private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
private func next(_ s: State, _ x: CGFloat?, _ y: CGFloat = 0, drag: Bool = false,
                  size: CGSize = canvas) -> State {
    s.updating(point: x.map { CGPoint(x: $0, y: y) }, size: size, dragging: drag)
}
private func at(_ edge: Edge, depth: CGFloat = 25, tangent: CGFloat = 400) -> CGPoint {
    switch edge {
    case .top: return CGPoint(x: tangent, y: depth)
    case .right: return CGPoint(x: canvas.width - depth, y: tangent)
    case .bottom: return CGPoint(x: tangent, y: canvas.height - depth)
    case .left: return CGPoint(x: depth, y: tangent)
    }
}
private var state = State()
for edge in [Edge.top, .right, .bottom, .left] {
    let p = at(edge)
    state = State().updating(point: p, size: canvas, dragging: false)
    expect(state.isVisible && state.anchor?.edge == edge, "wrong edge on reveal")
    let layout = state.layout(size: canvas, fallbackExitPoint: CGPoint(x: 0, y: 820))
    expect(layout.center.x.isFinite && layout.center.y.isFinite, "nonfinite center")
    expect(layout.isVertical == edge.isVertical, "orientation mismatch")
    // A far historical point must never move an active player's position.
    let other = state.layout(size: canvas, fallbackExitPoint: CGPoint(x: 1210, y: 0))
    expect(layout.center == other.center, "history overrode live approach")
}
state = next(State(), 20, 770)
state = next(state, nil)
state = next(state, 1190, 340)
expect(state.anchor?.edge == .right, "right pointer was left/bottom after re-entry")
expect(abs(state.layout(size: canvas, fallbackExitPoint: nil).center.y - 340) < 0.01, "wrong right position")

private let beforeReveal = next(State(), 1179, 400) // 31pt
expect(!beforeReveal.isVisible, "overbroad reveal")
private let atReveal = next(beforeReveal, 1180, 400) // 30pt inclusive
expect(atReveal.isVisible, "30pt failed")
private let held = next(atReveal, 1164, 470) // 46pt, outside button cluster
expect(held.isVisible && held.anchor == atReveal.anchor, "46pt failed to hold")
private let hidden = next(held, 1163, 470) // 47pt and outside corridor
expect(!hidden.isVisible, "centre-side player remained visible")
expect(!next(hidden, 1179, 400).isVisible, "hold band revealed a hidden player")
expect(!next(atReveal, nil).isVisible, "outside window did not hide")

// Same anchor while entering the actual controls; no chasing on small motion.
private let right = next(State(), 1190, 400)
private let layout = right.layout(size: canvas, fallbackExitPoint: nil)
private let overButton = next(right, layout.center.x, layout.center.y + 14)
expect(overButton == right, "button moved under pointer")
private let movedAlong = next(right, 1188, 640)
expect(movedAlong.anchor != right.anchor && movedAlong.anchor?.edge == .right, "large tangent move ignored")
private let swapped = next(movedAlong, 20, 440)
expect(swapped.anchor?.edge == .left, "changing edges failed")

// Hysteresis near a corner, without forcing every near-corner step to swap edge.
private let cornerRight = next(State(), 1190, 60)
private let cornerHeld = next(cornerRight, 1185, 23)
expect(cornerHeld.anchor?.edge == .right, "corner jitter changed edge")
private let nearTop = next(cornerRight, 1100, 10)
expect(nearTop.anchor?.edge == .top, "decisive change to top blocked")
expect(!next(State(), 20, 20).isVisible, "traffic-light region summoned controls")

// Active seek stays anchored; release in lyric centre hides. No song or seek
// services are part of this reducer; production keeps the track-identity guard.
private let dragging = next(right, 600, 400, drag: true)
expect(dragging.anchor == right.anchor && dragging.isVisible, "seek anchor not locked")
private let released = next(dragging, 600, 400, drag: false)
expect(!released.isVisible, "release in centre left stale controls")
expect(!next(dragging, nil, drag: true).isVisible, "outside during drag kept invisible hit targets")

for point in [CGPoint(x: CGFloat.nan, y: 10), CGPoint(x: 10, y: CGFloat.infinity),
              CGPoint(x: -1, y: 400), CGPoint(x: 1211, y: 400)] {
    expect(!right.updating(point: point, size: canvas, dragging: false).isVisible, "invalid pointer shown")
}
for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 820), CGSize(width: 100, height: -1)] {
    let invalid = right.updating(point: CGPoint(x: 5, y: 5), size: size, dragging: false)
    expect(!invalid.isVisible, "invalid canvas shown")
}
// Normalized anchor keeps the player in the window when it resizes.
private let resized = right.layout(size: CGSize(width: 800, height: 600), fallbackExitPoint: nil)
expect(abs(resized.center.y - (400.0 / 820.0 * 600)) < 0.01, "resize lost normalized anchor")
for size in [CGSize(width: 200, height: 120), CGSize(width: 36, height: 20),
             CGSize(width: 800, height: 600), CGSize(width: 1920, height: 1080)] {
    let fit = right.layout(size: size, fallbackExitPoint: nil)
    expect(fit.center.x >= 0 && fit.center.x <= size.width, "horizontal geometry invalid")
    expect(fit.center.y >= 0 && fit.center.y <= size.height, "vertical geometry invalid")
    expect(fit.scale >= 0 && fit.scale <= 1, "invalid scale")
}

// Regression for the user's resource concern: 10,000 moving points, no changed
// state while already in the lyric centre, nor while moving within one cluster.
private var idle = next(State(), 600, 400)
private var centreChanges = 0
for i in 0..<10_000 {
    let candidate = next(idle, 450 + CGFloat(i % 200), 250 + CGFloat(i % 240))
    if candidate != idle { centreChanges += 1; idle = candidate }
}
expect(centreChanges == 0, "mouse motion wrote lyric-centre state")
private var fixed = right
private var clusterChanges = 0
for i in 0..<10_000 {
    let candidate = next(fixed, 1185 + CGFloat(i % 10), 394 + CGFloat(i % 13))
    if candidate != fixed { clusterChanges += 1; fixed = candidate }
}
expect(clusterChanges == 0, "per-pixel motion republished fixed anchor")
private var sweeping = next(State(), 1190, 100)
private var sweepChanges = 0
for y in 101...720 {
    let candidate = next(sweeping, 1190, CGFloat(y))
    if candidate != sweeping { sweepChanges += 1; sweeping = candidate }
}
expect(sweepChanges > 0 && sweepChanges <= 8, "unbounded along-edge anchor updates")
print("PASS \(checks) checks; centre changes=\(centreChanges)/10000; cluster changes=\(clusterChanges)/10000; sweep changes=\(sweepChanges)/620")
print("Scope: exact Swift geometry/state logic only. macOS UI/CPU/RSS/frame-time NOT_RUN.")
'''
compiler = shutil.which('swiftc')
if not compiler:
    raise SystemExit('NOT_RUN: swiftc unavailable (not a PASS).')
with tempfile.TemporaryDirectory(prefix='lyric-edge-contract-') as temp:
    temp = Path(temp)
    main = temp / 'main.swift'
    main.write_text('import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n' + core + '\n' + TESTS, encoding='utf-8')
    for flags in (['-Onone'], ['-O']):
        exe = temp / ('test' + flags[0])
        subprocess.run([compiler, '-swift-version', '5', *flags, str(main), '-o', str(exe)], check=True, timeout=60)
        print('Build mode:', flags[0], flush=True)
        subprocess.run([str(exe)], check=True, timeout=20)
print('PASS: source wiring guards (not a native app build).')
