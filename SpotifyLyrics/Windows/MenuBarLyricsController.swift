import AppKit
import Combine
import SwiftUI

public enum MenuBarLyricsState: Equatable, Sendable {
    case idle
    case loading(title: String)
    case synchronized(current: String, next: String?)
    case unsynchronized(title: String)
    case noLyrics(title: String)
    case failed(title: String)
}

public struct MenuBarLyricsSnapshot: Equatable, Sendable {
    public let state: MenuBarLyricsState
    public let statusText: String
    public let trackTitle: String?
    public let artistName: String?
    public let currentLineText: String?
    public let nextLineText: String?
    public let isPlaying: Bool
    public let hasLiveTrack: Bool
    public let artworkURL: URL?
    /// Translation of the currently playing live line; never sourced from a search preview.
    public var currentTranslationText: String? = nil
}

public enum MenuBarTextFormatter {
    public static func statusItemTitle(snapshot: MenuBarLyricsSnapshot, lyricsEnabled: Bool) -> String {
        lyricsEnabled ? truncateToFit(snapshot.statusText) : ""
    }

    public static func statusItemSymbol(snapshot: MenuBarLyricsSnapshot) -> String {
        snapshot.hasLiveTrack && !snapshot.isPlaying ? "pause.fill" : "music.note"
    }

