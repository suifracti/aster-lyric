import Combine
import Foundation

/// The persisted selection boundary for the Presentation Catalog.
///
/// This object stores only stable presentation IDs. It deliberately does not
/// know about playback, lyrics sessions, timers, windows, caches, or SQLite.
/// A preview is an in-memory overlay; only an explicit Apply writes the map to
/// UserDefaults.
public final class PresentationSelectionStore: ObservableObject {
    public static let storageKey = "presentation.selectedStableIDs.v1"

    public static func runtimeKey(for category: PresentationCategory) -> String {
        "presentation.active.\(category.rawValue).v1"
    }

    public let catalog: PresentationCatalog

    @Published public private(set) var persistedSelections: [String: String]
    @Published public private(set) var transientPreviewSelections: [String: String] = [:]

    private let defaults: UserDefaults
    private var previewBaseline: [String: String]?

    public init(
        defaults: UserDefaults = .lyricsQ,
        catalog: PresentationCatalog = .shared
    ) {
        self.defaults = defaults
        self.catalog = catalog
        self.persistedSelections = Self.loadSelections(defaults: defaults)
        self.persistedSelections = Self.migrateLegacySelections(
            self.persistedSelections,
            defaults: defaults,
            catalog: catalog
        )
        persistIfNeeded()
        debugLog("event=init persisted=\(persistedSelections)")
    }

    /// The exact user value, including an unknown future ID. Keeping this
    /// separate from `currentStableID` allows a future build to recover the
    /// user's choice instead of silently deleting it during fallback.
    public func persistedSelectedStableID(for category: PresentationCategory) -> String? {
        persistedSelections[category.rawValue]
    }

    public func recommendedStableID(for category: PresentationCategory) -> String? {
        catalog.recommended(for: category)?.stableID
    }

    /// The applied runtime ID. Unknown, design-only, archived-only and
    /// unavailable values fail closed to a runnable entry in the same
    /// category. The raw persisted value remains untouched.
    public func currentStableID(for category: PresentationCategory) -> String {
        if let raw = persistedSelectedStableID(for: category), isRunnable(raw, category: category) {
            return raw
        }
        // An unset category keeps the catalog's current runtime choice. This
        // preserves explicitly selected compatible versions while new users
        // receive the current product presentation.
        if persistedSelectedStableID(for: category) == nil,
           let current = catalog.entries(for: category).first(where: {
               $0.status == .current && isRunnable($0)
           }) {
            return current.stableID
        }
        return safeFallbackForUnknownID(for: category)
    }

    public func transientPreviewStableID(for category: PresentationCategory) -> String? {
        transientPreviewSelections[category.rawValue]
    }

    public func effectiveStableID(for category: PresentationCategory) -> String {
        if let preview = transientPreviewStableID(for: category),
           isPreviewable(preview, category: category) {
            return preview
        }
        return currentStableID(for: category)
    }

    public func safeFallbackForUnknownID(for category: PresentationCategory) -> String {
        let candidates = catalog.entries(for: category)
        if let recommended = candidates.first(where: {
            $0.status == .recommended && isRunnable($0)
        }) {
            return recommended.stableID
        }
        if let current = candidates.first(where: {
            $0.status == .current && isRunnable($0)
        }) {
            return current.stableID
        }
        return candidates.first(where: isRunnable)?.stableID
            ?? candidates.first?.stableID
            ?? "(category.rawValue).unavailable.v0"
    }

    /// Starts or updates an in-memory preview. It never writes UserDefaults.
    @discardableResult
    public func beginPreview(category: PresentationCategory, stableID: String) -> Bool {
        guard isPreviewable(stableID, category: category) else { return false }
        if previewBaseline == nil {
            previewBaseline = persistedSelections
        }
        transientPreviewSelections[category.rawValue] = stableID
        debugLog(
            "event=preview category=\(category.rawValue) stableID=\(stableID) "
                + "persisted=\(persistedSelections[category.rawValue] ?? "none") "
                + "transient=\(transientPreviewSelections[category.rawValue] ?? "none")"
        )
        objectWillChange.send()
        return true
    }

