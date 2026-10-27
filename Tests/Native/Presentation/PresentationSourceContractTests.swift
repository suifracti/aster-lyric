import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import SpotifyLyrics

final class PresentationSourceContractTests: XCTestCase {
    @MainActor
    func testStoppingLibraryCompletionDoesNotStartAnotherSong() async {
        let batch = LyricsBatchCompletion()
        var searched: [String] = []
        batch.start(tracks: [Track(title: "Missing one", artist: "Artist", album: "Fixture", duration: 180), Track(title: "Missing two", artist: "Artist", album: "Fixture", duration: 180)]) { track in
            searched.append(track.title)
            batch.stop()
        }
        for _ in 0..<20 { if !batch.isRunning { break }; await Task.yield() }
        XCTAssertEqual(searched, ["Missing one"])
        XCTAssertFalse(batch.isRunning)
    }

    @MainActor
    func testJapaneseAndChineseSongsRestoreTheirOwnReadingSwitches() {
        let suite = "reading-language-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        let japanese = UUID(), chinese = UUID()
        let initial = settings.displayPreferences
        settings.applyReadingLanguage(versionID: japanese, text: "君の声が聞こえる。いつまでもあなたと一緒にいたい。")
        XCTAssertEqual(settings.displayPreferences, initial)
        settings.displayPreferences.showRomaji = false
        settings.applyReadingLanguage(versionID: chinese, text: "我想和你一起走过春天，听见你的声音，看见远方的灯光。")
        XCTAssertEqual(settings.activeReadingLanguage, .chinese)
        XCTAssertEqual(settings.displayPreferences.showRomaji, initial.showRomaji)
        settings.displayPreferences.showPinyin = false
        settings.applyReadingLanguage(versionID: japanese, text: "cached")
        XCTAssertEqual(settings.activeReadingLanguage, .japanese)
        XCTAssertFalse(settings.displayPreferences.showRomaji)
        XCTAssertEqual(settings.displayPreferences.showPinyin, initial.showPinyin)
        settings.applyReadingLanguage(versionID: chinese, text: "cached")
        XCTAssertFalse(settings.displayPreferences.showPinyin)
    }