    public static let maxVisualWidth: CGFloat = 240.0
    public static let font: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular))

    public static func truncateToFit(_ text: String, maxWidth: CGFloat = maxVisualWidth, font: NSFont = font) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let baseSize = (text as NSString).size(withAttributes: attributes)
        if baseSize.width <= maxWidth {
            return text
        }

        let ellipsis = "…"
        var low = 0
        var high = text.count
        var best = ellipsis

        while low <= high {
            let mid = (low + high) / 2
            let prefixIndex = text.index(text.startIndex, offsetBy: mid)
            let candidate = String(text[..<prefixIndex]) + ellipsis
            let candidateSize = (candidate as NSString).size(withAttributes: attributes)

            if candidateSize.width <= maxWidth {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}

@MainActor
public final class MenuBarLyricsController: NSObject, ObservableObject {
    public static let shared = MenuBarLyricsController(settings: .shared)

    @Published public private(set) var currentSnapshot: MenuBarLyricsSnapshot

    @Published public private(set) var statusItemTitle = ""
    public var menuBarLyricsEnabled: Bool {
        get { settings.menuBarLyricsEnabled }
        set { settings.menuBarLyricsEnabled = newValue }
    }

    private let settings: AppSettingsStore
    private var settingsSubscription: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var playbackState: PlaybackState?
    private var cancellables = Set<AnyCancellable>()
    private var openMainWindowHandler: (@MainActor () -> Void)?
    private var openLibraryHandler: (@MainActor () -> Void)?
    private var openSettingsHandler: (@MainActor () -> Void)?
    private var openEditorHandler: (@MainActor () -> Void)?

    public init(settings: AppSettingsStore) {
        self.settings = settings
        self.currentSnapshot = MenuBarLyricsSnapshot(
            state: .idle,
            statusText: "Lyric Island",
            trackTitle: nil,
            artistName: nil,
            currentLineText: nil,
            nextLineText: nil,
            isPlaying: false,
            hasLiveTrack: false,
            artworkURL: nil
        )
        super.init()
        // Subscribe to the emitted value: @Published sends before its stored
        // property changes, and playback can stay unchanged while paused.
        settingsSubscription = settings.$menuBarLyricsEnabled
            .sink { [weak self] enabled in
                self?.updateStatusItemButton(lyricsEnabled: enabled)
            }
    }

    public func bind(playbackState: PlaybackState) {
        self.playbackState = playbackState
        cancellables.removeAll()

        setupStatusItemIfNeeded()
        setupPopoverIfNeeded()

        playbackState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePlaybackStateChange()
            }
            .store(in: &cancellables)

        handlePlaybackStateChange()
    }

    public func setOpenMainWindowHandler(_ handler: @escaping @MainActor () -> Void) {
        self.openMainWindowHandler = handler
    }

    public func setOpenLibraryHandler(_ handler: @escaping @MainActor () -> Void) {
        self.openLibraryHandler = handler
    }

    public func setOpenSettingsHandler(_ handler: @escaping @MainActor () -> Void) {
        openSettingsHandler = handler
    }

    public func setOpenEditorHandler(_ handler: @escaping @MainActor () -> Void) {
        openEditorHandler = handler
    }

    public func openEditor() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        openEditorHandler?()
    }

    public func openMainWindow() {
        popover?.performClose(nil)

        openMainWindowHandler?()

        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.identifier?.rawValue == "main-window" || window.title == "Lyric Island" {
                if !window.isKind(of: NSPanel.self) {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
    }

    public func openLibrary() {
        popover?.performClose(nil)

        playbackState?.selectedLibraryToolTab = .library
        openLibraryHandler?()

        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.identifier?.rawValue == "personal-library-activity" || window.title == "歌词库与收听记录" {
                if !window.isKind(of: NSPanel.self) {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
    }

    public func openSettings() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        openSettingsHandler?()
    }

    public func quit() {
        popover?.performClose(nil)
        NSApp.terminate(nil)
    }

    public func togglePlayPause() {
        playbackState?.togglePlayPause()
    }

    public func previousTrack() {
        playbackState?.previousTrack()
    }

    public func nextTrack() {
        playbackState?.nextTrack()
    }

    private func setupStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = settings.menuBarLyricsEnabled ? .imageLeft : .imageOnly
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Lyric Island")
            button.title = settings.menuBarLyricsEnabled ? "Lyric Island" : ""
        }
        self.statusItem = item
        updateStatusItemButton(lyricsEnabled: settings.menuBarLyricsEnabled)
    }

    private func setupPopoverIfNeeded() {
        guard popover == nil else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(
            rootView: MenuBarLyricsPopoverView(controller: self)
        )
        self.popover = pop
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func handlePlaybackStateChange() {
        guard let playbackState else { return }
        let newSnapshot = Self.deriveSnapshot(from: playbackState)

        guard newSnapshot != currentSnapshot else { return }

        currentSnapshot = newSnapshot
        updateStatusItemButton(lyricsEnabled: settings.menuBarLyricsEnabled)
    }

    private func updateStatusItemButton(lyricsEnabled: Bool) {
        statusItemTitle = MenuBarTextFormatter.statusItemTitle(
            snapshot: currentSnapshot, lyricsEnabled: lyricsEnabled
        )
        guard let button = statusItem?.button else { return }
        button.title = statusItemTitle
        button.imagePosition = lyricsEnabled ? .imageLeft : .imageOnly
        button.image = NSImage(
            systemSymbolName: MenuBarTextFormatter.statusItemSymbol(snapshot: currentSnapshot),
            accessibilityDescription: "Lyric Island"
        )
    }

    public static func deriveSnapshot(from state: PlaybackState) -> MenuBarLyricsSnapshot {
        guard state.hasLiveTrack, !state.isMockPreviewMode else {
            return MenuBarLyricsSnapshot(
                state: .idle,
                statusText: "Lyric Island",
                trackTitle: nil,
                artistName: nil,
                currentLineText: nil,
                nextLineText: nil,
                isPlaying: false,
                hasLiveTrack: false,
                artworkURL: nil
            )
        }

        let track = state.currentTrack
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaying = state.isPlaying
        let artworkURL = track.artworkURL

        guard state.liveLyricsDocumentMatchesCurrentTrack else {
            let displayTitle = title.isEmpty ? "Lyric Island" : title
            return MenuBarLyricsSnapshot(
                state: .loading(title: displayTitle),
                statusText: "♪ \(displayTitle)",
                trackTitle: displayTitle,
                artistName: artist,
                currentLineText: nil,
                nextLineText: nil,
                isPlaying: isPlaying,
                hasLiveTrack: true,
                artworkURL: artworkURL
            )
        }

        let lyricsLoadState = state.liveLyricsState
        switch lyricsLoadState {
        case .loading:
            let displayTitle = title.isEmpty ? "Lyric Island" : title
            return MenuBarLyricsSnapshot(
                state: .loading(title: displayTitle),
                statusText: "♪ \(displayTitle)",
                trackTitle: displayTitle,
                artistName: artist,
                currentLineText: nil,
                nextLineText: nil,
                isPlaying: isPlaying,
                hasLiveTrack: true,
                artworkURL: artworkURL
            )

        case .noLyrics, .noSelection, .noMatch:
            let displayTitle = title.isEmpty ? "Lyric Island" : title
            return MenuBarLyricsSnapshot(
                state: .noLyrics(title: displayTitle),
                statusText: "♪ \(displayTitle)",
                trackTitle: displayTitle,
                artistName: artist,
                currentLineText: nil,
                nextLineText: nil,
                isPlaying: isPlaying,
                hasLiveTrack: true,
                artworkURL: artworkURL
            )

        case .failed:
            let displayTitle = title.isEmpty ? "Lyric Island" : title
            return MenuBarLyricsSnapshot(
                state: .failed(title: displayTitle),
                statusText: "♪ \(displayTitle)",
                trackTitle: displayTitle,
                artistName: artist,
                currentLineText: nil,
                nextLineText: nil,
                isPlaying: isPlaying,
                hasLiveTrack: true,
                artworkURL: artworkURL
            )

        case .loaded, .alignmentQueued, .alignmentRunning, .alignmentPreview:
            let lines = state.liveLyrics
            let isSync = state.liveLyricsAreSynchronized

            if isSync, let currentIndex = state.liveCurrentLineIndex, currentIndex >= 0, currentIndex < lines.count {
                let currentLine = lines[currentIndex].originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                let nextLine: String? = (currentIndex + 1 < lines.count)
                    ? lines[currentIndex + 1].originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil

                let statusText = currentLine.isEmpty ? "♪ \(title)" : "♪ \(currentLine)"
                var snapshot = MenuBarLyricsSnapshot(
                    state: .synchronized(current: currentLine, next: nextLine),
                    statusText: statusText,
                    trackTitle: title,
                    artistName: artist,
                    currentLineText: currentLine,
                    nextLineText: nextLine,
                    isPlaying: isPlaying,
                    hasLiveTrack: true,
                    artworkURL: artworkURL
                )
                // The adopted live document is the sole source of popover translation.
                // Include it in Equatable snapshot changes so translations arriving
                // after the original lyrics are immediately reflected in the UI.
                let translated = lines[currentIndex].translationText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.currentTranslationText = translated?.isEmpty == true ? nil : translated
                return snapshot
            } else if !isSync {
                let displayTitle = title.isEmpty ? "Lyric Island" : title
                return MenuBarLyricsSnapshot(
                    state: .unsynchronized(title: displayTitle),
                    statusText: "♪ \(displayTitle)",
                    trackTitle: displayTitle,
                    artistName: artist,
                    currentLineText: nil,
                    nextLineText: nil,
                    isPlaying: isPlaying,
                    hasLiveTrack: true,
                    artworkURL: artworkURL
                )
            } else {
                let displayTitle = title.isEmpty ? "Lyric Island" : title
                let nextLine: String? = lines.first?.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                return MenuBarLyricsSnapshot(
                    state: .synchronized(current: "", next: nextLine),
                    statusText: "♪ \(displayTitle)",
                    trackTitle: displayTitle,
                    artistName: artist,
                    currentLineText: nil,
                    nextLineText: nextLine,
                    isPlaying: isPlaying,
                    hasLiveTrack: true,
                    artworkURL: artworkURL
                )
            }

        case .idle, .candidates, .mockPreview:
            let displayTitle = title.isEmpty ? "Lyric Island" : title
            return MenuBarLyricsSnapshot(
                state: .noLyrics(title: displayTitle),
                statusText: "♪ \(displayTitle)",
                trackTitle: displayTitle,
                artistName: artist,
                currentLineText: nil,
                nextLineText: nil,
                isPlaying: isPlaying,
                hasLiveTrack: true,
                artworkURL: artworkURL
            )
        }
    }
}
