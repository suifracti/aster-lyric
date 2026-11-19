import SwiftUI

struct LibraryVersionCompareView: View {
    let request: LibraryCompareRequest
    let library: PersonalLyricsLibraryService
    let edit: (LibraryTranslationRevisionDraft) -> Void
    let adopt: ((UUID) -> Void)?
    let close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var baseID: UUID
    @State private var peerID: UUID
    private struct Pair: Hashable { let base: UUID; let peer: UUID }
    @State private var comparison: LibraryVersionComparison?
    @State private var issue: String?
    @State private var onlyDifferences = true
    @State private var focusedRow: Int?
    @State private var picks: [Pair: Set<Int>] = [:]
    @State private var preparing = false
    @State private var alignedVersions: [LibraryCompareVersion] = []
    @State private var alignmentRequest: UUID?
    @State private var alignmentMessage: String?

    init(request: LibraryCompareRequest, library: PersonalLyricsLibraryService, adopt: ((UUID) -> Void)? = nil,
         close: (() -> Void)? = nil,
         edit: @escaping (LibraryTranslationRevisionDraft) -> Void) {
        self.request = request
        self.library = library
        self.edit = edit
        self.adopt = adopt
        self.close = close
        _baseID = State(initialValue: request.base.id)
        _peerID = State(initialValue: request.firstReference)
    }

    private var versions: [LibraryCompareVersion] { [request.base] + request.references + alignedVersions }
    private var base: LibraryCompareVersion { versions.first { $0.id == baseID } ?? request.base }
    private var reference: LibraryCompareVersion? { versions.first { $0.id == peerID } }
    private var pair: Pair { Pair(base: baseID, peer: peerID) }
    private var selected: Set<Int> { picks[pair] ?? [] }

