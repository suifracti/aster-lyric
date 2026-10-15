#!/usr/bin/env python3
"""Exercise the production V3 preferences in an isolated defaults suite.

Only the settings section is compiled: this avoids loading playback, the real
library, or the shared settings singleton for a visual-preference contract.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "SpotifyLyrics/Settings/AppSettingsStore.swift").read_text()
presentation = source[source.index("public enum V3ArtworkPresentation"):source.index("/// Active playback provider")]
keys = source[source.index("    public enum Key {"):source.index("    public static let currentSettingsVersion")]
properties = source[source.index("    @Published public var v3PlaybackDetailsOnHover"):source.index("    /// Model names are non-secret")]
initialization = source[source.index("        let legacyBlur ="):source.index("        let storedLayout =")]

harness = """import Foundation
import Combine
""" + presentation + """
final class AppSettingsStore {
""" + keys + """
    private let defaults: UserDefaults
    private var v3BlurByPresentation: [V3ArtworkPresentation: Double] = [:]
    private var isApplyingStoredV3Blur = false
""" + properties + """
    init(defaults: UserDefaults) {
        self.defaults = defaults
""" + initialization + """
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let suite = "org.lyricsq.contract.classic-scale." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
defaults.set(V3ArtworkPresentation.classic.rawValue, forKey: AppSettingsStore.Key.v3ArtworkPresentation)
defaults.set(1.3, forKey: AppSettingsStore.Key.v3ArtworkSizeScale)
defaults.set("right", forKey: AppSettingsStore.Key.v3ArtworkPosition)
let originalDomain = defaults.persistentDomain(forName: suite)!
let settings = AppSettingsStore(defaults: defaults)
check(settings.v3ExpandArtworkWhenDetailsHidden, "hidden playback restores bounded cover expansion by default")
check(!settings.v3AmbientBackgroundShowsCompleteArtwork, "ambient background retains fill by default")
check(settings.v3ArtworkSizeScale == 1.3, "migration preserves foreground appearance")
check(settings.v3ClassicBackdropSizeScale == 1.3, "migration preserves background appearance")
for (key, value) in originalDomain {
    check((defaults.object(forKey: key) as? NSObject)?.isEqual(value) == true,
          "migration must not overwrite old preference keys")
}

settings.v3ArtworkSizeScale = 0.8
check(settings.v3ClassicBackdropSizeScale == 1.3, "foreground resize must not resize background")
let afterForeground = AppSettingsStore(defaults: defaults)
check(afterForeground.v3ClassicBackdropSizeScale == 1.3,
      "background remains unchanged after restart before its first edit")
check(afterForeground.v3ArtworkSizeScale == 0.8, "foreground survives restart")

settings.v3ClassicBackdropSizeScale = 1.1
settings.v3ExpandArtworkWhenDetailsHidden = false
settings.v3AmbientBackgroundShowsCompleteArtwork = true
check(settings.v3ArtworkSizeScale == 0.8, "background resize must not resize foreground")
check(settings.v3PreviewBackdropScale(for: .classic) == 1.1, "classic preview uses background size")
check(settings.v3PreviewScale(for: .classic) == 0.8, "classic foreground preview uses foreground size")

let beforePreview = defaults.persistentDomain(forName: suite)!
for style in V3ArtworkPresentation.allCases {
    _ = settings.v3PreviewBackdropScale(for: style)
    _ = settings.v3PreviewScale(for: style)
    _ = settings.v3PreviewPosition(for: style)
    _ = settings.v3PreviewLyricsPosition(for: style)
    _ = settings.v3PreviewBlur(for: style)
    _ = settings.v3ExpandArtworkWhenDetailsHidden
    _ = settings.v3AmbientBackgroundShowsCompleteArtwork
}
check(NSDictionary(dictionary: beforePreview).isEqual(to: defaults.persistentDomain(forName: suite)!),
      "hover preview must not write preferences")

settings.v3ArtworkPresentation = .ambient
settings.v3ArtworkSizeScale = 1.4
check(settings.v3PreviewBackdropScale(for: .ambient) == 1.4, "other modes retain their scale behavior")
check(settings.v3PreviewBackdropScale(for: .classic) == 1.1, "other mode edits do not change classic background")
settings.v3ArtworkPresentation = .ambientFeathered
settings.v3ArtworkSizeScale = 0.9
settings.v3ArtworkPresentation = .classic
check(settings.v3ArtworkSizeScale == 1.4, "classic retains the established shared foreground scale")
check(settings.v3ClassicBackdropSizeScale == 1.1, "mode switching preserves independent background")
let reopened = AppSettingsStore(defaults: defaults)
check(reopened.v3ArtworkSizeScale == 1.4 && reopened.v3ClassicBackdropSizeScale == 1.1,
      "both dimensions survive restart independently")
check(reopened.v3PreviewScale(for: .ambientFeathered) == 0.9, "feathered scale remains independent")
check(!reopened.v3ExpandArtworkWhenDetailsHidden && reopened.v3AmbientBackgroundShowsCompleteArtwork,
      "expansion and ambient fit choices survive style switching and restart independently")
check(reopened.v3PreviewBlur(for: .classic) == settings.v3PreviewBlur(for: .classic),
      "ambient fit and cover expansion must not change remembered blur")
print("PASS: independent V3 preferences, classic migration, legacy keys, read-only previews")
"""

with tempfile.TemporaryDirectory(prefix="lyricsq-classic-scale-") as folder:
    swift = Path(folder) / "main.swift"
    executable = Path(folder) / "contract"
    swift.write_text(harness)
    subprocess.run(["swiftc", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
