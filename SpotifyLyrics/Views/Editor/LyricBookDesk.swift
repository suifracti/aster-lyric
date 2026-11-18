import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricBookDesk: View {
    @Binding var book: LyricBook
    var fileURL: URL?
    @StateObject private var library = PersonalLyricsLibraryService()
    @StateObject private var session = LyricBookSession()
    @Environment(\.openSettings) private var openSettings
    @State private var selected: UUID?
    @State private var collecting = false
    @State private var inscription: Inscription?
    @State private var rendering: Task<Void, Never>?
    @State private var notice: String?

    private enum Inscription: Identifiable {
        case cover
        case note(UUID)
        var id: String { switch self { case .cover: "cover"; case .note(let id): id.uuidString } }
    }

    init(book: Binding<LyricBook>, fileURL: URL? = nil, initialChapter: UUID? = nil) {
        _book = book
        self.fileURL = fileURL
        _selected = State(initialValue: initialChapter)
    }

    private var chapterIndex: Int? { book.chapters.firstIndex { $0.id == selected } }

    var body: some View {
        GeometryReader { geometry in
            let showsSidebar = geometry.size.width >= 610
            VStack(spacing: 0) {
                toolbar(showsSidebar: showsSidebar)
                Divider()
                HStack(spacing: 0) {
                    if showsSidebar {
                        contents.frame(width: 200)
                        Divider()
                    }
                    reading
                }
            }
        }
        .frame(minWidth: 455, minHeight: 380)
        .background(WorkspacePalette.paper)
        .background(LyricBookWindowAnchor { [weak session] in session?.window = $0 })
        .accessibilityIdentifier("lyricBook.desk")
        .onAppear { publishDestination() }
        .onChange(of: book.title) { _, _ in publishDestination() }
        .onChange(of: fileURL) { _, _ in publishDestination() }
        .onDisappear { LyricBookWindows.shared.close(session.id); rendering?.cancel(); rendering = nil }
        .sheet(isPresented: $collecting) {
            LyricBookPicker(library: library, collected: Set(book.chapters.map(\.origin))) { add([$0]) }
        }
        .sheet(item: $inscription) { edit in inscriptionEditor(edit) }
    }

    private func toolbar(showsSidebar: Bool) -> some View {
        HStack(spacing: 10) {
            if !showsSidebar {
                Menu {
                    Button("封面") { selected = nil }
                    ForEach(book.chapters) { chapter in Button(chapter.titleInContents) { selected = chapter.id } }
                } label: { Label("目录", systemImage: "sidebar.left") }
                .fixedSize()
            }
            Button { collecting = true } label: { Label("收录…", systemImage: "plus") }
                .help("从歌词库或金句收录")
            Spacer(minLength: 2)
            if let index = chapterIndex {
                chapterMenu(book.chapters[index], at: index)
            } else {
                Button { inscription = .cover } label: { Image(systemName: "square.and.pencil") }
                    .help("编辑封面").accessibilityLabel("编辑封面")
            }
            Menu {
                Toggle("显示译文", isOn: $book.showsTranslation)
                Toggle("显示读音", isOn: $book.showsReading)
            } label: { Image(systemName: "textformat.size") }
            .help("文字显示").accessibilityLabel("文字显示")
            Menu {
                Button("导出 PDF…", systemImage: "arrow.down.document") { preparePrint(sendToPrinter: false) }
                Button("打印…", systemImage: "printer") { preparePrint(sendToPrinter: true) }
            } label: { Label("印本", systemImage: "printer") }
            .disabled(book.chapters.isEmpty || rendering != nil)
            if rendering != nil { ProgressView().controlSize(.small).accessibilityLabel("正在排版") }
        }
        .buttonStyle(.borderless).menuStyle(.borderlessButton).menuIndicator(.hidden)
        .padding(.horizontal, 16).frame(height: 43)
    }

    private func chapterMenu(_ chapter: LyricBook.Chapter, at index: Int) -> some View {
        Menu {
            Button("编者按…", systemImage: "pencil") { inscription = .note(chapter.id) }
            Button("回到歌词原稿", systemImage: "book") {
                SettingsNavigationRoute.shared.requestedLocation = .init(reading: chapter.origin)
                openSettings()
            }
            Divider()
            Button("向前移动", systemImage: "arrow.up") { book.move(chapter.id, by: -1) }.disabled(index == 0)
            Button("向后移动", systemImage: "arrow.down") { book.move(chapter.id, by: 1) }.disabled(index == book.chapters.count - 1)
            Button("从歌本移除", systemImage: "minus.circle", role: .destructive) {
                book.chapters.removeAll { $0.id == chapter.id }
                selected = book.chapters.isEmpty ? nil : book.chapters[min(index, book.chapters.count - 1)].id
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .help("篇目操作").accessibilityLabel("篇目操作")
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("目录").font(.callout.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(book.chapters.count) 篇").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 9)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        contentsRow("封面", subtitle: nil, symbol: "book.closed", id: nil)
                        ForEach(book.chapters) { chapter in
                            contentsRow(chapter.titleInContents, subtitle: chapter.byline,
                                        symbol: chapter.kind == .song ? "music.note" : "quote.opening", id: chapter.id)
                                .id(chapter.id)
                        }
                    }
                }
                .onChange(of: selected) { _, id in if let id { scroll.scrollTo(id) } }
            }
        }
        .padding(11).padding(.top, 5)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.primary.opacity(0.034))
    }

    private func contentsRow(_ title: String, subtitle: String?, symbol: String, id: UUID?) -> some View {
        Button { selected = id } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(WorkspacePalette.ink)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(id == selected ? .semibold : .regular)).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 9)
            .contentShape(Rectangle())
            .background(id == selected ? WorkspacePalette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).accessibilityAddTraits(id == selected ? .isSelected : [])
    }

    private var reading: some View {
        VStack(spacing: 0) {
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(10)
            }
            ScrollView {
                if let chapterIndex { page(book.chapters[chapterIndex]) } else { cover }
            }
            .id(selected)
            Spacer(minLength: 0)
            if !book.chapters.isEmpty {
                Divider()
                HStack {
                    Button("上一页", systemImage: "chevron.left") { flip(-1) }.disabled(chapterIndex == nil)
                    Spacer()
                    Text(chapterIndex.map { "\($0 + 1) / \(book.chapters.count)" } ?? "封面")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { flip(1) } label: {
                        HStack(spacing: 6) { Text("下一页"); Image(systemName: "chevron.right") }
                    }.disabled(chapterIndex == book.chapters.count - 1)
                }
                .buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 39)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "book.closed").font(.title3).accessibilityHidden(true)
                Spacer()
                if !book.chapters.isEmpty { Text("\(book.chapters.count) 篇").font(.caption.monospacedDigit()) }
            }.foregroundStyle(.white.opacity(0.8))
            Capsule().fill(.white.opacity(0.5)).frame(width: 30, height: 2).padding(.top, 22).accessibilityHidden(true)
            Text(book.displayTitle).font(.system(size: 39, weight: .semibold, design: .serif))
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if !book.author.isEmpty { Text(book.author).font(.callout).foregroundStyle(.white.opacity(0.75)) }
            if !book.introduction.isEmpty { Text(book.introduction).font(.system(.body, design: .serif)).lineSpacing(4).textSelection(.enabled) }
            if book.chapters.isEmpty {
                Button { collecting = true } label: { Label("收进第一篇", systemImage: "plus") }
                    .buttonStyle(.bordered).tint(.white).padding(.top, 16)
            }
        }
        .frame(maxWidth: 460, minHeight: 300, alignment: .topLeading)
        .padding(.vertical, 31).padding(.leading, 33).padding(.trailing, 27)
        .foregroundStyle(.white)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 13).fill(WorkspacePalette.sleeve)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.leading, 11)
                }
        }
        .padding(.horizontal, 26).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func page(_ chapter: LyricBook.Chapter) -> some View {
        let multipleVoices = Set(chapter.lines.compactMap(\.performer)).count > 1
        return VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 5) {
                Text(chapter.edition).font(.caption.weight(.medium)).foregroundStyle(WorkspacePalette.ink)
                Text(chapter.title).font(.system(size: 31, weight: .semibold, design: .serif)).accessibilityAddTraits(.isHeader)
                let detail = chapter.kind == .quote ? chapter.artist : chapter.byline
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            if !chapter.note.isEmpty {
                Text(chapter.note).font(.callout).foregroundStyle(WorkspacePalette.ink).textSelection(.enabled)
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(WorkspacePalette.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
            }
            Divider()
            LazyVStack(alignment: .leading, spacing: chapter.kind == .quote ? 13 : 10) {
                ForEach(chapter.lines.indices, id: \.self) { index in
                    let line = chapter.lines[index].text(for: book)
                    VStack(alignment: .leading, spacing: 4) {
                        if multipleVoices, let voice = chapter.lines[index].performer,
                           index == 0 || chapter.lines[index - 1].performer != voice {
                            Text("声部 \(voice)").font(.caption).foregroundStyle(WorkspacePalette.ink)
                        }
                        if let reading = line.reading { Text(reading).font(.caption).foregroundStyle(WorkspacePalette.ink) }
                        Text(line.main).font(.system(size: chapter.kind == .quote ? 27 : 17, design: .serif))
                        if let translation = line.translation { Text(translation).font(.callout).foregroundStyle(.secondary) }
                        if let background = line.background {
                            Label(background, systemImage: "music.note").font(.caption).foregroundStyle(.secondary)
                        }
                    }.textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: 575, alignment: .leading)
        .padding(.horizontal, 31).padding(.vertical, 25).frame(maxWidth: .infinity)
    }

    private func inscriptionEditor(_ edit: Inscription) -> some View {
        switch edit {
        case .cover:
            LyricBookInscription(title: book.title, author: book.author, text: book.introduction, isCover: true) { title, author, text in
                book.title = title; book.author = author; book.introduction = text
            }
        case .note(let id):
            LyricBookInscription(text: book.chapters.first(where: { $0.id == id })?.note ?? "", isCover: false) { _, _, text in
                if let index = book.chapters.firstIndex(where: { $0.id == id }) { book.chapters[index].note = text }
            }
        }
    }

    private func flip(_ step: Int) {
        let next = (chapterIndex ?? -1) + step
        if next == -1 { selected = nil }
        else if book.chapters.indices.contains(next) { selected = book.chapters[next].id }
    }

    private func add(_ chapters: [LyricBook.Chapter]) {
        var updated = book
        for chapter in chapters { selected = updated.add(chapter) }
        if updated != book { book = updated }
        notice = nil
    }

    private func publishDestination() {
        LyricBookWindows.shared.register(session.id, title: book.title.isEmpty ? fileURL?.deletingPathExtension().lastPathComponent ?? book.displayTitle : book.displayTitle) { chapters in
            add(chapters)
            session.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func preparePrint(sendToPrinter: Bool) {
        guard rendering == nil else { return }
        let snapshot = book
        notice = nil
        rendering = Task {
            defer { rendering = nil }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try LyricBookPrint.data(for: snapshot)
                }.value
                try Task.checkCancellation()
                if sendToPrinter {
                    guard let pdf = PDFDocument(data: data),
                          let operation = pdf.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true) else {
                        notice = "无法打开打印面板。"
                        return
                    }
                    if let window = session.window {
                        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
                    } else { operation.run() }
                } else {
                    savePDF(data, title: snapshot.displayTitle)
                }
            } catch is CancellationError {} catch { notice = "歌本未能完成排版。\(error.localizedDescription)" }
        }
    }

    private func savePDF(_ data: Data, title: String) {
        let panel = NSSavePanel()
        panel.title = "导出歌本"
        panel.allowedContentTypes = [.pdf]
        let filename = title.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "/:"))).joined(separator: " ")
        panel.nameFieldStringValue = filename + ".pdf"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { notice = error.localizedDescription }
        }
        if let window = session.window { panel.beginSheetModal(for: window, completionHandler: write) }
        else { write(panel.runModal()) }
    }
}

