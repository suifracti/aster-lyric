import Foundation

private actor InvocationCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

@main
@MainActor
struct AppleMusicProviderContract {
    static func main() async {
        let separator = String(UnicodeScalar(30))
        let readyRunnerCalls = InvocationCounter()

        // A ready environment reaches the injected script runner and parses its response.
        let provider = AppleMusicDesktopProvider(
            scriptRunner: { script, timeout in
                await readyRunnerCalls.record()
                if script.contains("current track") {
                    precondition(timeout == 3)
                    return [
                        "playing", "45.2", "七里香", "周杰伦", "七里香", "299.0",
                        "3B1F8E109761A672", "0"
                    ].joined(separator: separator)
                }
                precondition(timeout == 3)
                return ""
            },
            applicationIsInstalled: { true },
            applicationIsRunning: { true }
        )

        let snapshot = await provider.refresh()
        precondition(snapshot.status == .ready, "Status should be ready")
        precondition(snapshot.track?.title == "七里香", "Title mismatch")
        precondition(snapshot.track?.artist == "周杰伦", "Artist mismatch")
        precondition(snapshot.track?.album == "七里香", "Album mismatch")
        precondition(snapshot.track?.duration == 299.0, "Duration mismatch")
        precondition(snapshot.track?.id == "applemusic:3B1F8E109761A672", "Track ID mismatch")
        precondition(snapshot.isPlaying == true, "isPlaying mismatch")
        precondition(snapshot.position == 45.2, "Position mismatch")
        precondition(snapshot.sourceIdentity == .appleMusic, "Source identity mismatch")
        let readyRunnerCallCount = await readyRunnerCalls.value()
        precondition(readyRunnerCallCount == 1, "Ready environment should call the script runner")

        // Neither negative environment should enter the external script runner.
        let notRunningRunnerCalls = InvocationCounter()
        let notRunningProvider = AppleMusicDesktopProvider(
            scriptRunner: { _, _ in
                await notRunningRunnerCalls.record()
                return ""
            },
            applicationIsInstalled: { true },
            applicationIsRunning: { false }
        )
        let notRunningSnapshot = await notRunningProvider.refresh()
        precondition(notRunningSnapshot.status == .notRunning, "Running check should return .notRunning")
        let notRunningRunnerCallCount = await notRunningRunnerCalls.value()
        precondition(notRunningRunnerCallCount == 0, "Not-running environment must not call the script runner")

        let notInstalledRunnerCalls = InvocationCounter()
        let notInstalledProvider = AppleMusicDesktopProvider(
            scriptRunner: { _, _ in
                await notInstalledRunnerCalls.record()
                return ""
            },
            applicationIsInstalled: { false },
            applicationIsRunning: { false }
        )
        let notInstalledSnapshot = await notInstalledProvider.refresh()
        precondition(notInstalledSnapshot.status == .notInstalled, "Installation check should return .notInstalled")
        let notInstalledRunnerCallCount = await notInstalledRunnerCalls.value()
        precondition(notInstalledRunnerCallCount == 0, "Not-installed environment must not call the script runner")

        // Empty track parsing remains unchanged.
        let emptyProvider = AppleMusicDesktopProvider(
            scriptRunner: { _, _ in
                [
                    "stopped", "0", "", "", "", "0", "", "0"
                ].joined(separator: separator)
            },
            applicationIsInstalled: { true },
            applicationIsRunning: { true }
        )
        let emptySnapshot = await emptyProvider.refresh()
        precondition(emptySnapshot.status == .noTrack, "Empty state should be .noTrack")
        precondition(emptySnapshot.track == nil, "Empty track should be nil")
        precondition(!emptySnapshot.isPlaying, "Empty track should not be playing")

        // PlaybackProviderState user-facing messages remain unchanged.
        let state = PlaybackProviderState.ready
        precondition(state.userFacingMessage(for: "Apple Music") == "Apple Music 已连接")
        let notRunningState = PlaybackProviderState.notRunning
        precondition(notRunningState.userFacingMessage(for: "Apple Music") == "Apple Music 未运行")

        print("Apple Music provider contract passed")
    }
}
