import AppKit
import Combine
import SwiftUI

public enum MenuBarLyricsState: Equatable, Sendable {
    case idle
    case loading(title: String)
    case synchronized(current: String, next: String?)
    case unsynchronized(title: String)
    case noLyrics(title: String)
    case noSelection(title: String)
    case notSearched(title: String)
    case candidates(title: String, count: Int)
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
    public var currentKanaText: String? = nil
    public var currentRomajiText: String? = nil
    public var currentRubyTokens: [LyricRubyToken]? = nil
    /// Playback controls follow the current provider capability, not just retained metadata.
    public var canControlPlayback: Bool = false
}

/// Captured on the explicit read action, so selecting/copying text is stable
/// while playback advances. This never changes the main window's preview.
public struct MenuBarFullLyricsSnapshot: Equatable, Sendable {
    public let trackTitle: String
    public let artistName: String
    public let lyricsText: String

    public var copyText: String {
        [trackTitle, artistName, lyricsText].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public struct MenuBarLyricsAppearance: Equatable, Sendable {
    public var showsFullLine: Bool
    public var showsOriginal: Bool
    public var showsTranslation: Bool
    public var showsKana: Bool
    public var showsRomaji: Bool
    public var fontSize: Double
    public var readingsAbove: Bool

    public init(showsFullLine: Bool = false, showsOriginal: Bool = true,
                showsTranslation: Bool = false, showsKana: Bool = false,
                showsRomaji: Bool = false, fontSize: Double = 13, readingsAbove: Bool = true) {
        self.showsFullLine = showsFullLine
        self.showsOriginal = showsOriginal
        self.showsTranslation = showsTranslation
        self.showsKana = showsKana
        self.showsRomaji = showsRomaji
        self.fontSize = fontSize
        self.readingsAbove = readingsAbove
    }

    public var effectiveFontSize: CGFloat {
        CGFloat(fontSize.isFinite ? min(18, max(10, fontSize)) : 13)
    }
}

public enum MenuBarTextFormatter {
    public static func statusItemTitle(snapshot: MenuBarLyricsSnapshot, lyricsEnabled: Bool,
                                       appearance: MenuBarLyricsAppearance = .init()) -> String {
        guard lyricsEnabled else { return "" }
        let selected = [appearance.showsOriginal ? snapshot.currentLineText : nil,
                        appearance.showsTranslation ? snapshot.currentTranslationText : nil,
                        appearance.showsKana ? snapshot.currentKanaText : nil,
                        appearance.showsRomaji ? snapshot.currentRomajiText : nil]
        var parts: [String] = []
        for value in selected.compactMap({ $0 }) {
            let singleLine = value.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !singleLine.isEmpty && !parts.contains(singleLine) { parts.append(singleLine) }
        }
        let fallbackTitle = snapshot.trackTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = !parts.isEmpty ? "♪ " + parts.joined(separator: " · ")
            : (!fallbackTitle.isEmpty ? "♪ " + fallbackTitle : snapshot.statusText)
        return appearance.showsFullLine ? text : truncateToFit(
            text, font: .systemFont(ofSize: appearance.effectiveFontSize)
        )
    }

    /// Menu-bar height is fixed by macOS. Draw the existing token readings
    /// above their surfaces in one template image, preserving native tint/clicks.
    @MainActor public static func readingImage(snapshot: MenuBarLyricsSnapshot,
                                              appearance: MenuBarLyricsAppearance) -> NSImage? {
        guard appearance.readingsAbove, appearance.showsOriginal,
              appearance.showsKana || appearance.showsRomaji,
              let original = snapshot.currentLineText, !original.isEmpty else { return nil }
        let baseFont = NSFont.systemFont(ofSize: min(14, appearance.effectiveFontSize))
        let readingFont = NSFont.systemFont(ofSize: 7)
        let baseAttributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.black]
        let rubyAttributes: [NSAttributedString.Key: Any] = [.font: readingFont, .foregroundColor: NSColor.black]
        func annotation(kana: String?, romaji: String?) -> String {
            [appearance.showsKana ? kana : nil, appearance.showsRomaji ? romaji : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var pairs: [(String, String)] = []
        if let tokens = snapshot.currentRubyTokens, !tokens.isEmpty,
           tokens.map(\.surface).joined() == original {
            pairs = tokens.map { ($0.surface, annotation(kana: $0.ruby, romaji: $0.romaji)) }
        }
        if pairs.isEmpty || pairs.allSatisfy({ $0.1.isEmpty }) {
            pairs = [(original, annotation(kana: snapshot.currentKanaText, romaji: snapshot.currentRomajiText))]
        }
        guard pairs.contains(where: { !$0.1.isEmpty }) else { return nil }
        if appearance.showsTranslation, let translated = snapshot.currentTranslationText, !translated.isEmpty {
            pairs.append((" · " + translated, ""))
        }
        let widths = pairs.map { max(($0.0 as NSString).size(withAttributes: baseAttributes).width,
                                      ($0.1 as NSString).size(withAttributes: rubyAttributes).width) + 1 }
        let naturalWidth = widths.reduce(0, +) + 20
        let width = appearance.showsFullLine ? naturalWidth : min(maxVisualWidth, naturalWidth)
        let truncated = width < naturalWidth
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: truncated ? max(0, rect.width - 12) : rect.width, height: rect.height)).addClip()
            if let symbol = NSImage(systemSymbolName: statusItemSymbol(snapshot: snapshot), accessibilityDescription: nil) {
                symbol.draw(in: NSRect(x: 1, y: 5, width: 12, height: 12))
            }
            var x: CGFloat = 18
            for (index, pair) in pairs.enumerated() {
                let surfaceWidth = (pair.0 as NSString).size(withAttributes: baseAttributes).width
                let readingWidth = (pair.1 as NSString).size(withAttributes: rubyAttributes).width
                (pair.0 as NSString).draw(at: NSPoint(x: x + (widths[index] - surfaceWidth) / 2, y: 0), withAttributes: baseAttributes)
                (pair.1 as NSString).draw(at: NSPoint(x: x + (widths[index] - readingWidth) / 2, y: 14), withAttributes: rubyAttributes)
                x += widths[index]
                if x >= rect.width { break }
            }
            NSGraphicsContext.restoreGraphicsState()
            if truncated { ("…" as NSString).draw(at: NSPoint(x: rect.width - 12, y: 0), withAttributes: baseAttributes) }
            return true
        }
        image.isTemplate = true
        return image
    }

