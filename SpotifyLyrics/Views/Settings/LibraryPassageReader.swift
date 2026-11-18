import SwiftUI

struct FirstVisibleLyric: PreferenceKey {
    struct Row: Equatable {
        let id: Int
        let bottom: CGFloat
    }

    static let defaultValue: Row? = nil

    static func reduce(value: inout Row?, nextValue: () -> Row?) {
        guard let next = nextValue(), next.bottom < (value?.bottom ?? .infinity) else { return }
        value = next
    }
}

/// A stable page from the local archive. Its find cursor is independent of the playing song.
struct LibraryPassageReader: View {
    private struct ScrollRequest: Equatable {
        let id = UUID()
        let line: Int
        let restoreTop: Bool
    }

    private let initialTarget: LibraryPassageTarget
    @State private var editionSelection: (origin: LibraryPassageTarget, target: LibraryPassageTarget)?
    let library: PersonalLyricsLibraryService
    var openArchive: ((LibraryPassageTarget) -> Void)?
    var close: (() -> Void)?
    @Environment(\.newDocument) private var newDocument
    @State private var page: LibraryPassagePage?
    @State private var voices = PassageVoicePresentation(lines: [])
    @State private var failure: String?
    @State private var find: String
    @State private var matches: [Int] = []
    @State private var cursor = 0
    @State private var showsReading: Bool
    @State private var showsTranslation = true
    @State private var hoveredLine: Int?
    @State private var selectingExcerpt = false
    @State private var recall: LyricRecallSession?
    @State private var recallNotice: String?
    @State private var returnedLine: Int?
    @State private var topLine: Int?
    @State private var scrollRequest: ScrollRequest?
    @State private var loadedTarget: LibraryPassageTarget?
    @State private var recordedPosition: LibraryPassageTarget.ReadingPosition?
    @Namespace private var viewport

    init(target: LibraryPassageTarget, library: PersonalLyricsLibraryService,
         openArchive: ((LibraryPassageTarget) -> Void)? = nil, close: (() -> Void)? = nil) {
        self.initialTarget = target
        self.library = library
        self.openArchive = openArchive
        self.close = close
        _find = State(initialValue: target.readingPosition?.find ?? target.find)
        if case .reading = target.source { _showsReading = State(initialValue: true) }
        else { _showsReading = State(initialValue: false) }
    }

    private var target: LibraryPassageTarget {
        if let editionSelection, editionSelection.origin == initialTarget { return editionSelection.target }
        return initialTarget
    }

    private var currentMatch: Int? { matches.indices.contains(cursor) ? matches[cursor] : nil }
    private var focusedLine: Int? { returnedLine ?? currentMatch }
    private var visibleFocus: Int? { focusedLine.map { voices.visibleID(for: $0) } }
    private var readingPosition: LibraryPassageTarget.ReadingPosition {
        let restoredLine = scrollRequest.flatMap { $0.restoreTop ? $0.line : nil }
        let top = topLine ?? restoredLine
        return .init(find: find, lineIndex: focusedLine, topLineIndex: top == page?.lines.first?.id ? nil : top)
    }

    private var archiveTarget: LibraryPassageTarget {
        guard let page else { return .init(trackKey: target.trackKey) }
        return page.archiveTarget(from: target, position: readingPosition)
    }

    var body: some View {
        Group {
            if let page, selectingExcerpt {
                LyricBookExcerptPicker(page: page, source: target.source, initialLine: focusedLine ?? topLine,
                    backTitle: "返回阅读", back: {
                        let previousTop = topLine
                        selectingExcerpt = false
                        scrollToLine(previousTop ?? visibleFocus, restoreTop: previousTop != nil)
                    })
                    .padding(18)
            } else if let page, let recall {
                LyricRecallView(page: page, session: recall, voices: voices,
                                showsTranslation: showsTranslation, showsReading: showsReading) { line in
                    updateMatches(preferred: line)
                    returnedLine = line
                    self.recall = nil
                    scrollToLine(line)
                    rememberPosition()
                }
            } else { readingPage }
        }
        .background(WorkspacePalette.paper)
        .task(id: target) { await load() }
        .onDisappear { rememberPosition() }
    }

