import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class MultiRouteAMLLSession: AMLLSession, @unchecked Sendable {
    private let responses: [String: (body: String, code: Int)]
    private(set) var requests: [URLRequest] = []

    init(responses: [String: (body: String, code: Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.lastPathComponent ?? ""
        let match = responses[path] ?? ("", 404)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: match.code,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(match.body.utf8), response)
    }
}

@main
struct AMLLProviderContract {
    static func main() async {
        let sampleTTML = """
        <?xml version="1.0" encoding="utf-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="ja">
          <body>
            <div>
              <p begin="00:01.000" end="00:03.000" ttm:agent="v1">
                <span begin="00:01.000" end="00:02.000">Word </span>
                <span begin="00:02.000" end="00:03.000">One</span>
                <span ttm:role="x-translation" xml:lang="en">first line</span>
                <span ttm:role="x-translation" xml:lang="zh-Hans">第一句</span>
              </p>
            </div>
          </body>
        </tt>
        """
        let sampleLRC = """
        [ti:LRC Song]
        [ar:LRC Artist]
        [00:01.00]first line
        [00:02.50]second line
        """

        let session = MultiRouteAMLLSession(responses: [
            "ttmlTrack.ttml": (sampleTTML, 200),
            "lrcOnlyTrack.ttml": ("", 404),
            "lrcOnlyTrack.lrc": (sampleLRC, 200)
        ])

        let provider = AMLLLyricsProvider(
            session: session,
            baseURL: URL(string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/spotify-lyrics")!
        )

        // 1. Precise URL Contracts
        precondition(
            provider.ttmlURL(for: "test123").absoluteString == "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/spotify-lyrics/test123.ttml",
            "TTML URL contract failed"
        )
        precondition(
            provider.lrcURL(for: "test123").absoluteString == "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/spotify-lyrics/test123.lrc",
            "LRC URL contract failed"
        )

        // 2. TTML Preferred Match
        let ttmlTrack = Track(title: "TTML Song", artist: "Artist", album: "Album", duration: 180, spotifyId: "ttmlTrack")
        let ttmlIdentity = TrackIdentity(track: ttmlTrack)
        let ttmlResult = await provider.lookup(track: ttmlTrack, identity: ttmlIdentity)
        guard case .match(let ttmlDoc) = ttmlResult else {
            fatalError("expected AMLL TTML match")
        }
        precondition(ttmlDoc.source == .amll)
        precondition(ttmlDoc.hasTimedSpans, "TTML document must have hasTimedSpans == true")
        precondition(ttmlDoc.lines.count == 1)
        precondition(ttmlDoc.lines[0].timedSpans?.count == 2)
        precondition(ttmlDoc.language == "ja")
        precondition(ttmlDoc.lines[0].translationText == "第一句")

        // 3. LRC Fallback Match
        let lrcTrack = Track(title: "LRC Song", artist: "Artist", album: "Album", duration: 180, spotifyId: "lrcOnlyTrack")
        let lrcIdentity = TrackIdentity(track: lrcTrack)
        let lrcResult = await provider.lookup(track: lrcTrack, identity: lrcIdentity)
        guard case .match(let lrcDoc) = lrcResult else {
            fatalError("expected AMLL LRC fallback match")
        }
        precondition(lrcDoc.source == .amll)
        precondition(!lrcDoc.hasTimedSpans, "LRC fallback must not have timed spans")
        precondition(lrcDoc.lines.map(\.originalText) == ["first line", "second line"])

        // 4. Missing Spotify ID guard
        let missingIDTrack = Track(title: "No ID", artist: "Artist", album: "", duration: 10)
        let missing = await provider.lookup(track: missingIDTrack, identity: TrackIdentity(track: missingIDTrack))
        guard case .noMatch = missing else { fatalError("missing Spotify ID must not use fuzzy lookup") }

        // 5. 404 on both TTML and LRC
        let notFoundTrack = Track(title: "Not Found", artist: "Artist", album: "", duration: 10, spotifyId: "notFoundId")
        let notFound = await provider.lookup(track: notFoundTrack, identity: TrackIdentity(track: notFoundTrack))
        guard case .noMatch = notFound else { fatalError("404 must result in noMatch") }

        print("PASS: AMLL provider URL, TTML, and fallback contracts passed")
    }
}
