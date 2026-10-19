import SwiftUI

struct ReadingVersionEditorView: View {
    @ObservedObject var state: PlaybackState
    let version: StoredReadingVersion
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String]
    @State private var saving = false
    @State private var error = ""

    private var changedLineCount: Int {
        version.lines.enumerated().filter { index, line in
            !line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && drafts.indices.contains(index)
                && drafts[index] != (line.readingText ?? "")
        }.count
    }

    private var sourceIsCurrent: Bool {
        !state.isShowingSearchPreview && state.liveLyricsVersionID == version.record.lyricsVersionID
    }

    private var canSave: Bool { !saving && sourceIsCurrent && changedLineCount > 0 }

    init(state: PlaybackState, version: StoredReadingVersion) {
        self.state = state
        self.version = version
        _drafts = State(initialValue: version.lines.map { $0.readingText ?? "" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("编辑读音")
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                if state.hasLiveTrack {
                    Text("\(state.currentTrack.title) · \(state.currentTrack.artist)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text("保存后采用新的人工读音版本，原版本保留。原文、翻译与时间轴保持不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("表示 · \(ReadingRepresentationID(rawValue: version.record.representationID)?.displayName ?? "读音")")
                if version.record.isLocked {
                    Label("原版本已锁定", systemImage: "lock.fill")
                }
                Spacer()
                Text(changedLineCount == 0 ? "尚未修改" : "已修改 \(changedLineCount) 行")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !sourceIsCurrent {
                Label("当前歌词已变化。请关闭后重新打开对应版本。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            List {
                ForEach(Array(version.lines.enumerated()), id: \.element.lineIndex) { index, line in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(line.originalText.isEmpty ? "（空行）" : line.originalText)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                        }
                        TextField("读音", text: Binding(
                            get: { drafts.indices.contains(index) ? drafts[index] : "" },
                            set: { if drafts.indices.contains(index) { drafts[index] = $0 } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(saving || !sourceIsCurrent || line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .disabled(saving)
                    .keyboardShortcut(.cancelAction)
                if saving { ProgressView().controlSize(.small) }
                Button("保存并采用新版本") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard canSave else { return }
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

private struct ReadingRecordMark: View {
    var body: some View {
        VStack(spacing: 3) {
            Capsule().frame(width: 16, height: 2)
            Capsule().frame(width: 11, height: 2).frame(width: 16, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// Reference identity is stable in SwiftUI's environment, unlike a closure.
/// Updating its target keeps correction actions current without relaying out tokens.
final class RubyCorrectionAction: Equatable {
    var action: ((String, String) -> Void)?
    static func == (lhs: RubyCorrectionAction, rhs: RubyCorrectionAction) -> Bool { lhs === rhs }
    func callAsFunction(_ surface: String, _ reading: String) { action?(surface, reading) }
}

struct RubyCorrectionActionKey: EnvironmentKey {
    static let defaultValue: RubyCorrectionAction? = nil
}
extension EnvironmentValues {
    var rubyCorrectionAction: RubyCorrectionAction? {
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
            VStack(alignment: .leading, spacing: 5) {
                Text("修改「\(request.surface)」的读音")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                if state.hasLiveTrack {
                    Text("\(state.currentTrack.title) · \(state.currentTrack.artist)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TextField("假名，例如：からだ", text: $draft)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { save() }
                .disabled(saving)
            Text("仅记住这首歌中这个词的读法。保存为新的人工版本，原版保留；假名和罗马音同步更新。")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.disabled(saving)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存为新版本") { save() }
                    .buttonStyle(.borderedProminent).disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 380)
        .interactiveDismissDisabled(saving)
        .onAppear { focused = true }
    }
    private func save() {
        let reading = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving, !reading.isEmpty else { return }
        saving = true
        error = ""
        Task { @MainActor in
            do {
                try await state.readingSession.correctRuby(surface: request.surface, reading: reading,
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
