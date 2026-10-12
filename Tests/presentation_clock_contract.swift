import Foundation

// Test contract for LyricsPresentationClock

@main
struct PresentationClockContract {
    static func main() {
        print("=== PRESENTATION CLOCK CONTRACT ===")

        // 1. Playing + 100ms -> +0.1s
        print("[1] Testing playing monotonic advancement...")
        let clock1 = LyricsPresentationClock(
            authoritativePosition: 10.0,
            receivedAtMonotonicTime: 100.0,
            isPlaying: true,
            trackID: "track1",
            trackDuration: 200.0
        )
        let t1_0 = clock1.presentationTime(at: 100.0)
        let t1_1 = clock1.presentationTime(at: 100.1)
        let t1_5 = clock1.presentationTime(at: 100.5)
        assert(abs(t1_0 - 10.0) < 1e-6, "t1_0 should be 10.0, got \(t1_0)")
        assert(abs(t1_1 - 10.1) < 1e-6, "t1_1 should be 10.1, got \(t1_1)")
        assert(abs(t1_5 - 10.5) < 1e-6, "t1_5 should be 10.5, got \(t1_5)")

        // 2. Pause -> time fixed
        print("[2] Testing paused clock invariance...")
        let clock2 = LyricsPresentationClock(
            authoritativePosition: 10.5,
            receivedAtMonotonicTime: 100.5,
            isPlaying: false,
            trackID: "track1",
            trackDuration: 200.0
        )
        let t2_0 = clock2.presentationTime(at: 100.5)
        let t2_1 = clock2.presentationTime(at: 101.0)
        let t2_5 = clock2.presentationTime(at: 105.0)
        assert(abs(t2_0 - 10.5) < 1e-6, "t2_0 should be 10.5, got \(t2_0)")
        assert(abs(t2_1 - 10.5) < 1e-6, "t2_1 should be 10.5, got \(t2_1)")
        assert(abs(t2_5 - 10.5) < 1e-6, "t2_5 should be 10.5, got \(t2_5)")

        // 3. Resume -> starts advancing from new anchor
        print("[3] Testing resume from new anchor...")
        let clock3 = LyricsPresentationClock(
            authoritativePosition: 10.5,
            receivedAtMonotonicTime: 105.0,
            isPlaying: true,
            trackID: "track1",
            trackDuration: 200.0
        )
        let t3_0 = clock3.presentationTime(at: 105.0)
        let t3_2 = clock3.presentationTime(at: 105.2)
        assert(abs(t3_0 - 10.5) < 1e-6, "t3_0 should be 10.5, got \(t3_0)")
        assert(abs(t3_2 - 10.7) < 1e-6, "t3_2 should be 10.7, got \(t3_2)")

        // 4. Seek forward -> instant jump
        print("[4] Testing seek forward...")
        let clock4 = LyricsPresentationClock(
            authoritativePosition: 45.0,
            receivedAtMonotonicTime: 106.0,
            isPlaying: true,
            trackID: "track1",
            trackDuration: 200.0
        )
        let t4_0 = clock4.presentationTime(at: 106.0)
        let t4_3 = clock4.presentationTime(at: 106.3)
        assert(abs(t4_0 - 45.0) < 1e-6, "t4_0 should be 45.0, got \(t4_0)")
        assert(abs(t4_3 - 45.3) < 1e-6, "t4_3 should be 45.3, got \(t4_3)")

        // 5. Seek backward -> instant jump
        print("[5] Testing seek backward...")
        let clock5 = LyricsPresentationClock(
            authoritativePosition: 2.0,
            receivedAtMonotonicTime: 107.0,
            isPlaying: true,
            trackID: "track1",
            trackDuration: 200.0
        )
        let t5_0 = clock5.presentationTime(at: 107.0)
        let t5_1 = clock5.presentationTime(at: 107.1)
        assert(abs(t5_0 - 2.0) < 1e-6, "t5_0 should be 2.0, got \(t5_0)")
        assert(abs(t5_1 - 2.1) < 1e-6, "t5_1 should be 2.1, got \(t5_1)")

        // 6. Track change -> reset
        print("[6] Testing track change reset...")
        let clock6 = LyricsPresentationClock(
            authoritativePosition: 0.0,
            receivedAtMonotonicTime: 108.0,
            isPlaying: true,
            trackID: "track2",
            trackDuration: 180.0
        )
        assert(clock6.trackID == "track2", "Track ID should be track2")
        assert(abs(clock6.presentationTime(at: 108.0) - 0.0) < 1e-6, "Should start at 0")

        // 7. Authoritative correction -> no old drift
        print("[7] Testing authoritative Spotify correction without historical drift...")
        // At mono=108.0, Spotify tells us pos is 0.0
        // At mono=108.5, extrapolated was 0.5
        // At mono=108.5, Spotify authoritative arrives as 0.48 (small network latency)
        let clock7_corrected = LyricsPresentationClock(
            authoritativePosition: 0.48,
            receivedAtMonotonicTime: 108.5,
            isPlaying: true,
            trackID: "track2",
            trackDuration: 180.0
        )
        let t7 = clock7_corrected.presentationTime(at: 108.5)
        assert(abs(t7 - 0.48) < 1e-6, "Correction should immediately take 0.48, got \(t7)")

        // 8. Track duration clamp
        print("[8] Testing track duration clamp...")
        let clock8 = LyricsPresentationClock(
            authoritativePosition: 199.5,
            receivedAtMonotonicTime: 100.0,
            isPlaying: true,
            trackID: "track2",
            trackDuration: 200.0
        )
        let t8_over = clock8.presentationTime(at: 102.0)
        assert(abs(t8_over - 200.0) < 1e-6, "Should clamp at duration 200.0, got \(t8_over)")

        print("[9] Testing lyric boundary helper...")
        let stamps: [TimeInterval] = [1.0, 2.0, 2.0, 5.0]
        assert(LyricBoundary.nextTime(afterIndex: nil, timestamps: stamps) == 1.0)
        assert(LyricBoundary.nextTime(afterIndex: 0, timestamps: stamps) == 2.0)
        assert(LyricBoundary.nextTime(afterIndex: 1, timestamps: stamps) == 5.0)
        assert(LyricBoundary.nextTime(afterIndex: 2, timestamps: stamps) == 5.0)
        assert(LyricBoundary.nextTime(afterIndex: 3, timestamps: stamps) == nil)
        assert(LyricBoundary.nextTime(afterIndex: 0, timestamps: []) == nil)

        print("[10] Testing 10 line crossings are not 0.2s-quantized and do not wait for poll...")
        let lineStarts: [TimeInterval] = [
            1.03, 1.17, 1.41, 1.88, 2.05, 2.31, 2.74, 3.02, 3.19, 3.55, 4.01
        ]
        let clock10 = LyricsPresentationClock(
            authoritativePosition: 0.95,
            receivedAtMonotonicTime: 0,
            isPlaying: true,
            trackID: "track-10",
            trackDuration: 30.0
        )
        var index: Int? = nil
        var crossings: [(playhead: TimeInterval, index: Int)] = []
        var pollWouldHaveFired = 0
        let sampleStep = 0.01
        var lastPoll = 0.0
        for step in 0...400 {
            let mono = Double(step) * sampleStep
            let playhead = clock10.presentationTime(at: mono)
            if mono - lastPoll >= 1.0 {
                pollWouldHaveFired += 1
                lastPoll = mono
            }
            let nextIndex: Int? = {
                var lower = 0
                var upper = lineStarts.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if lineStarts[middle] <= playhead {
                        lower = middle + 1
                    } else {
                        upper = middle
                    }
                }
                return lower == 0 ? nil : lower - 1
            }()
            if nextIndex != index {
                if let nextIndex {
                    crossings.append((playhead, nextIndex))
                }
                index = nextIndex
            }
            if let current = index,
               let boundary = LyricBoundary.nextTime(afterIndex: current, timestamps: lineStarts) {
                let delay = boundary - playhead
                assert(delay > 0 || nextIndex == lineStarts.count - 1 || playhead + 0.0005 >= boundary,
                       "scheduled delay must target the next lyric timestamp")
            }
        }
        assert(crossings.count == 11, "expected 11 unique line activations, got \(crossings.count)")
        for (offset, crossing) in crossings.enumerated() {
            let expected = lineStarts[offset]
            let error = crossing.playhead - expected
            assert(error >= -0.0001 && error < sampleStep + 0.0001,
                   "crossing \(offset) at \(crossing.playhead) not at lyric start \(expected)")
            let fiveHzActivation = (expected / 0.2).rounded(.up) * 0.2
            let fiveHzError = fiveHzActivation - expected
            if fiveHzError > sampleStep {
                assert(error + 0.0001 < fiveHzError,
                       "crossing \(offset) no better than 0.2s tick (\(crossing.playhead) vs 5Hz \(fiveHzActivation))")
            }
        }
        let firstTenSpan = crossings[9].playhead - crossings[0].playhead
        assert(firstTenSpan < 3.0, "10 crossings should not wait on 1s/2s polls; span=\(firstTenSpan)")
        assert(pollWouldHaveFired >= 3, "simulation long enough that a 1s poll would have fired")

