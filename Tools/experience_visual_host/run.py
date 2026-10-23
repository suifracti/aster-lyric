"""Serve generated artwork on loopback and launch only the isolated fixture app."""
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import os, subprocess, sys, threading, tempfile, shutil
ROOT=Path('/tmp/lyrics-experience-visual-host')


def with_values(argv):
    """Give every '--flag' an explicit value.

    AppKit folds "-key value" pairs into the user-defaults argument domain and
    silently drops a flag that has no value of its own. With such a flag in
    argv SwiftUI never creates the fixture's WindowGroup window: no window
    exists at didFinishLaunching and the view body is never evaluated, so the
    capture waits until the 60 s timeout. Edge-player-expanded and
    hover-details are written as bare flags in the case table; they keep their
    meaning here and simply gain "true".
    """
    result = []
    for index, token in enumerate(argv):
        result.append(token)
        if not token.startswith("--"):
            continue
        following = argv[index + 1] if index + 1 < len(argv) else None
        if following is None or following.startswith("-"):
            result.append("true")
    return result
fixtures=ROOT/'fixtures';fixtures.mkdir(parents=True,exist_ok=True)
class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
server=ThreadingHTTPServer(('127.0.0.1',0),partial(QuietHandler,directory=str(fixtures)))
threading.Thread(target=server.serve_forever,daemon=True).start()
env=os.environ.copy()
env['SPOTIFYLYRICS_DISABLE_KEYCHAIN']='1'
env.pop('SPOTIFY_CLIENT_ID',None)
database_root=Path(tempfile.mkdtemp(prefix='lyricsq-visual-db-'))
source_database=os.environ.get('VISUAL_DATABASE_PATH')
database_path=database_root/'fixture.sqlite3'
if source_database:
    shutil.copyfile(source_database,database_path)
env['SPOTIFYLYRICS_DATABASE_PATH']=str(database_path)
env['VISUAL_ARTWORK_BASE_URL']=f'http://127.0.0.1:{server.server_port}'
app=ROOT/'DerivedData/Build/Products/Debug/SpotifyLyrics.app/Contents/MacOS/SpotifyLyrics'
try:
    raise SystemExit(subprocess.run([str(app),*with_values(sys.argv[1:])],env=env).returncode)
finally:
    server.shutdown();server.server_close()
    shutil.rmtree(database_root)
