import Foundation
import Darwin
import CryptoKit

/// The application's defaults boundary. Release and ordinary Debug retain
/// their existing standard domain; native acceptance has one validated suite.
extension UserDefaults {
    public static var lyricsQ: UserDefaults {
#if DEBUG
        if NativeTestRuntime.isEnabled { return NativeTestRuntime.defaults }
        if DebugAcceptanceDataIsolation.isRequested { return DebugAcceptanceDataIsolation.defaults }
#endif
        return .standard
    }
}

public enum LyricsQStorage {
    public static var homeDirectory: URL {
#if DEBUG
        if NativeTestRuntime.isEnabled { return NativeTestRuntime.root }
        if DebugAcceptanceDataIsolation.isRequested { return DebugAcceptanceDataIsolation.configuration.home }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

#if DEBUG
/// XCTest's hosted process must not construct the product's windows, providers
/// or shared data stores. Ordinary Debug and release launches never enter here.
enum NativeTestRuntime {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LYRICSQ_NATIVE_TESTS"] == "1"
    }
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lyricsq-native-tests-host-\(ProcessInfo.processInfo.processIdentifier)")
    private static let suite = "com.spotifylyrics.tests.\(ProcessInfo.processInfo.processIdentifier)"
    static let defaults = UserDefaults(suiteName: suite)!

    static func prepare() {
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.removePersistentDomain(forName: suite)
        setenv("SPOTIFYLYRICS_DATABASE_PATH", root.appendingPathComponent("test.sqlite3").path, 1)
        setenv("SPOTIFYLYRICS_ALIGNMENT_PROVENANCE_PATH", root.appendingPathComponent("provenance").path, 1)
        setenv("SPOTIFYLYRICS_DISABLE_KEYCHAIN", "1", 1)
        atexit {
            NativeTestRuntime.defaults.removePersistentDomain(forName: NativeTestRuntime.suite)
            try? FileManager.default.removeItem(at: NativeTestRuntime.root)
        }
    }
}

/// CFPreferences can route a named suite through the login user's daemon even
/// with CFFIXED_USER_HOME. Acceptance therefore implements the existing
/// UserDefaults API using one root-owned plist, never a CF persistent domain.
private final class DebugPrivateUserDefaults: UserDefaults {
    private let file: URL
    private let suite: String
    private let lock = NSRecursiveLock()
    private var values: [String: Any]
    init?(suiteName: String, storageURL: URL) {
        file = storageURL
        suite = suiteName
        if FileManager.default.fileExists(atPath: storageURL.path) {
            guard let data = try? Data(contentsOf: storageURL),
                  let result = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { DebugAcceptanceDataIsolation.refuse("private preferences unreadable") }
            values = result
        } else { values = [:] }
        super.init(suiteName: suiteName)
    }
    override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }; return values[key]
    }
    override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }; values[key] = value
        _ = synchronize()
    }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func url(forKey key: String) -> URL? { string(forKey: key).flatMap(URL.init(string:)) }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value?.absoluteString as Any?, forKey: key) }
    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; return values
    }
    override func persistentDomain(forName name: String) -> [String: Any]? { name == suite ? dictionaryRepresentation() : nil }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) {
        guard name == suite else { DebugAcceptanceDataIsolation.refuse("foreign preference domain") }
        lock.lock(); defer { lock.unlock() }; values = domain; _ = synchronize()
    }
    override func removePersistentDomain(forName name: String) { setPersistentDomain([:], forName: name) }
    override func register(defaults registration: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        for (key, value) in registration where values[key] == nil { values[key] = value }
    }
    override func synchronize() -> Bool {
        lock.lock(); defer { lock.unlock() }
        DebugAcceptanceDataIsolation.requireStorage(file)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: file, options: .atomic)
            return true
        } catch { DebugAcceptanceDataIsolation.refuse("private preferences write failed") }
    }
}

