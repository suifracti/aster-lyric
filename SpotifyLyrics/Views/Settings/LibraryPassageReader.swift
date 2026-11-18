import SwiftUI

/// A stable page from the local archive. Its find cursor is independent of the playing song.
struct LibraryPassageReader: View {
    let target: LibraryPassageTarget
    let library: PersonalLyricsLibraryService
    var openArchive: ((LibraryPassageTarget) -> Void)?
    var close: (() -> Void)?
    @State private var page: LibraryPassagePage?
    @State private var failure: String?
    @State private var find: String
    @State private var matches: [Int] = []
    @State private var cursor = 0
    @State private var showsReading: Bool
    @State private var showsTranslation = true
    @State private var hoveredLine: Int?
    @State private var recall: LyricRecallSession?
    @State private var recallNotice: String?
    @State private var returnedLine: Int?

    init(target: LibraryPassageTarget, library: PersonalLyricsLibraryService,
         openArchive: ((LibraryPassageTarget) -> Void)? = nil, close: (() -> Void)? = nil) {
        self.target = target
        self.library = library
        self.openArchive = openArchive
        self.close = close
        _find = State(initialValue: target.find)
        if case .reading = target.source { _showsReading = State(initialValue: true) }
        else { _showsReading = State(initialValue: false) }
    }

    private var currentMatch: Int? { matches.indices.contains(cursor) ? matches[cursor] : nil }
    private var focusedLine: Int? { returnedLine ?? currentMatch }

    private var archiveTarget: LibraryPassageTarget {
        guard let page else { return .init(trackKey: target.trackKey) }
        let source: LibraryPassageSource
        if case .reading = target.source { source = target.source }
        else if let translation = page.translationVersionID { source = .translation(translation) }
        else { source = .original(page.originalVersionID) }
        return .init(trackKey: page.entry.trackStableKey, source: source)
    }

    var body: some View {
        Group {
            if let page, let recall {
                LyricRecallView(page: page, session: recall, showsTranslation: showsTranslation, showsReading: showsReading) { line in
                    returnedLine = line
                    self.recall = nil
                }
            } else { readingPage }
        }
        .background(WorkspacePalette.paper)
        .onChange(of: find) { _, _ in returnedLine = nil; updateMatches() }
        .task(id: target) { await load() }
    }

