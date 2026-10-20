import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import SpotifyLyrics

@MainActor
final class MenuBarPresentationTests: XCTestCase {
    func testLyricsToggleUpdatesTheRealControllerAndPersistsInIsolatedDefaults() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.menuBarLyricsEnabled = false
        let controller = MenuBarLyricsController(settings: settings)

        XCTAssertEqual(controller.statusItemTitle, "")
        controller.menuBarLyricsEnabled = true
        XCTAssertTrue(settings.menuBarLyricsEnabled)
        XCTAssertEqual(controller.statusItemTitle, "Lyric Island")

        settings.menuBarLyricsShowsFullLine = true
        settings.menuBarLyricsShowsOriginal = false
        settings.menuBarLyricsShowsTranslation = true
        settings.menuBarLyricsShowsKana = true
        settings.menuBarLyricsShowsRomaji = true
        settings.menuBarLyricsFontSize = 16
        settings.menuBarLyricsReadingsAbove = false

        let reopenedSettings = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(reopenedSettings.menuBarLyricsEnabled)
        XCTAssertTrue(reopenedSettings.menuBarLyricsShowsFullLine)
        XCTAssertFalse(reopenedSettings.menuBarLyricsShowsOriginal)
        XCTAssertTrue(reopenedSettings.menuBarLyricsShowsTranslation)
        XCTAssertTrue(reopenedSettings.menuBarLyricsShowsKana)
        XCTAssertTrue(reopenedSettings.menuBarLyricsShowsRomaji)
        XCTAssertEqual(reopenedSettings.menuBarLyricsFontSize, 16)
        XCTAssertFalse(reopenedSettings.menuBarLyricsReadingsAbove)

