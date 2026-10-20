import Foundation
import XCTest
@testable import SpotifyLyrics

private struct OffsetScopeLookup: Hashable, Sendable {
    let trackKey: String
    let versionID: UUID
}

private actor OffsetScopeFixtureResolver: LyricsOffsetScopeResolving {
    private let canonicalKeys: [OffsetScopeLookup: String]
    private let delayedTrackKeys: Set<String>
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(
        canonicalKeys: [OffsetScopeLookup: String],
        delayedTrackKeys: Set<String> = [],
        delayNanoseconds: UInt64 = 0
    ) {
        self.canonicalKeys = canonicalKeys
        self.delayedTrackKeys = delayedTrackKeys
        self.delayNanoseconds = delayNanoseconds
    }

    func canonicalStableKeyForSavedLyricsVersion(
        trackStableKey: String,
        versionID: UUID
    ) async throws -> String? {
        calls += 1
        if delayedTrackKeys.contains(trackStableKey) {
            await waitIgnoringCancellation(delayNanoseconds)
        }
        return canonicalKeys[OffsetScopeLookup(trackKey: trackStableKey, versionID: versionID)]
    }

    func callCount() -> Int { calls }

    private func waitIgnoringCancellation(_ nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
    }
}

final class ScopedLyricsOffsetPresentationTests: XCTestCase {
    func testUnscopedStoreKeepsLegacyValueAndStoresPairsIndependently() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacyKey = ScopedLyricsOffsetStore.legacyGlobalDefaultsKey
        let legacyValue = NSNumber(value: 1.375)
        defaults.set(legacyValue, forKey: legacyKey)

        let store = ScopedLyricsOffsetStore(defaults: defaults)
        XCTAssertNil(store.activeScope)
        XCTAssertEqual(store.activeOffset, 0)
        XCTAssertFalse(store.setActiveValue(4))
        XCTAssertEqual(defaults.object(forKey: legacyKey) as? NSNumber, legacyValue)

        let trackA = try XCTUnwrap(LyricsOffsetScope(canonicalTrackStableKey: "track-a", lyricsVersionID: UUID()))
        let trackAV2 = try XCTUnwrap(LyricsOffsetScope(canonicalTrackStableKey: "track-a", lyricsVersionID: UUID()))
        let trackB = try XCTUnwrap(LyricsOffsetScope(canonicalTrackStableKey: "track-b", lyricsVersionID: trackA.lyricsVersionID))

        store.activate(trackA)
        XCTAssertEqual(store.activeOffset, 0)
        XCTAssertTrue(store.setActiveValue(0.75))
        store.setValue(-0.5, for: trackAV2)
        store.setValue(1.25, for: trackB)

        store.activate(trackAV2)
        XCTAssertEqual(store.activeOffset, -0.5)
        store.activate(trackB)
        XCTAssertEqual(store.activeOffset, 1.25)
        store.activate(trackA)
        XCTAssertEqual(store.activeOffset, 0.75)