/// Must complete before any StateObject, preferences, repository, credentials,
/// local-index scan or player bridge is constructed. No acceptance flag can
/// silently fall back to a daily resource.
enum DebugAcceptanceDataIsolation {
    /// Private daily use keeps the private library, but follows the user's
    /// connection and translation settings instead of acceptance-only limits.
    static var isDailyUse: Bool {
        isRequested && ProcessInfo.processInfo.environment["SPOTIFYLYRICS_PRIVATE_DAILY_USE"] == "1"
    }
    // One explicit, recording-bound subscription acceptance grant. A spent
    // counter remains valid on reopen, but can never authorize another send.
    static let translationGrant = "6110651480"
    static let secondTranslationGrant = "6119898076"
    static let secondTranslationTrackKey = "spotify-id:0zlwh8kzv299erleomelad|metadata:gijikoi|harukihamano|gijikoikoreanver|217"
    static let translationTrackKey = "spotify-id:3eqfsbmrzv3xbxqb6tofkw|metadata:ギジコイ|浜野はるき|lovetoxic|216"
    static func validModelBudget(_ budget: [String: Any], grant: String?) -> Bool {
        guard let maximum = budget["maximum"] as? Int, let used = budget["used"] as? Int,
              let stopped = budget["stopped"] as? Bool,
              let providers = budget["providers"] as? [String],
              let tracks = budget["trackKeys"] as? [String] else { return false }
        if maximum == 0 { return used == 0 && stopped && providers.isEmpty && tracks.isEmpty }
        let expectedTrack: String?
        switch grant {
        case translationGrant: expectedTrack = translationTrackKey
        case secondTranslationGrant: expectedTrack = secondTranslationTrackKey
        default: expectedTrack = nil
        }
        return expectedTrack != nil && maximum == 1 && (0...1).contains(used)
            && providers == ["translationEngine.codexChatGPT.v1"] && tracks == [expectedTrack!]
    }
    static var allowsExplicitTranslation: Bool {
        if isDailyUse { return true }
        let e = ProcessInfo.processInfo.environment
        guard let grant = e["SPOTIFYLYRICS_ACCEPTANCE_TRANSLATION_GRANT"],
              [translationGrant, secondTranslationGrant].contains(grant),
              let path = e["SPOTIFYLYRICS_ACCEPTANCE_BUDGET_FILE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let budget = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              validModelBudget(budget, grant: grant) else { return false }
        return budget["maximum"] as? Int == 1 && budget["used"] as? Int == 0 && budget["stopped"] as? Bool == false
    }
    struct Configuration {
        let root: URL
        let home: URL
        let database: URL
        let provenance: URL
        let suiteName: String
    }
    nonisolated(unsafe) private static var prepared: Configuration?
    nonisolated(unsafe) private static var preparedDefaults: UserDefaults?
    static var isRequested: Bool {
        let e = ProcessInfo.processInfo.environment
        return ProcessInfo.processInfo.arguments.contains("--debug-native-acceptance")
            || e["SPOTIFYLYRICS_DEBUG_ACCEPTANCE"] != nil
            || e["SPOTIFYLYRICS_ACCEPTANCE_DATA_ROOT"] != nil
            || e["SPOTIFYLYRICS_ACCEPTANCE_SUITE"] != nil
            || (Bundle.main.bundleIdentifier?.hasPrefix("com.spotifylyrics.acceptance.") ?? false)
    }
    static var configuration: Configuration {
        guard let prepared else { refuse("acceptance resource accessed before entry validation") }
        return prepared
    }
    static var defaults: UserDefaults {
        _ = configuration
        guard let preparedDefaults else { refuse("acceptance defaults unavailable") }
        return preparedDefaults
    }
    static func refuse(_ message: String) -> Never {
        FileHandle.standardError.write(Data("[SpotifyLyrics][NativeIsolation] refusal=\(message)\n".utf8))
        exit(78)
    }
    static func requireStorage(_ url: URL) {
        guard isRequested else { return }
        let root = configuration.root.path
        let raw = url.path
        guard raw.hasPrefix(root + "/"), !raw.split(separator: "/").contains(".."),
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL
        else { refuse("storage escaped private root") }
        if FileManager.default.fileExists(atPath: raw) {
            var s = stat()
            guard lstat(raw, &s) == 0, s.st_uid == geteuid(),
                  (s.st_mode & S_IFMT) != S_IFLNK,
                  ((s.st_mode & S_IFMT) != S_IFREG || s.st_nlink == 1) else { refuse("unsafe storage inode") }
        }
    }
    static func prepareBeforeStateObjectsIfNeeded(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard isRequested else { return }
        guard prepared == nil else { return }
        let e = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--debug-native-acceptance"),
              e["SPOTIFYLYRICS_DEBUG_ACCEPTANCE"] == "1",
              let bundleIdentifier, bundleIdentifier.hasPrefix("com.spotifylyrics.acceptance."),
              e["SPOTIFYLYRICS_ACCEPTANCE_BUNDLE_ID"] == bundleIdentifier,
              e["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1" else { refuse("missing flag, independent bundle identity or Keychain prohibition") }
        guard let raw = e["SPOTIFYLYRICS_ACCEPTANCE_DATA_ROOT"],
              raw.hasPrefix("/private/tmp/lyricsq-m1-native-"),
              !raw.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              !raw.contains("//"),
              URL(fileURLWithPath: raw).standardizedFileURL == URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
        else { refuse("invalid private root") }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let db = root.appendingPathComponent("lyrics.sqlite3")
        let provenance = root.appendingPathComponent("provenance", isDirectory: true)
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        let suite = bundleIdentifier + ".root." + digest
        guard e["SPOTIFYLYRICS_ACCEPTANCE_SUITE"] == suite,
              e["CFFIXED_USER_HOME"] == home.path,
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL == home.standardizedFileURL,
              e["TMPDIR"] == root.appendingPathComponent("tmp").path + "/",
              e["SPOTIFYLYRICS_DATABASE_PATH"] == db.path,
              e["SPOTIFYLYRICS_ALIGNMENT_PROVENANCE_PATH"] == provenance.path,
              e["SPOTIFYLYRICS_ACCEPTANCE_BUDGET_FILE"] == root.appendingPathComponent("budget.json").path,
              e["SPOTIFYLYRICS_ACCEPTANCE_CONTROL_PATH"] == root.appendingPathComponent("control.txt").path,
              e["SPOTIFYLYRICS_E2E_LOG_PATH"] == root.appendingPathComponent("logs/e2e.log").path,
              e["SPOTIFY_CLIENT_ID"] == nil,
              !e.keys.contains(where: { $0.hasPrefix("SPOTIFYLYRICS_SCK_") || $0.hasPrefix("SPOTIFYLYRICS_AUTO_ALIGN_") })
        else { refuse("environment, private home, suite or storage identity mismatch") }
        // Check all existing data before reading a budget or preferences file.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var paths = [root, home, root.appendingPathComponent("tmp"), provenance, root.appendingPathComponent("logs")]
        while let url = enumerator?.nextObject() as? URL { paths.append(url) }
        for url in paths {
            var s = stat()
            guard lstat(url.path, &s) == 0, s.st_uid == geteuid(),
                  (s.st_mode & S_IFMT) != S_IFLNK,
                  ((s.st_mode & S_IFMT) != S_IFREG || s.st_nlink == 1),
                  (s.st_mode & 0o077) == 0 else { refuse("private storage ownership, permission or link violation") }
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("budget.json")),
              let budget = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              validModelBudget(budget, grant: e["SPOTIFYLYRICS_ACCEPTANCE_TRANSLATION_GRANT"])
        else { refuse("missing, unapproved or invalid model budget") }
        prepared = Configuration(root: root, home: home, database: db, provenance: provenance, suiteName: suite)
        let preferences = root.appendingPathComponent("preferences.plist")
        requireStorage(preferences)
        guard let store = DebugPrivateUserDefaults(suiteName: suite, storageURL: preferences) else { refuse("private suite unavailable") }
        preparedDefaults = store
        // Never import daily settings/history. Preserve only this root's UI and
        // choices on reopen. Only strict acceptance freezes connection and
        // translation switches; private daily use follows the user's choices.
        if isDailyUse {
            if !store.bool(forKey: "privateDailyDefaultsRestored.v1") {
                // Earlier acceptance launches wrote false on every start.
                // Restore automatic connection once, then honor future edits.
                store.set(true, forKey: "general.connectSpotifyOnLaunch")
                store.set(true, forKey: "privateDailyDefaultsRestored.v1")
            }
        } else {
            store.set("spotify", forKey: "playback.sourceMode")
            store.set(false, forKey: "general.connectSpotifyOnLaunch")
            store.set(false, forKey: "ai.autoTranslateNewLyrics")
            store.set(false, forKey: "automaticAlignment.enabled.v1")
        }
        store.removeObject(forKey: "spotify.clientID")
        FileHandle.standardError.write(Data("[SpotifyLyrics][NativeIsolation] ready root=\(raw) suite=\(suite) keychain=OFF model_budget=\(budget["maximum"] as? Int ?? -1) used=\(budget["used"] as? Int ?? -1) imports=NONE\n".utf8))
    }
}

/// Fail-closed database boundary for Debug-only presentation experiments.
///
/// Release builds do not compile this type. A forced capsule experiment must
/// explicitly point at a database under a temporary directory; the formal
/// Application Support database is never an acceptable Debug experiment input.
enum DebugDatabaseSafety {
    static let forcedPresentationID = "capsule.dynamicIslandDark.v4"
    static let forcedPresentationArgument = "--debug-capsule-v4"
    static let topAttachedPresentationArgument = "--debug-capsule-v4-top-attached"
    static let databaseEnvironmentKey = "SPOTIFYLYRICS_DATABASE_PATH"

    static var isForcedPresentationArgument: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(forcedPresentationArgument)
            || arguments.contains(topAttachedPresentationArgument)
    }

    static var forcedPresentationMode: String {
        ProcessInfo.processInfo.arguments.contains(topAttachedPresentationArgument)
            ? "topAttachedEnvelope"
            : "stateSizedEnvelope"
    }

    struct Status: Equatable {
        let configuredDatabaseURL: URL?
        let actualDatabaseURL: URL?
        let formalDatabaseURL: URL
        let isTemporaryCopy: Bool
        let isSafeForForcedPresentation: Bool
        /// This is the open status for the forced activation itself. It is
        /// always false before repository construction; repository opens are
        /// logged separately through `logRepositoryOpen`.
        let formalDatabaseOpened: Bool
        let logLines: [String]
        let refusalMessage: String
    }

    static func status(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Status {
        let formalURL = formalDatabaseURL
        let configuredPath = environment[databaseEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredURL: URL? = configuredPath.flatMap { path in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        let resolvedConfiguredURL = configuredURL?.resolvingSymlinksInPath()
        let resolvedFormalURL = formalURL.resolvingSymlinksInPath()
        let isFormalPath = if let resolvedConfiguredURL {
            samePath(resolvedConfiguredURL, resolvedFormalURL)
        } else {
            false
        }
        let isTemporary = if let resolvedConfiguredURL, !isFormalPath {
            isTemporaryURL(resolvedConfiguredURL)
        } else {
            false
        }
        let safe = configuredURL != nil && isTemporary && !isFormalPath
        let actualPath = configuredURL?.path ?? "<none; launch refused before repository init>"
        let lines = [
            "[SpotifyLyrics][DebugSafety] event=forced_presentation",
            "[SpotifyLyrics][DebugSafety] forced_presentation_id=\(forcedPresentationID)",
            "[SpotifyLyrics][DebugSafety] forced_presentation_mode=\(forcedPresentationMode)",
            "[SpotifyLyrics][DebugSafety] database_path=\(actualPath)",
            "[SpotifyLyrics][DebugSafety] formal_database_path=\(formalURL.path)",
            "[SpotifyLyrics][DebugSafety] temporary_copy=\(isTemporary ? "YES" : "NO")",
            "[SpotifyLyrics][DebugSafety] formal_database_opened=NO"
        ]
        let refusal = safe ? "" : refusalMessage(
            configuredURL: configuredURL,
            formalURL: formalURL
        )

        return Status(
            configuredDatabaseURL: configuredURL,
            actualDatabaseURL: configuredURL,
            formalDatabaseURL: formalURL,
            isTemporaryCopy: isTemporary,
            isSafeForForcedPresentation: safe,
            formalDatabaseOpened: false,
            logLines: lines,
            refusalMessage: refusal
        )
    }

    /// Called before any StateObject that can construct a repository.
    /// Command-line v4 runs therefore cannot even initialize the app against
    /// the formal database.
    static func failClosedForCommandLineV4IfNeeded() {
        guard isForcedPresentationArgument else {
            return
        }

        let current = status()
        emit(current.logLines)
        guard current.isSafeForForcedPresentation else {
            emit(["[SpotifyLyrics][DebugSafety] refusal=\(current.refusalMessage)"])
            exit(78)
        }
    }

    /// Returns nil only when the Debug menu may activate v4. A normal Debug
    /// app launch may already have opened its configured repository; this
    /// guard prevents the menu action from forcing v4 without an explicit,
    /// temporary database and reports that fact instead of silently falling
    /// back to the formal database.
    static func menuActivationRefusalMessage() -> String? {
        let current = status()
        emit(current.logLines.map { $0.replacingOccurrences(of: "event=forced_presentation", with: "event=menu_activation") })
        guard current.isSafeForForcedPresentation else {
            let message = "[SpotifyLyrics][DebugSafety] menu_refusal=\(current.refusalMessage)"
            emit([message])
            return current.refusalMessage
        }
        return nil
    }

    /// Debug-only repository telemetry. This is intentionally limited to
    /// paths and safety classification; it never logs lyrics or credentials.
    static func logRepositoryOpen(databaseURL: URL) {
        let actual = databaseURL.standardizedFileURL
        let formal = samePath(actual.resolvingSymlinksInPath(), formalDatabaseURL.resolvingSymlinksInPath())
        let temporary = !formal && isTemporaryURL(actual.resolvingSymlinksInPath())
        emit([
            "[SpotifyLyrics][DebugSafety] event=repository_open",
            "[SpotifyLyrics][DebugSafety] forced_presentation_id=\(isForcedPresentationArgument ? forcedPresentationID : "none")",
            "[SpotifyLyrics][DebugSafety] forced_presentation_mode=\(isForcedPresentationArgument ? forcedPresentationMode : "none")",
            "[SpotifyLyrics][DebugSafety] database_path=\(actual.path)",
            "[SpotifyLyrics][DebugSafety] temporary_copy=\(temporary ? "YES" : "NO")",
            "[SpotifyLyrics][DebugSafety] formal_database_opened=\(formal ? "YES" : "NO")"
        ])
    }

    private static var formalDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpotifyLyrics/SpotifyLyrics.sqlite3")
            .standardizedFileURL
    }

    private static func refusalMessage(configuredURL: URL?, formalURL: URL) -> String {
        let configured = configuredURL?.path ?? "<missing>"
        return "Refusing forced Debug presentation \(forcedPresentationID): \(databaseEnvironmentKey) must point to a temporary database copy under /tmp or the system temporary directory (configured=\(configured)); formal database was not opened (\(formalURL.path))."
    }

    private static func isTemporaryURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let roots = [temporaryRoot, "/tmp", "/private/tmp"]
        return roots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func emit(_ lines: [String]) {
        let output = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(output.utf8))
    }
}
#endif
