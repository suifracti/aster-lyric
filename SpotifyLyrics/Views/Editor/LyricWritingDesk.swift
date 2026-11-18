import SwiftUI
import UniformTypeIdentifiers

extension LyricManuscript: FileDocument {
    static let manuscriptType = UTType(exportedAs: "com.suifracti.aster-lyric.manuscript", conformingTo: .text)
    static let readableContentTypes = [manuscriptType]

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadUnsupportedScheme) }
        self = try Self(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct LyricWritingDesk: View {
    private enum Mode { case writing, arrange, read }
    @Binding var draft: LyricManuscript
    var fileURL: URL?
    @StateObject private var library = PersonalLyricsLibraryService()
    @Environment(\.openSettings) private var openSettings
    @FocusState private var editingText: Bool
    @State private var preview: LocalLyricsFile?
    @State private var mode = Mode.writing
    @State private var pendingFile: LocalLyricsFile?
    @State private var filing = false
    @State private var error: String?
    @State private var showsAlbum = false

    private var title: String { draft.title.isEmpty ? fileURL?.deletingPathExtension().lastPathComponent ?? "" : draft.title }
    private var hasText: Bool { draft.text.contains(where: { !$0.isWhitespace }) }
    private var lastFiled: LibraryPassageTarget? {
        guard let trackKey = draft.recordingKey, let id = draft.filedVersionID else { return nil }
        return LibraryPassageTarget(trackKey: trackKey, source: .original(id))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("歌词手稿", systemImage: "pencil.and.outline")
                    .font(.callout.weight(.medium)).foregroundStyle(WorkspacePalette.ink)
                Spacer()
                Picker("手稿视图", selection: Binding(get: { mode }, set: { next in
                    if next == .read { prepare { preview = $0; mode = .read } }
                    else { mode = next; preview = nil; editingText = next == .writing }
                })) {
                    Text("写作").tag(Mode.writing)
                    Text("编排").tag(Mode.arrange)
                    Text("阅读").tag(Mode.read)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(!hasText && mode == .writing)
            }
            .padding(.horizontal, 22).frame(height: 42)
            Divider()
            if mode == .read, let preview {
                LyricFileReader(file: preview, name: title, library: library, preferredRecording: draft.recordingKey, onFiled: didFile)
            } else if mode == .arrange {
                ManuscriptArrangementView(text: $draft.text)
            } else { writing }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 400, minHeight: 355)
        .background(WorkspacePalette.paper)
        .onAppear { if draft.text.isEmpty { editingText = true } }
        .sheet(isPresented: $filing) {
            if let pendingFile {
                LyricFileFilingSheet(file: pendingFile, title: pendingFile.content.title.flatMap { $0.isEmpty ? nil : $0 } ?? title,
                                     library: library, preferredRecording: draft.recordingKey) { target in
                    didFile(target)
                    filing = false
                }
            }
        }
    }

    private var writing: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("歌名", text: $draft.title)
                    .font(.system(size: 32, weight: .semibold, design: .serif)).accessibilityLabel("手稿歌名")
                HStack(spacing: 8) {
                    Image(systemName: "person").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("歌手（选填）", text: $draft.artist).accessibilityLabel("手稿歌手")
                    if showsAlbum || !draft.album.isEmpty {
                        Image(systemName: "opticaldisc").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("专辑（选填）", text: $draft.album).accessibilityLabel("手稿专辑")
                    } else {
                        Button("添加专辑") { showsAlbum = true }.buttonStyle(.borderless).foregroundStyle(WorkspacePalette.ink)
                    }
                }.font(.callout)
                Rectangle().fill(WorkspacePalette.ink.opacity(0.6)).frame(height: 1).padding(.top, 8)
            }
            .textFieldStyle(.plain).padding(.top, 24)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.text)
                    .font(.system(size: 18, design: .serif)).lineSpacing(7)
                    .scrollContentBackground(.hidden).focused($editingText)
                    .accessibilityLabel("歌词正文")
                if draft.text.isEmpty {
                    Text("写下一句，或把歌词粘贴到这里。")
                        .font(.system(size: 18, design: .serif)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(.top, 16).padding(.leading, -5)
        }
        .frame(maxWidth: 680).padding(.horizontal, 30).frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Text("\(draft.text.split(whereSeparator: \.isNewline).count) 行")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let lastFiled {
                        Button("阅读已存稿") {
                            SettingsNavigationRoute.shared.requestedLocation = .init(reading: lastFiled)
                            openSettings()
                        }.buttonStyle(.borderless)
                    }
                    Button {
                        prepare { file in pendingFile = file; filing = true }
                    } label: {
                        Label("存入歌词库…", systemImage: "tray.and.arrow.down")
                    }.buttonStyle(.borderedProminent).tint(WorkspacePalette.ink).disabled(!hasText)
                }.padding(.horizontal, 20).frame(height: 46)
            }.background(WorkspacePalette.paper)
        }
    }

    private func prepare(_ action: (LocalLyricsFile) -> Void) {
        do { let file = try draft.lyricFile(); error = nil; action(file) }
        catch { self.error = error.localizedDescription }
    }

    private func didFile(_ target: LibraryPassageTarget) {
        guard case let .original(id) = target.source else { return }
        var linked = draft
        linked.recordingKey = target.trackKey
        linked.filedVersionID = id
        draft = linked
    }
}

struct ManuscriptArrangementView: View {
    @Binding var text: String

    var body: some View {
        let arrangement = ManuscriptStanzas(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("段落编排").font(.system(size: 27, weight: .semibold, design: .serif))
                    Spacer()
                    Text("共 \(arrangement.stanzas.count) 段").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
                if arrangement.stanzas.count < 2 {
                    Text("在写作页空一行，就可以把两段分开移动。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(arrangement.stanzas.indices, id: \.self) { index in
                    let stanza = arrangement.stanzas[index]
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").font(.system(.title3, design: .serif)).foregroundStyle(WorkspacePalette.ink)
                            .frame(minWidth: 20, alignment: .leading).accessibilityLabel("第 \(index + 1) 段")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(stanza.lines.first.map(String.init) ?? "").font(.system(.headline, design: .serif)).lineLimit(2)
                            if stanza.lines.count > 1 {
                                Text(stanza.lines.dropFirst().prefix(2).joined(separator: "\n")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(stanza.firstOccurrence == index ? "\(stanza.lines.count) 行" : "与第 \(stanza.firstOccurrence + 1) 段相同")
                                .font(.caption2).foregroundStyle(WorkspacePalette.ink)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button("上移一段", systemImage: "arrow.up") {
                                if let moved = arrangement.moving(index, by: -1) { text = moved }
                            }.disabled(index == 0)
                            Button("下移一段", systemImage: "arrow.down") {
                                if let moved = arrangement.moving(index, by: 1) { text = moved }
                            }.disabled(index + 1 == arrangement.stanzas.count)
                            Divider()
                            Button("在结尾再用这段", systemImage: "repeat") {
                                if let repeated = arrangement.repeatingAtEnd(index) { text = repeated }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("编排第 \(index + 1) 段")
                        .accessibilityLabel("编排第 \(index + 1) 段")
                    }
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .frame(maxWidth: 620).padding(24).frame(maxWidth: .infinity)
        }
    }
}
