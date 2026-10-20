import Foundation

/// The main-window toolbar's interaction rules, as plain values.
///
/// Behaviour is specified in `docs/TOOLBAR_BEHAVIOR.md` and pinned by
/// `Tests/v3_toolbar_model_contract.sh`. The view only forwards pointer and
/// click events here and renders the result; AppKit glue (popover windows,
/// first-click catchers, the pinned NSPanel) must not make its own decisions.
struct V3ToolbarModel: Equatable {
    enum Panel: String, CaseIterable, CustomStringConvertible {
        case library, search, translation, text, picture, more
        var description: String { rawValue }
        var title: String {
            switch self {
            case .library: return "歌词库"
            case .search: return "搜索"
            case .translation: return "译文"
            case .text: return "文字"
            case .picture: return "画面"
            case .more: return "更多"
            }
        }
        var symbol: String {
            switch self {
            case .library: return "books.vertical"
            case .search: return "magnifyingglass"
            case .translation: return "character.bubble"
            case .text: return "textformat"
            case .picture: return "photo"
            case .more: return "ellipsis"
            }
        }
    }

    enum Mode: Equatable {
        case idle
        /// Temporary panel inside the app while the pointer is on a trigger.
        case hover(Panel)
        /// Separate tool window on the right.
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

    func isSelected(_ panel: Panel) -> Bool { pinnedPanel == panel }

    func opacity(pointerInside: Bool, nearTop: Bool, otherPanelOpen: Bool = false) -> Double {
        if nearTop || isPresented || otherPanelOpen { return 1 }
        return pointerInside ? 0.32 : 0
    }

    func suppressesEdgeControls(nearTop: Bool, otherPanelOpen: Bool = false) -> Bool {
        nearTop || isPresented || otherPanelOpen
    }

    // MARK: Pointer

    mutating func pointerOnTrigger(_ panel: Panel, inside: Bool) -> Effect {
        if inside {
            pointerOnTrigger = panel
            guard pinnedPanel == nil else { return .none }
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
    /// A nil panel is the Settings action; library/search also open their own window.
    mutating func click(_ panel: Panel? = nil) {
        guard let panel, panel != .library, panel != .search else { dismiss(); return }
        pointerInPanel = nil
        mode = pinnedPanel == panel ? .idle : .pinned(panel)
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