    private var readingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("在这份歌词里查找", text: $find).textFieldStyle(.plain)
                    .onSubmit { move(1) }
                if !find.isEmpty {
                    Text(matches.isEmpty ? "无匹配" : "\(cursor + 1)/\(matches.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }
                        .help("上一处").accessibilityLabel("上一处").disabled(matches.isEmpty)
                    Button { move(1) } label: { Image(systemName: "chevron.down") }
                        .help("下一处").accessibilityLabel("下一处").disabled(matches.isEmpty)
                    Button { find = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .help("清除查找").accessibilityLabel("清除查找")
                }
                if let openArchive {
                    Button { openArchive(archiveTarget) } label: { Label("版本档案", systemImage: "books.vertical") }.fixedSize()
                }
                Menu {
                    Toggle("显示译文", isOn: $showsTranslation)
                    Toggle("显示读音", isOn: $showsReading)
                } label: { Image(systemName: "textformat.size") }
                .menuStyle(.borderlessButton).fixedSize().help("阅读外观").accessibilityLabel("阅读外观")
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .keyboardShortcut(.cancelAction).help("关闭阅读").accessibilityLabel("关闭阅读")
                }
            }
            .buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            if let recallNotice {
                Text(recallNotice).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.top, 8)
            }
            if let page {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(page.edition).font(.caption.weight(.semibold)).foregroundStyle(WorkspacePalette.ink)
                                Text(page.entry.title).font(.system(size: 26, weight: .semibold, design: .serif))
                                    .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                                HStack {
                                    Text(page.entry.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    PortableLyricsExportMenu { page.portableEdition }
                                    LyricBookOffer(title: page.entry.title) { [.init(page: page, source: target.source)] }
                                        .controlSize(.small).fixedSize()
                                    if page.lines.contains(where: { !$0.original.isEmpty }) {
                                        Button { startRecall(page, anchor: focusedLine) } label: {
                                            Label("接下一句", systemImage: "text.bubble")
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                            .padding(.horizontal, 10).padding(.bottom, 18)
                            ForEach(page.lines) { line in row(line, page: page).id(line.id) }
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 19).padding(.vertical, 22).frame(maxWidth: .infinity)
                    }
                    .task(id: focusedLine) {
                        guard let id = focusedLine else { return }
                        await Task.yield()
                        if !Task.isCancelled { scroll.scrollTo(id, anchor: .center) }
                    }
                }
            } else if let failure {
                VStack(spacing: 10) {
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    Button("重新读取") { Task { await load() } }.buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("读取保存的歌词")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func row(_ line: LibraryPassagePage.Line, page: LibraryPassagePage) -> some View {
        let selected = focusedLine == line.id
        return HStack(alignment: .top, spacing: 8) {
            PassageLineText(line: line, showsTranslation: showsTranslation || selected, showsReading: showsReading || selected)
            Spacer(minLength: 8)
            if !line.original.isEmpty {
                KeepLyricButton(entry: page.quote(line))
                    .opacity(hoveredLine == line.id || selected ? 1 : 0.45)
            }
            if [line.original, line.translation, line.reading, line.background].compactMap({ $0 }).contains(where: { !$0.isEmpty }) {
                // The found line can go straight into a songbook, keeping its version and line number.
                LyricBookOffer(label: "收录这句", title: page.entry.title, compact: true) {
                    [.init(page: page, source: target.source, excerpt: line)]
                }
                .buttonStyle(.plain).menuStyle(.borderlessButton).fixedSize()
                .opacity(hoveredLine == line.id || selected ? 1 : 0)
                .allowsHitTesting(hoveredLine == line.id || selected)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? WorkspacePalette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { inside in
            if inside { hoveredLine = line.id } else if hoveredLine == line.id { hoveredLine = nil }
        }
        .contextMenu {
            if !line.original.isEmpty {
                Button("从这句接下去", systemImage: "text.bubble") { startRecall(page, anchor: line.id) }
            }
            if [line.original, line.translation, line.reading, line.background].compactMap({ $0 }).contains(where: { !$0.isEmpty }) {
                LyricBookOffer(label: "收录这句", title: page.entry.title) { [.init(page: page, source: target.source, excerpt: line)] }
            }
        }
    }

    private func load() async {
        failure = nil
        page = nil
        recall = nil
        recallNotice = nil
        returnedLine = nil
        find = target.find
        do {
            let loaded = try await library.readPassage(target)
            try Task.checkCancellation()
            if let loaded, !loaded.lines.isEmpty {
                page = loaded
                let savedPosition = target.savedQuote?.originalVersionID == loaded.originalVersionID
                    && loaded.matchesOriginalVersion ? target.lineIndex : nil
                updateMatches(preferred: savedPosition ?? target.lineIndex)
                if let savedPosition, loaded.lines.contains(where: { $0.id == savedPosition }) {
                    returnedLine = savedPosition
                }
                if target.recallNextLine {
                    if let anchor = returnedLine ?? loaded.originalOccurrence(of: target.find, preferred: target.lineIndex) {
                        startRecall(loaded, anchor: anchor)
                    } else { recallNotice = "这份原词里找不到选中的那句。" }
                }
            } else { failure = "本机已找不到这份歌词，可以回歌曲档案查看其他版本。" }
        } catch {
            guard !Task.isCancelled else { return }
            failure = "暂时读不到这份歌词。"
        }
    }

    private func startRecall(_ page: LibraryPassagePage, anchor: Int?) {
        recall = LyricRecallSession(lines: page.lines, anchor: anchor)
        if recall != nil { recallNotice = nil }
        else if let anchor, page.lines.first(where: { $0.id == anchor })?.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            recallNotice = "这行只有译文，可以从另一句原词开始。"
        } else { recallNotice = "这句后面已经没有原词了。" }
    }

    private func updateMatches(preferred: Int? = nil) {
        let term = find.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = term.isEmpty ? [] : page?.lines.filter { $0.matches(term) }.map(\.id) ?? []
        cursor = preferred.flatMap { matches.firstIndex(of: $0) } ?? 0
    }

    private func move(_ offset: Int) {
        guard !matches.isEmpty else { return }
        returnedLine = nil
        cursor = (cursor + offset + matches.count) % matches.count
    }
}

struct PassageLineText: View {
    let line: LibraryPassagePage.Line
    let showsTranslation: Bool
    let showsReading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !line.original.isEmpty {
                Text(line.original).font(.system(size: 17, weight: .medium, design: .serif))
            }
            if let backing = line.background, !backing.isEmpty {
                Label(backing, systemImage: "person.2").labelStyle(.titleAndIcon)
                    .font(.callout.italic()).foregroundStyle(.secondary)
                    .accessibilityLabel("和声，\(backing)")
            }
            if let translation = line.translation, !translation.isEmpty,
               showsTranslation || line.original.isEmpty {
                Text(translation).font(.callout).foregroundStyle(.secondary)
            }
            if let reading = line.reading, !reading.isEmpty, showsReading {
                Text(reading).font(.caption).foregroundStyle(WorkspacePalette.ink)
            }
        }
        .textSelection(.enabled)
    }
}
