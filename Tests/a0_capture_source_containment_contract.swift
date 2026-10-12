import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private struct FakeCaptureIO {
    var discoveryCalls = 0
    var captureStartCalls = 0
    var providerSeekCalls = 0
}

private func tryAutomaticCapture(
    context: AutomaticLiveCaptureContext,
    spotifyProcessDiscoverable: Bool,
    io: inout FakeCaptureIO
) -> AutomaticLiveCaptureEligibility {
    // This is deliberately the production gate followed by fake external I/O.
    // The process flag is present only to prove that process discovery cannot
    // authorize an unsupported active playback source.
    let eligibility = AutomaticLiveCaptureSourceGate.evaluate(context)
    guard eligibility.isAllowed else { return eligibility }
    _ = spotifyProcessDiscoverable
    io.discoveryCalls += 1
    io.captureStartCalls += 1
    return eligibility
}

private func tryAdopt(
    guardToken: AutomaticLiveCaptureSessionGuard,
    currentSource: PlaybackSourceIdentity,
    currentIdentity: String?,
    currentGeneration: UInt64,
    providerReady: Bool,
    io: inout FakeCaptureIO
) -> Bool {
    guard guardToken.accepts(
        source: currentSource,
        identityKey: currentIdentity,
        generation: currentGeneration,
        providerReady: providerReady
    ) else {
        return false
    }
    io.captureStartCalls += 0 // adoption has no capture side effect
    return true
}

@main
struct A0CaptureSourceContainmentContract {
    static func main() {
        let spotifyA = AutomaticLiveCaptureContext(
            source: .spotifyDesktop,
            providerIsReady: true,
            hasLiveTrack: true,
            isMockPreview: false,
            isPlaying: true,
            identityKey: "track:A"
        )
        let musicA = AutomaticLiveCaptureContext(
            source: .appleMusic,
            providerIsReady: true,
            hasLiveTrack: true,
            isMockPreview: false,
            isPlaying: true,
            identityKey: "track:A"
        )
        let mock = AutomaticLiveCaptureContext(
            source: .mockPreview,
            providerIsReady: true,
            hasLiveTrack: true,
            isMockPreview: true,
            isPlaying: true,
            identityKey: "track:preview"
        )
        let unknown = AutomaticLiveCaptureContext(
            source: .unknown,
            providerIsReady: true,
            hasLiveTrack: true,
            isMockPreview: false,
            isPlaying: true,
            identityKey: "track:unknown"
        )
        let pausedSpotify = AutomaticLiveCaptureContext(
            source: .spotifyDesktop,
            providerIsReady: true,
            hasLiveTrack: true,
            isMockPreview: false,
            isPlaying: false,
            identityKey: "track:A"
        )

        var io = FakeCaptureIO()

        // A — active Spotify, discoverable: the supported path enters the
        // existing discovery/capture I/O exactly once.
        let a = tryAutomaticCapture(context: spotifyA, spotifyProcessDiscoverable: true, io: &io)
        require(a.isAllowed, "Spotify source is allowed")
        require(io.discoveryCalls == 1 && io.captureStartCalls == 1, "Spotify starts one capture")

        // B/C — Music active, whether or not Spotify is also discoverable:
        // source capability fails closed before discovery.
        let b = tryAutomaticCapture(context: musicA, spotifyProcessDiscoverable: false, io: &io)
        require(!b.isAllowed && b.reason.contains("source"), "Music is explicitly unsupported")
        let c = tryAutomaticCapture(context: musicA, spotifyProcessDiscoverable: true, io: &io)
        require(!c.isAllowed && c.reason.contains("source"), "Spotify process cannot override active Music source")
        require(io.discoveryCalls == 1 && io.captureStartCalls == 1, "Music never reaches Spotify discovery")

        // D — both players may exist, but an active Spotify snapshot remains
        // eligible; the gate does not infer source from process existence.
        let d = tryAutomaticCapture(context: spotifyA, spotifyProcessDiscoverable: true, io: &io)
        require(d.isAllowed, "active Spotify remains eligible")
        require(io.discoveryCalls == 2 && io.captureStartCalls == 2, "second eligible Spotify capture starts")

        // G — mock/unknown/preview cannot start capture.
        for context in [mock, unknown] {
            let result = tryAutomaticCapture(context: context, spotifyProcessDiscoverable: true, io: &io)
            require(!result.isAllowed, "unsupported or preview source fails closed")
        }
        require(io.discoveryCalls == 2 && io.captureStartCalls == 2, "mock/unknown never reach discovery")

        // Automatic entry requires active playback; the lower-level
        // coordinator may retain its existing paused-session/wait-for-resume
        // behavior without widening source capability.
        require(
            !AutomaticLiveCaptureSourceGate.evaluate(pausedSpotify).isAllowed,
            "automatic capture rejects paused Spotify"
        )
        require(
            AutomaticLiveCaptureSourceGate.evaluate(pausedSpotify, requiresPlaying: false).isAllowed,
            "coordinator can preserve paused Spotify wait behavior"
        )

        // E/F — one production session token covers source, track identity,
        // and generation. A stale result must not reach adoption.
        let token = AutomaticLiveCaptureSessionGuard(
            source: .spotifyDesktop,
            identityKey: "track:A",
            generation: 41
        )
        require(
            token.accepts(source: .spotifyDesktop, identityKey: "track:A", generation: 41, providerReady: true),
            "current Spotify A result is adoptable"
        )
        require(
            !token.accepts(source: .spotifyDesktop, identityKey: "track:B", generation: 41, providerReady: true),
            "track B rejects old A result"
        )
        require(
            !token.accepts(source: .appleMusic, identityKey: "track:A", generation: 41, providerReady: true),
            "Music rejects old Spotify result"
        )
        require(
            !token.accepts(source: .spotifyDesktop, identityKey: "track:A", generation: 42, providerReady: true),
            "new generation rejects old result"
        )
        require(
            !token.accepts(source: .spotifyDesktop, identityKey: "track:A", generation: 41, providerReady: false),
            "unavailable provider rejects adoption"
        )

        var staleIO = FakeCaptureIO()
        require(
            tryAdopt(
                guardToken: token,
                currentSource: .appleMusic,
                currentIdentity: "track:A",
                currentGeneration: 41,
                providerReady: true,
                io: &staleIO
            ) == false,
            "source change produces zero adoption"
        )
        require(staleIO.captureStartCalls == 0, "stale source cannot invoke adopter")

        print("a0_capture_source_containment_contract: PASS")
    }
}
