"""Exercise the native drag handle without creating an App or window."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / "SpotifyLyrics/Views/Floating/FloatingLyricsView.swift").read_text()
controller = (root / "SpotifyLyrics/Windows/FloatingLyricsWindowController.swift").read_text()
drag = controller[controller.index("    func beginDragging(with event:"):controller.index("    func close()")]
for protection in ["interactionMode == .interactive", "panel.isMovable", "!panel.ignoresMouseEvents",
                   "event.window === panel", "event.type == .leftMouseDown", "panel.performDrag(with: event)"]:
    assert protection in drag, f"Native drag lost protection: {protection}"
ribbon = view[view.index("private struct FloatingDesktopRibbon<"):view.index("private struct FloatingLyricsDragHandle:")]
assert "if canScroll {\n                ribbon.gesture" in ribbon, "Only an overflowing line may consume horizontal drags"
offset = ribbon[ribbon.index("private var offset:"):ribbon.index("var body: some View")]
assert "guard allowsMotion" not in offset, "Paused/reduced-motion rows must retain manual scrolling"
handle = view[view.index("private final class FloatingLyricsDragHandleView:"):view.index("private struct FloatingRibbonWidthKey:")]
host = """import AppKit
""" + handle + """
@main struct Contract {
    @MainActor static func main() {
        let handle = FloatingLyricsDragHandleView(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        var calls = 0
        handle.onMouseDown = { _ in calls += 1 }
        precondition(!handle.acceptsFirstMouse(for: event))
        precondition(handle.hitTest(NSPoint(x: 10, y: 10)) == nil)
        handle.mouseDown(with: event)
        precondition(calls == 0, "disabled drag handle must never dispatch")
        handle.isEnabled = true
        precondition(handle.acceptsFirstMouse(for: event), "moving a floating window must work without prior activation")
        precondition(handle.hitTest(NSPoint(x: 10, y: 10)) === handle)
        handle.mouseDown(with: event)
        precondition(calls == 1)
        handle.isEnabled = false
        handle.mouseDown(with: event)
        precondition(calls == 1, "locking again immediately disables dragging")
        print("PASS: native handle hit testing/first click/lock transition; controller and ribbon protections")
    }
}
"""
with tempfile.TemporaryDirectory(prefix="lyrics-floating-drag-") as folder:
    source = Path(folder) / "contract.swift"
    executable = Path(folder) / "contract"
    source.write_text(host)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
