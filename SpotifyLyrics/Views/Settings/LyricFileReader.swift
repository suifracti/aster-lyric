import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricFileDocument: FileDocument {
    static let lrcType = UTType(importedAs: "com.suifracti.aster-lyric.lrc", conformingTo: .plainText)
    static let ttmlType = UTType(importedAs: "com.suifracti.aster-lyric.ttml", conformingTo: .xml)
    static let readableContentTypes: [UTType] = [lrcType, ttmlType, .plainText]
    static let writableContentTypes: [UTType] = []
    let revision = UUID()
    let data: Data
    let kind: LocalLyricsFileKind

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadUnsupportedScheme) }
        self.data = data
        let name = configuration.file.preferredFilename ?? configuration.file.filename ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        kind = LocalLyricsFileKind(rawValue: ext) ?? (configuration.contentType == Self.ttmlType ? .ttml :
            configuration.contentType == Self.lrcType ? .lrc : .txt)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }

    @MainActor static func choose(multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.message = "打开本地歌词"
        panel.allowedContentTypes = readableContentTypes
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Standard document windows open from Finder, the File menu, and drops on the workspace.
struct LyricDocumentWindow: View {
    let document: LyricFileDocument
    let url: URL?
    @EnvironmentObject private var settings: AppSettingsStore
    @StateObject private var library = PersonalLyricsLibraryService()
    @State private var file: LocalLyricsFile?
    @State private var error: String?
    private struct ReadRequest: Hashable {
        let revision: UUID
        let language: String
    }

    var body: some View {
        Group {
            if let file {
                LyricFileReader(file: file, name: url?.lastPathComponent ?? "", library: library, sourceURL: url)
            } else if let error {
                ContentUnavailableView("歌词文件无法读取", systemImage: "doc.text", description: Text(error))
            } else { ProgressView("正在读歌词") }
        }
        .frame(minWidth: 400, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.paper)
        .task(id: ReadRequest(revision: document.revision, language: settings.aiTranslationConfiguration.targetLanguage)) {
            file = nil
            error = nil
            let language = settings.aiTranslationConfiguration.targetLanguage
            let data = document.data
            let kind = url.flatMap { LocalLyricsFileKind(rawValue: $0.pathExtension.lowercased()) } ?? document.kind
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try LocalLyricsFile(data: data, kind: kind, preferredLanguage: language)
                }.value
                try Task.checkCancellation()
                file = parsed
                error = nil
            } catch where !Task.isCancelled { self.error = error.localizedDescription }
            catch { }
        }
    }
}

struct LyricFileReader: View {
    let file: LocalLyricsFile
    let name: String
    let library: PersonalLyricsLibraryService
    var sourceURL: URL?
    var destination: PersonalLyricsLibraryEntry?
    var close: (() -> Void)?
    @Environment(\.openSettings) private var openSettings
    @State private var filing = false
    @State private var filed: LibraryPassageTarget?
    @State private var saving = false
    @State private var error: String?
    @State private var showsReading = true
    @State private var showsTranslation = true
    @State private var chosenLanguage: String?
    private var language: String? {
        if let chosenLanguage, file.translationLanguages.contains(chosenLanguage) { return chosenLanguage }
        return file.initialTranslationLanguage
    }
    @State private var find = ""
    @State private var finding = false
    @State private var matchIndex = 0
    @FocusState private var focusedFind: Bool

    private var title: String {
        if let title = file.content.title, !title.isEmpty { return title }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? "歌词文件" : stem
    }

    private var timing: String {
        if file.content.hasTimedSpans { return "逐字时间" }
        if file.content.isSynchronized { return "逐行同步" }
        return file.content.explicitlyTimedLineIndices == nil ? "自由阅读" : "部分有时间"
    }

