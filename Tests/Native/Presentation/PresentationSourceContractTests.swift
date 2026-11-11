import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import SpotifyLyrics

final class PresentationSourceContractTests: XCTestCase {
    @MainActor
    func testAnimationIslandClockUpdatesKeepTheirAllocatedSize() {
        let view = V3AnimationIslandView(root: AnyView(Text("00:09")))
        view.frame = NSRect(x: 0, y: 0, width: 34, height: 14)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.host.sizingOptions.isEmpty)
        let allocated = view.frame
        view.host.rootView = AnyView(Text("100:00"))
        view.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame, allocated)
        XCTAssertEqual(view.host.frame, view.bounds)
    }

    @MainActor
    func testTimedHighlightAnimatesOnlyMaskAndFreezesOnPause() {
        let view = TimedLyricHighlightView(root: Text("ずっと前から決めてたんだね"))
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        let fragment = TimedSpanFragment(spanID: 0, utf16Range: 0..<1, text: "句",
            startTime: 10, endTime: 20, startX: 0, endX: 240)
        let now = ProcessInfo.processInfo.systemUptime
        view.configure(clock: LyricsPresentationClock(authoritativePosition: 15, receivedAtMonotonicTime: now,
            isPlaying: true, trackDuration: 100), fragments: [fragment], totalWidth: 240, inset: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.reveal.animation(forKey: "lyricFill"))
        let textFrame = view.host.frame
        view.configure(clock: LyricsPresentationClock(authoritativePosition: 15, receivedAtMonotonicTime: now,
            isPlaying: false, trackDuration: 100), fragments: [fragment], totalWidth: 240, inset: 0)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.reveal.animation(forKey: "lyricFill"))
        XCTAssertEqual(view.reveal.bounds.width, 120, accuracy: 0.1)
        XCTAssertEqual(view.host.frame, textFrame)
    }

    @MainActor
    func testNativeRailAdvancesWithoutBodyTicksAndStopsForSeekPreview() {
        let view = V3EdgeRailView(frame: NSRect(x: 0, y: 0, width: 1116, height: 779))
        let clock = LyricsPresentationClock(authoritativePosition: 30, receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime,
            isPlaying: true, trackID: "current-song", trackDuration: 150)
        view.configure(clock: clock, draft: nil, active: true, color: NSColor.white.cgColor)
        XCTAssertNotNil(view.progressLayer.animation(forKey: "playhead"))
        view.configure(clock: clock, draft: 0.4, active: true, color: NSColor.white.cgColor)
        XCTAssertNil(view.progressLayer.animation(forKey: "playhead"))
        XCTAssertEqual(view.progressLayer.strokeEnd, 0.4, accuracy: 0.001)
        view.configure(clock: clock, draft: nil, active: false, color: NSColor.white.cgColor)
        XCTAssertNil(view.progressLayer.animation(forKey: "playhead"))
    }

    /// The rail at the window edge only shows progress: it never moves,
    /// thickens or takes a click, so it cannot compete with resizing.
    @MainActor
    func testEdgeRailStaysAtTheWindowEdgeAndTakesNoPointerEvents() {
        let view = V3EdgeRailView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.layoutSubtreeIfNeeded()
        let clock = LyricsPresentationClock(authoritativePosition: 30, receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime,
            isPlaying: true, trackID: "current-song", trackDuration: 150)
        view.configure(clock: clock, draft: nil, active: true, color: NSColor.white.cgColor)
        let bounds = view.progressLayer.path!.boundingBoxOfPath
        XCTAssertEqual(bounds, CGRect(x: 1.5, y: 1.5, width: 897, height: 697))
        XCTAssertEqual(view.trackLayer.path?.boundingBoxOfPath, bounds)
        XCTAssertEqual(view.progressLayer.lineWidth, 2.2, accuracy: 0.01)
        XCTAssertEqual(view.trackLayer.lineWidth, 2.1, accuracy: 0.01)
        for point in [CGPoint(x: 450, y: 2), CGPoint(x: 450, y: 12), CGPoint(x: 2, y: 350), CGPoint(x: 888, y: 350)] {
            XCTAssertNil(view.hitTest(point))
        }
    }

    @MainActor
    func testOpenPanelAppearanceTracksApplicationAppearance() async {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        let appearance = V3SystemAppearance.shared
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            NSApp.appearance = NSAppearance(named: name)
            // KVO delivers its change to the main actor.
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(appearance.colorScheme, name == .aqua ? .light : .dark)
        }
    }

    @MainActor
    func testColdSongReadingsNeverRunInTheViewAndAreReusedAfterPreparation() async {
        let line = LyricLine(timestamp: 0, originalText: "ずっと前から決めてたんだね")
        let presentation = V3JapaneseReadingCache.resolvedPresentation(for: line, language: "ja",
            userEntries: [], trackStableKey: "round7-unmei", artistDisplay: "はてなぷれいりすと",
            scriptConversion: .none)
        XCTAssertNil(presentation.kanaText, "A cold view read must show the original without running MeCab")
        await V3JapaneseReadingCache.prepare(.init(lines: [line], language: "ja", userEntries: [],
            trackStableKey: "round7-unmei", artistDisplay: "はてなぷれいりすと", scriptConversion: .none))
        // A projection can rebuild line UUIDs without changing the reading inputs.
        let projected = LyricLine(timestamp: 1, originalText: line.originalText)
        let ready = V3JapaneseReadingCache.resolvedPresentation(for: projected, language: "ja",
            userEntries: [], trackStableKey: "round7-unmei", artistDisplay: "はてなぷれいりすと", scriptConversion: .none)
        XCTAssertNotNil(ready.kanaText)
        XCTAssertTrue(ready.hasRuby)

    }

    func testSearchListsThePlayingSongOnceAndMergesDuplicateOtherSongs() {
        let playing = Track(title: "運命のふりをして", artist: "Fixture", album: "One", duration: 180, spotifyId: "playing")
        let other = Track(title: "Other", artist: "Fixture", album: "Two", duration: 200, spotifyId: "other")
        let rows = [SongSearchResult(id: "playing", source: .local, track: playing, confidence: 1),
                    SongSearchResult(id: "local", source: .local, track: other, confidence: 1),
                    SongSearchResult(id: "online", source: .spotifyCatalog, track: other, confidence: 1)]
        XCTAssertEqual(V3SearchPanel.otherSongs(rows, current: playing).map(\.track.title), ["Other"])
        let anotherRecording = Track(title: playing.title, artist: playing.artist, album: "Another recording", duration: 180, spotifyId: "another-recording")
        XCTAssertEqual(V3SearchPanel.otherSongs([SongSearchResult(id: "another-recording", source: .spotifyCatalog,
            track: anotherRecording, confidence: 1)], current: playing).count, 1)
    }

    /// With a foreground cover the line runs around it and glows; without a
    /// cover large enough it is the plain window-edge line again.
    @MainActor
    func testProgressHaloRunsAroundTheCoverAndFallsBackToTheWindowEdge() {
        let view = V3EdgeRailView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.layoutSubtreeIfNeeded()
        let clock = LyricsPresentationClock(authoritativePosition: 30, receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime,
            isPlaying: true, trackID: "current-song", trackDuration: 150)
        let cover = V3ForegroundCoverFrame(frame: CGRect(x: 60, y: 180, width: 320, height: 320), cornerRadius: 8)
        view.configure(clock: clock, draft: nil, active: true, color: NSColor.systemPink.cgColor, halo: cover)
        // 6 pt outside the cover on every side.
        XCTAssertEqual(view.progressLayer.path!.boundingBoxOfPath, cover.frame.insetBy(dx: -6, dy: -6))
        XCTAssertEqual(view.trackLayer.path?.boundingBoxOfPath, view.progressLayer.path?.boundingBoxOfPath)
        XCTAssertEqual(view.progressLayer.shadowOpacity, 0.9, accuracy: 0.001)
        XCTAssertEqual(view.progressLayer.lineWidth, 3, accuracy: 0.01)
        XCTAssertNotNil(view.progressLayer.animation(forKey: "playhead"), "the halo advances like the edge line")
        XCTAssertNil(view.hitTest(CGPoint(x: 54, y: 300)), "the drawn line never takes clicks; the band does")

        view.configure(clock: clock, draft: nil, active: true, color: NSColor.systemPink.cgColor, halo: nil)
        XCTAssertEqual(view.progressLayer.path!.boundingBoxOfPath, CGRect(x: 1.5, y: 1.5, width: 897, height: 697))
        XCTAssertEqual(view.progressLayer.shadowOpacity, 0)
        XCTAssertEqual(view.progressLayer.lineWidth, 2.2, accuracy: 0.01)

        XCTAssertTrue(cover.isLargeEnough)
        XCTAssertFalse(V3ForegroundCoverFrame(frame: CGRect(x: 0, y: 0, width: 52, height: 52), cornerRadius: 6).isLargeEnough,
                       "a thumbnail is not a place for the halo")
    }

    /// Both lines can be seeked from a band beside them. The window edge keeps
    /// its outer 8 pt for resizing; the halo's band is centred on the ring.
    func testProgressBandsSeekWithoutTouchingTheResizeBorder() {
        let canvas = CGSize(width: 900, height: 700)
        let edge = V3ProgressTrack(canvas: canvas, halo: nil)
        for depth: CGFloat in [2, 7.9] { XCTAssertFalse(edge.contains(CGPoint(x: 450, y: depth)), "resize border at \(depth)") }
        for depth: CGFloat in [8.1, 16, 23.9] {
            XCTAssertTrue(edge.contains(CGPoint(x: 450, y: depth)), "top band at \(depth)")
            XCTAssertTrue(edge.contains(CGPoint(x: 900 - depth, y: 350)), "right band at \(depth)")
        }
        XCTAssertFalse(edge.contains(CGPoint(x: 450, y: 30)), "lyrics below the band keep their clicks")
        XCTAssertEqual(edge.fraction(at: CGPoint(x: 450, y: 12))!, 0, accuracy: 0.01, "top middle is the start")
        XCTAssertEqual(edge.fraction(at: CGPoint(x: 450, y: 688))!, 0.5, accuracy: 0.01, "bottom middle is halfway")
        XCTAssertGreaterThan(edge.labelPosition(for: CGPoint(x: 450, y: 12)).y, 40, "the label sits inward from the edge")

        let cover = V3ForegroundCoverFrame(frame: CGRect(x: 60, y: 180, width: 320, height: 320), cornerRadius: 8)
        let halo = V3ProgressTrack(canvas: canvas, halo: cover)
        XCTAssertEqual(halo.ring, cover.frame.insetBy(dx: -6, dy: -6))
        XCTAssertTrue(halo.contains(CGPoint(x: 220, y: 174)), "on the ring above the cover")
        XCTAssertTrue(halo.contains(CGPoint(x: 220, y: 178)), "just outside the cover edge")
        XCTAssertFalse(halo.contains(CGPoint(x: 220, y: 300)), "the cover itself is not the band")
        XCTAssertFalse(halo.contains(CGPoint(x: 450, y: 12)), "with a halo the window edge is free")
        XCTAssertEqual(halo.fraction(at: CGPoint(x: 220, y: 174))!, 0, accuracy: 0.01)
        XCTAssertEqual(halo.fraction(at: CGPoint(x: 386, y: 340))!, 0.25, accuracy: 0.01, "right middle is a quarter")
        XCTAssertLessThan(halo.labelPosition(for: CGPoint(x: 220, y: 174)).y, 174, "the label sits outward from the cover")
    }

    /// Seeking lives on the pill, well inside the window.
    func testPillScrubberMapsThePointerAndKeepsClearOfTheResizeBorder() {
        XCTAssertEqual(V3EdgePillScrubber.fraction(at: 64, length: 256), 0.25, accuracy: 0.0001)
        XCTAssertEqual(V3EdgePillScrubber.fraction(at: -20, length: 256), 0)
        XCTAssertEqual(V3EdgePillScrubber.fraction(at: 400, length: 256), 1)
        XCTAssertEqual(V3EdgePillScrubber.fraction(at: 10, length: 0), 0)
        XCTAssertEqual(V3EdgePillScrubber.fraction(at: .nan, length: 256), 0)
        let canvas = CGSize(width: 900, height: 700)
        for (edge, exit) in [(V3WindowEdgeControlPositioner.Edge.top, CGPoint(x: 450, y: 0)), (.right, CGPoint(x: 900, y: 350)),
                             (.bottom, CGPoint(x: 450, y: 700)), (.left, CGPoint(x: 0, y: 350))] {
            let frame = V3WindowEdgeControlPositioner.layout(size: canvas, exitPoint: exit, preferredEdge: edge).frame
            // The whole pill, scrubber included, starts at the toolbar's inset.
            XCTAssertEqual(min(frame.minX, frame.minY, canvas.width - frame.maxX, canvas.height - frame.maxY),
                           V3WindowEdgeControlPositioner.edgeInset, accuracy: 0.01, "\(edge)")
        }
    }

    func testForegroundPlayerCardTracksCoverWidthWithMinimum() {
        let large = V3ResponsiveGeometry.adaptiveSplitMetrics(canvasSize: CGSize(width: 1440, height: 900), artworkScale: 1.4)
        XCTAssertGreaterThan(large.coverSize, 300)
        XCTAssertEqual(V3ResponsiveGeometry.foregroundCardWidth(coverSize: large.coverSize), large.coverSize)
        let small = V3ResponsiveGeometry.adaptiveSplitMetrics(canvasSize: CGSize(width: 1152, height: 720), artworkScale: 0.8)
        XCTAssertLessThan(small.coverSize, 300)
        XCTAssertEqual(V3ResponsiveGeometry.foregroundCardWidth(coverSize: small.coverSize), 300)
    }

    func testBigLineShowsTheWholeUnmeiPhraseWithinTwoLinesAndTheColumnHeight() {
        let phrase = "ずっと前から決めてたんだね"
        for width: CGFloat in [280, 600] {
            let size = V3BigLineLayout.fit(preferredSize: 84, maxHeight: 160) {
                V3BigLineLayout.text(phrase, size: $0, width: width)
            }
            let fitted = V3BigLineLayout.text(phrase, size: size, width: width)
            XCTAssertLessThanOrEqual(fitted.lines, 2)
            XCTAssertLessThanOrEqual(fitted.height, 160)
            XCTAssertLessThanOrEqual(fitted.width, width)
            XCTAssertEqual(V3LyricDisplayLineBreaker.breakText(phrase, fontSize: size,
                weight: V3LyricMotionPolicy.layoutNSWeight, availableWidth: width).replacingOccurrences(of: "\n", with: ""), phrase)
        }
    }

    @MainActor
    func testStoppingLibraryCompletionDoesNotStartAnotherSong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SQLiteLyricsRepository(databaseURL: root.appendingPathComponent("missing.sqlite3"))
        try await repository.prepare()
        let tracks = [Track(title: "Missing one", artist: "Artist", album: "Fixture", duration: 180),
                      Track(title: "Missing two", artist: "Artist", album: "Fixture", duration: 180)]
        for track in tracks { try await (repository as any LyricsRepository).saveTrackMetadata(.bootstrap(from: track)) }
        let missing = try await repository.loadPersonalLibraryEntries(includeMissingLyrics: true)
        XCTAssertEqual(missing.filter { $0.lyricsVersionCount == 0 }.count, 2)
        let batch = LyricsBatchCompletion()
        var searched: [String] = []
        batch.start(tracks: tracks) { track in
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
        let emptyVersion = UUID()
        settings.applyReadingLanguage(versionID: emptyVersion, text: " \n")
        XCTAssertEqual(settings.activeReadingLanguage, .japanese, "无歌词时不能猜成其他语言或切换偏好")
        XCTAssertFalse(settings.displayPreferences.showRomaji)
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
