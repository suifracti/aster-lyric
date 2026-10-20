"""Serve generated artwork on loopback and launch only the isolated fixture app."""
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import os, subprocess, sys, threading, tempfile, shutil
ROOT=Path('/tmp/lyrics-experience-visual-host')
fixtures=ROOT/'fixtures';fixtures.mkdir(parents=True,exist_ok=True)
class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
server=ThreadingHTTPServer(('127.0.0.1',0),partial(QuietHandler,directory=str(fixtures)))
threading.Thread(target=server.serve_forever,daemon=True).start()
env=os.environ.copy()
env['SPOTIFYLYRICS_DISABLE_KEYCHAIN']='1'
env.pop('SPOTIFY_CLIENT_ID',None)
database_root=Path(tempfile.mkdtemp(prefix='lyricsq-visual-db-'))
env['SPOTIFYLYRICS_DATABASE_PATH']=str(database_root/'fixture.sqlite3')
env['VISUAL_ARTWORK_BASE_URL']=f'http://127.0.0.1:{server.server_port}'
app=ROOT/'DerivedData/Build/Products/Debug/SpotifyLyrics.app/Contents/MacOS/SpotifyLyrics'
try:
    raise SystemExit(subprocess.run([str(app),*sys.argv[1:]],env=env).returncode)
finally:
    server.shutdown();server.server_close()
    shutil.rmtree(database_root)
