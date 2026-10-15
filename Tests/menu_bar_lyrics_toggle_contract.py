"""Run the real controller with isolated settings and no status item/UI creation."""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
store = (root/'SpotifyLyrics/Settings/AppSettingsStore.swift').read_text()
# Extract the actual persistence boundary for this setting, avoiding unrelated stores.
keys = re.findall(r'public static let menuBarLyrics\w+ = [^\n]+', store)
assert len(keys) == 7, 'Missing persistent menu-bar lyrics settings'
properties = re.findall(r'@Published public var menuBarLyrics\w+: (?:Bool|Double) \{\s*didSet \{[^\n]+\}\s*\}', store)
initial = '\n'.join(re.findall(r'^        menuBarLyrics\w+ = [^\n]+', store, re.M))
settings = '''import Foundation
import Combine
public final class AppSettingsStore: ObservableObject {
 static let shared = AppSettingsStore(defaults: UserDefaults(suiteName: "unused-menu-toggle-contract")!)
 enum Key { KEY }
 let defaults: UserDefaults
 PROP
 init(defaults: UserDefaults) { self.defaults = defaults; INITIAL }
}
'''.replace('KEY', '\n'.join(keys)).replace('PROP', '\n'.join(properties)).replace('INITIAL', initial)
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
  let full = MenuBarLyricsController.deriveFullLyricsSnapshot(from: state)!
  precondition(full.lyricsText == "Current lyric\\n当前中文\\n\\nNext lyric\\n下一句中文", "full page preserves every adopted live line and translation")
  precondition(full.copyText.contains("Song") && full.copyText.contains("Next lyric"), "copy includes the captured song and complete lyrics")
  let longLyric = String(repeating: "完整歌词不截断 ", count: 120)
  state.liveLyrics = [ProbeLine(originalText: longLyric)]
  precondition(MenuBarLyricsController.deriveFullLyricsSnapshot(from: state)!.lyricsText == longLyric.trimmingCharacters(in: .whitespacesAndNewlines))
  state.liveLyricsDocumentMatchesCurrentTrack = false
  precondition(MenuBarLyricsController.deriveFullLyricsSnapshot(from: state) == nil, "a mismatched live document cannot appear in the full page")
  state.liveLyricsDocumentMatchesCurrentTrack = true
  state.isMockPreviewMode = true
  precondition(MenuBarLyricsController.deriveFullLyricsSnapshot(from: state) == nil, "mock preview cannot appear in the live page")
  state.isMockPreviewMode = false
  state.liveLyrics = [ProbeLine(originalText: "Current lyric", translationText: "当前中文"), ProbeLine(originalText: "Next lyric", translationText: "下一句中文")]
  let translated = MenuBarLyricsController.deriveSnapshot(from: state)
  precondition(translated.currentTranslationText == "当前中文", "popover uses adopted current live line")
  state.preferences.showTranslation = false
  precondition(MenuBarLyricsController.deriveFullLyricsSnapshot(from: state)!.lyricsText == full.lyricsText, "main-window visibility must not crop the independent complete lyrics page")
  let hidden = MenuBarLyricsController.deriveSnapshot(from: state)
  precondition(hidden.currentTranslationText == "当前中文", "main-window display toggle must not remove available menu-bar translation")
  precondition(translated == hidden, "main-window visibility must not change the independent menu-bar snapshot")
  state.preferences.showTranslation = true
  state.liveLyrics[0].translationText = nil
  precondition(MenuBarLyricsController.deriveSnapshot(from: state).currentTranslationText == nil, "next-line translation must never leak into current")
  let help = MenuBarTextFormatter.statusItemHelp(snapshot: translated)
  precondition(help.contains("Song") && help.contains("Current lyric") && help.contains("当前中文"), "tooltip keeps full metadata and line content")
  state.liveLyrics = [ProbeLine(originalText: longLyric, translationText: "译文", kanaText: "かな", romajiText: "kana")]
  let layered = MenuBarLyricsController.deriveSnapshot(from: state)
  let fullAppearance = MenuBarLyricsAppearance(showsFullLine: true)
  let completeTitle = MenuBarTextFormatter.statusItemTitle(snapshot: layered, lyricsEnabled: true, appearance: fullAppearance)
  precondition(completeTitle == "♪ " + longLyric.trimmingCharacters(in: .whitespacesAndNewlines), "complete mode must not apply the 240pt crop")
  let compactTitle = MenuBarTextFormatter.statusItemTitle(snapshot: layered, lyricsEnabled: true)
  precondition(compactTitle.hasSuffix("…") && compactTitle.count < completeTitle.count, "compact mode retains its bounded title")
  let readings = MenuBarLyricsAppearance(showsFullLine: true, showsOriginal: false, showsTranslation: true, showsKana: true, showsRomaji: true)
  precondition(MenuBarTextFormatter.statusItemTitle(snapshot: layered, lyricsEnabled: true, appearance: readings) == "♪ 译文 · かな · kana")
  var absent = layered
  absent.currentTranslationText = nil; absent.currentKanaText = nil; absent.currentRomajiText = nil
  precondition(MenuBarTextFormatter.statusItemTitle(snapshot: absent, lyricsEnabled: true, appearance: readings) == "♪ Song", "missing selected readings retain the song title")
  for (input, expected) in [(Double.nan, 13.0), (Double.infinity, 13.0), (-10.0, 10.0), (999.0, 18.0)] {
   precondition(MenuBarLyricsAppearance(fontSize: input).effectiveFontSize == expected, "invalid font preferences must be bounded before AppKit")
  }
  var titleUpdates = 0
  let observation = controller.$statusItemTitle.sink { _ in titleUpdates += 1 }
  let beforeChange = titleUpdates
  settings.menuBarLyricsShowsFullLine = true
  settings.menuBarLyricsShowsOriginal = false
  settings.menuBarLyricsShowsTranslation = true
  settings.menuBarLyricsShowsKana = true
  settings.menuBarLyricsShowsRomaji = true
  settings.menuBarLyricsFontSize = 16
  precondition(titleUpdates >= beforeChange + 6, "every appearance change refreshes without a playback event")
  let restored = AppSettingsStore(defaults: defaults)
  precondition(restored.menuBarLyricsShowsFullLine && !restored.menuBarLyricsShowsOriginal && restored.menuBarLyricsShowsTranslation && restored.menuBarLyricsShowsKana && restored.menuBarLyricsShowsRomaji && restored.menuBarLyricsFontSize == 16)
  withExtendedLifetime(observation) {}
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
