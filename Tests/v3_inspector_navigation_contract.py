"""Exercise the production inspector transitions without opening windows."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()

def method(name):
    start = source.index('    private func ' + name + '(')
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func', 1)

methods = '\n'.join(method(n) for n in ['presentToolbarPopover', 'togglePinnedToolbarPanel',
    'dismissPinnedToolbarPanel', 'toolbarTriggerHover', 'scheduleToolbarDismissal'])
program = '''import Foundation
@MainActor final class Inspector {
 enum ToolbarPopover { case adjust, more }
 var activeToolbarPopover: ToolbarPopover?
 var pinnedToolbarPanel: ToolbarPopover?
 var hoveredToolbarTrigger: ToolbarPopover?
 var hoveredToolbarPanel: ToolbarPopover?
 var hoveredStyle: String?
 var toolbarDismissTask: Task<Void, Never>?
 var toolbarMenuDepth = 0
 var isWindowMenuPresented = false
 var isSearchPresented = false
 METHODS
}
@main struct Check {
 @MainActor static func main() {
  let ui = Inspector()
  ui.toolbarTriggerHover(.adjust, inside: true)
  precondition(ui.activeToolbarPopover == .adjust && ui.pinnedToolbarPanel == nil)
  ui.togglePinnedToolbarPanel(.adjust)
  precondition(ui.activeToolbarPopover == nil && ui.pinnedToolbarPanel == .adjust)
  ui.toolbarTriggerHover(.more, inside: true)
  precondition(ui.pinnedToolbarPanel == .adjust && ui.activeToolbarPopover == nil)
  ui.togglePinnedToolbarPanel(.adjust)
  precondition(ui.pinnedToolbarPanel == nil && ui.activeToolbarPopover == nil)
  ui.toolbarTriggerHover(.more, inside: true)
  precondition(ui.activeToolbarPopover == .more)
  ui.togglePinnedToolbarPanel(.more)
  ui.togglePinnedToolbarPanel(.adjust)
  precondition(ui.pinnedToolbarPanel == .adjust)
  ui.hoveredStyle = "temporary-preview"
  ui.dismissPinnedToolbarPanel()
  precondition(ui.pinnedToolbarPanel == nil && ui.activeToolbarPopover == nil && ui.hoveredStyle == nil)
  print("PASS production inspector hover, pin, ignore other hover, repeat close, explicit switch and dismissal")
 }
}
'''.replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='lyrics-inspector-') as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(program)
    binary = Path(directory) / 'contract'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