    @MainActor
    func testTranslationPanelOfflineRefreshAndMissingLyricsReportAnError() async throws {
        let suite = "translation-panel-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = AITranslationConfiguration(model: "offline", engineID: TranslationEngineID.codexChatGPT.rawValue)
        let directory = TranslationModelSettingsStore(defaults: defaults, configuration: configuration,
            loader: { _ in throw NSError(domain: "offline", code: 1, userInfo: [NSLocalizedDescriptionKey: "离线模型目录错误"]) })
        directory.refresh(configuration)
        XCTAssertEqual(directory.status, .loading)
        for _ in 0..<100 {
            if directory.status != .loading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .unavailable(let error) = directory.status else { return XCTFail("必须显示目录错误") }
        XCTAssertTrue(error.contains("离线模型目录错误"))
        let repository = SQLiteLyricsRepository(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let translation = TranslationSessionController(repository: repository, engine: nil, acceptanceBudget: nil)
        translation.translateCurrentLyrics()
        XCTAssertEqual(translation.state, .failed("当前歌词尚未就绪，请先采用歌词版本"))
    }

    @MainActor
    func testCenteredSubjectWithEmptierRightHalfKeepsNormalLyricWidth() {
        XCTAssertEqual(V3ScenePreset.initial(scene: .coverPhoto, renderer: .ambient).lyricsPosition, "automatic")
        let analysis = V3ArtworkSubject.Analysis(imageSize: CGSize(width: 800, height: 800), regions: [
                CGRect(x: 0.16, y: 0.10, width: 0.32, height: 0.80),
                CGRect(x: 0.48, y: 0.35, width: 0.36, height: 0.20)])
        let canvas = CGSize(width: 1200, height: 800)
        let crop = V3BackdropArtworkGeometry.rect(canvas: canvas, artwork: analysis.imageSize, scale: 1.12, complete: false)
        let subjects = analysis.subjects(in: crop)
        let placement = V3ArtworkSubjectLayout.placement(subjects: subjects, canvas: canvas, manualPosition: "automatic")
        XCTAssertEqual(placement.position, "right")
        XCTAssertEqual(placement.widthFraction, 0.57)
        XCTAssertEqual(V3ArtworkSubjectLayout.placement(subjects: subjects, canvas: canvas, manualPosition: "left").position, "left")
    }

    func testCenteredLibrarySearchOpensSwitchesAndDismissesWithoutAnEdgeHitBand() {
        var panel = V3LibrarySearchPresentation()
        panel.toggle(.library)
        XCTAssertEqual(panel.tab, .library)
        XCTAssertTrue(panel.isPresented)
        panel.toggle(.search)
        XCTAssertEqual(panel.tab, .search)
        panel.toggle(.search)
        XCTAssertFalse(panel.isPresented)
        panel.open(.library)
        panel.dismiss() // Escape and outside clicks use the same close action.
        XCTAssertFalse(panel.isPresented)
        XCTAssertEqual(V3LibrarySearchPresentation.size(in: CGSize(width: 700, height: 580)), CGSize(width: 620, height: 500))
        XCTAssertEqual(V3LibrarySearchPresentation.size(in: CGSize(width: 1200, height: 900)), CGSize(width: 760, height: 600))
    }

    @MainActor
    func testAtmospherePresetRespondsInItsPaddedArea() async throws {
        let suite = "preset-hit-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        settings.v3ArtworkPresentation = .ambient
        settings.setV3AtmosphereLevel(2, for: .ambient)
        let host = NSHostingView(rootView: V3VisualControls(settings: settings)
            .atmosphereButton("关闭", level: 0).frame(width: 180))
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 180, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTSkipIf((host.accessibilityChildren() ?? []).isEmpty,
                      "The native host exposes no SwiftUI accessibility children; confirm the padded tile in the real app.")
        let point = window.convertPoint(toScreen: NSPoint(x: 8, y: 20))
        let button = try XCTUnwrap(host.accessibilityHitTest(point) as? NSAccessibilityProtocol)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertTrue(button.accessibilityPerformPress())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(settings.v3AtmosphereLevel(for: .ambient), 0)
    }

    func testTopEdgePlayerClearsToolbarOrUsesBottomWithoutShrinking() {
        for (width, toolbarX, expectedEdge) in [(1200.0, 600.0, V3WindowEdgeControlPositioner.Edge.top),
                                               (700.0, 300.0, .bottom)] {
            let toolbar = CGRect(x: toolbarX, y: 18, width: width - toolbarX - 20, height: 44)
            let layout = V3WindowEdgeControlPositioner.layout(size: CGSize(width: width, height: 800),
                exitPoint: CGPoint(x: width - 50, y: 0), preferredEdge: .top, avoiding: toolbar)
            XCTAssertEqual(layout.edge, expectedEdge)
            XCTAssertEqual(layout.scale, 1)
            XCTAssertFalse(layout.frame.intersects(toolbar))
            if expectedEdge == .top { XCTAssertEqual(toolbar.minX - layout.frame.maxX, 12, accuracy: 0.01) }
        }
    }

    func testListeningLayerPresetsLinkExistingFlagsAndKeepReadingStyle() {
        var preferences = DisplayPreferences(showRomaji: true, kanaDisplayMode: .inlineRuby)
        preferences.listeningLayerPreset = .translationOnly
        XCTAssertFalse(preferences.showOriginal)
        XCTAssertTrue(preferences.showTranslation)
        XCTAssertFalse(preferences.showKana)
        XCTAssertTrue(preferences.showRomaji, "The reading sub-options are retained")
        preferences.listeningLayerPreset = .readingOnly
        XCTAssertFalse(preferences.showOriginal || preferences.showTranslation)
        XCTAssertEqual(preferences.kanaDisplayMode, .inlineRuby)
        preferences.listeningLayerPreset = .all
        XCTAssertTrue(preferences.showOriginal && preferences.showTranslation && preferences.showKana)
        preferences.showTranslation = false
        XCTAssertEqual(preferences.listeningLayerPreset, .custom)
    }

    @MainActor
    func testPlaybackPresentationMigratesLegacyFlagsAndStandardStaysVisible() {
        let suite = "playback-presentation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (edge, hover, expected) in [(false, false, V3PlaybackPresentation.standard),
                                        (false, true, .onHover), (true, false, .windowEdge),
                                        (true, true, .windowEdge)] {
            defaults.set(edge, forKey: AppSettingsStore.Key.v3EdgeProgressEnabled)
            defaults.set(hover, forKey: AppSettingsStore.Key.v3PlaybackDetailsOnHover)
            let settings = AppSettingsStore(defaults: defaults)
            XCTAssertEqual(settings.v3PlaybackPresentation, expected)
            settings.v3PlaybackPresentation = .standard
            XCTAssertFalse(settings.v3EdgeProgressEnabled)
            XCTAssertTrue(V3ResponsiveGeometry.playbackDetailsVisible(
                hoverOnly: settings.v3PlaybackDetailsOnHover, pointerInRegion: false,
                interacting: false, panelPresented: false))
            XCTAssertEqual(AppSettingsStore(defaults: defaults).v3PlaybackPresentation, .standard)
        }
    }

    @MainActor
    func testReadingProtectionDefaultsAndLegacySettings() {
        let suite = "lyricsq-reading-protection-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (stored, expected) in [(nil, "off"), ("automatic", "off"), ("auto", "off"),
                                   ("enhanced", "glow"), ("off", "off"), ("shadow", "shadow"), ("glow", "glow")] {
            defaults.set(stored, forKey: AppSettingsStore.Key.v3ReadingProtection)
            XCTAssertEqual(AppSettingsStore(defaults: defaults).v3ReadingProtection.rawValue, expected)
            XCTAssertEqual(defaults.string(forKey: AppSettingsStore.Key.v3ReadingProtection), expected)
        }
        for mode in V3ReadingProtection.allCases {
            XCTAssertEqual(mode.effective(reduceTransparency: true, increasedContrast: false), .glow)
            XCTAssertEqual(mode.effective(reduceTransparency: false, increasedContrast: true), .glow)
            XCTAssertEqual(mode.effective(reduceTransparency: false, increasedContrast: false), mode)
        }
    }

