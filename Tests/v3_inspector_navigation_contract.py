"""Exercise the production inspector transitions without opening windows.

The rules now live in V3ToolbarModel; this keeps the original hover, pin,
ignore-other-hover, repeat-close, switch and dismissal sequence, and checks
that the view routes through the model and clears the hover preview.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
model = root / 'SpotifyLyrics/Views/MainWindow/V3ToolbarModel.swift'

assert '@State private var toolbar = V3ToolbarModel()' in view, 'view must own one toolbar model'
assert '.onChange(of: toolbar.mode) { old, new in toolbarModeChanged(from: old, to: new) }' in view
changed = view[view.index('private func toolbarModeChanged('):]
assert 'hoveredStyle = nil' in changed[:changed.index('\n    }\n')], 'mode change must clear the hover preview'
for removed in ('togglePinnedToolbarPanel', 'presentToolbarPopover', 'hoveredToolbarTrigger', 'toolbarMenuDepth'):
    assert removed not in view, f'{removed} reintroduced outside the model'

program = '''@main struct Check {
 static func main() {
  var ui = V3ToolbarModel()
  _ = ui.pointerOnTrigger(.adjust, inside: true)
  precondition(ui.hoverPanel == .adjust && ui.pinnedPanel == nil)
  ui.click(.adjust)
  precondition(ui.hoverPanel == nil && ui.pinnedPanel == .adjust)
  _ = ui.pointerOnTrigger(.more, inside: true)
  precondition(ui.pinnedPanel == .adjust && ui.hoverPanel == nil)
  ui.click(.adjust)
  precondition(ui.pinnedPanel == nil && ui.hoverPanel == nil)
  _ = ui.pointerOnTrigger(.more, inside: true)
  precondition(ui.hoverPanel == .more)
  ui.click(.more)
  ui.click(.adjust)
  precondition(ui.pinnedPanel == .adjust)
  ui.dismiss()
  precondition(ui.pinnedPanel == nil && ui.hoverPanel == nil)
  print("PASS production inspector hover, pin, ignore other hover, repeat close, explicit switch and dismissal")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lyrics-inspector-') as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(program)
    binary = Path(directory) / 'contract'
    subprocess.run(['swiftc', '-parse-as-library', str(model), str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