        print("[11] Testing poll anti-regression only protects the just-crossed boundary...")
        assert(
            LyricIndexAntiRegression.shouldSuppressPollRegression(
                isPlaying: true,
                proposedIndex: 32,
                currentIndex: 33,
                confirmedIndex: 33,
                confirmedLineStart: 87.78,
                incomingTime: 87.63,
                nowMonotonic: 100.08,
                confirmedAtMonotonic: 100.00
            )
        )
        assert(
            LyricIndexAntiRegression.shouldSuppressPollRegression(
                isPlaying: true,
                proposedIndex: 17,
                currentIndex: 18,
                confirmedIndex: 18,
                confirmedLineStart: 69.530,
                incomingTime: 69.523,
                nowMonotonic: 100.67,
                confirmedAtMonotonic: 100.00
            ),
            "poll 0.67s after a crossing must still suppress"
        )
        assert(
            !LyricIndexAntiRegression.shouldSuppressPollRegression(
                isPlaying: true,
                proposedIndex: 32,
                currentIndex: 33,
                confirmedIndex: 33,
                confirmedLineStart: 87.78,
                incomingTime: 87.63,
                nowMonotonic: 102.00,
                confirmedAtMonotonic: 100.00
            ),
            "expired window must not suppress"
        )
        assert(
            !LyricIndexAntiRegression.shouldSuppressPollRegression(
                isPlaying: true,
                proposedIndex: 20,
                currentIndex: 33,
                confirmedIndex: 33,
                confirmedLineStart: 87.78,
                incomingTime: 60.62,
                nowMonotonic: 100.08,
                confirmedAtMonotonic: 100.00
            ),
            "multi-line backward seek must not suppress"
        )
        assert(
            !LyricIndexAntiRegression.shouldSuppressPollRegression(
                isPlaying: false,
                proposedIndex: 32,
                currentIndex: 33,
                confirmedIndex: 33,
                confirmedLineStart: 87.78,
                incomingTime: 87.63,
                nowMonotonic: 100.08,
                confirmedAtMonotonic: 100.00
            ),
            "paused clock must not use poll anti-regression"
        )