struct LyricBookOffer: View {
    var label = "编成歌本"
    var title = ""
    /// Line rows use an icon beside the bookmark; headers and menus keep the text label.
    var compact = false
    private let load: () async throws -> [LyricBook.Chapter]
    @ObservedObject private var windows = LyricBookWindows.shared
    @Environment(\.newDocument) private var newDocument
    @State private var addedTo: String?
    @State private var isLoading = false
    @State private var issue: String?

    init(label: String = "编成歌本", title: String = "", compact: Bool = false,
         chapters: @escaping () -> [LyricBook.Chapter]) {
        self.label = label
        self.title = title
        self.compact = compact
        load = { chapters() }
    }

    init(label: String, title: String, loadChapters: @escaping () async throws -> [LyricBook.Chapter]) {
        self.label = label
        self.title = title
        load = loadChapters
    }

    var body: some View {
        Group {
            if windows.destinations.isEmpty {
                Button { prepare { newDocument(LyricBook(title: title, chapters: $0)) } } label: { face }
            } else {
                Menu {
                    Button("新建歌本") { prepare { newDocument(LyricBook(title: title, chapters: $0)) } }
                    Section("加入打开的歌本") {
                        ForEach(windows.destinations) { destination in
                            Button(destination.title) { prepare { add($0, to: destination) } }
                        }
                    }
                } label: { face }
                .menuIndicator(compact ? .hidden : .visible)
            }
        }
        .disabled(isLoading)
        .alert("暂时无法收进歌本", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("好") { issue = nil }
        } message: { Text(issue ?? "") }
        .help(addedTo.map { "已收进《\($0)》" } ?? label)
        .accessibilityLabel(addedTo.map { "已收进《\($0)》" } ?? label)
        .task(id: addedTo) {
            guard addedTo != nil else { return }
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { addedTo = nil }
        }
    }