    /// Commits all currently previewed values as one UserDefaults update.
    /// Design-only and unavailable entries cannot become formal user
    /// selections. Debug-only entries follow their catalog availability and
    /// are only browseable from Debug; v4 is Release-capable.
    @discardableResult
    public func applyPreview() -> Bool {
        guard !transientPreviewSelections.isEmpty else { return false }
        debugLog("event=apply-before transient=\(transientPreviewSelections)")
        for (rawCategory, stableID) in transientPreviewSelections {
            guard let category = PresentationCategory(rawValue: rawCategory),
                  isRunnable(stableID, category: category) else {
                return false
            }
        }

        for (rawCategory, stableID) in transientPreviewSelections {
            persistedSelections[rawCategory] = stableID
        }
        persistIfNeeded()
        transientPreviewSelections.removeAll()
        previewBaseline = nil
        debugLog("event=apply-after persisted=\(persistedSelections)")
        objectWillChange.send()
        return true
    }

    /// Applies one runnable entry through the same explicit transaction used
    /// by the Release Experience Library.
    @discardableResult
    public func apply(category: PresentationCategory, stableID: String) -> Bool {
        guard beginPreview(category: category, stableID: stableID) else { return false }
        guard applyPreview() else {
            cancelPreview()
            return false
        }
        return true
    }

    /// Cancels the in-memory overlay. Persisted selections are never changed
    /// by Preview, so cancel simply removes the overlay and restores the
    /// applied values.
    public func cancelPreview() {
        debugLog("event=cancel-before transient=\(transientPreviewSelections) persisted=\(persistedSelections)")
        transientPreviewSelections.removeAll()
        previewBaseline = nil
        objectWillChange.send()
    }

    /// Persists the category's recommended runnable entry. If a product
    /// recommendation is not runnable on this build, the safe current runtime
    /// entry is used instead.
    @discardableResult
    public func restoreRecommended(for category: PresentationCategory) -> String {
        let target = catalog.entries(for: category).first(where: {
            $0.status == .recommended && isRunnable($0)
        })?.stableID
            ?? safeFallbackForUnknownID(for: category)
        persistedSelections[category.rawValue] = target
        transientPreviewSelections.removeValue(forKey: category.rawValue)
        persistIfNeeded()
        debugLog("event=restore-recommended category=\(category.rawValue) resolved=\(target) persisted=\(persistedSelections)")
        objectWillChange.send()
        return target
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[SpotifyLyrics][PresentationSelection] \(message())")
#endif
    }

    private func isPreviewable(_ stableID: String, category: PresentationCategory) -> Bool {
        guard let entry = catalog.metadata(for: stableID),
              entry.category == category,
              entry.isPreviewable else { return false }
        return entry.availability != .designOnly && entry.availability != .archived
    }

    private func isRunnable(_ stableID: String, category: PresentationCategory) -> Bool {
        guard let entry = catalog.metadata(for: stableID), entry.category == category else {
            return false
        }
        return isRunnable(entry)
    }

    private func isRunnable(_ entry: PresentationMetadata) -> Bool {
        entry.availability == .release
    }

    private func persistIfNeeded() {
        guard let data = try? JSONEncoder().encode(persistedSelections) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func loadSelections(defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return values
    }

    private static func migrateLegacySelections(
        _ selections: [String: String],
        defaults: UserDefaults,
        catalog: PresentationCatalog
    ) -> [String: String] {
        var next = selections
        if next[PresentationCategory.mainWindow.rawValue] == nil,
           let legacy = defaults.string(forKey: "mainWindowLayoutStyle") {
            let stableID: String?
            switch legacy {
            case "lyricsFocus": stableID = "mainWindow.lyricsFocus.v1"
            case "immersiveSplit": stableID = "mainWindow.immersiveSplit.v2"
            case "appleMusicImmersiveV3": stableID = "mainWindow.appleMusicImmersiveV3.v3"
            case "directionD": stableID = "mainWindow.directionD.v4"
            default: stableID = catalog.metadata(for: legacy)?.stableID
            }
            if let stableID { next[PresentationCategory.mainWindow.rawValue] = stableID }
        }

        if next[PresentationCategory.floatingLyrics.rawValue] == nil,
           let legacy = defaults.string(forKey: "general.floatingLyricsPresentation"),
           catalog.metadata(for: legacy)?.category == .floatingLyrics {
            next[PresentationCategory.floatingLyrics.rawValue] = legacy
        }
        return next
    }
}
