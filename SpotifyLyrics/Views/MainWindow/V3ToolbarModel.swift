import Foundation

/// Tabs of the 调整 panel. 译文 is a shortcut to `.currentSong`.
enum V3AdjustmentTab: String, CaseIterable, Identifiable {
    case picture, text, currentSong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .picture: return "画面"
        case .text: return "文字"
        case .currentSong: return "当前歌曲"
        }
    }
}

/// The main-window toolbar's interaction rules, as plain values.
///
/// Behaviour is specified in `docs/TOOLBAR_BEHAVIOR.md` and pinned by
/// `Tests/v3_toolbar_model_contract.sh`. The view only forwards pointer and
/// click events here and renders the result; AppKit glue (popover windows,
/// first-click catchers, the pinned NSPanel) must not make its own decisions.
struct V3ToolbarModel: Equatable {
    enum Panel: Equatable, CustomStringConvertible {
        case adjust, more, translation
        var description: String {
            switch self {
            case .adjust: return "adjust"
            case .more: return "more"
            case .translation: return "translation"
            }
        }
    }

    enum Mode: Equatable {
        case idle
        /// Temporary panel inside the app while the pointer is on a trigger.
        case hover(Panel)
        /// Separate tool window on the right. Never `.translation`: 译文 pins
        /// 调整 on the 当前歌曲 tab.
        case pinned(Panel)
    }

    /// What the view should do after an event, besides re-rendering.
    enum Effect: Equatable {
        case none
        /// Start (or restart) the short grace timer, then call `dismissTimerFired`.
        case scheduleHoverDismissal(Panel)
        case cancelHoverDismissal
    }

    /// Grace period that lets the pointer cross from a trigger to its panel.
    static let hoverGrace: Duration = .milliseconds(180)

    private(set) var mode: Mode = .idle
    var tab: V3AdjustmentTab = .picture
    private(set) var pointerOnTrigger: Panel?
    private(set) var pointerInPanel: Panel?
    private(set) var menuDepth = 0

    var hoverPanel: Panel? {
        if case .hover(let panel) = mode { return panel }
        return nil
    }

    var pinnedPanel: Panel? {
        if case .pinned(let panel) = mode { return panel }
        return nil
    }

    var isPresented: Bool { mode != .idle }

    var translationPinned: Bool { pinnedPanel == .adjust && tab == .currentSong }

    /// Toolbar button highlight. 译文 and 调整 never light up together.
    func isSelected(_ panel: Panel) -> Bool {
        switch panel {
        case .translation: return translationPinned
        case .adjust: return pinnedPanel == .adjust && !translationPinned
        case .more: return pinnedPanel == .more
        }
    }

    // MARK: Pointer

    mutating func pointerOnTrigger(_ panel: Panel, inside: Bool) -> Effect {
        if inside {
            pointerOnTrigger = panel
            guard pinnedPanel == nil else { return .none }
            if panel == .translation { tab = .currentSong }
            mode = .hover(panel)
            return .cancelHoverDismissal
        }
        if pointerOnTrigger == panel { pointerOnTrigger = nil }
        return hoverPanel == panel ? .scheduleHoverDismissal(panel) : .none
    }

    mutating func pointerInPanel(_ panel: Panel, inside: Bool) -> Effect {
        if inside {
            pointerInPanel = panel
            return hoverPanel == panel ? .cancelHoverDismissal : .none
        }
        if pointerInPanel == panel { pointerInPanel = nil }
        return hoverPanel == panel ? .scheduleHoverDismissal(panel) : .none
    }

    mutating func dismissTimerFired(_ panel: Panel) {
        guard hoverPanel == panel, pointerOnTrigger != panel, pointerInPanel != panel,
              menuDepth == 0 else { return }
        mode = .idle
    }

    /// Native menus inside a hover panel must not let it close under them.
    mutating func menuTrackingBegan() -> Effect {
        menuDepth += 1
        return hoverPanel == nil ? .none : .cancelHoverDismissal
    }

    mutating func menuTrackingEnded() -> Effect {
        menuDepth = max(0, menuDepth - 1)
        guard let panel = hoverPanel, menuDepth == 0 else { return .none }
        return .scheduleHoverDismissal(panel)
    }

    // MARK: Clicks

    /// One click on a panel button, from whichever path delivered it (the
    /// SwiftUI button, the first-click catcher, or a popover's event
    /// monitor). Every click visibly changes something.
    mutating func click(_ panel: Panel) {
        pointerInPanel = nil
        switch panel {
        case .translation:
            if translationPinned { mode = .idle; return }
            tab = .currentSong
            mode = .pinned(.adjust)
        case .adjust:
            if translationPinned { tab = .picture; return }
            mode = pinnedPanel == .adjust ? .idle : .pinned(.adjust)
        case .more:
            mode = pinnedPanel == .more ? .idle : .pinned(.more)
        }
    }

    /// Another toolbar action (歌词库, 搜索, 设置), Escape, or the pinned
    /// window's close button.
    mutating func dismiss() {
        mode = .idle
        pointerInPanel = nil
    }

    /// The hover popover closed itself (outside click, app deactivated).
    mutating func hoverClosed(_ panel: Panel) {
        if hoverPanel == panel { mode = .idle }
    }
}
