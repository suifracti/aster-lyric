// Rules from docs/TOOLBAR_BEHAVIOR.md (67b5be9).
import XCTest
import CoreGraphics
import Foundation
import SwiftUI
@testable import SpotifyLyrics

final class V3ToolbarPresentationTests: XCTestCase {
    @MainActor
    func testShuffleAndRepeatUseThePlayersOwnSettings() async throws {
        let spotify = SpotifyDesktopProvider(scriptRunner: { script, _ in
            XCTAssertTrue(script.contains("set shuffling to true"))
            XCTAssertTrue(script.contains("set repeating to false"))
            return "true|false"
        }, applicationIsInstalled: { true }, applicationIsRunning: { true })
        let spotifyModes = try await spotify.playbackModes(shuffle: true, repeatMode: .off)
        XCTAssertEqual(spotifyModes, PlayerPlaybackModes(shuffle: true, repeatMode: .off))
        let music = AppleMusicDesktopProvider(scriptRunner: { script, _ in
            XCTAssertTrue(script.contains("set shuffle enabled to false"))
            XCTAssertTrue(script.contains("set song repeat to one"))
            return "false|one"
        }, applicationIsInstalled: { true }, applicationIsRunning: { true })
        let musicModes = try await music.playbackModes(shuffle: false, repeatMode: .one)
        XCTAssertEqual(musicModes, PlayerPlaybackModes(shuffle: false, repeatMode: .one))
    }

