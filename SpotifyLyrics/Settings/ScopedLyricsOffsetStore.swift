import Combine
import Foundation

/// A presentation offset belongs to one persisted track/version pair. The
/// track key must already be resolved through the repository's redirect map.
public struct LyricsOffsetScope: Equatable, Hashable, Sendable {
    public let canonicalTrackStableKey: String
    public let lyricsVersionID: UUID

    public init?(canonicalTrackStableKey: String, lyricsVersionID: UUID) {
        let key = canonicalTrackStableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        self.canonicalTrackStableKey = key
        self.lyricsVersionID = lyricsVersionID
    }
}

/// Shared UserDefaults storage and live-scope projection for lyric-only
/// offsets. The legacy global preference is intentionally never read or
/// written by this store.
public final class ScopedLyricsOffsetStore: ObservableObject {
    public static let legacyGlobalDefaultsKey = "lyrics.presentationOffset.v1"
    public static let scopedDefaultsPrefix = "lyrics.presentationOffset.scoped.v1."

    @Published public private(set) var activeScope: LyricsOffsetScope?
    @Published public private(set) var activeOffset: Double = 0
    /// Changes when any pair is edited, including a non-live editor pair.
    @Published public private(set) var storageRevision: UInt64 = 0

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .lyricsQ) {
        self.defaults = defaults
        self.activeScope = nil
        self.activeOffset = 0
    }

    /// Activating no scope, an unsaved draft, or an unknown version always
    /// projects zero and never creates a persistent key.
    public func activate(_ scope: LyricsOffsetScope?) {
        guard activeScope != scope else { return }
        activeScope = scope
        activeOffset = scope.map(value(for:)) ?? 0
    }

    public func value(for scope: LyricsOffsetScope) -> Double {
        guard let stored = defaults.object(forKey: Self.defaultsKey(for: scope)) as? NSNumber else {
            return 0
        }
        return Self.normalized(stored.doubleValue)
    }

    @discardableResult
    public func setActiveValue(_ value: Double) -> Bool {
        guard let activeScope else { return false }
        setValue(value, for: activeScope)
        return true
    }

    public func setValue(_ value: Double, for scope: LyricsOffsetScope) {
        let normalized = Self.normalized(value)
        defaults.set(normalized, forKey: Self.defaultsKey(for: scope))
        storageRevision &+= 1
        if activeScope == scope {
            activeOffset = normalized
        }
    }

    /// Removes only this pair's value; absent values are represented as zero.
    public func resetValue(for scope: LyricsOffsetScope) {
        defaults.removeObject(forKey: Self.defaultsKey(for: scope))
        storageRevision &+= 1
        if activeScope == scope {
            activeOffset = 0
        }
    }

    @discardableResult
    public func resetActiveValue() -> Bool {
        guard let activeScope else { return false }
        resetValue(for: activeScope)
        return true
    }

    public static func defaultsKey(for scope: LyricsOffsetScope) -> String {
        let encodedTrack = Data(scope.canonicalTrackStableKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(scopedDefaultsPrefix)\(encodedTrack).\(scope.lyricsVersionID.uuidString.lowercased())"
    }

    private static func normalized(_ value: Double) -> Double {
        min(10, max(-10, value.isFinite ? value : 0))
    }
}

/// Resolves a requested live scope asynchronously and invalidates late results
/// when the track, saved version, or lyrics-session generation changes.
@MainActor
public final class LyricsOffsetScopeBinding {
    private struct Request: Equatable {
        let trackStableKey: String
        let versionID: UUID
        let sessionRevision: UInt64
    }

    private let store: ScopedLyricsOffsetStore
    private var generation: UInt64 = 0
    private var request: Request?
    private var task: Task<Void, Never>?

    public init(store: ScopedLyricsOffsetStore) {
        self.store = store
    }

    deinit {
        task?.cancel()
    }

    public func clear() {
        generation &+= 1
        request = nil
        task?.cancel()
        task = nil
        store.activate(nil)
    }

    public func bind(
        trackStableKey: String?,
        lyricsVersionID: UUID?,
        sessionRevision: UInt64,
        resolver: (any LyricsOffsetScopeResolving)?
    ) {
        guard let trackStableKey,
              !trackStableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let lyricsVersionID,
              let resolver else {
            clear()
            return
        }

        let nextRequest = Request(
            trackStableKey: trackStableKey,
            versionID: lyricsVersionID,
            sessionRevision: sessionRevision
        )
        guard request != nextRequest else { return }

        generation &+= 1
        let requestGeneration = generation
        request = nextRequest
        task?.cancel()
        store.activate(nil)

        task = Task { [weak self, resolver] in
            do {
                let canonicalKey = try await resolver.canonicalStableKeyForSavedLyricsVersion(
                    trackStableKey: nextRequest.trackStableKey,
                    versionID: nextRequest.versionID
                )
                guard !Task.isCancelled,
                      let canonicalKey,
                      let scope = LyricsOffsetScope(
                        canonicalTrackStableKey: canonicalKey,
                        lyricsVersionID: nextRequest.versionID
                      ),
                      let self,
                      self.generation == requestGeneration,
                      self.request == nextRequest else {
                    return
                }
                self.store.activate(scope)
                self.task = nil
            } catch {
                guard let self,
                      self.generation == requestGeneration,
                      self.request == nextRequest else { return }
                self.request = nil
                self.task = nil
                self.store.activate(nil)
            }
        }
    }
}
