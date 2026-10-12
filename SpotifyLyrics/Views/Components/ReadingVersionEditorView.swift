import SwiftUI

struct ReadingVersionEditorView: View {
    @ObservedObject var state: PlaybackState
    let version: StoredReadingVersion
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String]
    @State private var saving = false
    @State private var error = ""

    init(state: PlaybackState, version: StoredReadingVersion) {
        self.state = state
        self.version = version
        _drafts = State(initialValue: version.lines.map { $0.readingText ?? "" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑读音")
                .font(.title3.weight(.semibold))
            Text("保存会创建新的人工读音版本，不覆盖 \(version.record.engineID)。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            List {
                ForEach(Array(version.lines.enumerated()), id: \.element.lineIndex) { index, line in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(line.originalText.isEmpty ? "（空行）" : line.originalText)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        TextField("读音", text: Binding(
                            get: { drafts.indices.contains(index) ? drafts[index] : "" },
                            set: { if drafts.indices.contains(index) { drafts[index] = $0 } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(saving)
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .disabled(saving)
                if saving { ProgressView().controlSize(.small) }
                Button("另存为人工版本") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = ""
        let edited = ReadingManualEdit.lines(from: version.lines, drafts: drafts)
        Task { @MainActor in
            do {
                try await state.readingSession.saveManualEdit(version, readingLines: edited)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

struct RubyCorrectionActionKey: EnvironmentKey {
    static let defaultValue: ((String, String) -> Void)? = nil
}
extension EnvironmentValues {
    var rubyCorrectionAction: ((String, String) -> Void)? {
        get { self[RubyCorrectionActionKey.self] }
        set { self[RubyCorrectionActionKey.self] = newValue }
    }
}
struct RubyCorrectionRequest: Identifiable {
    let id = UUID()
    let surface: String
    let reading: String
    let trackKey: String
    let lyricsVersionID: UUID
    let readingVersionID: UUID?
    let lines: [LyricLine]
}
struct RubyCorrectionEditorView: View {
    @ObservedObject var state: PlaybackState
    let request: RubyCorrectionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var saving = false
    @State private var error = ""
    @FocusState private var focused: Bool

    init(state: PlaybackState, request: RubyCorrectionRequest) {
        self.state = state
        self.request = request
        _draft = State(initialValue: request.reading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改「\(request.surface)」的读音").font(.headline)
            TextField("假名，例如：からだ", text: $draft)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { save() }
                .disabled(saving)
            Text("仅记住这首歌中这个词的读法。保存为新的人工版本，原版保留；假名和罗马音同步更新。")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存读音") { save() }
                    .buttonStyle(.borderedProminent).disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 380)
        .interactiveDismissDisabled(saving)
        .onAppear { focused = true }
    }
    private func save() {
        guard !saving else { return }
        saving = true
        error = ""
        Task { @MainActor in
            do {
                try await state.readingSession.correctRuby(surface: request.surface, reading: draft,
                    trackKey: request.trackKey, lyricsVersionID: request.lyricsVersionID, visibleLines: request.lines,
                    expectedReadingVersionID: request.readingVersionID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