        settings.menuBarLyricsEnabled = false
        XCTAssertFalse(settings.menuBarLyricsEnabled)
        XCTAssertEqual(controller.statusItemTitle, "", "the controller should refresh without a playback event")
        XCTAssertFalse(AppSettingsStore(defaults: defaults).menuBarLyricsEnabled)
    }

    func testOpenSettingsUsesTheInjectedNativeHandlerForFirstRepeatAndReopen() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettingsStore(defaults: defaults)
        let controller = MenuBarLyricsController(settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Lyrics Settings Route Test"
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        defer { window.close() }

        var openRequests = 0
        controller.setOpenSettingsHandler {
            openRequests += 1
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }

        controller.openSettings()
        XCTAssertEqual(openRequests, 1)
        XCTAssertTrue(window.isVisible, "the first request should reach the native settings handler")

        controller.openSettings()
        XCTAssertEqual(openRequests, 2)
        XCTAssertTrue(window.isVisible, "a repeated request should leave the already open settings window visible")

        window.close()
        XCTAssertFalse(window.isVisible)
        controller.openSettings()
        XCTAssertEqual(openRequests, 3)
        XCTAssertTrue(window.isVisible, "the settings route should work again after the previous window closes")
    }

    func testNativePopoverHostKeepsFirstClickAndOpeningFocusBehavior() throws {
        let host = MenuBarPopoverHostingController(
            rootView: Text("Lyric Island")
                .frame(minWidth: 300, minHeight: 110)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.close() }

        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.view.fittingSize.width, 300)
        XCTAssertGreaterThan(host.view.fittingSize.height, 100)
        XCTAssertTrue(host.view.acceptsFirstMouse(for: nil))

        let keyboardField = NSTextField(string: "keyboard focus target")
        host.view.addSubview(keyboardField)
        XCTAssertTrue(window.makeFirstResponder(keyboardField))
        host.viewDidAppear()
        XCTAssertTrue(window.firstResponder === window, "opening should not focus the first action")
        XCTAssertTrue(window.makeFirstResponder(keyboardField), "keyboard focus should remain available")
    }

    func testMenuBarFormattingKeepsCurrentLineAndSelectedReadings() {
        var snapshot = MenuBarLyricsSnapshot(
            state: .synchronized(current: "Current lyric", next: "Next lyric"),
            statusText: "Lyric Island",
            trackTitle: "Song",
            artistName: "Artist",
            currentLineText: "Current lyric",
            nextLineText: "Next lyric",
            isPlaying: true,
            hasLiveTrack: true,
            artworkURL: nil
        )
        snapshot.currentTranslationText = "当前中文"
        snapshot.currentKanaText = "かな"
        snapshot.currentRomajiText = "kana"

        XCTAssertEqual(MenuBarTextFormatter.statusItemTitle(snapshot: snapshot, lyricsEnabled: false), "")
        XCTAssertEqual(MenuBarTextFormatter.statusItemSymbol(snapshot: snapshot), "music.note")
        let paused = MenuBarLyricsSnapshot(
            state: snapshot.state,
            statusText: snapshot.statusText,
            trackTitle: snapshot.trackTitle,
            artistName: snapshot.artistName,
            currentLineText: snapshot.currentLineText,
            nextLineText: snapshot.nextLineText,
            isPlaying: false,
            hasLiveTrack: snapshot.hasLiveTrack,
            artworkURL: snapshot.artworkURL
        )
        XCTAssertEqual(MenuBarTextFormatter.statusItemSymbol(snapshot: paused), "pause.fill")

        let readings = MenuBarLyricsAppearance(
            showsFullLine: true,
            showsOriginal: false,
            showsTranslation: true,
            showsKana: true,
            showsRomaji: true
        )
        XCTAssertEqual(
            MenuBarTextFormatter.statusItemTitle(snapshot: snapshot, lyricsEnabled: true, appearance: readings),
            "♪ 当前中文 · かな · kana"
        )
        var missingReadings = snapshot
        missingReadings.currentTranslationText = nil
        missingReadings.currentKanaText = nil
        missingReadings.currentRomajiText = nil
        XCTAssertEqual(
            MenuBarTextFormatter.statusItemTitle(snapshot: missingReadings, lyricsEnabled: true, appearance: readings),
            "♪ Song"
        )

        let longLine = String(repeating: "完整歌词不截断 ", count: 120)
        let longSnapshot = MenuBarLyricsSnapshot(
            state: .synchronized(current: longLine, next: nil),
            statusText: "Lyric Island",
            trackTitle: "Song",
            artistName: "Artist",
            currentLineText: longLine,
            nextLineText: nil,
            isPlaying: true,
            hasLiveTrack: true,
            artworkURL: nil
        )
        let complete = MenuBarLyricsAppearance(showsFullLine: true)
        let completeTitle = MenuBarTextFormatter.statusItemTitle(snapshot: longSnapshot, lyricsEnabled: true, appearance: complete)
        let compactTitle = MenuBarTextFormatter.statusItemTitle(snapshot: longSnapshot, lyricsEnabled: true)
        XCTAssertTrue(completeTitle.contains(longLine.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(compactTitle.hasSuffix("…"))
        XCTAssertLessThan(compactTitle.count, completeTitle.count)

        let onlyTranslation = MenuBarLyricsAppearance(showsFullLine: true, showsOriginal: false, showsTranslation: true)
        var noCurrentTranslation = snapshot
        noCurrentTranslation.currentTranslationText = nil
        let titleWithoutCurrentTranslation = MenuBarTextFormatter.statusItemTitle(
            snapshot: noCurrentTranslation,
            lyricsEnabled: true,
            appearance: onlyTranslation
        )
        XCTAssertTrue(titleWithoutCurrentTranslation.contains("Song"))
        XCTAssertFalse(titleWithoutCurrentTranslation.contains("Next lyric"), "the next line must never stand in for the current translation")

        let help = MenuBarTextFormatter.statusItemHelp(snapshot: longSnapshot)
        XCTAssertTrue(help.contains("Song"))
        XCTAssertTrue(help.contains("Artist"))
        XCTAssertTrue(help.contains(longLine.trimmingCharacters(in: .whitespacesAndNewlines)))
        let full = MenuBarFullLyricsSnapshot(
            trackTitle: "Song",
            artistName: "Artist",
            lyricsText: "Current lyric\n当前中文\n\nNext lyric\n下一句中文"
        )
        XCTAssertTrue(full.copyText.contains("Song"))
        XCTAssertTrue(full.copyText.contains("Next lyric"))
    }

    func testAppearanceBoundsAndReadingImageStayNativeAndCompact() {
        XCTAssertEqual(MenuBarLyricsAppearance(fontSize: .nan).effectiveFontSize, 13)
        XCTAssertEqual(MenuBarLyricsAppearance(fontSize: .infinity).effectiveFontSize, 13)
        XCTAssertEqual(MenuBarLyricsAppearance(fontSize: -10).effectiveFontSize, 10)
        XCTAssertEqual(MenuBarLyricsAppearance(fontSize: 999).effectiveFontSize, 18)

        var snapshot = MenuBarLyricsSnapshot(
            state: .synchronized(current: "空", next: nil),
            statusText: "Lyric Island",
            trackTitle: "Song",
            artistName: nil,
            currentLineText: "空",
            nextLineText: nil,
            isPlaying: true,
            hasLiveTrack: true,
            artworkURL: nil
        )
        snapshot.currentKanaText = "そら"
        let appearance = MenuBarLyricsAppearance(showsKana: true)
        let image = MenuBarTextFormatter.readingImage(snapshot: snapshot, appearance: appearance)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.height, 22)
        XCTAssertEqual(image?.isTemplate, true)

        var inline = appearance
        inline.readingsAbove = false
        XCTAssertNil(MenuBarTextFormatter.readingImage(snapshot: snapshot, appearance: inline))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "SpotifyLyrics-Presentation-MenuBar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
