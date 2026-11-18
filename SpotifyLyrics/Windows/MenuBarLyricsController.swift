import AppKit
import QuartzCore
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
    var currentVoiceLabel: String? = nil
    var nextVoiceLabel: String? = nil
    /// Playback controls follow the current provider capability, not just retained metadata.
    public var canControlPlayback: Bool = false
    /// The line before the current one and the current line's index, so the
    /// popover can scroll its three lines instead of swapping text.
    public var previousLineText: String? = nil
    public var currentLineIndex: Int? = nil
    var trackKey: String? = nil
    var lyricsVersionID: UUID? = nil
    var translationVersionID: UUID? = nil
    var lineLoop: PlaybackState.LyricLineLoopControl? = nil

    var keptLine: V3FavoriteLines.Entry? {
        guard let trackKey, let currentLineText, !currentLineText.isEmpty else { return nil }
        return .init(text: currentLineText, translation: currentTranslationText, title: trackTitle ?? "",
                     artist: artistName ?? "", trackKey: trackKey, artworkURL: artworkURL,
                     lyricsVersionID: lyricsVersionID, lineIndex: currentLineIndex, translationVersionID: translationVersionID)
    }
}

/// Captured on the explicit read action, so selecting/copying text is stable
/// while playback advances. This never changes the main window's preview.
public struct MenuBarFullLyricsSnapshot: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let text: LibraryPassagePage.Line
        let voiceLabel: String?
        var id: Int { text.id }
    }

    public let trackTitle: String
    public let artistName: String
    let rows: [Row]
    let focusedLine: Int?
    let showsReading: Bool
    let passage: LibraryPassageTarget?

    init?(track: Track, lines: [LyricLine], currentIndex: Int?, synchronized: Bool,
          showsReading: Bool = false, passage: LibraryPassageTarget? = nil) {
        let voices = LyricsTimeline.VoicePresentation(in: lines, isSynchronized: synchronized)
        let rows = lines.enumerated().compactMap { index, line -> Row? in
            guard voices.duplicates[index] == nil else { return nil }
            func nonempty(_ text: String?) -> String? {
                let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return text?.isEmpty == false ? text : nil
            }
            let original = nonempty(line.originalText) ?? ""
            let translation = nonempty(line.translationText)
            let background = nonempty(line.backgroundText)
            guard !original.isEmpty || translation != nil || background != nil else { return nil }
            let readings = [nonempty(line.kanaText), nonempty(line.romajiText)].compactMap { $0 }
            return Row(text: .init(id: index, original: original, translation: translation,
                                   reading: readings.isEmpty ? nil : readings.joined(separator: " · "), background: background),
                       voiceLabel: voices.labelAtChange(index))
        }
        guard !rows.isEmpty else { return nil }
        let index = currentIndex.map { voices.duplicates[$0] ?? $0 }
        let focusedLine = index.flatMap { index in rows.contains { $0.id == index } ? index : nil }
        var destination = passage
        destination?.readingPosition = .init(find: "", lineIndex: focusedLine)
        self.trackTitle = track.title
        self.artistName = track.artist
        self.rows = rows
        self.focusedLine = focusedLine
        self.showsReading = showsReading
        self.passage = destination
    }

    public var lyricsText: String {
        rows.map { row in
            [row.text.original, row.text.translation, row.text.background.map { "（\($0)）" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

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
    public var widthMode: String
    public var width: Double
    public var overflow: String
    public var contentWidth: CGFloat { CGFloat(min(480, max(120, width.isFinite ? width : 240))) - 16 }

    public init(showsFullLine: Bool = false, showsOriginal: Bool = true,
                showsTranslation: Bool = false, showsKana: Bool = false,
                showsRomaji: Bool = false, fontSize: Double = 13, readingsAbove: Bool = true,
                widthMode: String = "adaptive", width: Double = 240, overflow: String = "scroll") {
        self.showsFullLine = showsFullLine
        self.showsOriginal = showsOriginal
        self.showsTranslation = showsTranslation
        self.showsKana = showsKana
        self.showsRomaji = showsRomaji
        self.fontSize = fontSize
        self.readingsAbove = readingsAbove
        self.widthMode = widthMode; self.width = width; self.overflow = overflow
    }

    public var effectiveFontSize: CGFloat {
        CGFloat(fontSize.isFinite ? min(18, max(10, fontSize)) : 13)
    }
}

public enum MenuBarTextFormatter {
    private static func flattenNewlines(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
    }

    public static func statusItemTitle(snapshot: MenuBarLyricsSnapshot, lyricsEnabled: Bool,
                                       appearance: MenuBarLyricsAppearance = .init()) -> String {
        guard lyricsEnabled else { return "" }
        let selected = [appearance.showsOriginal ? snapshot.currentLineText : nil,
                        appearance.showsTranslation ? snapshot.currentTranslationText : nil,
                        appearance.showsKana ? snapshot.currentKanaText : nil,
                        appearance.showsRomaji ? snapshot.currentRomajiText : nil]
        var parts: [String] = []
        for value in selected.compactMap({ $0 }) {
            let singleLine = flattenNewlines(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !singleLine.isEmpty && !parts.contains(singleLine) { parts.append(singleLine) }
        }
        let fallbackTitle = snapshot.trackTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = !parts.isEmpty ? "♪ " + parts.joined(separator: " · ")
            : (!fallbackTitle.isEmpty ? "♪ " + fallbackTitle : snapshot.statusText)
        return appearance.showsFullLine ? text : truncateToFit(
            text, maxWidth: appearance.contentWidth, font: .systemFont(ofSize: appearance.effectiveFontSize)
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
                .compactMap { $0.map(flattenNewlines) }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var pairs: [(String, String)] = []
        if let tokens = snapshot.currentRubyTokens, !tokens.isEmpty,
           tokens.map(\.surface).joined() == original {
            pairs = tokens.map { (flattenNewlines($0.surface), annotation(kana: $0.ruby, romaji: $0.romaji)) }
        }
        if pairs.isEmpty || pairs.allSatisfy({ $0.1.isEmpty }) {
            pairs = [(flattenNewlines(original), annotation(kana: snapshot.currentKanaText, romaji: snapshot.currentRomajiText))]
        }
        guard pairs.contains(where: { !$0.1.isEmpty }) else { return nil }
        if appearance.showsTranslation, let translated = snapshot.currentTranslationText, !translated.isEmpty {
            pairs.append((" · " + flattenNewlines(translated), ""))
        }
        let widths = pairs.map { max(($0.0 as NSString).size(withAttributes: baseAttributes).width,
                                      ($0.1 as NSString).size(withAttributes: rubyAttributes).width) + 1 }
        let naturalWidth = widths.reduce(0, +) + 20
        let width = appearance.showsFullLine ? min(4096, naturalWidth) : min(appearance.contentWidth, naturalWidth)
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

    /// One native menu-bar item showing the original and its selected translation.
    /// Each row has its own width budget, including when overflow uses a marquee.
    @MainActor static func bilingualImage(snapshot: MenuBarLyricsSnapshot,
                                          appearance: MenuBarLyricsAppearance) -> NSImage? {
        guard appearance.showsOriginal, appearance.showsTranslation,
              let original = snapshot.currentLineText.map(flattenNewlines),
              let translation = snapshot.currentTranslationText.map(flattenNewlines),
              !original.isEmpty, !translation.isEmpty, original != translation else { return nil }
        let readings = [appearance.showsKana ? snapshot.currentKanaText : nil,
                        appearance.showsRomaji ? snapshot.currentRomajiText : nil]
            .compactMap { $0.map(flattenNewlines) }.filter { !$0.isEmpty }
        let primaryFont = NSFont.systemFont(ofSize: min(11, appearance.effectiveFontSize), weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: min(9, appearance.effectiveFontSize * 0.75))
        let label = ([translation] + readings).joined(separator: " · ")
        let budget = appearance.showsFullLine ? 4096 : appearance.contentWidth
        let rows = [(original, primaryFont), (label, detailFont)].map { text, font in
            NSAttributedString(string: truncateToFit(text, maxWidth: budget, font: font),
                               attributes: [.font: font, .foregroundColor: NSColor.black])
        }
        let width = min(budget, max(1, ceil(max(rows[0].size().width, rows[1].size().width))))
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
            rows[0].draw(at: NSPoint(x: 0, y: rect.height - rows[0].size().height + 1))
            rows[1].draw(at: NSPoint(x: 0, y: -1))
            return true
        }
        image.isTemplate = true
        return image
    }

    @MainActor static func statusImage(snapshot: MenuBarLyricsSnapshot, appearance: MenuBarLyricsAppearance) -> NSImage {
        if let ruby = readingImage(snapshot: snapshot, appearance: appearance) { return ruby }
        if let pair = bilingualImage(snapshot: snapshot, appearance: appearance) { return pair }

        let font = NSFont.systemFont(ofSize: appearance.effectiveFontSize)
        let title = statusItemTitle(snapshot: snapshot, lyricsEnabled: true, appearance: appearance)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = NSSize(width: max(1, min(4096, ceil(text.size().width))), height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    public static func statusItemSymbol(snapshot: MenuBarLyricsSnapshot) -> String {
        snapshot.hasLiveTrack && !snapshot.isPlaying ? "pause.fill" : "music.note"
    }

    static func marqueeAnimation(distance: CGFloat, remaining: TimeInterval?) -> CAKeyframeAnimation {
        let normalTravel = max(2, Double(distance) / 22)
        let window = remaining.map { max(0.1, $0) }
        let lead = window.map { min(1.4, $0 * 0.15) } ?? 1.4
        let hold = window.map { min(1.4, $0 * 0.25) } ?? 1.4
        let travel = min(normalTravel, window.map { $0 - lead - hold } ?? normalTravel)
        let duration = lead + travel * 2 + hold
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let end = NSNumber(value: -Double(distance))
        animation.values = [0, 0, end, end, 0]
        animation.keyTimes = [0, NSNumber(value: lead / duration),
            NSNumber(value: (lead + travel) / duration), NSNumber(value: (lead + travel + hold) / duration), 1]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        return animation
    }

    public static func statusItemHelp(snapshot: MenuBarLyricsSnapshot) -> String {
        let parts = [snapshot.trackTitle, snapshot.artistName, snapshot.currentVoiceLabel.map { "演唱：\($0)" },
                     snapshot.currentLineText, snapshot.currentTranslationText,
                     snapshot.currentKanaText, snapshot.currentRomajiText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (parts.isEmpty ? ["Aster · Lyric"] : parts).joined(separator: "\n")
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
final class MenuBarPopoverHostingController<Content: View>: NSViewController {
    init(rootView: Content) {
        super.init(nibName: nil, bundle: nil)
        let host = MenuBarPopoverHostingView(rootView: rootView)
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = [.intrinsicContentSize]
        view = host
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

    @Published public private(set) var presentationGeneration: UInt64 = 0
    @Published public private(set) var statusItemTitle = ""
    public var menuBarLyricsEnabled: Bool {
        get { settings.menuBarLyricsEnabled }
        set { settings.menuBarLyricsEnabled = newValue }
    }

    let settings: AppSettingsStore
    private var settingsSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
    private var widthSubscription: AnyCancellable?
    private var accessibilitySubscription: AnyCancellable?
    private var marqueeView: LyricIslandStatusTextView?
    private var lastStatusImageKey: String?
    private var lastStatusImage: NSImage?
    private var appearance = MenuBarLyricsAppearance()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    var isLyricsPopoverShown: Bool { popover?.isShown == true }
    private var applicationBeforePopover: NSRunningApplication?
    private weak var playbackState: PlaybackState?
    /// Read by the popover's progress rail on its own timeline, never observed.
    var livePlaybackState: PlaybackState? { playbackState }
    private var cancellables = Set<AnyCancellable>()
    private var openMainWindowHandler: (@MainActor () -> Void)?
    private var openLibraryHandler: (@MainActor () -> Void)?
    private var openSettingsHandler: (@MainActor () -> Void)?
    private var openEditorHandler: (@MainActor () -> Void)?

    public init(settings: AppSettingsStore) {
        self.settings = settings
        self.currentSnapshot = MenuBarLyricsSnapshot(
            state: .idle,
            statusText: "Aster · Lyric",
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
                showsRomaji: romaji, fontSize: fontSize, readingsAbove: readingsAbove,
                widthMode: self.appearance.widthMode, width: self.appearance.width,
                overflow: self.appearance.overflow
            )
            self.updateStatusItemButton(lyricsEnabled: self.settings.menuBarLyricsEnabled)
        }
        widthSubscription = Publishers.CombineLatest3(settings.$menuBarWidthMode,
            settings.$menuBarWidth, settings.$menuBarOverflow)
            .sink { [weak self] mode, width, overflow in
                guard let self else { return }
                self.appearance.widthMode = mode
                self.appearance.width = width
                self.appearance.overflow = overflow
                self.updateStatusItemButton(lyricsEnabled: self.settings.menuBarLyricsEnabled)
            }
        accessibilitySubscription = NotificationCenter.default.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItemButton(lyricsEnabled: self.settings.menuBarLyricsEnabled)
            }
    }

    public func bind(playbackState: PlaybackState) {
        self.playbackState = playbackState
        cancellables.removeAll()

        setupStatusItemIfNeeded()
        setupPopoverIfNeeded()

        playbackState.objectWillChange
            .filter { [weak playbackState] _ in playbackState?.isPublishingPlaybackClockTick != true }
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
            if window.identifier?.rawValue == "main-window" || window.title == "Aster · Lyric" || window.title == "Lyric Island" {
                if !window.isKind(of: NSPanel.self) {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
    }

    func openWorkspace() {
        MainWindowWorkspaceMode.shared.show(.workbench)
        openMainWindow()
    }

    func openLyricsWindow() {
        let hasContext = playbackState.map { $0.hasLiveTrack || $0.isShowingSearchPreview || $0.isUsingMockPreview } ?? false
        MainWindowWorkspaceMode.shared.show(hasContext ? .followsPlayback : .lyrics)
        openMainWindow()
    }

    /// Explicitly return to the live song before opening its lyrics. Merely
    /// opening the menu never changes a search preview or adopts a candidate.
    public func openCurrentLyrics() {
        if let playbackState, playbackState.hasLiveTrack, !playbackState.isMockPreviewMode {
            playbackState.clearSearchPreview()
        }
        openLyricsWindow()
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

    func openQuickFind() {
        popover?.performClose(nil)
        QuickFindLauncher.shared.show()
    }

    func openSettings(at location: SettingsLocation) {
        SettingsNavigationRoute.shared.requestedLocation = location
        openSettings()
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
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Aster · Lyric")
            button.title = settings.menuBarLyricsEnabled ? "Aster · Lyric" : ""
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
            presentationGeneration &+= 1
            popover.performClose(sender)
        } else {
            fullLyricsSnapshot = nil
            presentationGeneration &+= 1
            let generation = presentationGeneration
            let frontmost = NSWorkspace.shared.frontmostApplication
            applicationBeforePopover = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
            // Activation after show can dismiss a transient popover immediately.
            // Do not bring all of the app's windows forward with the menu.
            if !NSApp.isActive {
                _ = NSRunningApplication.current.activate(options: [])
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presentationGeneration == generation,
                      !popover.isShown, button.window != nil,
                      self.updatePopoverContentSize() else { return }
                // Leave the opening mouse-up/activation turn before presenting.
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
                (popover.contentViewController as? MenuBarPopoverHostingController<MenuBarLyricsPopoverView>)?.clearOpeningFocus()
            }
        }
    }

    /// Disclosure/full-song navigation changes the visible host's intrinsic
    /// height. Resize only for those events, never on playback ticks.
    func resizePopoverToContent() {
        DispatchQueue.main.async { [weak self] in
            _ = self?.updatePopoverContentSize()
        }
    }

    /// The first presentation must have a measured frame before AppKit shows it.
    @discardableResult
    private func updatePopoverContentSize() -> Bool {
        guard let popover, let view = popover.contentViewController?.view else { return false }
        view.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return false }
        if popover.contentSize != size { popover.contentSize = size }
        if view.frame.size != size { view.frame.size = size }
        return true
    }

    private func handlePlaybackStateChange() {
        guard let playbackState else { return }
        let newSnapshot = Self.deriveSnapshot(from: playbackState)

        guard newSnapshot != currentSnapshot else { return }

        currentSnapshot = newSnapshot
        updateStatusItemButton(lyricsEnabled: settings.menuBarLyricsEnabled)
    }

    private func updateStatusItemButton(lyricsEnabled: Bool) {
        var complete = appearance
        complete.showsFullLine = true
        let fullTitle = MenuBarTextFormatter.statusItemTitle(
            snapshot: currentSnapshot, lyricsEnabled: lyricsEnabled, appearance: complete)
        if statusItemTitle != fullTitle { statusItemTitle = fullTitle }
        guard let button = statusItem?.button else { return }
        let help = MenuBarTextFormatter.statusItemHelp(snapshot: currentSnapshot)
        button.toolTip = help
        button.setAccessibilityLabel("Aster · Lyric，歌词与播放")
        button.setAccessibilityValue(help)
        guard lyricsEnabled else {
            marqueeView?.removeFromSuperview(); marqueeView = nil
            lastStatusImage = nil; lastStatusImageKey = nil
            statusItem?.length = NSStatusItem.squareLength
            button.title = ""; button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: MenuBarTextFormatter.statusItemSymbol(snapshot: currentSnapshot),
                                   accessibilityDescription: "Aster · Lyric")
            return
        }
        let shouldScroll = appearance.overflow == "scroll" && currentSnapshot.isPlaying
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var renderAppearance = appearance
        renderAppearance.showsFullLine = shouldScroll
        // The key changes on lyric/appearance changes, not on playback time.
        let tokenKey = currentSnapshot.currentRubyTokens?.map { "\($0.surface):\($0.ruby ?? ""): \($0.romaji ?? "")" }.joined(separator: "|") ?? ""
        let key = [fullTitle, tokenKey, MenuBarTextFormatter.statusItemSymbol(snapshot: currentSnapshot), String(appearance.fontSize), String(appearance.showsKana),
                   String(appearance.showsRomaji), String(appearance.readingsAbove),
                   String(appearance.showsTranslation), String(appearance.showsOriginal), String(appearance.width), String(shouldScroll)].joined(separator: "\u{1F}")
        let image: NSImage
        if key == lastStatusImageKey, let cached = lastStatusImage { image = cached }
        else {
            image = MenuBarTextFormatter.statusImage(snapshot: currentSnapshot, appearance: renderAppearance)
            lastStatusImageKey = key; lastStatusImage = image
        }
        let requested = CGFloat(appearance.width.isFinite ? min(480, max(120, appearance.width)) : 240)
        let length = appearance.widthMode == "fixed" ? requested : min(requested, max(44, image.size.width + 16))
        if statusItem?.length != length { statusItem?.length = length }
        button.title = ""; button.image = nil; button.imagePosition = .noImage
        let view: LyricIslandStatusTextView
        if let current = marqueeView { view = current }
        else {
            view = LyricIslandStatusTextView(frame: .zero)
            button.addSubview(view)
            marqueeView = view
        }
        let frame = NSRect(x: 8, y: max(0, (button.bounds.height - 22) / 2), width: max(1, length - 16), height: 22)
        let lineKey = [key, currentSnapshot.trackKey ?? "", currentSnapshot.currentLineIndex.map(String.init) ?? ""].joined(separator: "\u{1F}")
        let remaining = shouldScroll && image.size.width > frame.width ? remainingLineTime() : nil
        view.configure(image: image, key: lineKey, frame: frame, animate: shouldScroll, remaining: remaining)
    }

    private func remainingLineTime() -> TimeInterval? {
        guard let state = playbackState, let index = currentSnapshot.currentLineIndex else { return nil }
        let clock = state.presentationClock
        let now = ProcessInfo.processInfo.systemUptime
        if let boundary = LyricsTimeline.nextBoundaryTime(lines: state.liveLyrics, currentIndex: index,
                                                          isSynchronized: state.liveLyricsAreSynchronized) {
            return max(0.1, boundary - clock.presentationTime(at: now) - PlaybackState.lineSwitchLead)
        }
        return clock.trackDuration > 0 ? max(0.1, clock.trackDuration - clock.playbackTime(at: now)) : nil
    }

    public static func deriveFullLyricsSnapshot(from state: PlaybackState) -> MenuBarFullLyricsSnapshot? {
        guard state.hasLiveTrack, !state.isMockPreviewMode,
              state.liveLyricsDocumentMatchesCurrentTrack else { return nil }
        var passage: LibraryPassageTarget?
        if let trackKey = state.liveTrackIdentity?.stableKey, let originalID = state.liveLyricsVersionID {
            let source: LibraryPassageSource
            if let translation = state.selectedTranslation, translation.isComplete,
               translation.record.lyricsVersionID == originalID,
               translation.record.sourceContentHash == state.lyricsSession.activeSourceContentHash {
                source = .translation(translation.record.id)
            } else {
                source = .original(originalID)
            }
            passage = LibraryPassageTarget(trackKey: trackKey, source: source)
        }
        let preferences = state.preferences
        return MenuBarFullLyricsSnapshot(
            track: state.currentTrack, lines: state.liveLyrics, currentIndex: state.liveCurrentLineIndex,
            synchronized: state.liveLyricsAreSynchronized,
            showsReading: preferences.showKana || preferences.showsRomajiLayer || preferences.showsPinyinLayer,
            passage: passage
        )
    }

    public static func deriveSnapshot(from state: PlaybackState) -> MenuBarLyricsSnapshot {
        var snapshot = deriveLyricsSnapshot(from: state)
        snapshot.canControlPlayback = state.canControlSpotify
        snapshot.trackKey = state.currentTrackIdentity?.stableKey
        snapshot.lyricsVersionID = state.liveLyricsVersionID
        snapshot.translationVersionID = state.selectedTranslation?.quoteVersionID(
            originalID: snapshot.lyricsVersionID, lineIndex: snapshot.currentLineIndex, text: snapshot.currentTranslationText)
        let lines = state.liveLyrics
        let lineID = snapshot.currentLineIndex.flatMap { lines.indices.contains($0) ? lines[$0].id : nil }
        snapshot.lineLoop = state.lyricLineLoopControl(for: lineID)
        return snapshot
    }

    private static func deriveLyricsSnapshot(from state: PlaybackState) -> MenuBarLyricsSnapshot {
        guard state.hasLiveTrack, !state.isMockPreviewMode else {
            return MenuBarLyricsSnapshot(
                state: .idle,
                statusText: "Aster · Lyric",
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
            let displayTitle = title.isEmpty ? "Aster · Lyric" : title
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
            let displayTitle = title.isEmpty ? "Aster · Lyric" : title
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
            let displayTitle = title.isEmpty ? "Aster · Lyric" : title
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
            let displayTitle = title.isEmpty ? "Aster · Lyric" : title
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

            let projection = isSync ? LyricsTimeline.presentedLyrics(in: lines, currentIndex: state.liveCurrentLineIndex, before: 1) : nil
            if let projection, let currentIndex = projection.current {
                let currentLine = lines[currentIndex].originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                let nextIndex = projection.visible.first { $0 > currentIndex }
                let nextLine = nextIndex.map { lines[$0].originalText.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                snapshot.currentLineIndex = currentIndex
                snapshot.currentVoiceLabel = projection.voices.label(at: currentIndex)
                snapshot.nextVoiceLabel = projection.voices.label(at: nextIndex)
                if let previousIndex = projection.visible.first(where: { $0 < currentIndex }) {
                    let previous = lines[previousIndex].originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    snapshot.previousLineText = previous.isEmpty ? nil : previous
                }
                return snapshot
            } else if !isSync {
                let displayTitle = title.isEmpty ? "Aster · Lyric" : title
                let firstIndex = lines.firstIndex { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let firstLine = firstIndex.map { lines[$0] }
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
                snapshot.currentLineIndex = firstIndex
                snapshot.currentTranslationText = translation?.isEmpty == true ? nil : translation
                snapshot.currentRubyTokens = firstLine?.rubyTokens
                snapshot.currentKanaText = firstLine?.kanaText
                snapshot.currentRomajiText = firstLine?.romajiText
                return snapshot
            } else {
                let displayTitle = title.isEmpty ? "Aster · Lyric" : title
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
            let displayTitle = title.isEmpty ? "Aster · Lyric" : title
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
        let displayTitle = title.isEmpty ? "Aster · Lyric" : title
        return MenuBarLyricsSnapshot(
            state: state, statusText: "♪ \(displayTitle)", trackTitle: displayTitle,
            artistName: artist, currentLineText: nil, nextLineText: nil,
            isPlaying: isPlaying, hasLiveTrack: true, artworkURL: artworkURL
        )
    }
}

/// Clip one cached template image. Core Animation moves the layer without
/// publishing SwiftUI state or measuring text for every animation frame.
@MainActor
private final class LyricIslandStatusTextView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private var contentKey = ""
    private var requestedAnimation = false
    private var lineDeadline: CFTimeInterval?
    private var observers: [NSObjectProtocol] = []
    private var animationDistance: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignLeft
        imageView.contentTintColor = .labelColor
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    func configure(image: NSImage, key: String, frame: NSRect, animate: Bool, remaining: TimeInterval?) {
        let contentChanged = contentKey != key || self.frame.size != frame.size
        if self.frame != frame { self.frame = frame }
        if contentChanged {
            contentKey = key
            imageView.layer?.removeAnimation(forKey: "lyric.marquee")
            imageView.layer?.transform = CATransform3DIdentity
            imageView.image = image
            imageView.frame = NSRect(x: 0, y: 0, width: image.size.width, height: 22)
            animationDistance = max(0, image.size.width - frame.width)
        }
        requestedAnimation = animate
        lineDeadline = remaining.map { CACurrentMediaTime() + $0 }
        refreshAnimation()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        guard let window else {
            imageView.layer?.removeAnimation(forKey: "lyric.marquee"); return
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                self?.refreshAnimation()
            })
        refreshAnimation()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        imageView.contentTintColor = .labelColor
        imageView.needsDisplay = true
    }
    private func refreshAnimation() {
        guard let layer = imageView.layer else { return }
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let active = requestedAnimation && visible && animationDistance > 1
        if !active {
            if layer.animation(forKey: "lyric.marquee") != nil, let presented = layer.presentation() {
                layer.transform = presented.transform
            }
            layer.removeAnimation(forKey: "lyric.marquee")
            return
        }
        guard layer.animation(forKey: "lyric.marquee") == nil else { return }
        layer.transform = CATransform3DIdentity
        let animation = MenuBarTextFormatter.marqueeAnimation(distance: animationDistance,
            remaining: lineDeadline.map { $0 - CACurrentMediaTime() })
        layer.add(animation, forKey: "lyric.marquee")
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
