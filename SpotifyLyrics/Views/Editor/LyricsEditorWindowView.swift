import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorWindowView: View {
    @EnvironmentObject private var state: PlaybackState
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var focusedLineID: UUID?
    @State private var isShowingLyricsOffset = false

    private var editor: LyricsEditorSessionController { state.lyricsEditor }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let preview = editor.pendingTranslationPaste {
                translationPastePreview(preview)
            } else if let preview = editor.pendingTextImport {
                textImportPreview(preview)
            } else if let preview = editor.pendingImport {
                importPreview(preview)
            } else if let draft = editor.draft {
                editorBody(draft)
            } else {
                ContentUnavailableView("没有可编辑的歌词版本", systemImage: "music.note.list", description: Text("请先在主窗口加载一首歌曲的歌词。"))
            }
            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 620)
        .preferredColorScheme(.dark)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if editor.draft == nil { state.prepareLyricsEditorForOpening() }
            // Partial-save confirmation (AppKit alert; no second session).
            editor.confirmPartialSave = { timed, untimed in
                let alert = NSAlert()
                alert.messageText = "保存部分时间轴？"
                alert.informativeText = "已排 \(timed) 行，仍有 \(untimed) 行未排。不会把未排行伪装成完整同步歌词。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "保存部分时间轴")
                alert.addButton(withTitle: "取消")
                return alert.runModal() == .alertFirstButtonReturn
            }
            editor.confirmTimingLoss = { summary in
                let alert = NSAlert()
                alert.messageText = "保存将丢失部分逐字时间"
                alert.informativeText = summary.confirmationMessage
                alert.alertStyle = .warning
                alert.addButton(withTitle: "确认并保存兼容部分")
                alert.addButton(withTitle: "取消")
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
        .focusable()
        .onKeyPress(.space) {
            markFocusedLineAtCurrentTime(advance: editor.assistAutoAdvance)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "nN")) { _ in
            jumpToNextUntimed()
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveFocus(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(delta: 1)
            return .handled
        }
        .onKeyPress(keys: [.init("z")]) { press in
            if press.modifiers.contains(.command) && press.modifiers.contains(.shift) {
                editor.redo()
                return .handled
            }
            if press.modifiers.contains(.command) {
                editor.undo()
                return .handled
            }
            return .ignored
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("歌词编辑")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(LyricsDesignTokens.primaryText)
                    let title = editor.draft?.title ?? (editor.draft?.identity == nil ? "" : state.currentTrack.title)
                    if !title.isEmpty {
                        Text("·")
                            .foregroundStyle(LyricsDesignTokens.mutedText)
                        Text(title)
                            .font(.headline.weight(.medium))
                            .foregroundStyle(LyricsDesignTokens.primaryText)
                            .lineLimit(1)
                    }
                }
                let artistText = editor.draft?.artist ?? (editor.draft?.identity == nil ? "未关联播放曲目" : state.currentTrack.artist)
                Text(artistText)
                    .font(.caption)
                    .foregroundStyle(LyricsDesignTokens.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            versionPicker
            translationPicker
            Button {
                isShowingLyricsOffset = true
            } label: {
                if let versionID = editor.selectedSavedLyricsOffsetVersionID {
                    Label("偏移 · \(versionID.uuidString.prefix(8))", systemImage: "clock.arrow.2.circlepath")
                } else {
                    Label("歌词偏移", systemImage: "clock.arrow.2.circlepath")
                }
            }
            .help(editor.lyricsOffsetDisabledReason ?? "调整所选已保存歌词版本的展示偏移")
            .popover(isPresented: $isShowingLyricsOffset) {
                LyricsPresentationOffsetControl(
                    settings: settings,
                    target: .savedVersion(
                        scope: editor.persistentLyricsOffsetScope,
                        versionID: editor.selectedSavedLyricsOffsetVersionID,
                        disabledReason: editor.lyricsOffsetDisabledReason
                    )
                )
                .padding(16)
                .frame(width: 360)
            }
            Menu("粘贴", systemImage: "doc.on.clipboard") {
                Button("作为翻译") { pasteTranslation(target: .translation) }
                Button("作为原文") { pasteTranslation(target: .original) }
                Divider()
                Button("作为新歌词版本") { pasteText() }
            }
            Button("导入 TXT", systemImage: "doc.text") { importTXT() }
            Button("导入 LRC", systemImage: "square.and.arrow.down") { importLRC() }
            Button("导出原文", systemImage: "square.and.arrow.up") { exportOriginal() }
            Button("导出翻译", systemImage: "text.badge.plus") { exportTranslation() }
            Button("关闭") { dismiss() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.12))
    }

    private var versionPicker: some View {
        Menu {
            ForEach(editor.availableVersions, id: \.record.id) { version in
                Button {
                    editor.selectLyricsVersion(versionID: version.record.id)
                } label: {
                    HStack {
                        Text("\(version.record.source) · \(version.record.id.uuidString.prefix(8))")
                        if version.record.isLocked { Image(systemName: "lock.fill") }
                    }
                }
            }
        } label: {
            Label("歌词版本", systemImage: "doc.text")
        }
        .menuStyle(.borderlessButton)
    }

    private var translationPicker: some View {
        Menu {
            if editor.availableTranslations.isEmpty {
                Text("暂无翻译版本")
            }
            ForEach(editor.availableTranslations, id: \.record.id) { version in
                Button {
                    editor.selectTranslation(versionID: version.record.id)
                } label: {
                    HStack {
                        Text("\(version.record.targetLanguage) · \(version.record.sourceKind.rawValue)")
                        if version.record.isLocked { Image(systemName: "lock.fill") }
                    }
                }
            }
        } label: {
            Label("翻译版本", systemImage: "character.bubble")
        }
        .menuStyle(.borderlessButton)
    }

    private func editorBody(_ draft: LyricsEditorDraft) -> some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                Text("行 / 时间 / 原文")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("翻译 / 读音")
                    .frame(width: 360, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(LyricsDesignTokens.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(draft.lines.enumerated()), id: \.element.id) { index, line in
                        lineRow(index: index, line: line, total: draft.lines.count)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("撤销", systemImage: "arrow.uturn.backward") { editor.undo() }
                .keyboardShortcut("z", modifiers: [.command])
            Button("重做", systemImage: "arrow.uturn.forward") { editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Divider().frame(height: 16)
            Button("插入空行", systemImage: "plus") { editor.insertBlank(after: nil) }
            Button("重新生成整首读音", systemImage: "textformat.abc") { editor.regenerateAllReadings() }
            Divider().frame(height: 16)
            Button("后退 2 秒", systemImage: "gobackward.2") {
                state.seek(to: max(0, state.currentTime - 2), source: "lyrics-editor")
            }
            Button(state.isPlaying ? "暂停" : "播放", systemImage: state.isPlaying ? "pause.fill" : "play.fill") {
                state.togglePlayPause()
            }
            Button("前进 2 秒", systemImage: "goforward.2") {
                state.seek(to: min(state.currentTrack.duration, state.currentTime + 2), source: "lyrics-editor")
            }
            Text(Self.formatTime(state.currentTime) + " / " + Self.formatTime(state.currentTrack.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(LyricsDesignTokens.secondaryText)
            Divider().frame(height: 16)
            Button("记当前行", systemImage: "scope") {
                markFocusedLineAtCurrentTime(advance: false)
            }
            Button("记当前并下一行", systemImage: "arrow.down.to.line") {
                markFocusedLineAtCurrentTime(advance: true)
            }
            Button("下一条未排", systemImage: "arrow.down.circle") {
                jumpToNextUntimed()
            }
            Toggle("标记后自动前进", isOn: Binding(
                get: { editor.assistAutoAdvance },
                set: { editor.assistAutoAdvance = $0 }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            Spacer()
            if let draft = editor.draft {
                Text("已排 \(draft.timedNonBlankLineCount) · 未排 \(draft.untimedNonBlankLineCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LyricsDesignTokens.mutedText)
            }
            Button("保存人工版本") { editor.save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(editor.draft?.identity == nil || !editor.canSave)
                .help(editor.draft?.identity == nil ? "当前未关联播放曲目，无法直接保存到数据库；请先在 Spotify 播放歌曲" : "")
            Button("保存并锁定", systemImage: "lock.fill") { editor.save(lockLyrics: true, lockTranslation: true) }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .disabled(editor.draft?.identity == nil || !editor.canSave)
                .help(editor.draft?.identity == nil ? "当前未关联播放曲目，无法直接保存到数据库；请先在 Spotify 播放歌曲" : "")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    private func lineRow(index: Int, line: LyricsEditorLineDraft, total: Int) -> some View {
        let isSuggested = editor.assistSuggestedLineIDs.contains(line.id)
        let isUntimed = line.startTime == nil
            && !line.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isFocused = focusedLineID == line.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LyricsDesignTokens.mutedText)
                        .frame(width: 28, alignment: .trailing)
                    if isSuggested {
                        Text("建议")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.25))
                            .clipShape(Capsule())
                    } else if isUntimed {
                        Text("未排")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 4) {
                    timeField(lineID: line.id, placeholder: isUntimed ? "未排" : "开始")
                    Text("→")
                        .font(.caption2.monospaced())
                        .foregroundStyle(LyricsDesignTokens.mutedText)
                    timeField(lineID: line.id, placeholder: "结束", isEnd: true)
                }
                .frame(width: 156)
            }
            TextField("原文", text: textBinding(lineID: line.id, key: .original))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onTapGesture { focusedLineID = line.id }
            VStack(alignment: .leading, spacing: 4) {
                TextField("翻译", text: textBinding(lineID: line.id, key: .translation))
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Text(line.kanaText ?? "—")
                    Text(line.romajiText ?? "—")
                        .foregroundStyle(LyricsDesignTokens.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    Button("试听") {
                        focusedLineID = line.id
                        if let startTime = line.startTime {
                            state.seek(to: startTime, source: "lyrics-editor-row")
                        }
                    }
                    Button("读音") { editor.regenerateReading(for: line.id) }
                    Button(editor.isReadingLocked(lineID: line.id) ? "已锁" : "锁读音") {
                        editor.toggleReadingLock(lineID: line.id)
                    }
                }
                .font(.caption)
            }
            .frame(width: 360, alignment: .leading)
            VStack(spacing: 3) {
                Button("↑") { editor.move(lineID: line.id, offset: -1) }
                    .disabled(index == 0)
                Button("↓") { editor.move(lineID: line.id, offset: 1) }
                    .disabled(index == total - 1)
                Menu {
                    Button("在中间拆分") {
                        editor.split(lineID: line.id, at: max(1, line.originalText.count / 2))
                    }
                    if index + 1 < total {
                        Button("与下一行合并") {
                            editor.merge(lineID: line.id, with: editor.draft?.lines[index + 1].id ?? line.id)
                        }
                    }
                    Button("删除") { editor.delete(lineID: line.id) }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .padding(6)
        .background(
            isFocused
                ? Color.accentColor.opacity(0.12)
                : (index.isMultiple(of: 2) ? Color.white.opacity(0.03) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { focusedLineID = line.id }
    }

    private enum TextFieldKey { case original, translation }

    private func textBinding(lineID: UUID, key: TextFieldKey) -> Binding<String> {
        Binding(
            get: {
                guard let line = editor.draft?.lines.first(where: { $0.id == lineID }) else { return "" }
                return key == .original ? line.originalText : (line.translationText ?? "")
            },
            set: { value in
                editor.updateLine(lineID) { line in
                    if key == .original { line.originalText = value } else { line.translationText = value }
                }
            }
        )
    }

    private func timeField(lineID: UUID, placeholder: String, isEnd: Bool = false) -> some View {
        TextField(placeholder, text: Binding(
            get: {
                guard let line = editor.draft?.lines.first(where: { $0.id == lineID }) else { return "" }
                let value = isEnd ? line.endTime : line.startTime
                return value.map { String(format: "%.3f", $0) } ?? ""
            },
            set: { text in
                let parsed = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Double(text)
                editor.updateLine(lineID) { line in
                    if isEnd { line.endTime = parsed } else { line.startTime = parsed }
                }
            }
        ))
        .font(.system(size: 11, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .frame(width: 70)
    }

    private func markFocusedLineAtCurrentTime(advance: Bool) {
        let targetID = focusedLineID
            ?? editor.draft?.lines.first(where: {
                $0.startTime == nil
                    && !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.id
            ?? editor.draft?.lines.first?.id
        guard let targetID else { return }
        focusedLineID = targetID
        let now = min(max(0, state.currentTime), max(0, state.currentTrack.duration))
#if DEBUG
        if let next = editor.markLineAtPlayback(lineID: targetID, position: now, advance: advance) {
            focusedLineID = next
            return
        }
#endif
        editor.updateLine(targetID) { line in
            line.startTime = now
            if let end = line.endTime, end < now { line.endTime = nil }
        }
        guard advance || editor.assistAutoAdvance,
              let next = editor.draft?.nextUntimedLineID(after: targetID) else { return }
        focusedLineID = next
    }

    private func jumpToNextUntimed() {
        if let next = editor.draft?.nextUntimedLineID(after: focusedLineID) {
            focusedLineID = next
        }
    }

    private func moveFocus(delta: Int) {
        guard let lines = editor.draft?.lines, !lines.isEmpty else { return }
        if let focusedLineID, let index = lines.firstIndex(where: { $0.id == focusedLineID }) {
            let next = min(max(0, index + delta), lines.count - 1)
            self.focusedLineID = lines[next].id
        } else {
            focusedLineID = delta >= 0 ? lines.first?.id : lines.last?.id
        }
    }

    private static func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let seconds = Int(value.rounded(.down))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: editor.validation.isSaveAllowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(editor.validation.isSaveAllowed ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.validation.isSynchronized ? "同步歌词时间轴有效" : "纯文本或部分时间轴：不会自动平均铺开")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LyricsDesignTokens.primaryText)
                if !editor.validation.issues.isEmpty {
                    Text(editor.validation.issues.map(\.message).joined(separator: "；"))
                        .font(.caption2)
                        .foregroundStyle(LyricsDesignTokens.secondaryText)
                        .lineLimit(2)
                } else if let message = editor.message {
                    Text(message).font(.caption2).foregroundStyle(LyricsDesignTokens.secondaryText)
                }
            }
            Spacer()
            Text(editor.state.userFacingMessage)
                .font(.caption)
                .foregroundStyle(LyricsDesignTokens.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.15))
    }

    private func importPreview(_ preview: LyricsEditorImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LRC 导入预览").font(.title2.weight(.semibold))
            Text("行数：\(preview.result.lines.count) · \(preview.result.isSynchronized ? "包含逐行时间轴" : "纯文本 / 部分时间轴")")
            if let title = preview.result.metadata.title { Text("标题：\(title)") }
            if let artist = preview.result.metadata.artist { Text("艺人：\(artist)") }
            if preview.match.isMismatchWarning {
                Label("元数据或时长与当前歌曲不完全匹配，请确认是否继续。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("与当前歌曲匹配。原始 LRC 文件不会被修改。", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            if !preview.result.warnings.isEmpty {
                Text(preview.result.warnings.joined(separator: "；"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("取消") { editor.cancelImportPreview() }
                Spacer()
                Button("确认导入并锁定") { editor.confirmImport(lock: true) }
                Button("确认导入") { editor.confirmImport() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func textImportPreview(_ preview: TextLyricsImportResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("纯文本歌词导入预览").font(.title2.weight(.semibold))
            Text("行数：\(preview.lines.count) · 编码：\(preview.encoding.rawValue)")
                .foregroundStyle(.secondary)
            if preview.warnings.isEmpty {
                Label("未发现需要特别确认的行。原始 TXT/剪贴板内容不会被修改。", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("发现 \(preview.warnings.count) 个提示；默认保留这些行，不会静默删除。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(preview.warnings.prefix(8).map { "第 \($0.lineIndex + 1) 行：\($0.kind.rawValue)" }.joined(separator: "；"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(preview.lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.32))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("取消") { editor.cancelImportPreview() }
                Spacer()
                Button("确认并载入编辑器") { editor.confirmTextImport() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func translationPastePreview(_ preview: TranslationPasteImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("粘贴\(preview.target.title)预览").font(.title2.weight(.semibold))
            Text(preview.summary)
                .foregroundStyle(preview.canApply ? .green : .orange)
            Text(preview.importedWasTimed
                 ? "已按稳定行序和时间标签检查；检测到的整体偏移只用于匹配，不会改写原歌词时间。"
                 : "未发现时间标签；只有非空行数完全一致时才会按顺序导入。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !preview.matches.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(preview.matches.prefix(24).enumerated()), id: \.offset) { _, match in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("第 \(match.sourceLineIndex + 1) 行")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(match.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(match.confidence == .high ? "已匹配" : "待确认")
                                    .font(.caption)
                                    .foregroundStyle(match.confidence == .high ? .green : .orange)
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.32))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            if !preview.canApply {
                Label("存在缺行、多行或歧义；确认按钮已禁用，不会静默错配。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Button("取消") { editor.cancelImportPreview() }
                Spacer()
                Button("确认导入") { editor.confirmTranslationPaste() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!preview.canApply)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            editor.reportExportResult("剪贴板中没有文本")
            return
        }
        editor.prepareTextImport(text, source: .manualCreate)
    }

    private func pasteTranslation(target: TranslationPasteTarget) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            editor.reportExportResult("剪贴板中没有文本")
            return
        }
        editor.prepareTranslationPaste(text, target: target)
    }

    private func importTXT() {
        let panel = NSOpenPanel()
        panel.title = "导入纯文本歌词"
        panel.message = "选择 TXT 文件；原文件不会被修改"
        panel.allowedContentTypes = [UTType.plainText, UTType.text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            editor.prepareTextImport(data: try Data(contentsOf: url), source: .manualImport)
        } catch {
            editor.reportExportResult("TXT 读取失败：\(error.localizedDescription)")
        }
    }

    private func importLRC() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            editor.prepareImport(try String(contentsOf: url, encoding: .utf8))
        } catch {
            editor.prepareImport("")
        }
    }

    private func exportOriginal() {
        guard let draft = editor.draft, let document = draft.document(source: draft.source) else { return }
        saveFile(contents: LRCExporter.original(
            document: document,
            source: draft.source.rawValue,
            locked: false
        ), suggestedName: "\(draft.title ?? "lyrics").lrc")
    }

    private func exportTranslation() {
        guard let draft = editor.draft, let document = draft.document(source: draft.source) else { return }
        let selected = editor.selectedTranslation
        let translations = selected?.lines
            .sorted { $0.lineIndex < $1.lineIndex }
            .map(\.translatedText)
            ?? draft.lines.map { $0.translationText ?? "" }
        guard translations.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        saveFile(contents: LRCExporter.translation(
            document: document,
            translations: translations,
            targetLanguage: selected?.record.targetLanguage ?? "und",
            source: selected?.record.sourceKind.rawValue ?? "legacyEmbedded",
            locked: selected?.record.isLocked ?? false
        ), suggestedName: "\(draft.title ?? "lyrics").\(selected?.record.targetLanguage ?? "und").lrc")
    }

    private func saveFile(contents: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        // `.plainText` makes NSSavePanel append `.txt` to an otherwise valid
        // LRC filename. Use the dynamic LRC UTI so exports remain reparsable
        // as `song.lrc` / `song.zh-Hans.lrc`.
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            editor.reportExportResult("已导出 LRC：\(url.lastPathComponent)")
        } catch {
            editor.reportExportResult("导出失败：\(error.localizedDescription)")
        }
    }
}