        print("[12] Testing presentation-only advance/delay/reset semantics...")
        let advanceByTwoSeconds = LyricsPresentationClock(
            authoritativePosition: 10,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "offset",
            trackDuration: 30,
            presentationOffset: 2.0
        )
        let delayByTwoSeconds = LyricsPresentationClock(
            authoritativePosition: 10,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "offset",
            trackDuration: 30,
            presentationOffset: -2.0
        )
        let reset = LyricsPresentationClock(
            authoritativePosition: 10,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "offset",
            trackDuration: 30,
            presentationOffset: 0
        )
        assert(abs(advanceByTwoSeconds.playbackTime(at: 100) - 10.0) < 1e-6,
               "+offset must not move the playback-domain time")
        assert(abs(delayByTwoSeconds.playbackTime(at: 100) - 10.0) < 1e-6,
               "-offset must not move the playback-domain time")
        assert(abs(advanceByTwoSeconds.presentationTime(at: 100) - 12.0) < 1e-6,
               "正 offset 2s must move lyrics earlier: presentation 10s -> 12s")
        assert(abs(delayByTwoSeconds.presentationTime(at: 100) - 8.0) < 1e-6,
               "负 offset 2s must move lyrics later: presentation 10s -> 8s")
        assert(abs(reset.presentationTime(at: 100) - 10) < 1e-6)
        let sourceLine = LyricLine(timestamp: 10, originalText: "unchanged")
        assert(sourceLine.timestamp == 10, "presentation offset must not mutate source timestamps")

