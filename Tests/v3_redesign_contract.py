#!/usr/bin/env python3
"""Exact scene metadata, normalization and external-panel geometry contracts.
These do not claim user-Mac rendering, frame rates, or a full UI automation pass.
"""
from pathlib import Path
import shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
settings=(ROOT/'SpotifyLyrics/Settings/AppSettingsStore.swift').read_text()
controls=(ROOT/'SpotifyLyrics/Views/Components/LyricIslandControls.swift').read_text()
window=(ROOT/'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
backdrop=(ROOT/'SpotifyLyrics/Views/Components/AppleMusicImmersiveV3BackdropView.swift').read_text()
a=settings.index('public enum V3ArtworkTheme:')
b=settings.index('public enum PlaybackSourceMode:',a)
models=settings[a:b]
geometry=controls.split('// BEGIN EXTERNAL PANEL GEOMETRY',1)[1].split('// END EXTERNAL PANEL GEOMETRY',1)[0]
checks=r'''
var count=0
func expect(_ p:@autoclosure () -> Bool,_ reason:String) { count+=1; precondition(p(),reason) }
expect(V3ListeningScene.allCases.count==5,"five complete scenes")
expect(V3ArtworkPresentation.allCases.count==8,"eight legacy renderer identities retained")
let all=V3ListeningScene.allCases.flatMap(\.renderers)
expect(Set(all)==Set(V3ArtworkPresentation.allCases),"no loved renderer lost")
expect(V3ListeningScene.flowingField.renderers.contains(.ambientFeathered),"full feather renderer reachable")
expect(V3ListeningScene.coverPhoto.renderers.contains(.classicGaussian),"classic Gaussian reachable")
expect(Set(V3ListeningScene.allCases.map(\.rawValue)).isDisjoint(with:Set(V3ArtworkPresentation.allCases.map(\.rawValue))),"scene IDs replace old renderer IDs")
for scene in V3ListeningScene.allCases {
 for renderer in scene.renderers {
  var preset=V3ScenePreset.initial(scene:scene,renderer:renderer)
  let decoded=try! JSONDecoder().decode(V3ScenePreset.self,from:JSONEncoder().encode(preset))
  expect(decoded==preset,"persist finite independent preset")
  preset.blur = .nan; preset.foregroundScale = .infinity; preset.backdropScale = -100
  preset.foregroundPosition="invalid"; preset.lyricsPosition="wrong"; preset.atmosphere=99
  let normalized=preset.normalized()
  expect(normalized.blur.isFinite && (0...100).contains(normalized.blur),"invalid blur")
  expect(normalized.foregroundScale.isFinite && (0.8...1.4).contains(normalized.foregroundScale),"invalid foreground")
  expect((0.8...1.4).contains(normalized.backdropScale),"invalid backdrop")
  expect(normalized.atmosphere==2,"invalid motion level")
 }
}
let visible=CGRect(x:0,y:0,width:1800,height:1100)
let requested=CGSize(width:360,height:720)
let owner=CGRect(x:100,y:180,width:900,height:800)
let right=LyricIslandPanelPlacement.frame(owner:owner,visible:visible,requested:requested)
expect(right.minX==owner.maxX+12,"right gap")
expect(!right.intersects(owner),"right inspector changes/occludes available canvas")
let wideOwner=CGRect(x:760,y:180,width:900,height:800)
let edge=LyricIslandPanelPlacement.frame(owner:wideOwner,visible:visible,requested:requested)
expect(edge.maxX==min(wideOwner.maxX,visible.maxX-8)-12 && edge.minX>wideOwner.minX && edge.maxY<=wideOwner.maxY-64,"no room on the right docks inside the right edge below the toolbar, never left")
for screen in [visible,CGRect(x:-1600,y:-100,width:1600,height:1000),CGRect(x:0,y:0,width:600,height:420)] {
 let full=CGRect(x:screen.minX,y:screen.minY,width:screen.width,height:screen.height)
 let panel=LyricIslandPanelPlacement.frame(owner:full,visible:screen,requested:requested)
 expect(screen.contains(panel),"floating panel off owner screen")
 expect(full.width==screen.width,"owner canvas changed")
}
for canvasHeight: CGFloat in [400, 500, 640, 820, 1080] {
 for footerHeight: CGFloat in [0, 44] {
  let field=LyricIslandSceneBudget.fieldReadingHeight(canvasHeight:canvasHeight,footerHeight:footerHeight)
  let fieldTotal=84+24+28+16+field+(footerHeight>0 ? footerHeight+16 : 0)
  expect(abs(fieldTotal-canvasHeight)<0.01,"flow scene overflows the window")
  for headerHeight: CGFloat in [80,104] {
   let reading=LyricIslandSceneBudget.linerReadingHeight(canvasHeight:canvasHeight,headerHeight:headerHeight,footerHeight:footerHeight)
   let total=76+24+headerHeight+1+36+reading+(footerHeight>0 ? footerHeight+18 : 0)
   expect(abs(total-canvasHeight)<0.01,"liner scene hides its footer below the window")
  }
 }
}
print("PASS \(count) scene/normalization/placement assertions")
'''
compiler=shutil.which('swiftc')
if not compiler: raise SystemExit('NOT_RUN: swiftc missing')
with tempfile.TemporaryDirectory(prefix='lyric-redesign-contract-') as d:
 p=Path(d);(p/'main.swift').write_text('import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n'+models+geometry+checks)
 subprocess.run([compiler,'-swift-version','5','-O',str(p/'main.swift'),'-o',str(p/'test')],check=True,timeout=90)
 subprocess.run([str(p/'test')],check=True,timeout=20)
# Actual source boundaries, not tests tied to whether a particular title was renamed.
assert 'let canvasWidth = max(1, geometry.size.width)' in window
assert 'geometry.size.width - inspectorWidth' not in window
assert '.fittingSize' not in window[window.index('private struct V3PinnedInspectorPanelHost'):window.index('private struct QuietToolbarButtonStyle')]
popover_host=window[window.index('func v3ToolPopover<Content: View>'):window.index('private struct V3PinnedInspectorPanelHost')]
pinned_host=window[window.index('private struct V3PinnedInspectorPanelHost'):window.index('private struct QuietToolbarButtonStyle')]
assert 'v3ToolPanelRoot(content())' in popover_host, 'hover tool content must override the listening canvas color scheme'
assert pinned_host.count('v3ToolPanelRoot(parent.content)') >= 2, 'pinned tool content must override inherited dark color scheme on create and update'
assert 'isProjectingScene = true' in settings and 'selectLegacyV3Presentation' in settings
assert 'scenePresets[Self.sceneKey(scene, renderer)]' in settings
assert 'sceneOverride: compositionScene' in window
assert '.onChange(of: timeline.date)' not in backdrop[backdrop.index('struct V3AtmosphereFieldView'):]
assert 'Timer.' not in controls and 'URLSession' not in controls
assert '.activeAlways' in (ROOT/'SpotifyLyrics/Views/MainWindow/V3WindowEdgePlaybackOverlay.swift').read_text()
print('PASS structural boundaries; native GUI/performance NOT_RUN')

# A zero-height frame alone does not remove controls or their hit regions.
focus=window[window.index('private func lyricsOnlyLayout'):window.index('private func albumPosterLayout')]
assert 'if footerHeight > 0 {' in focus
notes=window[window.index('private func linerNotesLayout'):window.index('private func sceneTransport')]
assert 'coverColumnWidth / 1.4 * coverScale' in notes
assert 'coverWidth * min(1,' not in notes
menu=(ROOT/'SpotifyLyrics/Windows/MenuBarLyricsController.swift').read_text()
assert 'Double(animationDistance) / 22' in menu and 'min(60, max(2' not in menu
assert 'Double(input)' in controls and 'formatter.number(from: draft)' not in controls
print('PASS empty playback footprint, finite cover scaling, full numeric input and constant marquee speed guards')

field=window[window.index('private func fieldReadingLayout'):window.index('private func photographicLayout')]
assert 'LyricIslandSceneBudget.fieldReadingHeight' in field and 'if footerHeight > 0' in field
assert 'LyricIslandSceneBudget.linerReadingHeight' in notes and 'if footerHeight > 0' in notes
print('PASS bounded narrow/short scene geometry with and without standard playback')
