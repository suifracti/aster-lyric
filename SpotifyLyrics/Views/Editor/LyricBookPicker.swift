import SwiftUI

struct LyricBookPicker: View {
    private enum Source { case archive, quotes }
    private struct MatchedVersion {
        let page: LibraryPassagePage
        let source: LibraryPassageSource
        let matches: [LibraryPassagePage.Line]
        let voices: PassageVoicePresentation
    }
    let library: PersonalLyricsLibraryService
    let collected: Set<LibraryPassageTarget>
    let add: (LyricBook.Chapter) -> Void
    @ObservedObject private var favorites = V3FavoriteLines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.archive
    @State private var query = ""
    @State private var songs: [LibraryPassageHit] = []
    @State private var loadedTerm: String?
    @State private var returnToSong: String?
    @State private var preview: MatchedVersion?
    @State private var excerptAnchor: Int?
    @State private var additions: Set<LibraryPassageTarget> = []
    @State private var loading = false
    @State private var adding: Task<Void, Never>?
    @State private var failure: String?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleSongs: [LibraryPassageHit] { loadedTerm == term ? songs : [] }
    private var quotes: [V3FavoriteLines.Entry] {
        guard !term.isEmpty else { return favorites.entries }
        return favorites.entries.filter { [$0.text, $0.translation ?? "", $0.title, $0.artist].contains { $0.localizedStandardContains(term) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview, let excerptAnchor {
                LyricBookExcerptPicker(page: preview.page, source: preview.source, initialLine: excerptAnchor,
                    backTitle: "返回命中歌词", back: { self.excerptAnchor = nil }, isCollected: isCollected, add: collect)
            } else if let preview { matchedVersion(preview) }
            else { sourceBrowser }
            HStack {
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if adding != nil { ProgressView().controlSize(.small).accessibilityLabel("读取版本") }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 416, height: 390)
        .padding(17)
        .background(WorkspacePalette.paper)
        .task(id: (source == .archive ? "archive:" : "quotes:") + term) {
            if source == .archive { await search(term) }
        }
        .onDisappear { adding?.cancel() }
    }

    private var sourceBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收进歌本").font(.headline)
                Spacer()
                Picker("来自", selection: $source) {
                    Text("歌词库").tag(Source.archive)
                    Text("金句").tag(Source.quotes)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(source == .archive ? "查找歌曲或已存歌词" : "查找收藏的金句", text: $query).textFieldStyle(.plain)
            }
            .padding(8).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            Group {
                if source == .archive, loading, visibleSongs.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if source == .archive ? visibleSongs.isEmpty : quotes.isEmpty {
                    Text(term.isEmpty ? (source == .archive ? "歌词库还没有可收录的版本" : "还没有收藏金句") : "没有找到匹配内容")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                if source == .archive {
                                    ForEach(visibleSongs) { hit in
                                        let target = hit.readingTarget(for: term)
                                        let origin = LibraryPassageTarget(trackKey: target.trackKey, source: target.source)
                                        let information = [hit.entry.artist, hit.source?.label, hit.excerpt].compactMap { $0 }
                                            .filter { !$0.isEmpty }.joined(separator: " · ")
                                        HStack(spacing: 2) {
                                            row(hit.entry.title, subtitle: information, symbol: "music.note",
                                                origin: hit.source == nil ? origin : nil) {
                                                loadSong(origin, matching: hit.source == nil ? nil : term)
                                            }
                                            if hit.source == nil {
                                                Button { loadSong(origin, matching: term, opensExcerpt: true) } label: {
                                                    Image(systemName: "scissors").padding(6)
                                                }
                                                .buttonStyle(.borderless).disabled(adding != nil)
                                                .help("从这首歌选一段").accessibilityLabel("从\(hit.entry.title)选一段")
                                            }
                                        }
                                        .id(hit.id)
                                    }
                                } else {
                                    ForEach(quotes) { quote in
                                        row(quote.text, subtitle: [quote.title, quote.artist].filter { !$0.isEmpty }.joined(separator: " · "),
                                            symbol: "quote.opening", origin: quote.passage) {
                                            add(.init(quote: quote))
                                            additions.insert(quote.passage)
                                        }
                                    }
                                }
                            }
                        }
                        .task(id: returnToSong) {
                            guard let id = returnToSong else { return }
                            await Task.yield()
                            if !Task.isCancelled { scroll.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func matchedVersion(_ version: MatchedVersion) -> some View {
        let page = version.page
        let origin = LyricBook.Chapter.origin(for: page, source: version.source)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                preview = nil
            } label: { Label("返回搜索结果", systemImage: "chevron.left") }
                .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.entry.title).font(.headline).lineLimit(2)
                    Text([page.entry.artist, page.edition].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button("选一段") { excerptAnchor = version.matches.first?.id ?? page.lines.first?.id }
                Button(isCollected(origin) ? "已收录整首" : "收录整首") { collect(version) }
                    .disabled(isCollected(origin))
            }
            Divider()
            if version.matches.isEmpty {
                Text("没有可单独收录的匹配行，可以收录整首。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(version.matches) { line in
                            let label = "第 \(line.id + 1) 行"
                            let origin = LyricBook.Chapter.origin(for: page, source: version.source, excerpt: line)
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text([label, line.startTime.map(v3EdgeTimeText)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    PassageLineText(line: line, showsTranslation: true, showsReading: true,
                                                    voiceLabel: version.voices.label(for: line.id))
                                    Button("从这句选一段") { excerptAnchor = line.id }
                                        .buttonStyle(.borderless).font(.caption)
                                        .accessibilityLabel("从\(label)选一段")
                                }
                                Spacer(minLength: 4)
                                Button(isCollected(origin) ? "已收录" : "收录这句") { collect(version, line: line) }
                                    .disabled(isCollected(origin))
                                    .accessibilityLabel(isCollected(origin) ? "已收录\(label)" : "收录\(label)")
                            }
                        }
                    }.padding(.horizontal, 2).padding(.vertical, 5)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func collect(_ version: MatchedVersion, line: LibraryPassagePage.Line? = nil) {
        collect(.init(page: version.page, source: version.source, excerpt: line))
    }

    private func collect(_ chapter: LyricBook.Chapter) {
        add(chapter)
        additions.insert(chapter.origin)
    }

    private func isCollected(_ origin: LibraryPassageTarget) -> Bool {
        collected.contains(origin) || additions.contains(origin)
    }

    private func row(_ title: String, subtitle: String, symbol: String, origin: LibraryPassageTarget?,
                     perform: @escaping () -> Void) -> some View {
        let alreadyCollected = origin.map(isCollected) ?? false
        return Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(WorkspacePalette.ink).frame(width: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(2)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 3)
                Image(systemName: origin == nil ? "chevron.right" : alreadyCollected ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(WorkspacePalette.ink)
            }
            .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyCollected || adding != nil)
        .accessibilityLabel(origin == nil ? "查看 \(title) 的命中歌词" : alreadyCollected ? "已收录 \(title)" : "收录 \(title)")
    }

    private func search(_ term: String) async {
        songs = []
        loadedTerm = nil
        returnToSong = nil
        failure = nil
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            if !term.isEmpty { try await Task.sleep(for: .milliseconds(155)) }
            let hits = try await library.bookSources(matching: term)
            try Task.checkCancellation()
            songs = hits
            loadedTerm = term
        } catch is CancellationError {} catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func loadSong(_ origin: LibraryPassageTarget, matching term: String?, opensExcerpt: Bool = false) {
        guard adding == nil else { return }
        failure = nil
        adding = Task {
            defer { adding = nil }
            do {
                guard let page = try await library.readPassage(origin, recordOpening: false), !page.lines.isEmpty else {
                    failure = "这份版本里没有可收录的歌词。"
                    return
                }
                try Task.checkCancellation()
                if let term {
                    guard source == .archive, self.term == term else { return }
                    let voices = PassageVoicePresentation(lines: page.lines)
                    let matches = voices.visibleLines(in: page.lines).filter { $0.matches(term) }
                    returnToSong = origin.trackKey
                    preview = .init(page: page, source: origin.source, matches: matches, voices: voices)
                    if opensExcerpt { excerptAnchor = matches.first?.id ?? page.lines.first?.id }
                } else {
                    let chapter = LyricBook.Chapter(page: page, source: origin.source)
                    add(chapter)
                    additions.formUnion([origin, chapter.origin])
                }
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}

/// Select two endpoints in one saved edition. The preview and the resulting
/// chapter use the same visible rows, while the source keeps its original IDs.
struct LyricBookExcerptPicker: View {
    let page: LibraryPassagePage
    let source: LibraryPassageSource
    let backTitle: String
    let back: () -> Void
    let isCollected: (LibraryPassageTarget) -> Bool
    let add: ((LyricBook.Chapter) -> Void)?

    private let voices: PassageVoicePresentation
    private let rows: [LibraryPassagePage.Line]
    private let initialLine: Int?
    @State private var start: Int?
    @State private var end: Int?

    init(page: LibraryPassagePage, source: LibraryPassageSource, initialLine: Int?,
         backTitle: String, back: @escaping () -> Void,
         isCollected: @escaping (LibraryPassageTarget) -> Bool = { _ in false }, add: ((LyricBook.Chapter) -> Void)? = nil) {
        self.page = page
        self.source = source
        self.backTitle = backTitle
        self.back = back
        self.isCollected = isCollected
        self.add = add
        let voices = PassageVoicePresentation(lines: page.lines)
        self.voices = voices
        rows = voices.visibleLines(in: page.lines)
        let selected = initialLine.map { voices.visibleID(for: $0) }
        self.initialLine = selected
        _start = State(initialValue: selected)
    }

    private var bounds: ClosedRange<Int>? {
        start.map { min($0, end ?? $0)...max($0, end ?? $0) }
    }

    var body: some View {
        let range = bounds
        let chapter = end == nil ? nil : range.flatMap { LyricBook.Chapter(page: page, source: source, range: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            Button(action: back) { Label(backTitle, systemImage: "chevron.left") }
                .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.entry.title).font(.headline).lineLimit(1)
                    Text(instruction(range)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if start != nil {
                    Button("重新选") { start = nil; end = nil }.buttonStyle(.borderless)
                }
                if let chapter, let add {
                    let collected = isCollected(chapter.origin)
                    Button(collected ? "已收录" : "收录这段") { add(chapter) }.disabled(collected)
                } else if let chapter {
                    LyricBookOffer(label: "收录这段", title: page.entry.title) { [chapter] }
                }
            }
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { line in
                            let selected = range?.contains(line.id) == true
                            Button { select(line.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(line.id + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                    PassageLineText(line: line, showsTranslation: true, showsReading: true,
                                                    voiceLabel: voices.label(for: line.id))
                                    Spacer(minLength: 0)
                                }
                                .padding(7).contentShape(Rectangle())
                                .background(selected ? WorkspacePalette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain).id(line.id)
                            .accessibilityLabel("第 \(line.id + 1) 行，\(line.original.isEmpty ? line.translation ?? line.reading ?? "" : line.original)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .task {
                    guard let initialLine else { return }
                    await Task.yield()
                    if !Task.isCancelled { scroll.scrollTo(initialLine, anchor: .center) }
                }
            }
        }
    }

    private func instruction(_ range: ClosedRange<Int>?) -> String {
        guard let range else { return "点选起始行" }
        guard end != nil else { return "已选第 \(range.lowerBound + 1) 行，再点另一行" }
        return "第 \(range.lowerBound + 1)–\(range.upperBound + 1) 行"
    }

    private func select(_ id: Int) {
        if let start, end == nil {
            if start != id { end = id }
        } else {
            start = id
            end = nil
        }
    }
}
