"""Source lifecycle guard; not a claim of physical status-item click acceptance."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'SpotifyLyrics/Windows/MenuBarLyricsController.swift').read_text()
start = source.index('@objc private func statusItemClicked')
end = source.index('private func handlePlaybackStateChange', start)
opening = source[start:end]
activate = opening.index('NSRunningApplication.current.activate(options: [])')
show = opening.index('popover.show(')
assert activate < show, 'activate the app before showing a transient popover; later activation can dismiss it'
assert 'DispatchQueue.main.async' in opening[activate:show], 'finish the opening mouse-up/activation turn before presenting'
assert opening.index('updatePopoverContentSize()', activate) < show, 'measure and apply the first frame before showing'
assert 'popover.performClose(sender)' in opening, 'a repeated status click must retain the close path'
assert 'applicationBeforePopover = frontmost?' in opening, 'keep the previous app for auxiliary window actions'
size = opening[opening.index('private func updatePopoverContentSize'):]
assert 'DispatchQueue.main.async' not in size, 'first-show measurement must complete synchronously'
assert 'popover.contentSize = size' in size and 'view.frame.size = size' in size
assert 'popover.contentSize != size' in size, 'unchanged dimensions must not trigger another layout'
assert 'pop.behavior = .transient' in source, 'outside click/Escape behavior stays native'
assert 'override func hitTest(_ point: NSPoint) -> NSView? { nil }' in source, 'marquee content must not intercept the status button'
print('PASS menu-bar opening activation, first-frame sizing, close path and hit-test lifecycle guards')

if sys.platform == 'darwin':
    def block(start):
        begin = source.index(start)
        opening_brace = source.index('{', begin)
        depth, end = 1, opening_brace + 1
        while depth:
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        return source[begin:end]

    # Use the exact native hosting and measurement code without showing a
    # status item/window, accessing preferences, or activating another app.
    native = '''import AppKit
import SwiftUI
@MainActor
HOST_VIEW
@MainActor
HOST_CONTROLLER
@MainActor final class Probe {
 let popover: NSPopover? = NSPopover()
 MEASUREMENT
 func measure() -> Bool { updatePopoverContentSize() }
}
@main struct Contract {
 @MainActor static func main() {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let probe = Probe()
  let host = MenuBarPopoverHostingController(rootView: Text("Fixture").frame(width: 340, height: 380))
  probe.popover!.contentViewController = host
  probe.popover!.contentSize = .zero
  precondition(probe.measure())
  precondition(probe.popover!.contentSize == NSSize(width: 340, height: 380), "first presentation must already have a usable frame")
  precondition(host.view.frame.size == probe.popover!.contentSize)
  precondition(host.view.acceptsFirstMouse(for: nil))
  let size = probe.popover!.contentSize
  precondition(probe.measure() && probe.popover!.contentSize == size, "unchanged content must keep its size")
  precondition(!probe.popover!.isShown, "the sizing test must not open user UI")
  print("PASS native first-frame measurement, stable repeat sizing and first-click hosting")
 }
}
'''
    native = native.replace('HOST_VIEW', block('final class MenuBarPopoverHostingView'))
    native = native.replace('HOST_CONTROLLER', block('final class MenuBarPopoverHostingController'))
    native = native.replace('MEASUREMENT', block('private func updatePopoverContentSize'))
    with tempfile.TemporaryDirectory(prefix='lyrics-menu-opening-') as temporary:
        directory = Path(temporary)
        swift = directory / 'main.swift'
        swift.write_text(native)
        binary = directory / 'contract'
        subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=20)
print('Scope: source wiring/native offscreen sizing; physical background-app click acceptance is separate.')
