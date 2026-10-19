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
// Production publisher HTML also uses valid, unquoted class attributes.
let minified = body.replacingOccurrences(of: "class='lyric_header'", with: "class=lyric_header")
    .replacingOccurrences(of: "class='lyric_text'", with: "class=lyric_text")
expect(LinkCoreHTML.lyricPage(minified)?.lines == words.lines, "minified unquoted publisher classes")
expect(LinkCoreHTML.lyricPage(body.replacingOccurrences(of: "class='lyric_text'", with: "class=lyric_text_other")) == nil, "unquoted class must be exact")
expect(LinkCoreHTML.lyricPage("<h2>Catalog title only</h2>") == nil, "catalog is not a lyric body")
expect(LinkCoreHTML.lyricPage(body.replacingOccurrences(of: "lyric_text", with: "lyric_credit")) == nil, "credits masquerading as lyrics")
for raw in ["http://linkco.re/AAAA1234", "https://linkco.re.evil.invalid/a", "https://x@linkco.re/a", "https://linkco.re:8443/a", "file:///etc/passwd"] {
    expect(!LinkCoreHTML.isAllowed(URL(string: raw)!), "unsafe URL " + raw)
}
expect(LinkCoreHTML.isAllowed(URL(string:"https://www.tunecore.co.jp/artists?keyword=Example")!), "official catalog URL")
expect(LinkCoreHTML.pageProps(String(repeating:"x",count:1_500_001)) == nil, "unbounded document")
print("PASS \(checks) exact parser assertions; no app UI or performance claim")
'''
# Optional bounded public identity/body path. Network status and parser status
# are distinct. No body text is printed, saved in the repo, or uploaded as evidence.
if '--live' in sys.argv:
    fixtures += r'''
final class FetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var item: (String?, Int, String) = (nil, 0, "not started")
    func set(_ value: (String?, Int, String)) { lock.lock(); defer { lock.unlock() }; item = value }
    func get() -> (String?, Int, String) { lock.lock(); defer { lock.unlock() }; return item }
}
func fetch(_ url: URL) -> (html: String?, status: Int, error: String) {
    let semaphore = DispatchSemaphore(value: 0), box = FetchBox()
    var request = URLRequest(url: url); request.timeoutInterval = 12
    request.setValue("LyricIsland/1.0 (public publisher lyrics)", forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let allowed = response?.url.map { LinkCoreHTML.isAllowed($0) } ?? false
        let html = allowed && code == 200 && error == nil && (data?.count ?? 0) <= 1_500_000
            ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
        box.set((html, code, error.map { String(describing: type(of: $0)) } ?? (allowed ? "" : "unexpected host")))
    }
    task.resume()
    if semaphore.wait(timeout: .now()+14) == .timedOut { task.cancel(); return (nil, 0, "timeout") }
    return box.get()
}
func marker(_ pattern: String, in html: String) -> Bool {
    html.range(of: pattern, options: .regularExpression) != nil
}
var liveFailures = 0, liveUnavailable = 0, liveBodies = 0
for (artistName,title) in [("SACBEN","HANABI"),("toh","WAITING AT 3AM")] {
    var parts = URLComponents(string:"https://www.tunecore.co.jp/artists")!
    parts.queryItems = [URLQueryItem(name:"keyword",value:artistName),URLQueryItem(name:"lang",value:"en")]
    let directory = fetch(parts.url!)
    guard let html = directory.html else {
        print("LIVE NOT_RUN directory artist=\(artistName) HTTP=\(directory.status) error=\(directory.error)"); liveUnavailable += 1; continue
    }
    let ids = LinkCoreHTML.artistDirectory(html, matching:artistName)
    guard let id = ids.first else {
        print("LIVE FAIL directory parse artist=\(artistName) bytes=\(html.utf8.count)"); liveFailures += 1; continue
    }
    let profile = fetch(URL(string:"https://www.tunecore.co.jp/artists?id=\(id)&lang=en")!)
    guard let profileHTML = profile.html else {
        print("LIVE NOT_RUN artist entity=\(id) HTTP=\(profile.status)"); liveUnavailable += 1; continue
    }
    guard let artist = LinkCoreHTML.artistPage(profileHTML), artist.id == id else {
        print("LIVE FAIL artist parse entity=\(id)"); liveFailures += 1; continue
    }
    let songs = artist.songs.filter { LinkCoreHTML.key($0.versionedTitle) == LinkCoreHTML.key(title) }
    guard let song = songs.first, let url = song.lyricURL else {
        print("LIVE FAIL release lookup entity=\(id) title=\(title)"); liveFailures += 1; continue
    }
    print("LIVE CATALOG verified entity=\(id) title=\(title) aliases=\(artist.names.joined(separator: " / ")) duration=\(song.duration)")
    let body = fetch(url)
    if body.status == 404 {
        print("LIVE BODY_NOT_PUBLISHED entity=\(id) release=\(song.releaseCode) song=\(song.songID); catalog identity is not lyric success")
        if artistName == "SACBEN" { liveFailures += 1 }
        continue
    }
    guard let html = body.html else {
        print("LIVE NOT_RUN body entity=\(id) HTTP=\(body.status) error=\(body.error)"); liveUnavailable += 1; continue
    }
    guard let page = LinkCoreHTML.lyricPage(html) else {
        let header = marker(#"(?is)<section\b[^>]*\bclass\s*=\s*(?:["'][^"']*\blyric_header\b[^"']*["']|lyric_header(?=[\s>]))[^>]*>(.*?)</section\s*>"#, in: html)
        let text = marker(#"(?is)<div\b[^>]*\bclass\s*=\s*(?:["'][^"']*\blyric_text\b[^"']*["']|lyric_text(?=[\s>]))[^>]*>(.*?)</div\s*>"#, in: html)
        print("LIVE FAIL body parse entity=\(id) HTTP=\(body.status) bytes=\(html.utf8.count) header=\(header) lyric_text=\(text)")
        liveFailures += 1; continue
    }
    let matches = song.titles.contains { LinkCoreHTML.key($0)==LinkCoreHTML.key(page.title) }
        && song.artistNames.contains { LinkCoreHTML.key($0)==LinkCoreHTML.key(page.artist) }
    print("LIVE \(matches ? "PASS" : "FAIL") entity=\(id), release=\(song.releaseCode), song=\(song.songID), lines=\(page.lines.count), sync=false")
    if matches { liveBodies += 1 } else { liveFailures += 1 }
}
print("LIVE summary: verifiedBodies=\(liveBodies) failures=\(liveFailures) unavailable=\(liveUnavailable); no GUI or automatic-adoption claim")
if liveFailures > 0 { exit(1) }
if liveUnavailable > 0 { exit(2) } // NOT_RUN must not silently become PASS.
'''
compiler=shutil.which('swiftc')
if not compiler: raise SystemExit('NOT_RUN: swiftc unavailable')
with tempfile.TemporaryDirectory(prefix='lyric-linkcore-test-') as d:
    p=Path(d);main=p/'main.swift';exe=p/'test'
    main.write_text('import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'+models+parser+fixtures)
    subprocess.run([compiler,'-swift-version','5','-O',str(main),'-o',str(exe)],check=True,timeout=90)
    raise SystemExit(subprocess.run([str(exe)],timeout=110).returncode)