        let reopenedStore = ScopedLyricsOffsetStore(defaults: defaults)
        reopenedStore.activate(trackAV2)
        XCTAssertEqual(reopenedStore.activeOffset, -0.5)
        XCTAssertEqual(defaults.object(forKey: legacyKey) as? NSNumber, legacyValue)
    }

    func testScopeValuesClampNonFiniteInputAndResetOnlyTheRequestedPair() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ScopedLyricsOffsetStore(defaults: defaults)
        let a = try XCTUnwrap(LyricsOffsetScope(canonicalTrackStableKey: "track-a", lyricsVersionID: UUID()))
        let b = try XCTUnwrap(LyricsOffsetScope(canonicalTrackStableKey: "track-b", lyricsVersionID: UUID()))
        store.setValue(3, for: a)
        store.setValue(-0.5, for: b)

        store.activate(a)
        XCTAssertTrue(store.setActiveValue(50))
        XCTAssertEqual(store.activeOffset, 10)
        XCTAssertTrue(store.setActiveValue(-50))
        XCTAssertEqual(store.activeOffset, -10)
        XCTAssertTrue(store.setActiveValue(.infinity))
        XCTAssertEqual(store.activeOffset, 0)
        XCTAssertTrue(store.setActiveValue(.nan))
        XCTAssertEqual(store.activeOffset, 0)
        store.setValue(25, for: a)
        XCTAssertEqual(store.value(for: a), 10)
        store.setValue(-25, for: a)
        XCTAssertEqual(store.value(for: a), -10)
        store.setValue(3, for: a)

        store.resetValue(for: a)
        XCTAssertEqual(store.value(for: a), 0)
        XCTAssertEqual(store.value(for: b), -0.5)
        XCTAssertTrue(store.resetActiveValue())
        XCTAssertEqual(store.value(for: a), 0)
        store.activate(b)
        XCTAssertEqual(store.activeOffset, -0.5)
        XCTAssertTrue(store.resetActiveValue())
        XCTAssertEqual(store.value(for: b), 0)
        XCTAssertTrue(store.resetActiveValue(), "reset reports success while a scope is active, even when its value is already zero")
    }

    @MainActor
    func testBindingCanonicalizesAliasesAndClearsUnknownScopes() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ScopedLyricsOffsetStore(defaults: defaults)
        let binder = LyricsOffsetScopeBinding(store: store)
        let alias = "historical-track-a"
        let canonical = "track-a"
        let savedVersion = UUID()
        let unknownVersion = UUID()
        let resolver = OffsetScopeFixtureResolver(canonicalKeys: [
            OffsetScopeLookup(trackKey: alias, versionID: savedVersion): canonical
        ])

        binder.bind(trackStableKey: alias, lyricsVersionID: savedVersion, sessionRevision: 1, resolver: resolver)
        let didResolve = await waitUntil { store.activeScope?.canonicalTrackStableKey == canonical }
        XCTAssertTrue(didResolve)
        XCTAssertEqual(store.activeScope?.lyricsVersionID, savedVersion)

        XCTAssertTrue(store.setActiveValue(0.75))
        binder.bind(trackStableKey: alias, lyricsVersionID: unknownVersion, sessionRevision: 2, resolver: resolver)
        XCTAssertNil(store.activeScope)
        XCTAssertEqual(store.activeOffset, 0)
        let didFinishUnknownLookup = await waitUntil { await resolver.callCount() >= 2 }
        XCTAssertTrue(didFinishUnknownLookup)
        XCTAssertNil(store.activeScope)
        XCTAssertFalse(store.setActiveValue(2))

        binder.bind(trackStableKey: nil, lyricsVersionID: nil, sessionRevision: 3, resolver: resolver)
        XCTAssertNil(store.activeScope)
        XCTAssertEqual(store.activeOffset, 0)
    }

    @MainActor
    func testLateScopeResolutionCannotReplaceTheNewerLivePair() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ScopedLyricsOffsetStore(defaults: defaults)
        let binder = LyricsOffsetScopeBinding(store: store)
        let versionA = UUID()
        let versionB = UUID()
        let resolver = OffsetScopeFixtureResolver(
            canonicalKeys: [
                OffsetScopeLookup(trackKey: "track-a-alias", versionID: versionA): "track-a",
                OffsetScopeLookup(trackKey: "track-b", versionID: versionB): "track-b"
            ],
            delayedTrackKeys: ["track-a-alias"],
            delayNanoseconds: 120_000_000
        )

        binder.bind(trackStableKey: "track-a-alias", lyricsVersionID: versionA, sessionRevision: 1, resolver: resolver)
        binder.bind(trackStableKey: "track-b", lyricsVersionID: versionB, sessionRevision: 2, resolver: resolver)
        let didResolveB = await waitUntil { store.activeScope?.lyricsVersionID == versionB }
        XCTAssertTrue(didResolveB)
        XCTAssertTrue(store.setActiveValue(1.25))

        let lateACompleted = await waitUntil { await resolver.callCount() >= 2 }
        XCTAssertTrue(lateACompleted)
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(store.activeScope?.canonicalTrackStableKey, "track-b")
        XCTAssertEqual(store.activeScope?.lyricsVersionID, versionB)
        XCTAssertEqual(store.activeOffset, 1.25)
    }

    func testPresentationOffsetChangesLyricsClockWithoutMovingPlaybackAnchor() {
        let clock = LyricsPresentationClock(
            authoritativePosition: 42,
            receivedAtMonotonicTime: 100,
            isPlaying: false,
            trackID: "offset-test",
            trackDuration: 180,
            presentationOffset: 0
        )
        let adjusted = clock.withPresentationOffset(-0.5)

        XCTAssertEqual(clock.playbackTime(at: 500), adjusted.playbackTime(at: 500))
        XCTAssertEqual(adjusted.presentationTime(at: 500), 41.5)
        XCTAssertEqual(clock.authoritativePosition, adjusted.authoritativePosition)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "SpotifyLyrics-Presentation-Offset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