        print("[13] Testing lyric advance/delay against raw playback cases...")
        let advanceCase = LyricsPresentationClock(
            authoritativePosition: 8,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "advance-case",
            trackDuration: 60,
            presentationOffset: 2
        )
        let delayCase = LyricsPresentationClock(
            authoritativePosition: 12,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "delay-case",
            trackDuration: 60,
            presentationOffset: -2
        )
        assert(advanceCase.playbackTime(at: 100) == 8)
        assert(advanceCase.presentationTime(at: 100) == 10)
        assert(delayCase.playbackTime(at: 100) == 12)
        assert(delayCase.presentationTime(at: 100) == 10)

        print("[14] Testing paused offset mutation and independent clamps...")
        let pausedZero = LyricsPresentationClock(
            authoritativePosition: 10,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "paused",
            trackDuration: 60,
            presentationOffset: 0
        )
        let pausedAdvance = pausedZero.withPresentationOffset(2)
        assert(pausedAdvance.playbackTime(at: 999) == 10)
        assert(pausedZero.presentationTime(at: 999) == 10)
        assert(pausedAdvance.presentationTime(at: 999) == 12)

        let lowerBound = LyricsPresentationClock(
            authoritativePosition: 0,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "clamp",
            trackDuration: 60,
            presentationOffset: -2
        )
        let upperBound = LyricsPresentationClock(
            authoritativePosition: 60,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "clamp",
            trackDuration: 60,
            presentationOffset: 2
        )
        assert(lowerBound.playbackTime(at: 100) == 0)
        assert(lowerBound.presentationTime(at: 100) == 0)
        assert(upperBound.playbackTime(at: 100) == 60)
        assert(upperBound.presentationTime(at: 100) == 60)

        assert(!PlaybackTickTimeUpdatePolicy.shouldPublish(currentTime: 12, nextTime: 12))
        assert(!PlaybackTickTimeUpdatePolicy.shouldPublish(currentTime: 0, nextTime: 0))
        assert(!PlaybackTickTimeUpdatePolicy.shouldPublish(currentTime: 60, nextTime: 60))
        assert(PlaybackTickTimeUpdatePolicy.shouldPublish(currentTime: 12, nextTime: 12.2))
        assert(PlaybackTickTimeUpdatePolicy.shouldPublish(currentTime: 12, nextTime: 11.8))
        assert(!PlaybackTickTimeUpdatePolicy.shouldFinishMockPlayback(isPlaying: false, currentTime: 60, duration: 60))
        assert(PlaybackTickTimeUpdatePolicy.shouldFinishMockPlayback(isPlaying: true, currentTime: 60, duration: 60))
        assert(!PlaybackTickTimeUpdatePolicy.shouldFinishMockPlayback(isPlaying: true, currentTime: 59, duration: 60))

        print("PASS: Presentation clock contract verified")
    }
}
