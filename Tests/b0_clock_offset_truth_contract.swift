import Combine
import Foundation

@MainActor
private final class B0PublishedOrderProbe {
    @Published var value: Double = 0
    private var cancellables: Set<AnyCancellable> = []
    private(set) var receivedValue: Double?
    private(set) var storedValueAtCallback: Double?

    init() {
        $value
            .dropFirst()
            .sink { [weak self] newValue in
                self?.receivedValue = newValue
                self?.storedValueAtCallback = self?.value
            }
            .store(in: &cancellables)
    }
}

/// B0 runtime probe for the production LyricsPresentationClock.
///
/// This intentionally compiles the production clock from Models.swift rather
/// than reimplementing it in a fake. No player, database, Keychain, or AppKit
/// surface is constructed here; UI and PlaybackState routing are checked by
/// the companion source assertions in b0_clock_offset_truth_contract.sh.
@main
@MainActor
struct B0ClockOffsetTruthContract {
    private static let tolerance = 0.000001

    private static func assertClose(
        _ actual: TimeInterval,
        _ expected: TimeInterval,
        _ label: String
    ) {
        guard abs(actual - expected) < tolerance else {
            print("FAIL: \(label): expected \(expected), got \(actual)")
            exit(1)
        }
    }

    private static func clamped(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(duration, max(0, value))
    }

    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let suiteName = environment["B0_DEFAULTS_SUITE"] ?? "com.spotifylyrics.tests.b0-clock-fallback"
        let temporaryDatabaseURL = URL(
            fileURLWithPath: environment["B0_TEMP_DATABASE"] ?? "/tmp/spotifylyrics-b0-unused.sqlite3"
        )
        guard let suite = UserDefaults(suiteName: suiteName) else {
            print("FAIL: could not create named defaults suite")
            exit(1)
        }
        precondition(suite !== UserDefaults.standard, "B0 must not use standard defaults")
        suite.set("clock-only", forKey: "b0.marker")
        defer { suite.removePersistentDomain(forName: suiteName) }

        print("B0 isolation: suite=\(suiteName) temporaryDatabase=\(temporaryDatabaseURL.path) databaseOpened=false")
        print("case\tmode\traw\telapsed\toffset\tpresentation\tstatus")

        let raw: TimeInterval = 10
        let duration: TimeInterval = 60
        let anchor: TimeInterval = 100
        let playingNow: TimeInterval = 101.25
        let pausedNow: TimeInterval = 109

        for isPlaying in [true, false] {
            let now = isPlaying ? playingNow : pausedNow
            let elapsed = isPlaying ? now - anchor : 0
            let mode = isPlaying ? "playing" : "paused"

            for offset in [0.0, 2.0, -2.0] {
                let clock = LyricsPresentationClock(
                    authoritativePosition: raw,
                    receivedAtMonotonicTime: anchor,
                    isPlaying: isPlaying,
                    trackID: "b0-track",
                    trackDuration: duration,
                    presentationOffset: offset
                )
                let expected = clamped(raw + elapsed + offset, duration: duration)
                let actual = clock.presentationTime(at: now)
                assertClose(actual, expected, "\(mode) offset=\(offset)")
                assertClose(clock.authoritativePosition, raw, "\(mode) raw remains authoritative")
                print(
                    "raw-10-\(mode)-offset-\(offset)\t\(mode)\t\(raw)\t\(elapsed)\t\(offset)\t\(actual)\tPASS"
                )
            }
        }

        print("case\tmode\tlyricTimestamp\toffset\trawArrival\tpresentationAtArrival\tstatus")
        for offset in [0.0, 2.0, -2.0] {
            let expectedRawArrival = 10 - offset
            let playingClock = LyricsPresentationClock(
                authoritativePosition: 0,
                receivedAtMonotonicTime: anchor,
                isPlaying: true,
                trackID: "b0-track",
                trackDuration: duration,
                presentationOffset: offset
            )
            let playingPresentation = playingClock.presentationTime(at: anchor + expectedRawArrival)
            assertClose(playingPresentation, 10, "playing lyric arrival offset=\(offset)")
            print(
                "lyric-10-playing-offset-\(offset)\tplaying\t10\t\(offset)\t\(expectedRawArrival)\t\(playingPresentation)\tPASS"
            )

            let pausedClock = LyricsPresentationClock(
                authoritativePosition: expectedRawArrival,
                receivedAtMonotonicTime: anchor,
                isPlaying: false,
                trackID: "b0-track",
                trackDuration: duration,
                presentationOffset: offset
            )
            let pausedPresentation = pausedClock.presentationTime(at: pausedNow)
            assertClose(pausedPresentation, 10, "paused lyric arrival offset=\(offset)")
            print(
                "lyric-10-paused-offset-\(offset)\tpaused\t10\t\(offset)\t\(expectedRawArrival)\t\(pausedPresentation)\tPASS"
            )
        }

        let lowerClamp = LyricsPresentationClock(
            authoritativePosition: 0,
            receivedAtMonotonicTime: anchor,
            isPlaying: false,
            trackID: "b0-track",
            trackDuration: duration,
            presentationOffset: -2
        ).presentationTime(at: pausedNow)
        assertClose(lowerClamp, 0, "lower duration clamp")
        print("clamp-lower\tpaused\t0\t0\t-2\t\(lowerClamp)\tPASS")

        let upperClamp = LyricsPresentationClock(
            authoritativePosition: 59,
            receivedAtMonotonicTime: anchor,
            isPlaying: false,
            trackID: "b0-track",
            trackDuration: duration,
            presentationOffset: 2
        ).presentationTime(at: pausedNow)
        assertClose(upperClamp, duration, "upper duration clamp")
        print("clamp-upper\tpaused\t59\t0\t2\t\(upperClamp)\tPASS")

        print("PASS: B0 production clock raw/elapsed/offset/presentation and clamp cases")

        let publishedOrder = B0PublishedOrderProbe()
        publishedOrder.value = 2
        precondition(publishedOrder.receivedValue == 2, "@Published callback must receive the new value")
        precondition(
            publishedOrder.storedValueAtCallback == 0,
            "@Published sink must be checked for willSet ordering"
        )
        precondition(publishedOrder.value == 2, "stored value must update after callback")
        print("published-will-set\treceived=2\tstored-at-callback=0\tfinal=2\tPASS")
        print("PASS: @Published ordering probe for paused offset update path")
    }
}