    @MainActor
    func testEmbeddedLibraryFitsTheSettingsDetailColumn() {
        let settings = AppSettingsStore(defaults: .lyricsQ)
        let playback = PlaybackState(settings: settings)
        let host = NSHostingView(rootView: PersonalLyricsLibraryView(embeddedInSettings: true)
            .environmentObject(playback))
        // An 860pt Settings window leaves about 615pt after its navigation column.
        host.frame = NSRect(x: 0, y: 0, width: 615, height: 540)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 615,
            "The embedded library must not push the Settings sidebar out of the window")
    }

    func testFloatingWindowKeepsItsLiveProjectionAndSharedTimeline() throws {
        let playback = try source("SpotifyLyrics/Services/PlaybackState.swift")
        let translation = try source("SpotifyLyrics/Services/TranslationSessionController.swift")
        let timeline = try source("SpotifyLyrics/Lyrics/LyricsModels.swift")
        let floating = try source("SpotifyLyrics/Views/Floating/FloatingLyricsView.swift")

        XCTAssertTrue(playback.contains("liveLyrics"))
        XCTAssertTrue(playback.contains("liveCurrentLineIndex"))
        XCTAssertTrue(playback.contains("liveLyricsProjectionCache"))
        XCTAssertTrue(translation.contains("identity: TrackIdentity"))
        XCTAssertTrue(timeline.contains("middle = lower"), "timeline lookup should stay binary-search based")
        XCTAssertFalse(timeline.contains("lines.indices.last"), "playback lookup should not scan backward from the end")
        XCTAssertTrue(floating.contains("NSAttributedString(string: text, attributes:"))
        XCTAssertTrue(floating.contains("FloatingTimedRubyLayoutCache.layout(for: key)"))
    }

    func testExperienceLibraryRouteAndPreviewAdaptersStayPresentationOnly() throws {
        let adapters = try source("SpotifyLyrics/Views/Debug/PresentationPreviewAdapters.swift")
        let releaseView = try source("SpotifyLyrics/Views/Settings/ExperienceLibrarySettingsView.swift")
        let settings = try source("SpotifyLyrics/Views/Settings/SettingsRootView.swift")

        let adapterCode = adapters
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        for forbidden in ["PlaybackState", "LyricsSession", "TranslationSession", "Timer", "SQLite", "seek("] {
            XCTAssertFalse(adapterCode.contains(forbidden), "preview adapters must not own runtime behavior: \(forbidden)")
        }

        XCTAssertTrue(releaseView.contains("体验版本库"))
        XCTAssertTrue(releaseView.contains("PresentationPreviewAdapterView"))
        XCTAssertTrue(releaseView.contains("applyPresentationSelection"))
        XCTAssertTrue(releaseView.contains("Restore Recommended") || releaseView.contains("恢复推荐"))
        for debugOnly in ["snapshotKey", "renderer signature", "Observer 数量", "Debug geometry", "Apply-to-Debug"] {
            XCTAssertFalse(releaseView.contains(debugOnly), "debug diagnostics should stay out of the release page")
        }

        guard let primaryStart = settings.range(of: "static var primaryCases"),
              let primaryEnd = settings.range(of: "\n    }", range: primaryStart.upperBound..<settings.endIndex) else {
            XCTFail("SettingsRootView should expose the primary sidebar cases")
            return
        }
        let primaryCases = settings[primaryStart.lowerBound..<primaryEnd.lowerBound]
        XCTAssertFalse(primaryCases.contains(".experienceLibrary"), "experience library should remain under advanced settings")
        XCTAssertTrue(settings.contains("onOpenTool(.experienceLibrary)"))
        XCTAssertTrue(settings.contains("accessibilityIdentifier(\"btn_enter_experience_library\")"))
        XCTAssertTrue(settings.contains("onOpenTool: { tool in selection = tool }"))
        XCTAssertTrue(settings.contains("ExperienceLibrarySettingsView(selectionStore: settings.presentationSelections)"))
    }

    func testScopedOffsetConsumersUseTheVersionScopedValue() throws {
        let state = try source("SpotifyLyrics/Services/PlaybackState.swift")
        let controls = try source("SpotifyLyrics/Views/Components/LyricsPreferencesPopover.swift")
        let editor = try source("SpotifyLyrics/Services/LyricsEditorSessionController.swift")
        let v3 = try v3Sources()
        let fullscreen = try source("SpotifyLyrics/Views/Fullscreen/FullScreenLyricsView.swift")
        let floating = try source("SpotifyLyrics/Views/Floating/FloatingLyricsView.swift")
        let capsule = try source("SpotifyLyrics/Views/Capsule/CapsuleLyricsView.swift")
        let settingsView = try source("SpotifyLyrics/Views/Settings/SettingsRootView.swift")

        XCTAssertTrue(state.contains("presentationOffset: settingsStore.lyricsOffsetStore.activeOffset"))
        XCTAssertTrue(state.contains("syncLiveLyricsOffsetScope()"))
        XCTAssertTrue(state.contains("session.$activeLyricsVersionID"))
        XCTAssertTrue(state.contains("syncLiveLyricsOffsetScope(lyricsVersionID: versionID)"))
        XCTAssertTrue(controls.contains("settings.lyricsOffsetStore"))
        XCTAssertTrue(controls.contains(".onChange(of: scope) { _, _ in syncInput() }"))
        XCTAssertTrue(editor.contains("persistentLyricsOffsetScope"))
        XCTAssertTrue(v3.contains("LyricsPresentationOffsetControl(settings: settings)"))
        XCTAssertTrue(floating.contains("LyricsPresentationOffsetControl(settings: settings)"))
        XCTAssertTrue(settingsView.contains("LyricsPresentationOffsetControl(settings: settings)"))
        XCTAssertTrue(fullscreen.contains("AppleMusicImmersiveV3WindowView(state: state, settings: settings,"))
        XCTAssertTrue(capsule.contains("currentIndex: state.liveCurrentLineIndex"))

        for file in [state, controls, v3, settingsView] {
            XCTAssertFalse(file.contains("lyricsPresentationOffset"), "live offset controls must not read the legacy global property")
        }

        let sourceDirectory = try repositoryRoot().appendingPathComponent("SpotifyLyrics", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate the SpotifyLyrics source directory")
            return
        }
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "AppSettingsStore.swift" {
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(contents.contains(".lyricsPresentationOffset"), "legacy offset consumer remains in \(url.lastPathComponent)")
        }
    }

    func testToolbarViewStillRoutesInteractionThroughItsModelAndMatchesTheBehaviorSpec() throws {
        let view = try v3Sources()
        let spec = try source("docs/TOOLBAR_BEHAVIOR.md")

        XCTAssertTrue(view.contains("@State private var toolbar = V3ToolbarModel()"))
        XCTAssertTrue(view.contains(".onChange(of: toolbar.mode) { old, new in toolbarModeChanged(from: old, to: new) }"))
        guard let changedStart = view.range(of: "private func toolbarModeChanged("),
              let changedEnd = view.range(of: "\n    }", range: changedStart.upperBound..<view.endIndex) else {
            XCTFail("Toolbar model changes should flow through toolbarModeChanged")
            return
        }
        XCTAssertTrue(view[changedStart.lowerBound..<changedEnd.lowerBound].contains("hoveredStyle = nil"))
        for removed in ["togglePinnedToolbarPanel", "presentToolbarPopover", "hoveredToolbarTrigger", "toolbarMenuDepth"] {
            XCTAssertFalse(view.contains(removed), "old toolbar state path was reintroduced: \(removed)")
        }
        XCTAssertTrue(spec.contains("180 ms after"))
        XCTAssertTrue(spec.contains("While pinned"))
        XCTAssertTrue(spec.contains("An outside click"))
        XCTAssertTrue(spec.contains("Never** to the left of the window"))
    }

    func testMenuBarSettingsAndToggleStayConnectedToProductionViews() throws {
        let popover = try source("SpotifyLyrics/Views/MenuBar/MenuBarLyricsPopoverView.swift")
        let controller = try source("SpotifyLyrics/Windows/MenuBarLyricsController.swift")
        let mainWindow = try source("SpotifyLyrics/Views/MainWindow/MainLyricsWindowView.swift")
        let settingsStore = try source("SpotifyLyrics/Settings/AppSettingsStore.swift")

        XCTAssertTrue(popover.contains("@ObservedObject private var settings: AppSettingsStore"))
        XCTAssertTrue(popover.contains("Toggle(\"菜单栏显示歌词\", isOn: $settings.menuBarLyricsEnabled)"))
        XCTAssertTrue(popover.contains("controller.openSettings()"))
        XCTAssertTrue(controller.contains("MenuBarLyricsPopoverView(controller: self)"))
        XCTAssertTrue(controller.contains("openSettingsHandler?()"))
        XCTAssertTrue(mainWindow.contains("MenuBarLyricsController.shared.setOpenSettingsHandler { [openSettings] in"))
        XCTAssertTrue(mainWindow.contains("openSettings()"))

        let settings = [
            "menuBarLyricsEnabled", "menuBarLyricsShowsFullLine", "menuBarLyricsShowsOriginal",
            "menuBarLyricsShowsTranslation", "menuBarLyricsShowsKana", "menuBarLyricsShowsRomaji",
            "menuBarLyricsReadingsAbove", "menuBarLyricsFontSize"
        ]
        for name in settings {
            XCTAssertTrue(settingsStore.contains("public static let \(name) ="), "missing persistent key for \(name)")
            XCTAssertTrue(settingsStore.contains("@Published public var \(name):"), "missing published setting for \(name)")
        }
    }

    private func v3Sources() throws -> String {
        try ["WindowView", "Toolbar", "Transport", "Lyrics", "Inspector"]
            .map { try source("SpotifyLyrics/Views/MainWindow/AppleMusicImmersiveV3\($0).swift") }
            .joined(separator: "\n")
    }

    private func source(_ relativePath: String) throws -> String {
        let root = try repositoryRoot()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func repositoryRoot() throws -> URL {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["LYRICSQ_SOURCE_ROOT"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = (0..<4).reduce(URL(fileURLWithPath: #filePath)) { candidate, _ in
                candidate.deletingLastPathComponent()
            }
        }

        var isDirectory: ObjCBool = false
        let sourceDirectory = root.appendingPathComponent("SpotifyLyrics", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: "PresentationSourceContractTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Source root does not contain SpotifyLyrics/: \(root.path)"]
            )
        }
        return root
    }
}
