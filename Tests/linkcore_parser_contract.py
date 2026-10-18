#!/usr/bin/env python3
"""Compiles the exact bounded catalog/lyrics parser; fixtures contain no song lyrics.
Optional --live downloads public HTML to a temporary process and prints only identity
metadata and line counts, never lyric text or a snapshot with credentials.
"""
from pathlib import Path
import json, shutil, subprocess, tempfile, sys
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT/'SpotifyLyrics/Providers/LinkCoreLyricsProvider.swift').read_text()
models = source[source.index('struct LinkCoreSong:'):source.index('private struct LinkCoreRequestError:')]
parser = source.split('// BEGIN LINKCORE PURE PARSER', 1)[1].split('// END LINKCORE PURE PARSER', 1)[0]
fixtures = r'''
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ reason: String) { checks += 1; precondition(condition(), reason) }
func nextHTML(_ value: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["props": ["pageProps": value]])
    return "<script id=\"__NEXT_DATA__\" type=\"application/json\">" + String(data: data, encoding: .utf8)! + "</script>"
}
let artist: [String: Any] = ["id": 582402, "nameEn": "SACBEN", "nameJa": "SACBEN", "dsp": [:], "releases": [
    ["nameEn": "HANABI", "nameJa": "はなび", "songNum": 1, "totalSeconds": 120,
     "linkcore": ["url": "https://linkco.re/YSn8Z79P"], "songs": [["id":"2380258","nameEn":"HANABI","nameJa":"はなび"]]],
    ["nameEn":"Different Song (Sped Up)","nameJa":"Different Song (Sped Up)","songNum":1,"totalSeconds":149,
     "linkcore":["url":"https://linkco.re/AbCd1234"],"songs":[["id":"21","nameEn":"Different Song","nameJa":"Different Song"]]],
    ["nameEn":"Album","songNum":2,"totalSeconds":700,"linkcore":["url":"https://linkco.re/MnOp4321"],
     "songs":[["id":"22","nameEn":"A","nameJa":"A"],["id":"23","nameEn":"B","nameJa":"B"]]],
    ["nameEn":"Unsafe","songNum":1,"linkcore":["url":"https://linkco.re.evil.invalid/ABCD1234"],"songs":[["id":"99","nameEn":"Unsafe"]]]
]]
let page = LinkCoreHTML.artistPage(nextHTML(["artist": artist]))!
expect(page.id == "582402" && page.songs.count == 4, "catalog route validation")
expect(page.songs[0].titles.contains("HANABI") && page.songs[0].titles.contains("はなび"), "localized title provenance")
expect(page.songs[0].duration == 120, "single duration")
expect(page.songs[1].versionedTitle.contains("Sped Up"), "release version was stripped")
expect(page.songs[2].duration == 0 && page.songs[3].duration == 0, "album duration copied to track")
let directory = nextHTML(["artistList": [["id":"582402","nameEn":"SACBEN","nameJa":"SACBEN"],
                                       ["id":"111","nameEn":"SACBEN remixes","nameJa":"Other"],
                                       ["id":"bad/path","nameEn":"SACBEN","nameJa":"SACBEN"]]])
expect(LinkCoreHTML.artistDirectory(directory, matching: "sacben") == ["582402"], "artist exact identity")
let localized = nextHTML(["artist":["id":1077427,"nameEn":"toh","nameJa":"透（toh）","releases":[]]])
expect(LinkCoreHTML.artistPage(localized)?.names == ["toh","透（toh）"], "source-bound artist aliases")
let body = "<section class='lyric_header'><h1>Lyrics</h1><h2>Example</h2><h3>Artist</h3></section><div class='lyric_text'><p>Line &amp; one<p>Line &#x4E8C;<br>Third &lt;line&gt;<p>\n</div><div class='lyric_credit'>Do not read credits</div>"
let words = LinkCoreHTML.lyricPage(body)!
expect(words.lines == ["Line & one", "Line 二", "Third <line>"], "HTML paragraph/BR/entity handling")
expect(words.title == "Example" && words.artist == "Artist", "independent page metadata")
expect(LinkCoreHTML.lyricPage("<h2>Catalog title only</h2>") == nil, "catalog is not a lyric body")
expect(LinkCoreHTML.lyricPage(body.replacingOccurrences(of: "lyric_text", with: "lyric_credit")) == nil, "credits masquerading as lyrics")
for raw in ["http://linkco.re/AAAA1234", "https://linkco.re.evil.invalid/a", "https://x@linkco.re/a", "https://linkco.re:8443/a", "file:///etc/passwd"] {
    expect(!LinkCoreHTML.isAllowed(URL(string: raw)!), "unsafe URL " + raw)
}
expect(LinkCoreHTML.isAllowed(URL(string:"https://www.tunecore.co.jp/artists?keyword=Example")!), "official catalog URL")
expect(LinkCoreHTML.pageProps(String(repeating:"x",count:1_500_001)) == nil, "unbounded document")
print("PASS \(checks) exact parser assertions; no app UI or performance claim")
'''
# Optional bounded public identity/body path. No polling and no lyric body output.
live = r'''
import FoundationNetworking
'''
if '--live' in sys.argv:
    fixtures += r'''
func fetch(_ url: URL) -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: String?
    var request = URLRequest(url:url); request.timeoutInterval = 10
    request.setValue("LyricIsland-Compatibility/1.0",forHTTPHeaderField:"User-Agent")
    let task = URLSession.shared.dataTask(with:request) { data, response, error in
        defer { semaphore.signal() }
        if error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
           let data, data.count < 1_500_000 { result = String(data:data,encoding:.utf8) }
    }
    task.resume()
    if semaphore.wait(timeout:.now()+12) == .timedOut { task.cancel();return nil }
    return result
}
for (artistName,title) in [("SACBEN","HANABI"),("toh","WAITING AT 3AM")] {
    var parts=URLComponents(string:"https://www.tunecore.co.jp/artists")!
    parts.queryItems=[URLQueryItem(name:"keyword",value:artistName),URLQueryItem(name:"lang",value:"en")]
    guard let html=fetch(parts.url!) else { print("NOT_RUN public directory: \(artistName)");continue }
    let ids=LinkCoreHTML.artistDirectory(html,matching:artistName)
    guard let id=ids.first,
          let profileHTML=fetch(URL(string:"https://www.tunecore.co.jp/artists?id=\(id)&lang=en")!),
          let artist=LinkCoreHTML.artistPage(profileHTML) else { print("FAIL official artist lookup \(artistName), ids=\(ids)");continue }
    let songs=artist.songs.filter { LinkCoreHTML.key($0.versionedTitle) == LinkCoreHTML.key(title) }
    guard let song=songs.first,let url=song.lyricURL else { print("FAIL release/song lookup \(title)");continue }
    guard let html=fetch(url),let page=LinkCoreHTML.lyricPage(html) else {
        print("BODY_UNAVAILABLE \(artist.id) \(song.releaseCode)/\(song.songID) \(title)");continue
    }
    let matches=song.titles.contains { LinkCoreHTML.key($0)==LinkCoreHTML.key(page.title) }
        && song.artistNames.contains { LinkCoreHTML.key($0)==LinkCoreHTML.key(page.artist) }
    print("LIVE \(matches ? "PASS" : "FAIL") entity=\(artist.id), release=\(song.releaseCode), song=\(song.songID), lines=\(page.lines.count), title=\(page.title), sync=false")
}
'''
compiler=shutil.which('swiftc')
if not compiler: raise SystemExit('NOT_RUN: swiftc unavailable')
with tempfile.TemporaryDirectory(prefix='lyric-linkcore-test-') as d:
    p=Path(d);main=p/'main.swift';exe=p/'test'
    main.write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'+models+parser+fixtures)
    subprocess.run([compiler,'-swift-version','5','-O',str(main),'-o',str(exe)],check=True,timeout=90)
    subprocess.run([str(exe)],check=True,timeout=90)
