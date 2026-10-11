import Foundation

private actor FirstProjection {
    var at: Date?;var document: LyricsDocument?
    func receive(_ value:LyricsDocument) { if at == nil { at = Date() }; document = value }
}
private struct CandidateSource: LyricsProvider {
    let name = "LRCLIB isolated"; let candidate: LyricsCandidate
    var executionLane: LyricsProviderExecutionLane { .network }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult { .candidates([candidate]) }
}
private struct SlowSource: LyricsProvider {
    let name = "QQ isolated long tail"
    var executionLane: LyricsProviderExecutionLane { .network }
    var timeoutInterval: TimeInterval { 2 }
    func lookup(track: Track, identity: TrackIdentity) async -> LyricsLookupResult {
        do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return .failed(.cancelled) }
        return .failed(.serverError(500))
    }
}
@main struct GijikoiContract {
    static let track = Track(title:"GIJIKOI", artist:"Haruki Hamano", album:"GIJIKOI (Korean ver.)", duration:216.875, spotifyId:"0ZLWH8kZv299eRlEoMelAD")
    static func candidate(_ title:String = "ギジコイ - GIJIKOI", artist:String="Haruki Hamano", duration:Double=216.875, spotifyID:String?=nil, isrc:String?=nil) -> LyricsCandidate {
        LyricsCandidate(id:"fixture:gijikoi", identity:TrackIdentity(track:track), title:title, artist:artist, album:"ギジコイ", duration:duration, lines:[LyricLine(timestamp:1,originalText:"自写检查句"),LyricLine(timestamp:3,originalText:"另一自写句")],isSynchronized:true, source:.lrclib, confidence:0.46,spotifyTrackID:spotifyID,isrc:isrc)
    }
    static func require(_ condition:Bool,_ message:String) { if !condition { print("FAIL: " + message);exit(1) } }
    static func main() async {
        if CommandLine.arguments.contains("--provisional") {
            let started = Date(); let projection = FirstProjection()
            let outcome = await LyricsSearchManager(providers: [SlowSource(), CandidateSource(candidate:candidate())]).search(track:track, identity:TrackIdentity(track:track), onProvisional:{ await projection.receive($0) })
            guard let shown=await projection.document, let at=await projection.at else { require(false,"eligible synchronized original never displayed while higher-priority source waited");return }
            require(shown.lines.map(\.timestamp)==[1,3] && shown.isSynchronized,"provisional sync must preserve original timing")
            require(at.timeIntervalSince(started)<0.5,"eligible automatic original blocked by higher-priority long tail")
            guard case .match=outcome.result else { require(false,"final match lost after early display");return }
            print("PASS: safe automatic synchronized original projected before higher-priority long tail; final result still automatic")
            return
        }
        let meta=TrackMetadata.bootstrap(from:track)
        for title in ["ギジコイ - GIJIKOI","ギジコイ - Giji Koi","GIJIKOI - ギジコイ","ギジコイ（GIJIKOI）","Giji Koi","ギジコイ"] {
            let d=LyricsSafeMatcher.decide(candidate:candidate(title), metadata:meta)
            print("DECISION title=\(title) tier=\(d.tier) evidence=\(d.explanation)")
            require(d.tier == .autoMedium || d.tier == .autoHigh, "complete bilingual/spacing title must automatically match: " + title)
        }
        for c in [candidate("GIJIKOI - Another ver."), candidate("ギジコイ - OTHER"), candidate("GIJIKOI Love"), candidate("GIJI"),candidate(artist:"Another Artist"),candidate(duration:245),candidate(duration:0),candidate(spotifyID:"wrong-track-id")] {
            let d=LyricsSafeMatcher.decide(candidate:c,metadata:meta)
            require(d.tier != .autoHigh && d.tier != .autoMedium,"partial title/artist/duration/independent ID conflict adopted: " + c.title)
        }
        let identified = Track(title:track.title,artist:track.artist,album:track.album,duration:track.duration,isrc:"JPTEST0000001",spotifyId:track.spotifyId)
        require(LyricsSafeMatcher.decide(candidate:candidate(isrc:"JPTEST0000002"),metadata:TrackMetadata.bootstrap(from:identified)).hardReject,"ISRC conflict must remain hard rejected")
        for title in ["ギジコイ - GIJIKOI (Piano)","ギジコイ - GIJIKOI (Live)","ギジコイ - GIJIKOI (Remix)","ギジコイ - GIJIKOI (Sped Up Ver.)"] {
            require(LyricsSafeMatcher.decide(candidate:candidate(title),metadata:meta).versionConflict,"recording barrier missing")
        }
        let plain=Track(title:"GIJIKOI",artist:track.artist,album:track.album,duration:track.duration)
        let unknown = LyricsSafeMatcher.decide(candidate:candidate("GIJIKOI (Korean ver.)"),metadata:TrackMetadata.bootstrap(from:plain))
        require(unknown.tier != .autoMedium && unknown.tier != .autoHigh,"unknown version suffix collapsed")
        let start=Date()
        let outcome=await LyricsSearchManager(providers:[CandidateSource(candidate:candidate()),SlowSource()]).search(track:track,identity:meta.identity)
        guard case .match(let document)=outcome.result else { require(false,"automatic chain still stops at candidates");return }
        require(document.isSynchronized && document.lines.map(\.timestamp)==[1,3],"matched source timing must be unchanged")
        require(Date().timeIntervalSince(start) < 0.5,"eligible synchronized result blocked by lower-priority slow provider")
        print("PASS: full bilingual identity automatically adopted; partial/wrong artist/duration/IDs/recording barriers intact; no lower-priority tail wait")
    }
}