    @MainActor
    func testNightGentleHoursAndDefault() {
        XCTAssertFalse(V3NightPolicy.isNight(hour: 19))
        XCTAssertTrue(V3NightPolicy.isNight(hour: 20))
        XCTAssertTrue(V3NightPolicy.isNight(hour: 6))
        XCTAssertFalse(V3NightPolicy.isNight(hour: 7))
        let suite = "night-\(UUID())"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: store)
        XCTAssertFalse(settings.v3NightGentleEnabled)
        settings.v3NightGentleEnabled = true
        XCTAssertTrue(AppSettingsStore(defaults: store).v3NightGentleEnabled)
    }

    @MainActor
    func testCoverAccentKeepsNeutralCoversNeutral() {
        let plain = BackdropPalette(primary: .neutral, secondary: .neutral, glow: .neutral,
            luminance: 0.8, saturation: 0.02, readabilityVeilOpacity: 0, textureOpacity: 0)
        XCTAssertNil(LyricIslandArtworkColors.listeningAccent(plain))
        XCTAssertNil(LyricIslandArtworkColors.listeningAccent(.neutral))
        let colour = BackdropPalette(primary: BackdropColor(red: 0.9, green: 0.2, blue: 0.1), secondary: .neutral,
            glow: .neutral, luminance: 0.4, saturation: 0.7, readabilityVeilOpacity: 0, textureOpacity: 0)
        XCTAssertNotNil(LyricIslandArtworkColors.listeningAccent(colour))
    }

    @MainActor
    func testListeningKeysAndLikeConfirmation() {
        XCTAssertEqual(V3ListeningKey.resolve("/", modifiers: [], repeating: false, focused: true, editing: false), .blurCycle)
        XCTAssertEqual(V3ListeningKey.resolve("/", modifiers: [.shift], repeating: false, focused: true, editing: false), .help)
        XCTAssertEqual(V3ListeningKey.resolve("?", modifiers: [], repeating: false, focused: true, editing: false), .blurCycle)
        for unused in ["[", "]"] {
            XCTAssertNil(V3ListeningKey.resolve(unused, modifiers: [], repeating: false, focused: true, editing: false))
        }
        XCTAssertEqual([0.0, 25, 35, 50, 75, 100].map(V3LyricActions.nextBlurPreset), [25, 50, 50, 75, 100, 0])
        XCTAssertEqual(V3ListeningKey.resolve("A", modifiers: [], repeating: false, focused: true, editing: false), .previous)
        XCTAssertEqual(V3ListeningKey.resolve("z", modifiers: [], repeating: true, focused: true, editing: false), .offset(-0.1))
        XCTAssertEqual(V3ListeningKey.resolve(",", modifiers: [], repeating: true, focused: true, editing: false), .blurFine(-5))
        XCTAssertEqual(V3ListeningKey.resolve("?", modifiers: [.shift], repeating: false, focused: true, editing: false), .help)
        XCTAssertNil(V3ListeningKey.resolve("a", modifiers: [.command], repeating: false, focused: true, editing: false))
        XCTAssertNil(V3ListeningKey.resolve(" ", modifiers: [], repeating: false, focused: true, editing: true))
        XCTAssertNil(V3ListeningKey.resolve("s", modifiers: [], repeating: false, focused: false, editing: false))
        var confirmation = V3LikeConfirmation()
        XCTAssertEqual(confirmation.target(isLiked: false, track: "one", now: 0), true)
        XCTAssertNil(confirmation.target(isLiked: true, track: "one", now: 1))
        XCTAssertEqual(confirmation.target(isLiked: true, track: "one", now: 2), false)
        XCTAssertNil(confirmation.target(isLiked: true, track: "one", now: 6))
        XCTAssertNil(confirmation.target(isLiked: true, track: "two", now: 7))
    }

    func testSpotifyLikesUseOnlyTrackLibraryRequestsAndTwoScopes() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrackLikeRequestFixture.self]
        let service = SpotifyCatalogService(session: URLSession(configuration: config))
        TrackLikeRequestFixture.requests = []
        let id = "0123456789012345678901"
        let saved = try await service.isTrackSaved(id: id, accessToken: "fixture")
        XCTAssertTrue(saved)
        try await service.setTrackSaved(true, id: id, accessToken: "fixture")
        try await service.setTrackSaved(false, id: id, accessToken: "fixture")
        XCTAssertEqual(TrackLikeRequestFixture.requests.map(\.httpMethod), ["GET", "PUT", "DELETE"])
        XCTAssertEqual(TrackLikeRequestFixture.requests.map { $0.url!.path }, ["/v1/me/library/contains", "/v1/me/library", "/v1/me/library"])
        XCTAssertTrue(TrackLikeRequestFixture.requests.allSatisfy {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems?.first?.value == "spotify:track:" + id
        })
        let url = try service.authorizationURL(clientID: "fixture", state: "fixture", codeChallenge: "fixture")
        let scopes = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!
        XCTAssertEqual(Set(scopes.split(separator: " ").map(String.init)), ["user-library-read", "user-library-modify"])
    }

    @MainActor
    func testAppleMusicLikesAddressTheRecording() async throws {
        let provider = AppleMusicDesktopProvider(scriptRunner: { script, _ in
            XCTAssertTrue(script.contains("favorited"))
            XCTAssertTrue(script.contains("persistent ID of targetTrack as text) is not \"ABCDEF1234567890\""))
            return "true"
        }, applicationIsInstalled: { true }, applicationIsRunning: { true })
        let value = try await provider.trackFavorite(id: "applemusic:ABCDEF1234567890", set: true)
        XCTAssertTrue(value)
    }

    @MainActor
    func testPanelReportsContentHeightInsteadOfAFullScreen() async {
        let height = expectation(description: "the host receives the short panel's height")
        let suite = "panel-height-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        let state = PlaybackState(provider: MockPlaybackProvider(), settings: settings)
        let root = V3ToolbarQuickControls(panel: .more, state: state, search: state.songSearchManager,
                                         openLibrary: {}, openSearch: {}) { Text("短面板") }
        .onPreferenceChange(V3ToolPanelHeight.self) { value in
            if value > 0 && value < 100 { height.fulfill() }
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await fulfillment(of: [height], timeout: 2)
    }

    @MainActor
    func testGesturesUseExistingPreferences() {
        let defaults = UserDefaults(suiteName: "lyric-bar-\(UUID())")!
        let settings = AppSettingsStore(defaults: defaults)
        let actions = V3LyricActions(settings: settings)
        var display = settings.displayPreferences
        display.fontSize = 22
        settings.displayPreferences = display
        XCTAssertEqual(actions.fontSize(2), "字号 24")
        XCTAssertEqual(settings.displayPreferences.fontSize, 24)
        _ = actions.fontSize(100)
        XCTAssertEqual(settings.displayPreferences.fontSize, 42)
        _ = actions.fontSize(-100)
        XCTAssertEqual(settings.displayPreferences.fontSize, 14)
        let original = actions.family
        _ = actions.scene(1)
        XCTAssertNotEqual(actions.family, original)
        _ = actions.scene(-1)
        XCTAssertEqual(actions.family, original)
    }

    @MainActor
    func testSpaceLeavesTextEntryAlone() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)!
        XCTAssertTrue(V3SpacePlayback.handles(space, in: window))
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView!.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(V3SpacePlayback.handles(space, in: window))
    }

    @MainActor
    func testPanelModelAndReasoningSelectionPersist() throws {
        let suite = "panel-model-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        var config = settings.aiTranslationConfiguration
        config.engineID = TranslationEngineID.codexChatGPT.rawValue
        config.model = "fixture-one"
        settings.aiTranslationConfiguration = config
        let models = [TranslationModelDescriptor(id: "fixture-one", displayName: "First model", reasoningEfforts: ["medium"]),
                      TranslationModelDescriptor(id: "fixture-two", displayName: "Second model", reasoningEfforts: ["high"])]
        defaults.set(try JSONEncoder().encode([config.engineID: models]), forKey: TranslationModelSettingsStore.directoriesKey)
        _ = settings.translationModelSettings
        let controls = TranslationProviderControls(settings: settings)
        controls.modelBinding.wrappedValue = "fixture-two"
        controls.reasoningBinding.wrappedValue = "high"
        let reopened = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.aiTranslationConfiguration.model, "fixture-two")
        XCTAssertEqual(reopened.aiTranslationConfiguration.codexReasoningEffort, "high")
    }

    func testHorizontalSceneGestureLeavesVerticalScrollAlone() {
        var swipe = V3SceneSwipe()
        XCTAssertNil(swipe.move(x: 0, y: 80))
        XCTAssertNil(swipe.move(x: -25, y: 0))
        XCTAssertEqual(swipe.move(x: -40, y: 0), 1)
        XCTAssertNil(swipe.move(x: -80, y: 0))
        swipe.begin()
        XCTAssertEqual(swipe.move(x: 65, y: 0), -1)
    }

    func testHoverLifetimeAndMenus() {
        XCTAssertEqual(V3ToolbarModel.hoverGrace, .milliseconds(180))
        for panel in V3ToolbarModel.Panel.allCases {
            var m = V3ToolbarModel()
            XCTAssertEqual(m.pointerOnTrigger(panel, inside: true), .cancelHoverDismissal)
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.hoverPanel, panel, "the button keeps its hover open")
            XCTAssertEqual(m.pointerOnTrigger(panel, inside: false), .scheduleHoverDismissal(panel))
            _ = m.pointerInPanel(panel, inside: true)
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.hoverPanel, panel, "the panel keeps itself open")
            _ = m.menuTrackingBegan()
            _ = m.pointerInPanel(panel, inside: false)
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.hoverPanel, panel, "a native menu keeps hover open")
            XCTAssertEqual(m.menuTrackingEnded(), .scheduleHoverDismissal(panel))
            m.dismissTimerFired(panel)
            XCTAssertEqual(m.mode, .idle)
        }
    }

    func testClicksPinRepeatSwitchAndDismiss() {
        XCTAssertEqual(V3ToolbarModel.Panel.allCases.map(\.title), ["歌词库", "搜索", "译文", "文字", "画面", "更多"])
        for panel in [V3ToolbarModel.Panel.translation, .text, .picture, .more] {
            var m = V3ToolbarModel()
            _ = m.pointerOnTrigger(panel, inside: true)
            m.click(panel)
            XCTAssertEqual(m.pinnedPanel, panel, "a hover click pins that same full panel")
            for other in V3ToolbarModel.Panel.allCases {
                XCTAssertEqual(m.isSelected(other), other == panel)
                _ = m.pointerOnTrigger(other, inside: true)
                XCTAssertEqual(m.pinnedPanel, panel, "pinned ignores other hovers")
            }
            m.hoverClosed(panel)
            XCTAssertEqual(m.pinnedPanel, panel, "outside clicks never close a pinned panel")
            m.click(panel)
            XCTAssertEqual(m.mode, .idle, "repeat click closes")
            m.click(panel)
            let other: V3ToolbarModel.Panel = panel == .more ? .text : .more
            m.click(other)
            XCTAssertEqual(m.pinnedPanel, other, "another button switches directly")
            m.dismiss() // Escape and the close button share this action.
            XCTAssertEqual(m.mode, .idle)
        }
        for action in [V3ToolbarModel.Panel.library, .search] {
            var m = V3ToolbarModel()
            m.click(.translation)
            m.click(action)
            XCTAssertEqual(m.mode, .idle, "library/search open their window and close panels")
        }
        var m = V3ToolbarModel()
        _ = m.pointerOnTrigger(.more, inside: true)
        m.hoverClosed(.more)
        XCTAssertEqual(m.mode, .idle, "outside clicks close hover")
        m.click(.text)
        m.click() // Settings has no hover panel.
        XCTAssertEqual(m.mode, .idle)
    }

    func testVisibilityAndEdgePriority() {
        var m = V3ToolbarModel()
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false), 0)
        XCTAssertEqual(m.opacity(pointerInside: true, nearTop: false), 0.32)
        XCTAssertEqual(m.opacity(pointerInside: true, nearTop: true), 1)
        XCTAssertFalse(m.suppressesEdgeControls(nearTop: false))
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: true))
        _ = m.pointerOnTrigger(.text, inside: true)
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false), 1)
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: false))
        m.click(.text)
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false), 1)
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: false))
        m.dismiss()
        XCTAssertTrue(m.suppressesEdgeControls(nearTop: false, otherPanelOpen: true))
        XCTAssertEqual(m.opacity(pointerInside: false, nearTop: false, otherPanelOpen: true), 1)
    }

    @MainActor
    func testCategoryShortcutUsesTheFullSelectorsStyle() {
        let suite = "lyricsq-family-shortcut-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        settings.selectV3Scene(.coverPhoto, renderer: .classicGaussian)
        let current = V3SceneFamily.cover.target(settings: settings)
        XCTAssertEqual(current.0, .coverPhoto)
        XCTAssertEqual(current.1, .classicGaussian)
        let first = V3SceneFamily.focus.target(settings: settings)
        XCTAssertEqual(first.0, .focusedLyrics)
        XCTAssertEqual(first.1, .lyricsOnly)
    }

    func testHoverPanelStaysInsideTheMainWindow() {
        let owner = CGRect(x: 704, y: 540, width: 1152, height: 720)
        let overflowing = CGRect(x: 1547, y: 825, width: 346, height: 376)
        let placed = V3HoverPanelPlacement.frame(overflowing, inside: owner)
        XCTAssertTrue(owner.contains(placed))
        XCTAssertEqual(placed.maxX, owner.maxX)
    }

    func testPinnedPlacement() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let requested = CGSize(width: 360, height: 720)
        let owner = CGRect(x: 100, y: 180, width: 900, height: 800)
        let roomy = LyricIslandPanelPlacement.frame(owner: owner, visible: visible, requested: requested)
        XCTAssertEqual(roomy.minX, owner.maxX + 12)
        XCTAssertFalse(roomy.intersects(owner))
        let wide = CGRect(x: 760, y: 180, width: 900, height: 800)
        let edge = LyricIslandPanelPlacement.frame(owner: wide, visible: visible, requested: requested)
        XCTAssertEqual(edge.maxX, visible.maxX - 8)
        XCTAssertGreaterThan(edge.minX, wide.minX, "never to the left")
    }
}

private final class TrackLikeRequestFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: request.httpMethod == "GET" ? Data("[true]".utf8) : Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
