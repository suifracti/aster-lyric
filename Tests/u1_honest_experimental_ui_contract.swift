import Foundation

@main
struct U1HonestExperimentalUIContract {
    @MainActor
    static func main() {
        precondition(
            DirectionDTrackSummaryPresentation.displayTitle("", hasCurrentTrack: false) == "等待歌曲",
            "an absent current track must not be labelled as a song"
        )
        precondition(
            DirectionDTrackSummaryPresentation.displayTitle("曲名", hasCurrentTrack: true) == "曲名",
            "a known current track title must be preserved"
        )
        precondition(
            DirectionDTrackSummaryPresentation.displayTitle("  \n", hasCurrentTrack: true) == "歌曲标题未知",
            "an identified track with a blank title must be reported as unknown"
        )
        precondition(
            DirectionDTrackSummaryPresentation.displayTitle(nil, hasCurrentTrack: true) == "歌曲标题未知",
            "an identified track with no title value must be reported as unknown"
        )

        var preparationCalls = 0
        var editorOpenCalls = 0

        DirectionDActionRouter.performManualLyricsImport(
            prepare: {
                preparationCalls += 1
                return false
            },
            openEditor: { editorOpenCalls += 1 }
        )
        precondition(preparationCalls == 1, "failed/cancelled preparation must run once")
        precondition(editorOpenCalls == 0, "failed/cancelled preparation must not open the editor")

        DirectionDActionRouter.performManualLyricsImport(
            prepare: {
                preparationCalls += 1
                return true
            },
            openEditor: { editorOpenCalls += 1 }
        )
        precondition(preparationCalls == 2, "successful preparation must run once")
        precondition(editorOpenCalls == 1, "successful preparation must open the existing editor exactly once")
        print("U1 manual import action: cancellation stays closed; success opens editor once")
    }
}
