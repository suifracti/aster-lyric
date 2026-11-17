import SwiftUI

struct LibraryVersionCompareView: View {
    let request: LibraryCompareRequest
    let library: PersonalLyricsLibraryService
    let edit: (LibraryTranslationRevisionDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var peerID: UUID
    @State private var comparison: LibraryVersionComparison?
    @State private var issue: String?
    @State private var onlyDifferences = true
    @State private var focusedRow: Int?
    @State private var picks: [UUID: Set<Int>] = [:]
    @State private var preparing = false

    init(request: LibraryCompareRequest, library: PersonalLyricsLibraryService, edit: @escaping (LibraryTranslationRevisionDraft) -> Void) {
        self.request = request
        self.library = library
        self.edit = edit
        _peerID = State(initialValue: request.firstReference)
    }

    private var reference: LibraryCompareVersion? { request.references.first { $0.id == peerID } }
    private var translations: Bool { request.base.translation != nil }
    private var selected: Set<Int> { picks[peerID] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(translations ? "译文对读" : "原词对读", systemImage: "rectangle.split.2x1")
                        .font(.callout.weight(.medium)).foregroundStyle(WorkspacePalette.ink)
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text(request.entry.title).font(.system(size: 25, weight: .semibold, design: .serif)).textSelection(.enabled)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("底稿").font(.caption).foregroundStyle(.secondary)
                        Text(request.base.title).font(.headline).lineLimit(2)
                        Text(metadata(request.base)).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("参照稿").font(.caption).foregroundStyle(.secondary)
                        Menu {
                            Picker("参照稿", selection: $peerID) {
                                ForEach(request.references) { version in
                                    Text("\(version.title) · \(metadata(version))").tag(version.id)
                                }
                            }.pickerStyle(.inline)
                        } label: { Text(reference?.title ?? "选择版本").font(.headline).lineLimit(2) }
                        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).disabled(preparing)
                        if let reference { Text(metadata(reference)).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
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
        .frame(minWidth: 450, idealWidth: 730, minHeight: 390, idealHeight: 560)
        .background(WorkspacePalette.paper)
        .task(id: peerID) {
            comparison = nil
            issue = nil
            focusedRow = nil
            guard let reference else { return }
            do {
                let loaded = try await library.compare(request, with: reference)
                try Task.checkCancellation()
                comparison = loaded
            } catch where !Task.isCancelled { issue = error.localizedDescription }
            catch { }
        }
    }

    private func pages(_ comparison: LibraryVersionComparison) -> some View {
        let differences = comparison.rows.filter { $0.change != .same }
        let visible = onlyDifferences ? differences : comparison.rows
        return ScrollViewReader { proxy in
            HStack(spacing: 10) {
                Text("\(differences.count) 处不同").font(.caption.monospacedDigit())
                Spacer()
                Toggle("只看不同", isOn: $onlyDifferences).toggleStyle(.checkbox).controlSize(.small)
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
                                rowView(row, wide: bounds.size.width >= 620, canPick: comparison.canPickTranslationLines)
                                    .id(row.id)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func rowView(_ row: LibraryVersionComparison.Row, wide: Bool, canPick: Bool) -> some View {
        let sameOriginalText = row.base?.original == row.reference?.original
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.change.rawValue).font(.caption.weight(.semibold)).foregroundStyle(WorkspacePalette.ink)
                if translations, sameOriginalText, let source = row.base?.original, !source.isEmpty {
                    Text(source).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if canPick, let base = row.base, let reference = row.reference,
                   (base.translation ?? "") != (reference.translation ?? "") {
                    Button {
                        if selected.contains(base.id) { picks[peerID, default: []].remove(base.id) }
                        else { picks[peerID, default: []].insert(base.id) }
                    } label: {
                        Label(selected.contains(base.id) ? "已选这句" : "选这句",
                              systemImage: selected.contains(base.id) ? "checkmark.circle.fill" : "arrow.left.circle")
                    }.controlSize(.small).disabled(preparing)
                    .help("把参照稿的这一句带入译文编辑")
                }
            }
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            layout {
                column(row.base, comparedWith: row.reference, title: "底稿", label: !wide, showOriginal: !sameOriginalText, change: row.change)
                column(row.reference, comparedWith: row.base, title: "参照", label: !wide, showOriginal: !sameOriginalText, change: row.change)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 20)
        .background(focusedRow == row.id ? WorkspacePalette.selection : .clear)
    }

    private func column(_ line: LibraryPassagePage.Line?, comparedWith other: LibraryPassagePage.Line?, title: String, label: Bool, showOriginal: Bool,
                        change: LibraryVersionComparison.Change) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if label { Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading) }
            VStack(alignment: .leading, spacing: 4) {
                if let line {
                    if translations {
                        if showOriginal, !line.original.isEmpty { Text(line.original).font(.caption).foregroundStyle(.secondary) }
                        if let text = line.translation, !text.isEmpty {
                            Text(marked(text, against: other?.translation)).font(.system(size: 16, design: .serif))
                        } else { Text("此句暂无译文").font(.callout).foregroundStyle(.secondary) }
                    } else {
                        if change == .text, let other {
                            Text(marked(line.original, against: other.original)).font(.system(size: 17, weight: .medium, design: .serif))
                        } else { PassageLineText(line: line, showsTranslation: change == .layer, showsReading: change == .layer) }
                        if change == .timing {
                            Text([line.startTime, line.endTime].compactMap { $0 }.map(Self.time).joined(separator: " – "))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let spans = line.timedSpans, !spans.isEmpty {
                                DisclosureGroup("\(spans.count) 段逐字时间") {
                                    Text(spans.map { "\($0.text) \(Self.time($0.startTime))–\(Self.time($0.endTime))" }.joined(separator: "  ·  "))
                                }.font(.caption)
                            }
                        }
                    }
                } else { Text("—").foregroundStyle(.tertiary).accessibilityLabel("这一稿没有对应行") }
            }.textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func marked(_ text: String, against other: String?) -> AttributedString {
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

    private static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1000 else { return "—" }
        let ms = Int64((seconds * 1000).rounded())
        return String(format: "%lld:%02lld.%03lld", ms / 60_000, ms / 1000 % 60, ms % 1000)
    }

    private func metadata(_ version: LibraryCompareVersion) -> String {
        let tag = version.translation?.targetLanguage
        let language = tag.flatMap { $0 == "und" ? nil : Locale(identifier: "zh_CN").localizedString(forIdentifier: $0) ?? $0 }
        return [version.isCurrent ? "使用中" : nil, language, v3ShortDateText(version.updatedAt)].compactMap { $0 }.joined(separator: " · ")
    }

    private func jump(_ step: Int, _ differences: [LibraryVersionComparison.Row], _ proxy: ScrollViewProxy) {
        guard !differences.isEmpty else { return }
        let old = differences.firstIndex { $0.id == focusedRow } ?? (step > 0 ? -1 : 0)
        let next = differences[(old + step + differences.count) % differences.count].id
        focusedRow = next
        proxy.scrollTo(next, anchor: .center)
    }

    private func prepareDraft() {
        guard !preparing, let base = request.base.translation, let reference = reference?.translation else { return }
        let indices = selected
        preparing = true
        Task {
            defer { preparing = false }
            do {
                let draft = try await library.translationDraft(for: base, entry: request.entry, picking: indices, from: reference)
                if library.comparison?.id == request.id { edit(draft) }
            } catch { issue = error.localizedDescription }
        }
    }
}
