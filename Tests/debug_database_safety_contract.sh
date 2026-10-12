#!/usr/bin/env bash
set -euo pipefail
umask 077
export LYRICSQ_CONTRACT_SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - <<'PYTHON'
from pathlib import Path
import os,subprocess,json,tempfile,hashlib,sys,resource
w=Path(os.environ['LYRICSQ_CONTRACT_SOURCE_ROOT']);p=Path(tempfile.mkdtemp(prefix='lyricsq-debug-isolation-contract-',dir='/private/tmp'));p.chmod(0o700);print('EVIDENCE_ROOT='+str(p),flush=True);sources=[w/'SpotifyLyrics/DebugDatabaseSafety.swift',w/'SpotifyLyrics/Spotify/SpotifyTokenStore.swift',w/'SpotifyLyrics/AI/AITranslationKeychain.swift',w/'Tests/debug_database_safety_contract.swift'];(p/'gate-inputs.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2));cmd=['swiftc','-D','DEBUG','-parse-as-library',*map(str,sources),'-o',str(p/'gate-contract')]
with (p/'gate-compile.log').open('w') as out:c=subprocess.run(cmd,stdout=out,stderr=subprocess.STDOUT)
results={'prepare':0,'compile':c.returncode,'cases':{}};(p/'gate-exits.json').write_text(json.dumps(results));
if c.returncode:print('COMPILE FAIL',c.returncode);sys.exit(c.returncode)
bundle='com.spotifylyrics.acceptance.m1native20261011'
def setup():
 r=Path(tempfile.mkdtemp(prefix='lyricsq-m1-native-contract-',dir='/private/tmp'));r.chmod(0o700)
 for n in ['home','tmp','provenance','logs','home/Library','home/Library/Preferences']:(r/n).mkdir(mode=0o700)
 (r/'budget.json').write_text(json.dumps({'maximum':0,'used':0,'stopped':True,'providers':[],'trackKeys':[]}));(r/'budget.json').chmod(0o600)
 e={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','CFFIXED_USER_HOME':str(r/'home'),'TMPDIR':str(r/'tmp')+'/','CFPREFERENCES_AVOID_DAEMON':'1','SPOTIFYLYRICS_DEBUG_ACCEPTANCE':'1','SPOTIFYLYRICS_ACCEPTANCE_DATA_ROOT':str(r),'SPOTIFYLYRICS_ACCEPTANCE_BUNDLE_ID':bundle,'CONTRACT_BUNDLE':bundle,'SPOTIFYLYRICS_ACCEPTANCE_SUITE':bundle+'.root.'+hashlib.sha256(str(r).encode()).hexdigest(),'SPOTIFYLYRICS_DISABLE_KEYCHAIN':'1','SPOTIFYLYRICS_DATABASE_PATH':str(r/'lyrics.sqlite3'),'SPOTIFYLYRICS_ALIGNMENT_PROVENANCE_PATH':str(r/'provenance'),'SPOTIFYLYRICS_ACCEPTANCE_BUDGET_FILE':str(r/'budget.json'),'SPOTIFYLYRICS_ACCEPTANCE_CONTROL_PATH':str(r/'control.txt'),'SPOTIFYLYRICS_E2E_LOG_PATH':str(r/'logs/e2e.log')}
 return r,e
def run(n,mutate=None,args=None,want=78,root=None):
 r,e=setup() if root is None else root
 if mutate:mutate(r,e)
 def limit():os.umask(0o077);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 v=subprocess.run([str(p/'gate-contract'),*(args if args is not None else ['--debug-native-acceptance'])],env=e,capture_output=True,text=True,preexec_fn=limit);(p/(n+'.log')).write_text(v.stdout+v.stderr);results['cases'][n]={'runtime':v.returncode,'expected':want,'root':str(r)};(p/'gate-exits.json').write_text(json.dumps(results,indent=2));print(n,v.returncode,'expected',want,flush=True)
 if v.returncode!=want:sys.exit(1)
 return r,e
run('missing-argument',args=[])
run('formal-bundle',lambda r,e:e.update(CONTRACT_BUNDLE='com.spotifylyrics.app'))
run('missing-root',lambda r,e:e.pop('SPOTIFYLYRICS_ACCEPTANCE_DATA_ROOT'))
run('wrong-suite-standard',lambda r,e:e.update(SPOTIFYLYRICS_ACCEPTANCE_SUITE='com.spotifylyrics.app'))
run('wrong-private-home',lambda r,e:e.update(CFFIXED_USER_HOME=str(r)))
run('escaped-database',lambda r,e:e.update(SPOTIFYLYRICS_DATABASE_PATH='/tmp/arbitrary.sqlite3'))
run('path-traversal',lambda r,e:e.update(SPOTIFYLYRICS_DATABASE_PATH=str(r/'home/../lyrics.sqlite3')))
run('keychain-enabled',lambda r,e:e.pop('SPOTIFYLYRICS_DISABLE_KEYCHAIN'))
run('budget-missing',lambda r,e:(r/'budget.json').unlink())
run('budget-nonzero',lambda r,e:(r/'budget.json').write_text('{"maximum":1,"used":0,"stopped":false,"providers":[],"trackKeys":[]}'))
run('symlink',lambda r,e:(r/'provenance/link').symlink_to('/private/tmp'))
run('hardlink',lambda r,e:os.link(r/'budget.json',r/'budget-copy.json'))
run('wrong-owner-permissions',lambda r,e:r.chmod(0o755))
run('recording-env',lambda r,e:e.update(SPOTIFYLYRICS_SCK_SPIKE='1'))
run('escaped-resource-after-ready',lambda r,e:e.update(CONTRACT_ESCAPED_STORAGE='/tmp/arbitrary.sqlite3'))
r,e=run('private-positive',want=0)
suite=e['SPOTIFYLYRICS_ACCEPTANCE_SUITE'];pref=r/'preferences.plist';assert pref.is_file(),str(pref)
run('private-reopen-preserves-choice',args=['--debug-native-acceptance','--cache-reopen'],want=0,root=(r,e))
plain={'PATH':'/usr/bin:/bin'};v=subprocess.run([str(p/'gate-contract')],env=plain,capture_output=True,text=True);results['ordinary-debug']={'runtime':v.returncode};assert v.returncode==0;print('ordinary-debug old contract',v.returncode)
# Supplemental static completeness: no shipped consumer can accidentally call standard.
misused=[]
for f in (w/'SpotifyLyrics').rglob('*.swift'):
 if f.name!='DebugDatabaseSafety.swift' and ('UserDefaults.standard' in f.read_text() or 'defaults: UserDefaults = .standard' in f.read_text()):misused.append(str(f))
assert not misused,misused
results['private_preferences_file']=str(pref);results['standard_consumer_audit']='PASS';(p/'gate-exits.json').write_text(json.dumps(results,indent=2));print('ALL GATES PASS')

PYTHON
