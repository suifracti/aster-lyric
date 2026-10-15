import Foundation

@main
struct DebugDatabaseSafetyContract {
    static func main() {
        if CommandLine.arguments.contains("--debug-native-acceptance") || ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DEBUG_ACCEPTANCE"] != nil {
            let bundle = ProcessInfo.processInfo.environment["CONTRACT_BUNDLE"]
            DebugAcceptanceDataIsolation.prepareBeforeStateObjectsIfNeeded(bundleIdentifier: bundle)
            if let escaped = ProcessInfo.processInfo.environment["CONTRACT_ESCAPED_STORAGE"] {
                DebugAcceptanceDataIsolation.requireStorage(URL(fileURLWithPath: escaped))
            }
            let store = UserDefaults.lyricsQ
            if DebugAcceptanceDataIsolation.isDailyUse {
                precondition(DebugAcceptanceDataIsolation.allowsExplicitTranslation)
                if CommandLine.arguments.contains("--cache-reopen") {
                    precondition(!store.bool(forKey: "general.connectSpotifyOnLaunch"), "daily reopen overwrote user connection setting")
                    precondition(store.bool(forKey: "ai.autoTranslateNewLyrics"), "daily reopen reset automatic translation")
                } else {
                    precondition(store.bool(forKey: "general.connectSpotifyOnLaunch"), "first daily launch still requires reconnect")
                    store.set(false, forKey: "general.connectSpotifyOnLaunch")
                    store.set(true, forKey: "ai.autoTranslateNewLyrics")
                }
            } else {
                precondition(store.string(forKey: "playback.sourceMode") == "spotify")
                precondition(!store.bool(forKey: "general.connectSpotifyOnLaunch"))
                precondition(!store.bool(forKey: "ai.autoTranslateNewLyrics"))
                precondition(!store.bool(forKey: "automaticAlignment.enabled.v1"))
            }
            precondition(store.string(forKey: "spotify.clientID") == nil)
            store.set(true, forKey: "contract.bool")
            store.set(12.5, forKey: "contract.double")
            store.set(7, forKey: "contract.int")
            store.set(["a": "b"], forKey: "contract.dictionary")
            store.set(Data([1, 2, 3]), forKey: "contract.data")
            store.set(URL(string: "https://example.invalid/fixture")!, forKey: "contract.url")
            precondition(store.bool(forKey: "contract.bool"))
            precondition(store.double(forKey: "contract.double") == 12.5)
            precondition(store.integer(forKey: "contract.int") == 7)
            precondition(store.dictionary(forKey: "contract.dictionary")?["a"] as? String == "b")
            precondition(store.data(forKey: "contract.data") == Data([1, 2, 3]))
            precondition(store.url(forKey: "contract.url")?.absoluteString == "https://example.invalid/fixture")
            store.removeObject(forKey: "contract.bool")
            precondition(!store.bool(forKey: "contract.bool"))
            let config = DebugAcceptanceDataIsolation.configuration
            precondition(LyricsQStorage.homeDirectory == config.home)
            if CommandLine.arguments.contains("--cache-reopen") {
                precondition(store.string(forKey: "contract.choice") == "manual-preserved")
            } else {
                store.set("manual-preserved", forKey: "contract.choice")
                precondition(store.synchronize())
            }
            let spotify = KeychainSpotifyTokenStore()
            precondition(try! spotify.load() == nil)
            do {
                try spotify.save(SpotifyTokenRecord(accessToken: "synthetic", refreshToken: nil, expiresAt: Date()))
                preconditionFailure("acceptance must reject Spotify credential write")
            } catch {}
            try! spotify.delete()
            let transport = ForbiddenKeychainTransport()
            let ai = KeychainAITranslationAPIKeyStore(transport: transport)
            precondition(ai.read() == nil)
            do { try ai.save("synthetic"); preconditionFailure("acceptance must reject AI credential write") } catch {}
            try! ai.delete()
            print("native isolation contract PASS suite=\(config.suiteName) home=\(config.home.path) keychain=OFF")
            return
        }
        let formal = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpotifyLyrics/SpotifyLyrics.sqlite3")

        let noOverride = DebugDatabaseSafety.status(environment: [
            "SPOTIFYLYRICS_DATABASE_PATH": ""
        ])
        precondition(noOverride.configuredDatabaseURL == nil)
        precondition(!noOverride.isSafeForForcedPresentation)
        precondition(!noOverride.formalDatabaseOpened)
        precondition(noOverride.logLines.contains(where: { $0.contains("formal_database_opened=NO") }))
        precondition(noOverride.refusalMessage.contains("SPOTIFYLYRICS_DATABASE_PATH"))
        precondition(noOverride.refusalMessage.contains(DebugDatabaseSafety.forcedPresentationID))

        let temporary = URL(fileURLWithPath: "/tmp/spotifylyrics-debug-safety.sqlite3")
        let temporaryStatus = DebugDatabaseSafety.status(environment: [
            "SPOTIFYLYRICS_DATABASE_PATH": temporary.path
        ])
        precondition(temporaryStatus.configuredDatabaseURL == temporary.standardizedFileURL)
        precondition(temporaryStatus.isTemporaryCopy)
        precondition(temporaryStatus.isSafeForForcedPresentation)
        precondition(!temporaryStatus.formalDatabaseOpened)
        precondition(temporaryStatus.actualDatabaseURL == temporary.standardizedFileURL)
        precondition(temporaryStatus.logLines.contains(where: { $0.contains("temporary_copy=YES") }))

        let foundationTemporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotifylyrics-debug-safety.sqlite3")
        let foundationTemporaryStatus = DebugDatabaseSafety.status(environment: [
            "SPOTIFYLYRICS_DATABASE_PATH": foundationTemporary.path
        ])
        precondition(foundationTemporaryStatus.isSafeForForcedPresentation)

        let formalStatus = DebugDatabaseSafety.status(environment: [
            "SPOTIFYLYRICS_DATABASE_PATH": formal.path
        ])
        precondition(!formalStatus.isTemporaryCopy)
        precondition(!formalStatus.isSafeForForcedPresentation)
        precondition(!formalStatus.formalDatabaseOpened)
        precondition(formalStatus.refusalMessage.contains("temporary"))

        print("debug database safety contract: PASS")
    }
}

private struct ForbiddenKeychainTransport: AITranslationKeychainTransport {
    func read(service: String, account: String) -> String? { preconditionFailure("forbidden Keychain transport read") }
    func save(service: String, account: String, key: String) throws { preconditionFailure("forbidden Keychain transport save") }
    func delete(service: String, account: String) throws { preconditionFailure("forbidden Keychain transport delete") }
}
