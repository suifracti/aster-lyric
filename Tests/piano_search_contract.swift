import Foundation

@main
struct PianoSearchContract {
    static func main() async {
        let track = Track(title: "アーカイブ - Piano Ver.", artist: "stb", album: "アーカイブ", duration: 240, spotifyId: "5O45JO2bYhtyah2flZ9TI0")
        let identity = TrackIdentity(track: track)
        let metadata = TrackMetadata.bootstrap(from: track)
        let candidate = LyricsCandidate(id: "fixture", identity: identity, title: "アーカイブ", artist: "stb;NEA;ささ。", album: "アーカイブ", duration: 240, lines: [LyricLine(timestamp: 0, originalText: "Generated test line")], source: .qqExperimental, confidence: 0.87)
        if CommandLine.arguments.contains("live") {
            let result = await LyricsSearchManager(providers: [QQExperimentalLyricsProvider()]).lookup(track: track, identity: identity)
            guard case .candidates(let candidates) = result, !candidates.isEmpty else { fatalError("Live piano search should expose explicit candidates: \(result)") }
            print("LIVE candidates", candidates.map { "\($0.title)|\($0.artist)|\($0.lines.count) lines" })
            return
        }
        let decision = LyricsSafeMatcher.decide(candidate: candidate, metadata: metadata)
        print("Decision", decision.tier, decision.score, decision.reasons)
        precondition(decision.tier == .candidates, "Semicolon artist + arrangement title must yield selectable candidate, never automatic")
        precondition(decision.versionConflict)
        precondition(TrackTextNormalizer.extractVersionTags(fromTitle: "Piano Man").isEmpty)
        precondition(TrackTextNormalizer.stripVersionMarkers(fromTitle: "Piano Man") == "Piano Man")
        for title in ["アーカイブ - Piano Ver.", "アーカイブ (Piano Version)", "アーカイブ（ピアノ版）"] {
            precondition(TrackTextNormalizer.extractVersionTags(fromTitle: title).contains(.piano))
            precondition(TrackTextNormalizer.stripVersionMarkers(fromTitle: title) == "アーカイブ")
        }
        precondition(TrackTextNormalizer.artistTokens("stb;NEA;ささ。").primary == "stb")
        precondition(TrackTextNormalizer.artistTokens("HUNTR/X").primary == "HUNTR/X")
        precondition(LyricsQueryPlanner.plan(for: metadata).contains { $0.titleQuery == "アーカイブ" && $0.artistQuery == "stb" })
        let unrelated = LyricsCandidate(id: "unrelated", identity: identity, title: "アーカイブ", artist: "Other Artist;NEA", album: "アーカイブ", duration: 240, lines: candidate.lines, source: .qqExperimental, confidence: 0.9)
        precondition(LyricsSafeMatcher.decide(candidate: unrelated, metadata: metadata).tier == .reject)
        func copy(title: String = "アーカイブ", artist: String = "stb;NEA;ささ。", spotifyID: String? = nil, explanation: [String] = []) -> LyricsCandidate {
            LyricsCandidate(id: "copy", identity: identity, title: title, artist: artist, album: candidate.album, duration: candidate.duration, lines: candidate.lines, source: candidate.source, confidence: candidate.confidence, spotifyTrackID: spotifyID, matchExplanation: explanation)
        }
        precondition(LyricsSafeMatcher.decide(candidate: copy(spotifyID: "unrelated-recording"), metadata: metadata).tier == .reject)
        let exact = copy(title: track.title, artist: track.artist)
        let exactDecision = LyricsSafeMatcher.decide(candidate: exact, metadata: metadata)
        precondition(!exactDecision.versionConflict)
        precondition(exactDecision.tier == .autoHigh || exactDecision.tier == .autoMedium)
        precondition(copy(explanation: decision.explanation).arrangementNotice != nil)
        precondition(exact.arrangementNotice == nil)

        // Verified Spotify artists scenario: stb (Piano Ver.) with Spotify official artists stb, NEA, ささ。, KASUMI
        var enrichedMetadata = metadata
        enrichedMetadata.verifiedSpotifyArtists = ["stb", "NEA", "ささ。", "KASUMI"]

        // 1. Piano Ver. candidate with known collaborator subset (stb;NEA;ささ。) must be auto-adopted
        let pianoCandidate = copy(title: "アーカイブ (Piano Ver.)", artist: "stb;NEA;ささ。")
        let pianoDecision = LyricsSafeMatcher.decide(candidate: pianoCandidate, metadata: enrichedMetadata)
        precondition(!pianoDecision.versionConflict, "Piano Ver. candidate must not have version conflict")
        precondition(pianoDecision.tier == .autoHigh || pianoDecision.tier == .autoMedium,
                     "Piano Ver. candidate with verified Spotify artist subset must be auto-adopted: \(pianoDecision.tier)")
        precondition(pianoDecision.reasons.contains("featuredArtistsVerifiedSubset"),
                     "Must record featuredArtistsVerifiedSubset evidence: \(pianoDecision.reasons)")
        precondition(!pianoDecision.reasons.contains("missingFeaturedArtist"),
                     "Must not penalize missing secondary Spotify artist when candidate subset is verified")
        precondition(!pianoDecision.reasons.contains("extraFeaturedArtist"),
                     "Must not flag extra featured artist when all candidate artists are in official list")

        // 2. Safety barrier: Plain アーカイブ must NEVER be auto-adopted for Piano Ver.
        let plainCandidate = copy(title: "アーカイブ", artist: "stb;NEA;ささ。")
        let plainDecision = LyricsSafeMatcher.decide(candidate: plainCandidate, metadata: enrichedMetadata)
        precondition(plainDecision.versionConflict, "Plain arrangement must have version conflict for Piano Ver. track")
        precondition(plainDecision.tier == .candidates, "Plain arrangement must NEVER be auto-adopted for Piano Ver. track: \(plainDecision.tier)")

        // 3. Unverified guest artist must remain .candidates
        let unverifiedCandidate = copy(title: "アーカイブ (Piano Ver.)", artist: "stb;NEA;RandomStranger")
        let unverifiedDecision = LyricsSafeMatcher.decide(candidate: unverifiedCandidate, metadata: enrichedMetadata)
        precondition(unverifiedDecision.tier == .candidates, "Candidate with unverified artist must remain .candidates: \(unverifiedDecision.tier)")
        precondition(unverifiedDecision.reasons.contains("extraFeaturedArtist"), "Must flag extraFeaturedArtist")

        print("Piano search PASS")
    }
}