    private var readingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("在这份歌词里查找", text: Binding(get: { find }, set: changeFind)).textFieldStyle(.plain)
                    .onSubmit { move(1) }
                if !find.isEmpty {
                    Text(matches.isEmpty ? "无匹配" : "\(cursor + 1)/\(matches.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }
                        .help("上一处").accessibilityLabel("上一处").disabled(matches.isEmpty)
                    Button { move(1) } label: { Image(systemName: "chevron.down") }
                        .help("下一处").accessibilityLabel("下一处").disabled(matches.isEmpty)
                    Button { changeFind("") } label: { Image(systemName: "xmark.circle.fill") }
                        .help("清除查找").accessibilityLabel("清除查找")
                }
                if let openArchive {
                    Button { openArchive(archiveTarget) } label: { Label("版本档案", systemImage: "books.vertical") }.fixedSize()
                        .disabled(page == nil && failure == nil)
                }
                if let page, page.editions.contains(where: { $0.source != page.resolvedSource }) {
                    editionMenu(page)
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
            if let label = target.excerptLineLabel, page != nil {
                Label("歌本摘段 · \(label)", systemImage: "quote.opening")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.top, 8)
            }
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
                                    if page.canWriteManuscript {
                                        Button {
                                            if let draft = LyricManuscript(copyingOriginal: page) { newDocument(draft) }
                                        } label: {
                                            Image(systemName: "square.and.pencil")
                                        }
                                        .buttonStyle(.borderless).controlSize(.small)
                                        .help("从这版写手稿 · 复制原词和每行的起始时间")
                                        .accessibilityLabel("从这版写手稿")
                                    }
                                    PortableLyricsExportMenu { page.portableEdition }
                                    LyricBookOffer(title: page.entry.title) { [.init(page: page, source: target.source)] }
                                        .controlSize(.small).fixedSize()
                                    if page.lines.count > 1 {
                                        Button("摘一段", systemImage: "scissors") { selectingExcerpt = true }
                                            .controlSize(.small).fixedSize()
                                    }
                                    if page.lines.contains(where: { !$0.original.isEmpty }) {
                                        Button { startRecall(page, anchor: focusedLine) } label: {
                                            Label("接下一句", systemImage: "text.bubble")
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                            .padding(.horizontal, 10).padding(.bottom, 18)
                            ForEach(voices.visibleLines(in: page.lines)) { line in
                                row(line, page: page)
                                    .background {
                                        GeometryReader { geometry in
                                            let bottom = geometry.frame(in: .named(viewport)).maxY
                                            Color.clear.preference(key: FirstVisibleLyric.self,
                                                value: bottom > 1 ? .init(id: line.id, bottom: bottom) : nil)
                                        }
                                    }
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 19).padding(.vertical, 22).frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: viewport)
                    .onPreferenceChange(FirstVisibleLyric.self) { row in
                        if let id = row?.id, topLine != id { topLine = id }
                    }
                    .task(id: scrollRequest) {
                        guard let request = scrollRequest else { return }
                        await Task.yield()
                        if !Task.isCancelled { scroll.scrollTo(request.line, anchor: request.restoreTop ? .top : .center) }
                    }
                    .task(id: topLine) {
                        guard topLine != nil, !Task.isCancelled else { return }
                        try? await Task.sleep(for: .milliseconds(220))
                        if !Task.isCancelled { rememberPosition() }
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

    private func editionMenu(_ page: LibraryPassagePage) -> some View {
        Menu {
            ForEach(LibraryPassageEdition.Kind.allCases, id: \.self) { kind in
                let editions = page.editions.filter { $0.kind == kind }
                if !editions.isEmpty {
                    Section(kind.label) {
                        ForEach(editions) { edition in
                            let title = [library.readingEditionTitle(edition), v3ShortDateText(edition.updatedAt), edition.status]
                                .compactMap { $0 }.joined(separator: " · ")
                            let current = edition.source == page.resolvedSource
                            Button {
                                guard !current else { return }
                                rememberPosition()
                                editionSelection = (initialTarget, edition.readingTarget(from: page, position: readingPosition))
                            } label: {
                                if current { Label(title, systemImage: "checkmark") }
                                else { Text(title) }
                            }
                        }
                    }
                }
            }
        } label: { Image(systemName: "square.stack") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("切换阅读版本").accessibilityLabel("切换阅读版本")
    }

    private func row(_ line: LibraryPassagePage.Line, page: LibraryPassagePage) -> some View {
        let selected = visibleFocus == line.id
        let partOfExcerpt = target.excerptRange?.contains(line.id) == true
        let sourceLine = selected && focusedLine != line.id
            ? page.lines.first(where: { $0.id == focusedLine }) ?? line : line
        return HStack(alignment: .top, spacing: 8) {
            PassageLineText(line: line, showsTranslation: showsTranslation || selected, showsReading: showsReading || selected,
                            voiceLabel: voices.label(for: line.id))
            Spacer(minLength: 8)
            if !line.original.isEmpty {
                KeepLyricButton(entry: page.quote(sourceLine))
                    .opacity(hoveredLine == line.id || selected ? 1 : 0.45)
            }
            if [line.original, line.translation, line.reading, line.background].compactMap({ $0 }).contains(where: { !$0.isEmpty }) {
                // The found line can go straight into a songbook, keeping its version and line number.
                LyricBookOffer(label: "收录这句", title: page.entry.title, compact: true) {
                    [.init(page: page, source: target.source, excerpt: sourceLine)]
                }
                .buttonStyle(.plain).menuStyle(.borderlessButton).fixedSize()
                .opacity(hoveredLine == line.id || selected ? 1 : 0)
                .allowsHitTesting(hoveredLine == line.id || selected)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(WorkspacePalette.selection.opacity(selected ? 1 : partOfExcerpt ? 0.5 : 0), in: RoundedRectangle(cornerRadius: 7))
        .onHover { inside in
            if inside { hoveredLine = line.id } else if hoveredLine == line.id { hoveredLine = nil }
        }
        .contextMenu {
            if !line.original.isEmpty {
                Button("从这句接下去", systemImage: "text.bubble") { startRecall(page, anchor: line.id) }
            }
            if [line.original, line.translation, line.reading, line.background].compactMap({ $0 }).contains(where: { !$0.isEmpty }) {
                LyricBookOffer(label: "收录这句", title: page.entry.title) { [.init(page: page, source: target.source, excerpt: sourceLine)] }
            }
        }
    }

    private func load() async {
        let target = self.target
        let switched = editionSelection?.origin == initialTarget
        loadedTarget = nil
        recordedPosition = nil
        scrollRequest = nil
        topLine = nil
        failure = nil
        page = nil
        selectingExcerpt = false
        recall = nil
        recallNotice = nil
        returnedLine = nil
        find = target.readingPosition?.find ?? target.find
        matches = []
        cursor = 0
        do {
            let loaded = try await library.readPassage(target, recordOpening: false, includeEditions: true)
            try Task.checkCancellation()
            if let loaded, !loaded.lines.isEmpty {
                if case .reading = target.source { showsReading = true }
                voices = PassageVoicePresentation(lines: loaded.lines)
                page = loaded
                loadedTarget = target
                let savedPosition = target.savedQuote?.originalVersionID == loaded.originalVersionID
                    && loaded.matchesOriginalVersion ? target.lineIndex : nil
                let restored = switched && !loaded.matchesOriginalVersion ? nil : target.readingPosition
                let preferred = restored != nil ? restored?.lineIndex
                    : (target.savedQuote == nil ? target.lineIndex : savedPosition)
                updateMatches(preferred: preferred)
                if let preferred, loaded.lines.contains(where: { $0.id == preferred }) {
                    returnedLine = preferred
                }
                if let top = restored?.topLineIndex, loaded.lines.contains(where: { $0.id == top }) {
                    scrollToLine(top, restoreTop: true)
                } else {
                    scrollToLine(visibleFocus)
                }
                rememberPosition()
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
        recall = LyricRecallSession(lines: voices.visibleLines(in: page.lines),
                                    anchor: anchor.map { voices.visibleID(for: $0) })
        if recall != nil { recallNotice = nil }
        else if let anchor, page.lines.first(where: { $0.id == anchor })?.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            recallNotice = "这行只有译文，可以从另一句原词开始。"
        } else { recallNotice = "这句后面已经没有原词了。" }
    }

    private func updateMatches(preferred: Int? = nil) {
        let term = find.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = term.isEmpty ? [] : page.map { voices.visibleLines(in: $0.lines).filter { $0.matches(term) }.map(\.id) } ?? []
        cursor = preferred.flatMap { matches.firstIndex(of: voices.visibleID(for: $0)) } ?? 0
    }

    private func changeFind(_ text: String) {
        find = text
        returnedLine = nil
        updateMatches()
        scrollToLine(visibleFocus)
        rememberPosition()
    }

    private func scrollToLine(_ id: Int?, restoreTop: Bool = false) {
        guard let id else { return }
        topLine = nil
        scrollRequest = .init(line: voices.visibleID(for: id), restoreTop: restoreTop)
    }

    private func rememberPosition() {
        guard let page, loadedTarget == target, recordedPosition != readingPosition else { return }
        recordedPosition = readingPosition
        library.rememberReading(page, openedFrom: target, position: readingPosition)
    }

    private func move(_ offset: Int) {
        guard !matches.isEmpty else { return }
        returnedLine = nil
        cursor = (cursor + offset + matches.count) % matches.count
        scrollToLine(visibleFocus)
        rememberPosition()
    }
}

struct PassageLineText: View {
    let line: LibraryPassagePage.Line
    let showsTranslation: Bool
    let showsReading: Bool
    var voiceLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let voiceLabel { PassageVoiceLabel(text: voiceLabel) }
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

struct PassageVoiceLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}
