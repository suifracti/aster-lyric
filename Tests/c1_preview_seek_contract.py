"""Exercise production lyric-row guards with a seek-I/O spy.

--source-only checks wiring without claiming Swift execution.
The default command compiles and runs the extracted production methods.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
state_source = (root / 'SpotifyLyrics/Services/PlaybackState.swift').read_text()


def block(signature, text):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


identity_property = block('public var canSeekDisplayedLyrics: Bool', state_source)
seek_method = block('public func seekFromDisplayedLyrics(', state_source)
assert 'documentIdentity: TrackIdentity' in seek_method, 'row origin identity is missing'
assert 'documentRevision: UInt64' in seek_method, 'row origin revision is missing'
assert 'documentSource: LyricsSeekDocumentSource' in seek_method, 'row origin session is missing'
assert 'guard canSeekDisplayedLyrics' in seek_method, 'existing preview gate must remain'
assert 'documentIdentity == TrackIdentity(track: currentTrack)' in seek_method
assert 'activeIdentity == documentIdentity' in seek_method
assert 'currentRevision == documentRevision' in seek_method
assert 'guard isShowingSearchPreview else { return false }' in seek_method
assert 'lyricsSession.revision' in seek_method and 'searchPreviewSession.revision' in seek_method
assert 'lyricsSession.activeIdentity' in seek_method and 'searchPreviewSession.activeIdentity' in seek_method
assert seek_method.index('currentRevision == documentRevision') < seek_method.index('seek(to: position')
source_enum = block('public enum LyricsSeekDocumentSource', state_source)
identity_property = identity_property.replace('public var', 'var', 1)
seek_method = seek_method.replace('public func', 'func', 1)
source_enum = source_enum.replace('public enum', 'enum', 1)

program = '''import Foundation

final class SessionProbe {
    var activeIdentity: TrackIdentity?
    var revision: UInt64
    init(identity: TrackIdentity?, revision: UInt64) {
        self.activeIdentity = identity
        self.revision = revision
    }
}
final class PreviewGuardProbe {
    var isShowingSearchPreview: Bool
    var displayedTrack: Track
    var currentTrack: Track
    var liveTrackIdentity: TrackIdentity?
    let isMockPreviewMode: Bool
    let lyricsSession: SessionProbe
    let searchPreviewSession: SessionProbe
    var seeks: [Double] = []

    init(isPreview: Bool, displayedTrack: Track, liveTrack: Track?,
         liveRevision: UInt64 = 10, previewRevision: UInt64 = 3, isMock: Bool = false) {
        let liveIdentity: TrackIdentity? = isMock ? nil : liveTrack.map(TrackIdentity.init(track:))
        self.isShowingSearchPreview = isPreview
        self.displayedTrack = displayedTrack
        self.currentTrack = liveTrack ?? displayedTrack
        self.liveTrackIdentity = liveIdentity
        self.isMockPreviewMode = isMock
        self.lyricsSession = SessionProbe(identity: liveIdentity, revision: liveRevision)
        self.searchPreviewSession = SessionProbe(
            identity: isPreview ? TrackIdentity(track: displayedTrack) : nil,
            revision: previewRevision)
    }
    func replaceLive(with track: Track, revision: UInt64) {
        currentTrack = track
        liveTrackIdentity = TrackIdentity(track: track)
        lyricsSession.activeIdentity = liveTrackIdentity
        lyricsSession.revision = revision
        if !isShowingSearchPreview { displayedTrack = track }
    }
ORIGIN
IDENTITY
    func seek(to position: TimeInterval, source: String) { seeks.append(position) }
SEEK
}
func attempt(_ probe: PreviewGuardProbe, _ time: Double, _ identity: TrackIdentity,
             _ revision: UInt64, _ origin: PreviewGuardProbe.LyricsSeekDocumentSource) -> Bool {
    probe.seekFromDisplayedLyrics(to: time, documentIdentity: identity,
        documentRevision: revision, documentSource: origin, source: "contract-row")
}
let liveA = Track(id: "a", title: "A", artist: "artist", album: "album", duration: 180, spotifyId: "spotify-a")
let liveB = Track(id: "b", title: "B", artist: "artist", album: "album", duration: 300, spotifyId: "spotify-b")
let identityA = TrackIdentity(track: liveA)
let identityB = TrackIdentity(track: liveB)

let cross = PreviewGuardProbe(isPreview: true, displayedTrack: liveB, liveTrack: liveA)
precondition(!cross.canSeekDisplayedLyrics)
precondition(!attempt(cross, 42, identityB, 3, .searchPreview), "preview B must not control live A")
precondition(!attempt(cross, 42, identityA, 10, .live), "live origin must not bypass the existing preview gate")
precondition(cross.seeks.isEmpty)

let same = PreviewGuardProbe(isPreview: true, displayedTrack: liveA, liveTrack: liveA)
precondition(same.canSeekDisplayedLyrics)
precondition(attempt(same, 42, identityA, 3, .searchPreview), "same-song preview remains legal")
precondition(attempt(same, 18, identityA, 10, .live), "fullscreen uses live revision while same-song preview is displayed")
precondition(same.seeks == [42, 18])
precondition(!attempt(same, 42, identityA, 3, .live), "preview revision with live origin must fail")
precondition(!attempt(same, 18, identityA, 10, .searchPreview), "live revision with preview origin must fail")
precondition(!attempt(same, 42, identityA, 2, .searchPreview), "old preview revision must fail")
precondition(!attempt(same, 18, identityA, 9, .live), "old live revision must fail")
same.searchPreviewSession.activeIdentity = identityB
precondition(!attempt(same, 42, identityA, 3, .searchPreview), "preview session identity must also match")
same.searchPreviewSession.activeIdentity = identityA
precondition(same.seeks == [42, 18], "rejected rows must not call seek")

let handoff = PreviewGuardProbe(isPreview: false, displayedTrack: liveA, liveTrack: liveA)
let oldARow = { attempt(handoff, 12.5, identityA, 10, .live) }
handoff.replaceLive(with: liveB, revision: 11)
precondition(!oldARow(), "a saved A row must not seek B")
precondition(handoff.seeks.isEmpty)
handoff.replaceLive(with: liveA, revision: 12)
precondition(!oldARow(), "A-to-B-to-A must reject the first A revision")
precondition(handoff.seeks.isEmpty)
precondition(attempt(handoff, 0, identityA, 12, .live), "a real synchronized zero-second row remains legal")
precondition(attempt(handoff, 42, identityA, 12, .live), "current forward seek remains legal")
precondition(attempt(handoff, 18, identityA, 12, .live), "current backward seek remains legal")
precondition(handoff.seeks == [0, 42, 18])
let metadataVariant = Track(id: "a-variant", title: "A Live", artist: "artist", album: "album", duration: 180, spotifyId: "spotify-a")
precondition(!attempt(handoff, 18, TrackIdentity(track: metadataVariant), 12, .live),
    "a matching Spotify ID alone must not replace complete identity equality")
precondition(!attempt(handoff, 18, identityA, 3, .searchPreview), "inactive preview origin must fail")
handoff.lyricsSession.activeIdentity = identityB
precondition(!attempt(handoff, 18, identityA, 12, .live), "session identity handoff must fail closed")
precondition(handoff.seeks == [0, 42, 18])

let missing = PreviewGuardProbe(isPreview: true, displayedTrack: liveB, liveTrack: nil)
precondition(!missing.canSeekDisplayedLyrics)
precondition(!attempt(missing, 42, identityB, 3, .searchPreview))
precondition(missing.seeks.isEmpty)

let mock = PreviewGuardProbe(isPreview: false, displayedTrack: liveA, liveTrack: nil, isMock: true)
precondition(attempt(mock, 0, identityA, 10, .live), "explicit Mock Preview retains local seeking")
precondition(!attempt(mock, 12, identityA, 9, .live), "old mock revision must fail")
precondition(mock.seeks == [0])
print("C1 row guard runtime: PASS (A-B, A-B-A, zero/forward/backward, preview/live origins, stale revisions, mock)")
'''.replace('ORIGIN', source_enum).replace('IDENTITY', identity_property).replace('SEEK', seek_method)

v3_source = (root / 'SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3WindowView.swift').read_text()
canvas_source = (root / 'SpotifyLyrics/Views/Components/LyricsCanvasView.swift').read_text()
for source, target, label in (
    (v3_source, 'timestamp', 'v3-lyric-line'),
    (canvas_source, 'seekTimestamp', 'lyric-line'),
):
    assert re.search(
        rf'state\.seekFromDisplayedLyrics\(\s*to: {target},\s*'
        rf'documentIdentity: seekDocumentIdentity,\s*'
        rf'documentRevision: seekDocumentRevision,\s*'
        rf'documentSource: seekDocumentSource,\s*source: "{label}"', source
    ), f'{label} must pass the captured document context'
assert 'let seekDocumentIdentity = TrackIdentity(track: documentTrack)' in v3_source
assert 'let seekDocumentRevision = documentRevision' in v3_source
assert 'isPreview ? .searchPreview : .live' in v3_source
assert 'let seekDocumentIdentity = TrackIdentity(track: seekDocumentTrack)' in canvas_source
assert 'let seekDocumentRevision = state.lyricsSessionRevision' in canvas_source
assert 'state.isShowingSearchPreview ? .searchPreview : .live' in canvas_source
print('C1 row guard SOURCE checks: PASS (guard ordering and captured V3/Classic context)')

if sys.argv[1:] == ['--source-only']:
    print('Swift compilation/runtime and Mac event delivery: NOT RUN (--source-only)')
elif sys.argv[1:]:
    raise SystemExit('usage: c1_preview_seek_contract.py [--source-only]')
else:
    with tempfile.TemporaryDirectory(prefix='spotifylyrics-c1-preview-') as temp:
        script = Path(temp) / 'main.swift'
        script.write_text(program)
        binary = Path(temp) / 'contract'
        subprocess.run([
            'swiftc', str(root / 'SpotifyLyrics/Models/Models.swift'),
            str(root / 'SpotifyLyrics/Lyrics/TrackIdentity.swift'),
            str(script), '-o', str(binary)
        ], check=True)
        subprocess.run([str(binary)], check=True)