    private var matches: [Int] {
        guard !find.isEmpty else { return [] }
        return file.lines.indices.filter { passageLine($0).matches(find) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text").foregroundStyle(WorkspacePalette.ink)
                    Text(file.kind.rawValue.uppercased()).font(.caption.monospaced().weight(.semibold))
                    Text(timing).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { finding.toggle(); focusedFind = finding } label: { Image(systemName: "magnifyingglass") }
                        .keyboardShortcut("f").accessibilityLabel("在文件中查找").help("在文件中查找")
                    if !file.translationLanguages.isEmpty || file.lines.contains(where: { $0.translationText != nil || $0.romajiText != nil || $0.kanaText != nil }) {
                        Menu {
                            if file.translationLanguages.count > 1 {
                                Picker("译文语言", selection: Binding(get: { language ?? "und" }, set: { value in
                                    chosenLanguage = value
                                    showsTranslation = true
                                    matchIndex = 0
                                })) {
                                    ForEach(file.translationLanguages, id: \.self) { tag in
                                        Text(LyricSourceTranslation.displayName(tag)).tag(tag)
                                    }
                                }.pickerStyle(.inline)
                                Divider()
                            }
                            Toggle("显示译文", isOn: $showsTranslation)
                            Toggle("显示读音", isOn: $showsReading)
                        } label: {
                            if file.translationLanguages.count > 1, let language {
                                Label(LyricSourceTranslation.displayName(language), systemImage: "character.book.closed")
                            } else { Label("阅读图层", systemImage: "textformat.size") }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    if let close { Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("关闭文件") }
                }
                .buttonStyle(.borderless).padding(.horizontal, 22).frame(height: 40)
                if finding {
                    HStack {
                        TextField("在原词、翻译和读音中查找", text: $find).textFieldStyle(.plain).focused($focusedFind)
                            .onSubmit { moveMatch(1, proxy) }
                        Text(find.isEmpty ? "" : matches.isEmpty ? "无匹配" : "\(matchIndex + 1)/\(matches.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { moveMatch(-1, proxy) } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel("上一处").disabled(matches.isEmpty)
                        Button { moveMatch(1, proxy) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("下一处").disabled(matches.isEmpty)
                    }
                    .buttonStyle(.borderless).padding(.horizontal, 22).padding(.bottom, 8)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 33, weight: .semibold, design: .serif))
                            .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                        let byline = [file.content.artist, file.content.album].compactMap { $0 }.filter { !$0.isEmpty }
                        if !byline.isEmpty {
                            Text(byline.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        Rectangle().fill(WorkspacePalette.ink.opacity(0.55)).frame(height: 1).padding(.vertical, 18)
                        let results = finding ? matches : []
                        let current = results.indices.contains(matchIndex) ? results[matchIndex] : nil
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(file.lines.indices, id: \.self) { index in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    if file.content.isSynchronized || file.content.explicitlyTimedLineIndices != nil {
                                        Text(file.content.lineHasExplicitTiming(index) ? v3EdgeTimeText(file.lines[index].timestamp) : "")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(minWidth: 30, alignment: .trailing)
                                    }
                                    PassageLineText(line: passageLine(index), showsTranslation: showsTranslation || index == current,
                                                    showsReading: showsReading || index == current)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                                .background(index == current ? WorkspacePalette.selection : .clear)
                                .id(index)
                            }
                        }
                    }
                    .padding(.horizontal, 29).padding(.vertical, 22)
                    .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: find) { _, _ in
                    matchIndex = 0
                    if let first = matches.first { proxy.scrollTo(first, anchor: .center) }
                }
                Divider()
                HStack(spacing: 12) {
                    Text(error ?? "\(file.lines.filter { !$0.originalText.isEmpty }.count) 行歌词")
                        .font(.caption).foregroundStyle(error == nil ? Color.secondary : .red)
                    Spacer(minLength: 0)
                    PortableLyricsExportMenu(sourceURL: sourceURL) {
                        PortableLyricsEdition(document: file.viewing(language).content, title: title, originalSource: "manualImport",
                                              originalLocked: file.locked, translationLanguage: language, translationSource: "providerEmbedded")
                    }
                    if let filed {
                        Button("阅读已存版本") {
                            SettingsNavigationRoute.shared.requestedLocation = .init(reading: filed)
                            close?()
                            openSettings()
                        }
                    } else {
                        Button {
                            if let destination { fileWith(destination) }
                            else { filing = true }
                        } label: {
                            Label(destination.map { "存入《\($0.title)》" } ?? "存入歌词库…", systemImage: "tray.and.arrow.down")
                                .lineLimit(1)
                        }.buttonStyle(.borderedProminent).tint(WorkspacePalette.ink).disabled(saving)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .background(WorkspacePalette.paper)
        .sheet(isPresented: $filing) {
            LyricFileFilingSheet(file: file.viewing(language), title: title, library: library) { target in
                filed = target
                filing = false
            }
        }
    }

    private func passageLine(_ index: Int) -> LibraryPassagePage.Line {
        let line = file.lines[index]
        let reading = [line.kanaText, line.romajiText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let translation: String?
        if let language { translation = line.sourceTranslation(in: language) }
        else { translation = line.translationText }
        return .init(id: index, original: line.originalText, translation: translation,
                     reading: reading.isEmpty ? nil : reading, background: line.backgroundText)
    }

    private func moveMatch(_ delta: Int, _ proxy: ScrollViewProxy) {
        let options = matches
        guard !options.isEmpty else { return }
        matchIndex = (matchIndex + delta + options.count) % options.count
        proxy.scrollTo(options[matchIndex], anchor: .center)
    }

    private func fileWith(_ entry: PersonalLyricsLibraryEntry) {
        saving = true
        Task {
            defer { saving = false }
            do { filed = try await library.fileLyrics(file.viewing(language), with: entry.libraryTrack, archiveKey: entry.trackStableKey); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// A save panel belongs to the edition that opened it, including read-only files.
struct PortableLyricsExportMenu: View {
    var sourceURL: URL?
    var edition: () -> PortableLyricsEdition

    var body: some View {
        Menu {
            PortableLyricsExportItems(edition: edition(), sourceURL: sourceURL)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("导出这份歌词").help("导出这份歌词")
    }
}

struct PortableLyricsExportItems: View {
    let edition: PortableLyricsEdition
    var sourceURL: URL?
    var onSaved: ((URL) -> Void)?

    var body: some View {
        ForEach(edition.formats) { format in
            Button(format.label) { save(format) }
        }
    }

    private func save(_ format: PortableLyricsFormat) {
        let panel = NSSavePanel()
        panel.title = "导出这份歌词"
        panel.nameFieldStringValue = edition.filename(for: format)
        if let sourceURL { panel.directoryURL = sourceURL.deletingLastPathComponent() }
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let sourceURL, url.resolvingSymlinksInPath().standardizedFileURL == sourceURL.resolvingSymlinksInPath().standardizedFileURL {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                              userInfo: [NSLocalizedDescriptionKey: "请为副本选一个新文件名，保留打开的原文件。"])
            }
            try edition.contents(format).write(to: url, atomically: true, encoding: .utf8)
            onSaved?(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct LyricFileFilingSheet: View {
    let file: LocalLyricsFile
    let library: PersonalLyricsLibraryService
    let finished: (LibraryPassageTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [DatabaseTrackRecord] = []
    @State private var query: String
    @State private var newRecord = false
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var chosen: String?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    init(file: LocalLyricsFile, title: String, library: PersonalLyricsLibraryService,
         finished: @escaping (LibraryPassageTarget) -> Void) {
        self.file = file
        self.library = library
        self.finished = finished
        _title = State(initialValue: title)
        _query = State(initialValue: title)
        _artist = State(initialValue: file.content.artist ?? "")
        _album = State(initialValue: file.content.album ?? "")
    }

    private var results: [DatabaseTrackRecord] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return records.filter { row in
            let text = [row.title, row.artistDisplay, row.album].joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }

    private var draft: Track {
        Track(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
              artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
              album: album.trimmingCharacters(in: .whitespacesAndNewlines),
              duration: file.kind == .lrc ? file.content.duration ?? 0 : 0)
    }

    private var existing: DatabaseTrackRecord? {
        if newRecord {
            let key = TrackIdentity(track: draft).stableKey
            return records.first { $0.stableKey == key }
        }
        return results.first { $0.stableKey == chosen }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("收进哪一份档案？").font(.system(size: 24, weight: .semibold, design: .serif))
            Picker("存入位置", selection: $newRecord) {
                Text("已有录音").tag(false)
                Text("本机新档案").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if newRecord {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow { Text("歌名"); TextField("歌名", text: $title) }
                    GridRow { Text("歌手"); TextField("选填", text: $artist) }
                    GridRow { Text("专辑"); TextField("选填", text: $album) }
                }.textFieldStyle(.roundedBorder)
                if existing != nil {
                    Text("相同录音已有本机档案，这份歌词将作为独立版本存入。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("找歌名、歌手或专辑", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if results.isEmpty {
                    ContentUnavailableView("没有匹配的本地录音", systemImage: "music.note.list",
                        description: Text("换个词搜索，或为这份歌词建立档案。"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results, id: \.stableKey) { row in
                                Button { chosen = row.stableKey } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(row.title).font(.headline)
                                            Text([row.artistDisplay, row.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }.lineLimit(1)
                                        Spacer(minLength: 8)
                                        if row.duration > 0 { Text(v3EdgeTimeText(row.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                        Image(systemName: chosen == row.stableKey ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(WorkspacePalette.ink)
                                    }
                                    .padding(8).background(chosen == row.stableKey ? WorkspacePalette.selection : .clear,
                                                          in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .accessibilityAddTraits(chosen == row.stableKey ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            Divider()
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("原有版本和采用状态都会保留。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("存入") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || loading || (newRecord ? draft.title.isEmpty : existing == nil))
            }
        }
        .padding(20).frame(minWidth: 410, idealWidth: 465, minHeight: 360, idealHeight: 400)
        .background(WorkspacePalette.paper)
        .task {
            do {
                records = try await library.fileDestinations()
                if records.isEmpty { newRecord = true }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func save() {
        let record = existing
        guard let track = record?.libraryTrack ?? (newRecord ? draft : nil), !track.title.isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do { finished(try await library.fileLyrics(file, with: track, archiveKey: record?.stableKey)) }
            catch { self.error = error.localizedDescription }
        }
    }
}