    private func readingRow(in comparison: LibraryVersionComparison) -> LibraryVersionComparison.Row? {
        request.readingRow(in: comparison, baseID: baseID, referenceID: peerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if close == nil {
                    HStack {
                        Text("对比译文").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button("关闭") { dismiss() }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    }
                }
                Text(request.entry.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(alignment: .top, spacing: 14) {
                    versionPicker("底稿", version: base, selection: Binding(get: { baseID }, set: { newID in
                        if newID == peerID { peerID = baseID }
                        baseID = newID
                    }))
                    Divider()
                    if let reference {
                        versionPicker("参照稿", version: reference, selection: Binding(get: { peerID }, set: { newID in
                            if newID == baseID { baseID = peerID }
                            peerID = newID
                        }))
                    }
                }.fixedSize(horizontal: false, vertical: true)
                if let alignmentMessage {
                    Text(alignmentMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if let comparison { pages(comparison) }
            else if let issue {
                ContentUnavailableView("无法打开这两份稿", systemImage: "doc.text.magnifyingglass", description: Text(issue))
            } else { ProgressView("正在打开两个版本").frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let comparison, comparison.canPickTranslationLines && !selected.isEmpty {
                Divider()
                HStack {
                    if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
                    else { Text("已从参照稿选了 \(selected.count) 句").font(.callout) }
                    Spacer()
                    Button("带入译文编辑…") { prepareDraft() }.buttonStyle(.borderedProminent).disabled(preparing)
                }.padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.paper)
        .tint(WorkspacePalette.ink)
        .onExitCommand { if let close { close() } else { dismiss() } }
        .task(id: alignmentRequest) {
            guard let alignmentRequest,
                  let option = versions.first(where: { $0.id == alignmentRequest }),
                  let version = option.translation else { return }
            let usesBase = baseID == alignmentRequest
            alignmentMessage = "正在按词源时间对齐…"
            defer { self.alignmentRequest = nil }
            do {
                let aligned = try await library.realignSourceTranslation(version, entry: request.entry)
                try Task.checkCancellation()
                if !versions.contains(where: { $0.id == aligned.id }) { alignedVersions.append(aligned) }
                if usesBase { baseID = aligned.id } else { peerID = aligned.id }
                alignmentMessage = "已保存对齐版，可对比或使用其中的译文"
            } catch where !Task.isCancelled {
                alignmentMessage = error.localizedDescription
            } catch { }
        }
        .task(id: pair) {
            comparison = nil
            issue = nil
            focusedRow = nil
            guard let reference else { return }
            do {
                let loaded = try await library.compare(trackKey: request.entry.trackStableKey, base: base, with: reference)
                try Task.checkCancellation()
                if let row = readingRow(in: loaded) {
                    focusedRow = row.id
                    if row.change == .same { onlyDifferences = false }
                }
                comparison = loaded
            } catch where !Task.isCancelled { issue = error.localizedDescription }
            catch { }
        }
    }

    private func versionPicker(_ role: String, version: LibraryCompareVersion, selection: Binding<UUID>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role).font(.caption).foregroundStyle(.secondary)
            Menu {
                Picker(role, selection: selection) {
                    ForEach(versions) { item in Text("\(item.title) · \(metadata(item))").tag(item.id) }
                }.pickerStyle(.inline)
            } label: { Text(version.title).font(.callout.weight(.semibold)).lineLimit(2).foregroundStyle(.primary) }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).disabled(preparing || alignmentRequest != nil)
            .accessibilityLabel("选择" + role)
            Text(metadata(version)).font(.caption).foregroundStyle(.secondary)
            HStack {
                if let playing = request.playing, let adopt, playing.adoptable.contains(version.id), !version.isCurrent {
                    Button("采用" + role) { adopt(version.id) }.disabled(preparing || alignmentRequest != nil)
                }
                if version.canRealignSource {
                    Button("重新对齐词源译文") { alignmentRequest = version.id }
                        .disabled(preparing || alignmentRequest != nil)
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pages(_ comparison: LibraryVersionComparison) -> some View {
        let differences = comparison.rows.filter { $0.change != .same }
        let visible = onlyDifferences ? differences : comparison.rows
        let reading = readingRow(in: comparison)
        return ScrollViewReader { proxy in
            HStack(spacing: 10) {
                Text("\(differences.count) 处不同").font(.caption.monospacedDigit())
                Spacer()
                Toggle("只看不同", isOn: $onlyDifferences).toggleStyle(.checkbox).controlSize(.small)
                Button("末句") {
                    guard let last = comparison.rows.last(where: { row in
                        !(row.base?.original ?? row.reference?.original ?? "").isEmpty
                    }) else { return }
                    if last.change == .same { onlyDifferences = false }
                    focusedRow = last.id
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }.help("跳到全歌最后一句")
                Button { jump(-1, differences, proxy) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("上一处不同").disabled(differences.isEmpty)
                Button { jump(1, differences, proxy) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("下一处不同").disabled(differences.isEmpty)
            }.buttonStyle(.borderless).padding(.horizontal, 20).frame(height: 34)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView("这两份稿相同", systemImage: "text.alignleft",
                    description: Text("关闭「只看不同」可以阅读全文。"))
            } else {
                GeometryReader { bounds in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { row in
                                rowView(row, wide: bounds.size.width >= 570, canPick: comparison.canPickTranslationLines,
                                        isReadingRow: row.id == reading?.id)
                                    .id(row.id)
                                Divider()
                            }
                        }
                    }
                }
                .task(id: pair) {
                    guard let reading, !onlyDifferences || reading.change != .same else { return }
                    await Task.yield()
                    if !Task.isCancelled { proxy.scrollTo(reading.id, anchor: .center) }
                }
            }
        }
    }

    private func rowView(_ row: LibraryVersionComparison.Row, wide: Bool, canPick: Bool, isReadingRow: Bool) -> some View {
        let sameOriginalText = row.baseLines.count == 1 && row.referenceLines.count == 1 &&
            row.base?.original == row.reference?.original
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isReadingRow {
                    Label("刚才阅读", systemImage: "bookmark").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(((row.base ?? row.reference)?.id ?? 0) + 1)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if sameOriginalText, let source = row.base?.original, !source.isEmpty {
                    Text(source).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if canPick, let base = row.base, let reference = row.reference,
                   !suspectCredit(reference, version: self.reference),
                   (base.translation ?? "") != (reference.translation ?? "") {
                    let choice = (reference.translation ?? "").isEmpty ? "选参照稿的空白" : "选参照稿这句"
                    Toggle(choice, isOn: Binding(get: { selected.contains(base.id) }, set: { on in
                        if on { picks[pair, default: []].insert(base.id) }
                        else { picks[pair, default: []].remove(base.id) }
                    })).toggleStyle(.checkbox).controlSize(.small).disabled(preparing)
                    .help("把参照稿的这一句带入译文编辑")
                }
            }
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            layout {
                column(row.baseLines, version: base, title: "底稿", label: !wide,
                       showOriginal: !sameOriginalText, voice: row.baseVoice)
                column(row.referenceLines, version: reference, title: "参照", label: !wide,
                       showOriginal: !sameOriginalText, voice: row.referenceVoice)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 20)
        .background(focusedRow == row.id ? WorkspacePalette.selection.opacity(0.55) : .clear)
    }

    private func column(_ lines: [LibraryPassagePage.Line], version: LibraryCompareVersion?,
                        title: String, label: Bool, showOriginal: Bool, voice: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if label { Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading) }
            VStack(alignment: .leading, spacing: 8) {
                if let voice { PassageVoiceLabel(text: voice) }
                if lines.isEmpty { Text("—").foregroundStyle(.tertiary).accessibilityLabel("这一稿没有对应行") }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        if showOriginal, !line.original.isEmpty { Text(line.original).font(.caption).foregroundStyle(.secondary) }
                        if let text = line.translation, !text.isEmpty {
                            Text(text).font(.system(size: 17)).foregroundStyle(.primary.opacity(0.87))
                            if suspectCredit(line, version: version) {
                                Label("词源译文可能对错行", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("此句暂无译文").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }.textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suspectCredit(_ line: LibraryPassagePage.Line, version: LibraryCompareVersion?) -> Bool {
        guard version?.translation?.sourceKind == AITranslationSourceKind.providerEmbedded.rawValue,
              LyricsCreditOnly.isCredit(line.original), let translation = line.translation, !translation.isEmpty else { return false }
        return !LyricsCreditOnly.isCredit(translation)
    }

    private func metadata(_ version: LibraryCompareVersion) -> String {
        let tag = version.translation?.targetLanguage
        let language = tag.flatMap { $0 == "und" ? nil : Locale(identifier: "zh_CN").localizedString(forIdentifier: $0) ?? $0 }
        let state = version.translation
        return [version.isCurrent ? "使用中" : nil, state?.isLocked == true ? "已锁定" : nil,
                state?.isArchived == true ? "已归档" : nil, language, v3ShortDateText(version.updatedAt)].compactMap { $0 }.joined(separator: " · ")
    }

    private func jump(_ step: Int, _ differences: [LibraryVersionComparison.Row], _ proxy: ScrollViewProxy) {
        guard !differences.isEmpty else { return }
        let old = differences.firstIndex { $0.id == focusedRow } ?? (step > 0 ? -1 : 0)
        let next = differences[(old + step + differences.count) % differences.count].id
        focusedRow = next
        proxy.scrollTo(next, anchor: .center)
    }

    private func prepareDraft() {
        guard !preparing, let base = base.translation, let reference = reference?.translation else { return }
        let indices = selected
        let focusedLine = comparison?.rows.first { $0.id == focusedRow }?.base?.id
        let openingLine = focusedLine.flatMap { indices.contains($0) ? $0 : nil } ?? indices.min()
        preparing = true
        Task {
            defer { preparing = false }
            do {
                let draft = try await library.translationDraft(for: base, entry: request.entry, picking: indices,
                                                               from: reference, openingLineIndex: openingLine)
                if library.comparison?.id == request.id { edit(draft) }
            } catch { issue = error.localizedDescription }
        }
    }
}

private enum LibraryDifferenceText {
    static func marked(_ text: String, against other: String?) -> AttributedString {
        guard let other, !other.isEmpty else { return AttributedString(text) }
        let changed = LibraryVersionComparison.changedCharacters(in: text, comparedWith: other)
        guard !changed.isEmpty, changed.count < text.count else { return AttributedString(text) }
        var result = AttributedString(), run = "", marking = false
        func flush() {
            var piece = AttributedString(run)
            if marking { piece.backgroundColor = WorkspacePalette.selection; piece.underlineStyle = .single }
            result += piece
            run = ""
        }
        for (index, char) in text.enumerated() {
            let shouldMark = changed.contains(index)
            if marking != shouldMark { flush(); marking = shouldMark }
            run.append(char)
        }
        flush()
        return result
    }
}

struct LibraryMultiCompareView: View {
    typealias Edition = LibraryVersionsWorkspace.Edition
    typealias Difference = LibraryOriginalComparison.Difference

    let editions: [Edition]
    let track: PersonalLyricsLibraryEntry
    let library: PersonalLyricsLibraryService
    let initialComparison: LibraryCompareRequest?
    let back: () -> Void

    @State private var preferredBase: Edition.ID?
    @State private var alignment: LibraryVersionComparison.Alignment = .text
    @State private var differences = Set(Difference.allCases)
    @State private var onlyDifferences = true
    @State private var focusedRow: Int?
    @State private var comparison: LibraryOriginalComparison?
    @State private var loadedKey: ComparisonKey?
    @State private var cachedPages: [Edition.ID: LibraryPassagePage] = [:]
    @State private var issue: String?

    private var ordered: [Edition] {
        guard let preferredBase, let base = editions.first(where: { $0.id == preferredBase }) else { return editions }
        return [base] + editions.filter { $0.id != preferredBase }
    }

    private var allowsTime: Bool { editions.count >= 2 && editions.allSatisfy { $0.timing != "纯文本" } }
    private var effectiveAlignment: LibraryVersionComparison.Alignment {
        alignment == .time && !allowsTime ? .text : alignment
    }

    private struct ComparisonKey: Hashable {
        let ids: [Edition.ID]
        let alignment: LibraryVersionComparison.Alignment
    }

    private var key: ComparisonKey { .init(ids: ordered.map(\.id), alignment: effectiveAlignment) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("返回预览", systemImage: "chevron.left", action: back)
                    .buttonStyle(.plain).foregroundStyle(WorkspacePalette.ink)
                Spacer()
                if let first = ordered.first {
                    Menu {
                        ForEach(editions) { edition in
                            Button(edition.title + " · " + edition.timing) { preferredBase = edition.id }
                        }
                    } label: {
                        Text("底稿 · " + first.title).lineLimit(1)
                    }
                    .accessibilityLabel("选择底稿")
                    .menuStyle(.borderlessButton)
                }
                Menu {
                    ForEach(LibraryVersionComparison.Alignment.allCases) { mode in
                        Button(mode == .time && !allowsTime ? "按时间（各版本都需要时间轴）" : mode.rawValue) {
                            alignment = mode
                        }.disabled(mode == .time && !allowsTime)
                    }
                } label: {
                    Label(effectiveAlignment.rawValue, systemImage: "line.3.horizontal")
                }
                .fixedSize().menuStyle(.borderlessButton)
                .accessibilityLabel("对齐方式")
            }
            .padding(.horizontal, 16).frame(height: 42)
            Divider()
            if editions.count < 2 {
                ContentUnavailableView("勾选至少两个版本", systemImage: "rectangle.split.2x1")
            } else if let comparison, loadedKey == key {
                grid(comparison)
            } else if let issue {
                ContentUnavailableView("无法打开所选版本", systemImage: "doc.text.magnifyingglass", description: Text(issue))
            } else {
                ProgressView("正在对齐所选版本").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) { await loadComparison() }
    }

    private func loadComparison() async {
        comparison = nil
        issue = nil
        focusedRow = nil
        let selection = ordered
        let mode = effectiveAlignment
        let requestKey = key
        guard selection.count >= 2 else { return }
        do {
            var pages: [LibraryPassagePage] = []
            for edition in selection {
                let page: LibraryPassagePage
                if let cached = cachedPages[edition.id] {
                    page = cached
                } else {
                    page = try await edition.loadPage(track: track, library: library)
                    try Task.checkCancellation()
                    cachedPages[edition.id] = page
                }
                pages.append(page)
            }
            let lines = pages.map(\.lines)
            let loaded = await Task.detached(priority: .userInitiated) {
                LibraryOriginalComparison(editions: lines, alignment: mode)
            }.value
            try Task.checkCancellation()
            if let row = readingRow(in: loaded) {
                focusedRow = row.id
                if !row.differs(in: differences) { onlyDifferences = false }
            }
            comparison = loaded
            loadedKey = requestKey
        } catch where !Task.isCancelled {
            issue = error.localizedDescription
        } catch { }
    }

    private func readingRow(in comparison: LibraryOriginalComparison) -> LibraryOriginalComparison.Row? {
        for (column, edition) in ordered.enumerated() {
            guard case .saved(let id) = edition.id, let index = initialComparison?.readingLine(for: id) else { continue }
            return comparison.rows.first { $0.lines[column].contains { $0.id == index } }
        }
        return nil
    }

    private func grid(_ comparison: LibraryOriginalComparison) -> some View {
        let changed = comparison.rows.filter { $0.differs(in: differences) }
        let visible = onlyDifferences ? changed : comparison.rows
        let columns = ordered
        return ScrollViewReader { proxy in
            HStack(spacing: 10) {
                Text("\(changed.count) 处不同").font(.caption.monospacedDigit())
                Menu {
                    ForEach(Difference.allCases) { kind in
                        Toggle(kind.rawValue, isOn: Binding(get: { differences.contains(kind) }, set: { on in
                            if on { differences.insert(kind) }
                            else if differences.count > 1 { differences.remove(kind) }
                        }))
                    }
                } label: {
                    Text(differences.count == Difference.allCases.count ? "全部差异" :
                         Difference.allCases.filter { differences.contains($0) }.map(\.rawValue).joined(separator: "、"))
                }.fixedSize().menuStyle(.borderlessButton)
                Spacer()
                Toggle("只看不同", isOn: $onlyDifferences).toggleStyle(.checkbox)
                Button { jump(-1, in: changed, proxy: proxy) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("上一处不同").disabled(changed.isEmpty)
                Button { jump(1, in: changed, proxy: proxy) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("下一处不同").disabled(changed.isEmpty)
            }
            .buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 36)
            Divider()
            GeometryReader { bounds in
                let width = max(200, (bounds.size.width - 2) / CGFloat(columns.count))
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(visible) { row in
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(columns.indices, id: \.self) { index in
                                        let group = row.lines[index]
                                        let peer = index == 0
                                            ? row.lines.dropFirst().first { !$0.isEmpty && $0.map(\.original) != group.map(\.original) }
                                            : row.lines.first
                                        comparisonCell(group, voices: row.voiceLabels[index], against: peer ?? [])
                                            .frame(width: width, alignment: .topLeading)
                                    }
                                }
                                .background(focusedRow == row.id ? WorkspacePalette.selection : .clear)
                                .id(row.id)
                                Divider()
                            }
                        } header: {
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(Array(columns.enumerated()), id: \.element.id) { index, edition in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(edition.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        Text((index == 0 ? "底稿 · " : "") + edition.timing)
                                            .font(.caption.weight(.medium)).foregroundStyle(WorkspacePalette.ink)
                                            .help(LibraryLineTiming.explanation(edition.timing))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12).frame(width: width, alignment: .leading)
                                }
                            }
                            .background(WorkspacePalette.paper)
                            .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView("所选项目没有差异", systemImage: "checkmark.circle")
                    }
                }
            }
            .task(id: key) {
                guard let row = readingRow(in: comparison) else { return }
                await Task.yield()
                if !Task.isCancelled { proxy.scrollTo(row.id, anchor: .center) }
            }
        }
    }

    private func comparisonCell(_ lines: [LibraryPassagePage.Line], voices: [String?],
                                against peer: [LibraryPassagePage.Line]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if lines.isEmpty {
                Text("—").foregroundStyle(.tertiary).accessibilityLabel("这一稿没有对应行")
            }
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                VStack(alignment: .leading, spacing: 5) {
                    if differences.contains(.timing) {
                        LibraryLineTiming(start: line.startTime, end: line.endTime, spans: line.timedSpans)
                    }
                    let showLayers = differences.contains(.layers)
                    let highlight = differences.contains(.text) && lines.count == peer.count
                        ? LibraryDifferenceText.marked(line.original, against: peer[index].original) : nil
                    PassageLineText(line: line, showsTranslation: showLayers, showsReading: showLayers,
                                    voiceLabel: showLayers ? voices[index] : nil, markedOriginal: highlight)
                    if showLayers, let romanization = line.romanization, romanization != line.reading {
                        Text(romanization).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func jump(_ step: Int, in rows: [LibraryOriginalComparison.Row], proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == focusedRow } ?? (step > 0 ? -1 : 0)
        let next = rows[(current + step + rows.count) % rows.count].id
        focusedRow = next
        proxy.scrollTo(next, anchor: .center)
    }
}

extension LibraryVersionsWorkspace.Edition {
    @MainActor func loadPage(track: PersonalLyricsLibraryEntry, library: PersonalLyricsLibraryService) async throws -> LibraryPassagePage {
        switch self {
        case .saved(let version, _, _):
            guard let page = try await library.readPassage(.init(trackKey: track.trackStableKey, source: .original(version.id)),
                                                           recordOpening: false) else {
                throw LyricsEditingRepositoryError.sourceNotFound
            }
            return page
        case .candidate(let candidate):
            let document = candidate.makeDocument()
            return LibraryPassagePage(entry: track, originalVersionID: UUID(), edition: title,
                lines: document.lines.enumerated().map { index, line in
                    .init(id: index, original: line.originalText, translation: line.translationText,
                          reading: line.kanaText, background: line.backgroundText,
                          startTime: document.isSynchronized ? line.timestamp : nil, endTime: line.endTime,
                          timedSpans: line.hasValidTimedSpans(lineStartIsMeaningful: document.isSynchronized) ? line.timedSpans : nil,
                          performerID: line.performerID, romanization: line.romajiText)
                }, matchesOriginalVersion: false, language: document.language)
        }
    }
}

struct LibrarySavedVersionPreview: View {
    let edition: LibraryVersionsWorkspace.Edition
    let track: PersonalLyricsLibraryEntry
    let library: PersonalLyricsLibraryService
    @State private var page: LibraryPassagePage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(edition.title).font(.headline)
            Text(LibraryLineTiming.explanation(edition.timing)).font(.caption).foregroundStyle(.secondary)
            Divider()
            if let page {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(page.lines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                LibraryLineTiming(start: line.startTime, end: line.endTime, spans: line.timedSpans)
                                PassageLineText(line: line, showsTranslation: true, showsReading: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            } else if failed {
                ContentUnavailableView("无法预览这份稿", systemImage: "doc.text.magnifyingglass")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(16)
        .task {
            do { page = try await edition.loadPage(track: track, library: library) }
            catch where !Task.isCancelled { failed = true }
            catch { }
        }
    }
}

struct LibraryLineTiming: View {
    let start: TimeInterval?
    let end: TimeInterval?
    let spans: [TimedTextSpan]?

    static func explanation(_ timing: String) -> String {
        switch timing {
        case "逐字": return "逐字 · 字词会随演唱进度依次高亮"
        case "逐行": return "逐行 · 随演唱切换整句高亮"
        default: return "纯文本 · 没有同步时间"
        }
    }

    var body: some View {
        if let start {
            let time = [start, end].compactMap { $0 }.map(Self.timestamp).joined(separator: "–")
            if let spans, !spans.isEmpty {
                DisclosureGroup("\(time) · 逐字 \(spans.count) 段") {
                    Text(spans.map { "\($0.text) \(Self.timestamp($0.startTime))–\(Self.timestamp($0.endTime))" }
                        .joined(separator: "  ·  "))
                        .textSelection(.enabled)
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1000 else { return "—" }
        let ms = Int64((seconds * 1000).rounded())
        return String(format: "%lld:%02lld.%03lld", ms / 60_000, ms / 1000 % 60, ms % 1000)
    }
}