    public static func statusItemSymbol(snapshot: MenuBarLyricsSnapshot) -> String {
        snapshot.hasLiveTrack && !snapshot.isPlaying ? "pause.fill" : "music.note"
    }

    public static func statusItemHelp(snapshot: MenuBarLyricsSnapshot) -> String {
        let parts = [snapshot.trackTitle, snapshot.artistName,
                     snapshot.currentLineText, snapshot.currentTranslationText,
                     snapshot.currentKanaText, snapshot.currentRomajiText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (parts.isEmpty ? ["Lyric Island"] : parts).joined(separator: "\n")
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

/// Status-item controls must receive the first click even while the app is inactive.
@MainActor
final class MenuBarPopoverHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class MenuBarPopoverHostingController<Content: View>: NSHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        view = MenuBarPopoverHostingView(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    override func viewDidAppear() {
        super.viewDidAppear()
        clearOpeningFocus()
    }

    /// Avoid selecting the first action just by opening the popover. Tab can
    /// still move keyboard focus to the controls in their normal order.
    func clearOpeningFocus() {
        view.window?.makeFirstResponder(nil)
    }
}

@MainActor
public final class MenuBarLyricsController: NSObject, ObservableObject {
    public static let shared = MenuBarLyricsController(settings: .shared)

    @Published public private(set) var currentSnapshot: MenuBarLyricsSnapshot
    @Published public private(set) var fullLyricsSnapshot: MenuBarFullLyricsSnapshot?

    @Published public private(set) var statusItemTitle = ""
    public var menuBarLyricsEnabled: Bool {
        get { settings.menuBarLyricsEnabled }
        set { settings.menuBarLyricsEnabled = newValue }
    }

    let settings: AppSettingsStore
    private var settingsSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
    private var appearance = MenuBarLyricsAppearance()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var applicationBeforePopover: NSRunningApplication?
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
        appearanceSubscription = Publishers.CombineLatest4(
            settings.$menuBarLyricsShowsFullLine, settings.$menuBarLyricsShowsOriginal,
            settings.$menuBarLyricsShowsTranslation, settings.$menuBarLyricsShowsKana
        )
        .combineLatest(settings.$menuBarLyricsShowsRomaji, settings.$menuBarLyricsFontSize, settings.$menuBarLyricsReadingsAbove)
        .sink { [weak self] values in
            guard let self else { return }
            let (flags, romaji, fontSize, readingsAbove) = values
            self.appearance = MenuBarLyricsAppearance(
                showsFullLine: flags.0, showsOriginal: flags.1,
                showsTranslation: flags.2, showsKana: flags.3,
                showsRomaji: romaji, fontSize: fontSize, readingsAbove: readingsAbove
            )
            self.updateStatusItemButton(lyricsEnabled: self.settings.menuBarLyricsEnabled)
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

    /// Explicitly return to the live song before opening its lyrics. Merely
    /// opening the menu never changes a search preview or adopts a candidate.
    public func openCurrentLyrics() {
        if let playbackState, playbackState.hasLiveTrack, !playbackState.isMockPreviewMode {
            playbackState.clearSearchPreview()
        }
        openMainWindow()
    }

    public func showFullLyrics() {
        guard let playbackState else { return }
        fullLyricsSnapshot = Self.deriveFullLyricsSnapshot(from: playbackState)
    }

    public func closeFullLyrics() {
        fullLyricsSnapshot = nil
    }

    public func toggleFloatingLyrics() {
        guard let playbackState else { return }
        popover?.performClose(nil)
        WindowManager.shared.toggleFloatingLyrics(state: playbackState)
        restoreApplicationAfterAuxiliaryAction()
    }

    public func toggleCapsule() {
        guard let playbackState else { return }
        popover?.performClose(nil)
        WindowManager.shared.toggleCapsule(state: playbackState)
        restoreApplicationAfterAuxiliaryAction()
    }

    /// Closing a key popover must return to the prior app, rather than let
    /// AppKit promote this app's previously key main window with desktop lyrics.
    private func restoreApplicationAfterAuxiliaryAction() {
        let previous = applicationBeforePopover
        applicationBeforePopover = nil
        guard let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !previous.isTerminated else { return }
        DispatchQueue.main.async {
            _ = previous.activate(options: [])
        }
    }

    public func restoreFloatingInteraction() {
        guard let playbackState else { return }
        WindowManager.shared.restoreFloatingInteractiveMode(state: playbackState)
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
        pop.contentViewController = MenuBarPopoverHostingController(
            rootView: MenuBarLyricsPopoverView(controller: self)
        )
        self.popover = pop
    }

    /// The same popover is reachable by keyboard and from the status item.
    public func togglePopover() { statusItemClicked(nil) }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            fullLyricsSnapshot = nil
            let frontmost = NSWorkspace.shared.frontmostApplication
            applicationBeforePopover = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Native checkbox, slider and segmented controls need a key host.
            // Auxiliary actions restore the app that was active before opening.
            popover.contentViewController?.view.window?.makeKey()
            _ = NSRunningApplication.current.activate(options: [])
            (popover.contentViewController as? MenuBarPopoverHostingController<MenuBarLyricsPopoverView>)?.clearOpeningFocus()
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
            snapshot: currentSnapshot, lyricsEnabled: lyricsEnabled, appearance: appearance
        )
        guard let button = statusItem?.button else { return }
        button.title = statusItemTitle
        button.font = .systemFont(ofSize: appearance.effectiveFontSize)
        button.imagePosition = lyricsEnabled ? .imageLeft : .imageOnly
        button.image = NSImage(
            systemSymbolName: MenuBarTextFormatter.statusItemSymbol(snapshot: currentSnapshot),
            accessibilityDescription: "Lyric Island"
        )
        if lyricsEnabled, let rubyImage = MenuBarTextFormatter.readingImage(snapshot: currentSnapshot, appearance: appearance) {
            button.title = ""
            button.image = rubyImage
            button.imagePosition = .imageOnly
        }
        let help = MenuBarTextFormatter.statusItemHelp(snapshot: currentSnapshot)
        button.toolTip = help
        button.setAccessibilityLabel("Lyric Island，歌词与播放")
        button.setAccessibilityValue(help)
    }

    public static func deriveFullLyricsSnapshot(from state: PlaybackState) -> MenuBarFullLyricsSnapshot? {
        guard state.hasLiveTrack, !state.isMockPreviewMode,
              state.liveLyricsDocumentMatchesCurrentTrack else { return nil }
        let paragraphs = state.liveLyrics.compactMap { line -> String? in
            let original = line.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = line.translationText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = [original, translation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        guard !paragraphs.isEmpty else { return nil }
        return MenuBarFullLyricsSnapshot(
            trackTitle: state.currentTrack.title,
            artistName: state.currentTrack.artist,
            lyricsText: paragraphs.joined(separator: "\n\n")
        )
    }

    public static func deriveSnapshot(from state: PlaybackState) -> MenuBarLyricsSnapshot {
        var snapshot = deriveLyricsSnapshot(from: state)
        snapshot.canControlPlayback = state.canControlSpotify
        return snapshot
    }

    private static func deriveLyricsSnapshot(from state: PlaybackState) -> MenuBarLyricsSnapshot {
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

        case .noSelection:
            return emptyLyricsSnapshot(state: .noSelection(title: title), title: title,
                                       artist: artist, isPlaying: isPlaying, artworkURL: artworkURL)

        case .candidates(_, let candidates):
            let candidateState: MenuBarLyricsState = candidates.isEmpty
                ? .noLyrics(title: title) : .candidates(title: title, count: candidates.count)
            return emptyLyricsSnapshot(state: candidateState, title: title,
                                       artist: artist, isPlaying: isPlaying, artworkURL: artworkURL)

        case .noLyrics, .noMatch:
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
                let translated = lines[currentIndex].translationText?.trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.currentTranslationText = translated?.isEmpty == true ? nil : translated
                snapshot.currentRubyTokens = lines[currentIndex].rubyTokens
                snapshot.currentKanaText = lines[currentIndex].kanaText
                snapshot.currentRomajiText = lines[currentIndex].romajiText
                return snapshot
            } else if !isSync {
                let displayTitle = title.isEmpty ? "Lyric Island" : title
                let firstLine = lines.first { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                var snapshot = MenuBarLyricsSnapshot(
                    state: .unsynchronized(title: displayTitle),
                    statusText: "♪ \(displayTitle)",
                    trackTitle: displayTitle,
                    artistName: artist,
                    currentLineText: firstLine?.originalText.trimmingCharacters(in: .whitespacesAndNewlines),
                    nextLineText: nil,
                    isPlaying: isPlaying,
                    hasLiveTrack: true,
                    artworkURL: artworkURL
                )
                let translation = firstLine?.translationText?.trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.currentTranslationText = translation?.isEmpty == true ? nil : translation
                snapshot.currentRubyTokens = firstLine?.rubyTokens
                snapshot.currentKanaText = firstLine?.kanaText
                snapshot.currentRomajiText = firstLine?.romajiText
                return snapshot
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

        case .idle, .mockPreview:
            let displayTitle = title.isEmpty ? "Lyric Island" : title
            return MenuBarLyricsSnapshot(
                state: .notSearched(title: displayTitle),
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

    private static func emptyLyricsSnapshot(state: MenuBarLyricsState, title: String,
                                            artist: String, isPlaying: Bool, artworkURL: URL?) -> MenuBarLyricsSnapshot {
        let displayTitle = title.isEmpty ? "Lyric Island" : title
        return MenuBarLyricsSnapshot(
            state: state, statusText: "♪ \(displayTitle)", trackTitle: displayTitle,
            artistName: artist, currentLineText: nil, nextLineText: nil,
            isPlaying: isPlaying, hasLiveTrack: true, artworkURL: artworkURL
        )
    }
}