    @ViewBuilder private var face: some View {
        let symbol = addedTo == nil ? "book.closed" : "checkmark"
        if compact {
            Image(systemName: symbol).frame(width: 25, height: 25).contentShape(Rectangle())
        } else {
            Label(addedTo.map { "已收进《\($0)》" } ?? label, systemImage: symbol)
        }
    }

    private func add(_ chapters: [LyricBook.Chapter], to destination: LyricBookWindows.Destination) {
        destination.add(chapters)
        addedTo = destination.title.isEmpty ? "歌本" : destination.title
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "已收进《\(addedTo ?? "歌本")》", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func prepare(_ use: @escaping ([LyricBook.Chapter]) -> Void) {
        guard !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let chapters = try await load()
                guard !chapters.isEmpty else {
                    issue = "这份版本里没有可收录的歌词。"
                    return
                }
                use(chapters)
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}

@MainActor
fileprivate final class LyricBookWindows: ObservableObject {
    struct Destination: Identifiable {
        let id: UUID
        let title: String
        let add: ([LyricBook.Chapter]) -> Void
    }
    static let shared = LyricBookWindows()
    @Published private(set) var destinations: [Destination] = []

    func register(_ id: UUID, title: String, add: @escaping ([LyricBook.Chapter]) -> Void) {
        let destination = Destination(id: id, title: title, add: add)
        if let index = destinations.firstIndex(where: { $0.id == id }) { destinations[index] = destination }
        else { destinations.append(destination) }
    }

    func close(_ id: UUID) { destinations.removeAll { $0.id == id } }
}

private final class LyricBookSession: ObservableObject {
    let id = UUID()
    weak var window: NSWindow?
}

private struct LyricBookWindowAnchor: NSViewRepresentable {
    let attached: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor(attached: attached) }
    func updateNSView(_ view: Anchor, context: Context) { view.attached = attached }

    final class Anchor: NSView {
        var attached: (NSWindow?) -> Void
        init(attached: @escaping (NSWindow?) -> Void) {
            self.attached = attached
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached(window) }
    }
}

private struct LyricBookInscription: View {
    @State var title = ""
    @State var author = ""
    @State var text: String
    let isCover: Bool
    let save: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isCover ? "编辑封面" : "编者按").font(.headline)
            if isCover {
                TextField("歌本名称", text: $title)
                TextField("编者（可选）", text: $author)
            }
            Text(isCover ? "序言（可选）" : "这一篇的备注").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(minHeight: 90)
                .accessibilityLabel(isCover ? "序言" : "编者按")
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("完成") { save(title, author, text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(19).frame(width: 400)
    }
}
