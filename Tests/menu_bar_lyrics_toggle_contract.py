"""Run the real controller with isolated settings and no status item/UI creation."""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
store = (root/'SpotifyLyrics/Settings/AppSettingsStore.swift').read_text()
# Extract the actual persistence boundary for this setting, avoiding unrelated stores.
key = re.search(r'public static let menuBarLyricsEnabled = [^\n]+', store)
assert key, 'Missing persistent menu-bar lyrics setting'
prop = re.search(r'@Published public var menuBarLyricsEnabled: Bool \{\s*didSet \{[^\n]+\}\s*\}', store).group()
initial = re.search(r'^        menuBarLyricsEnabled = [^\n]+', store, re.M).group()
settings = '''import Foundation
import Combine
public final class AppSettingsStore: ObservableObject {
 static let shared = AppSettingsStore(defaults: UserDefaults(suiteName: "unused-menu-toggle-contract")!)
 enum Key { KEY }
 let defaults: UserDefaults
 PROP
 init(defaults: UserDefaults) { self.defaults = defaults; INITIAL }
}
'''.replace('KEY', key.group()).replace('PROP', prop).replace('INITIAL', initial)
host = '''import AppKit
import Combine
@main struct Contract {
 @MainActor static func main() {
  let name = "lyrics-menu-toggle-contract-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  let settings = AppSettingsStore(defaults: defaults)
  precondition(!settings.menuBarLyricsEnabled)
  let controller = MenuBarLyricsController(settings: settings)
  precondition(controller.statusItemTitle.isEmpty)
  let unchangedSnapshot = controller.currentSnapshot
  controller.menuBarLyricsEnabled = true
  precondition(controller.statusItemTitle == "Lyric Island", "external setting changes must repaint")
  precondition(controller.currentSnapshot == unchangedSnapshot, "popover content remains available")
  precondition(AppSettingsStore(defaults: defaults).menuBarLyricsEnabled)
  settings.menuBarLyricsEnabled = false
  precondition(controller.statusItemTitle.isEmpty, "must repaint without a playback event")
  precondition(!AppSettingsStore(defaults: defaults).menuBarLyricsEnabled)
  let state = PlaybackState()
  state.hasLiveTrack = true
  state.currentTrack.title = "Song"
  state.liveLyricsDocumentMatchesCurrentTrack = true
  state.liveLyricsState = .loaded
  state.liveLyricsAreSynchronized = true
  state.liveLyrics = [ProbeLine(originalText: "Current lyric")]
  state.liveCurrentLineIndex = 0
  for playing in [true, false] {
   state.isPlaying = playing
   let snapshot = MenuBarLyricsController.deriveSnapshot(from: state)
   precondition(MenuBarTextFormatter.statusItemTitle(snapshot: snapshot, lyricsEnabled: false).isEmpty)
   precondition(MenuBarTextFormatter.statusItemTitle(snapshot: snapshot, lyricsEnabled: true) == "♪ Current lyric")
   precondition(MenuBarTextFormatter.statusItemSymbol(snapshot: snapshot) == (playing ? "music.note" : "pause.fill"))
  }
  state.preferences.showTranslation = true
  state.liveLyrics = [ProbeLine(originalText: "Current lyric", translationText: "当前中文"), ProbeLine(originalText: "Next lyric", translationText: "下一句中文")]
  let translated = MenuBarLyricsController.deriveSnapshot(from: state)
  precondition(translated.currentTranslationText == "当前中文", "popover uses adopted current live line")
  state.preferences.showTranslation = false
  let hidden = MenuBarLyricsController.deriveSnapshot(from: state)
  precondition(hidden.currentTranslationText == nil, "display toggle hides translation without a request")
  precondition(translated != hidden, "changing only the translation must repaint the popover")
  state.preferences.showTranslation = true
  state.liveLyrics[0].translationText = nil
  precondition(MenuBarLyricsController.deriveSnapshot(from: state).currentTranslationText == nil, "next-line translation must never leak into current")
  print("PASS menu-bar default, persistence, immediate toggle, unchanged snapshot, playing/paused icon policy")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lyrics-menu-toggle-') as temporary:
 t = Path(temporary)
 (t/'settings.swift').write_text(settings)
 (t/'host.swift').write_text(host)
 stub=(root/'Tests/fixtures/settings_playback_stub.swift').read_text()
 stub=stub[:stub.index('struct MenuBarLyricsPopoverView: View')]
 (t/'playback.swift').write_text(stub)
 subprocess.run(['swiftc','-parse-as-library',str(t/'settings.swift'),str(t/'playback.swift'),str(root/'SpotifyLyrics/Windows/MenuBarLyricsController.swift'),str(root/'SpotifyLyrics/Views/MenuBar/MenuBarLyricsPopoverView.swift'),str(t/'host.swift'),'-o',str(t/'contract')],check=True)
 subprocess.run([str(t/'contract')],check=True)
