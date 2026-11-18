import AppKit
import SwiftUI

@MainActor
final class QuickFindLauncher: NSObject, ObservableObject {
    static let shared = QuickFindLauncher()
    struct Request: Equatable { let id = UUID(); let query: String }
    @Published private(set) var request = Request(query: "")
    private var openWindow: (() -> Void)?
    private var pending = false

    func connect(_ open: @escaping () -> Void) {
        openWindow = open
        if pending {
            pending = false
            DispatchQueue.main.async { open() }
        }
    }

    func show(query: String = "") {
        request = Request(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        if let openWindow { openWindow() } else { pending = true }
    }

    /// macOS supplies a dedicated pasteboard containing the text the reader selected.
    @objc(findLyrics:userData:error:)
    func findLyrics(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let value = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { error.pointee = "请选择要查找的文字"; return }
        show(query: value)
    }
}

@MainActor
struct WorkspaceQuickFind: View {
    @ObservedObject var launcher: QuickFindLauncher
    @StateObject private var lookup = WorkspaceLookup()
    @StateObject private var library: PersonalLyricsLibraryService
    @ObservedObject private var favorites = V3FavoriteLines.shared
    @AppStorage(LastOpenedLyricsRecord.defaultsKey, store: .lyricsQ) private var lastOpened = Data()
    @AppStorage(RecentLyricsReadings.defaultsKey, store: .lyricsQ) private var recentReadings = Data()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var query = ""
    @State private var selectedID: String?
    @State private var reading: LibraryPassageTarget?
    @State private var focusRequest = UUID()
    @FocusState private var readingFocused: Bool

    init(launcher: QuickFindLauncher? = nil, library: PersonalLyricsLibraryService? = nil) {
        self.launcher = launcher ?? .shared
        _library = StateObject(wrappedValue: library ?? PersonalLyricsLibraryService())
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [WorkspaceLookupRow] {
        if term.isEmpty {
            let last = try? JSONDecoder().decode(LastOpenedLyricsRecord.self, from: lastOpened)
            return WorkspaceLookupRow.suggestions(readings: RecentLyricsReadings.records(from: recentReadings, legacy: last),
                                                  lastOpened: last, favorites: favorites.entries)
        }
        return WorkspaceLookupRow.matches(term, songs: lookup.songs(for: term), favorites: favorites.entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reading {
                VStack(alignment: .leading, spacing: 0) {
                    Button { backToSearch() } label: {
                        Label(term.isEmpty ? "返回查找" : "返回「\(term)」", systemImage: "chevron.left").lineLimit(1)
                    }
                        .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help("Esc 返回查找结果")
                        .padding(.horizontal, 17).padding(.vertical, 9)
                    Divider()
                    LibraryPassageReader(target: reading, library: library, openArchive: { archive in
                        SettingsNavigationRoute.shared.requestedLocation = .init(archive: archive)
                        openSettings()
                    })
                }
                .focusable().focusEffectDisabled().focused($readingFocused)
                .onExitCommand(perform: backToSearch)
                .onAppear { readingFocused = true }
            } else {
                searchView
            }
        }
        .frame(minWidth: 390, idealWidth: 555, minHeight: 300, idealHeight: 425)
        .background(WorkspacePalette.paper)
        .onChange(of: launcher.request, initial: true) { _, next in
            reading = nil
            query = next.query
            selectedID = nil
            focusRequest = next.id
        }
        .task(id: term) { await lookup.search(term, library: library) }
    }

    private var searchView: some View {
        let rows = items
        let active = rows.first { $0.id == selectedID } ?? rows.first
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(WorkspacePalette.ink)
                QuickFindField(text: $query, focus: focusRequest, move: { step in
                    guard !rows.isEmpty else { return }
                    let current = rows.firstIndex { $0.id == active?.id } ?? 0
                    selectedID = rows[min(max(0, current + step), rows.count - 1)].id
                }, submit: { if let active { openResult(active) } }, cancel: { close() })
                .frame(height: 36)
                if !query.isEmpty {
                    Button { query = ""; focusRequest = UUID() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("清空查找")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 7)
            Divider()
            if rows.isEmpty {
                if lookup.result?.term != term && !term.isEmpty {
                    ProgressView("正在查本机歌词库").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(lookup.result?.failed == true ? "暂时读不到歌词库" : "没有找到匹配",
                        systemImage: "text.magnifyingglass", description: Text("试试歌名、另一句歌词或设置名称。"))
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || rows[index - 1].group != item.group {
                                    Text(item.group.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        .padding(.leading, 12).padding(.top, 10).padding(.bottom, 3)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                Button { openResult(item) } label: {
                                    WorkspaceResultLabel(item: item, selected: item.id == active?.id).padding(.horizontal, 10)
                                }
                                .buttonStyle(.plain)
                                .background(item.id == active?.id ? WorkspacePalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityAddTraits(item.id == active?.id ? .isSelected : [])
                                .id(item.id)
                            }
                        }.padding(.horizontal, 9).padding(.bottom, 9)
                    }
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                    .task(id: rows.map(\.id)) {
                        if let selectedID, rows.contains(where: { $0.id == selectedID }) {
                            await Task.yield()
                            if !Task.isCancelled { proxy.scrollTo(selectedID) }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                if lookup.result?.term == term && lookup.result?.failed == true {
                    Label("暂时读不到歌词库", systemImage: "exclamationmark.circle")
                } else { Text("↑ ↓ 选择") }
                Spacer()
                Text(active?.location.passage == nil ? "↩ 打开" : "↩ 读这句").foregroundStyle(WorkspacePalette.ink)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 19).frame(height: 32)
        }
        .onChange(of: term) { _, _ in selectedID = nil }
    }

    private func openResult(_ row: WorkspaceLookupRow) {
        selectedID = row.id
        open(row.location)
    }

    private func open(_ location: SettingsLocation) {
        if let passage = location.passage { reading = passage; return }
        SettingsNavigationRoute.shared.requestedLocation = location
        close()
        openSettings()
    }
    private func backToSearch() { reading = nil; focusRequest = UUID() }
    private func close() { dismissWindow(id: "quick-find") }
}

/// Keep normal macOS text editing and input-method composition. The field editor
/// owns arrow keys and Return, so route those commands only after composition ends.
private struct QuickFindField: NSViewRepresentable {
    @Binding var text: String
    let focus: UUID
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    final class Field: NSTextField {
        var wantsFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if wantsFocus { focusWhenReady() }
        }
        func focusWhenReady() {
            wantsFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.wantsFocus = false
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickFindField
        var servedFocus: UUID?
        init(_ parent: QuickFindField) { self.parent = parent }
        @objc func submitted(_ sender: NSTextField) {
            parent.submit()
        }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "找一句歌词、歌名或设置"
        field.setAccessibilityLabel("查找本机资料")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.servedFocus != focus {
            context.coordinator.servedFocus = focus
            field.focusWhenReady()
        }
    }
}
