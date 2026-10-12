import SwiftUI

struct LyricsPreferencesPopover: View {
    @Binding var preferences: DisplayPreferences
    @ObservedObject var playbackState: PlaybackState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("歌词显示")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.primaryText)
                Text("只显示需要的语言层级")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
            }

            VStack(spacing: 10) {
                preferenceToggle("原文", systemImage: "textformat", isOn: $preferences.showOriginal)
                preferenceToggle("翻译", systemImage: "character.bubble", isOn: $preferences.showTranslation)
                preferenceToggle("罗马音", systemImage: "textformat.abc", isOn: $preferences.showRomaji)
                kanaDisplayControls
            }

            Divider().overlay(LyricsDesignTokens.controlBorder)
            LyricsPresentationOffsetControl(settings: AppSettingsStore.shared)

            Divider().overlay(LyricsDesignTokens.controlBorder)

            VStack(alignment: .leading, spacing: 10) {
                Text("显示窗口")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)

                modeButton("悬浮歌词", systemImage: "rectangle.on.rectangle", isActive: playbackState.showFloatingWindow) {
                    WindowManager.shared.toggleFloatingLyrics(state: playbackState)
                }
                modeButton("顶部胶囊", systemImage: "capsule", isActive: playbackState.showCapsulePlayer) {
                    WindowManager.shared.toggleCapsule(state: playbackState)
                }
                Text("顶部胶囊为实验显示方式，与主窗口共享当前播放状态。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
                modeButton("全屏歌词", systemImage: "arrow.up.left.and.arrow.down.right", isActive: playbackState.showFullScreen) {
                    WindowManager.shared.toggleFullScreen(state: playbackState)
                }
            }
        }
        .padding(22)
        .frame(width: 344)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    private var kanaDisplayControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            preferenceToggle("假名", systemImage: "character.book.closed", isOn: $preferences.showKana)

            Picker("假名显示方式", selection: kanaDisplayModeBinding) {
                Text("独立行").tag(KanaDisplayMode.independentLine)
                Text("汉字上方").tag(KanaDisplayMode.inlineRuby)
                Text("假名替换").tag(KanaDisplayMode.kanaReplacement)
            }
            .pickerStyle(.radioGroup)
            .font(.system(size: 12, design: .rounded))
            .accessibilityLabel("假名显示方式")

            Text(preferences.kanaDisplayMode.detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var kanaDisplayModeBinding: Binding<KanaDisplayMode> {
        Binding(
            get: {
                preferences.kanaDisplayMode == .hidden
                    ? .independentLine
                    : preferences.kanaDisplayMode
            },
            set: { mode in
                // Choosing any of the three presentations is sufficient to
                // enable that presentation; none is gated by the old Boolean.
                preferences.kanaDisplayMode = mode
            }
        )
    }

    private func preferenceToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.secondaryText)
        }
        .toggleStyle(.switch)
        .tint(LyricsDesignTokens.accent)
    }

    private func modeButton(_ title: String, systemImage: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(LyricsDesignTokens.accent)
                }
            }
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(LyricsDesignTokens.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One shared presentation offset editor used by the main preferences,
/// settings center, and floating desktop inspector. It only changes the
/// lyric presentation clock; it never seeks Spotify or edits LRC timestamps.
enum LyricsPresentationOffsetTarget {
    case active
    case savedVersion(scope: LyricsOffsetScope?, versionID: UUID?, disabledReason: String?)
}

/// Shared offset editor. Live windows target PlaybackState's active pair;
/// the editor supplies its own selected saved-version pair.
struct LyricsPresentationOffsetControl: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject private var offsetStore: ScopedLyricsOffsetStore
    let target: LyricsPresentationOffsetTarget
    @State private var input = ""

    init(settings: AppSettingsStore, target: LyricsPresentationOffsetTarget = .active) {
        self.settings = settings
        self.target = target
        self._offsetStore = ObservedObject(wrappedValue: settings.lyricsOffsetStore)
    }

    private var scope: LyricsOffsetScope? {
        switch target {
        case .active:
            return offsetStore.activeScope
        case .savedVersion(let scope, _, _):
            return scope
        }
    }

    private var offset: Double {
        scope.map(offsetStore.value(for:)) ?? 0
    }

    private var isWritable: Bool {
        switch target {
        case .active:
            return offsetStore.activeScope != nil
        case .savedVersion(let scope, _, let reason):
            return scope != nil && reason == nil
        }
    }

    private var disabledReason: String? {
        switch target {
        case .active:
            return offsetStore.activeScope == nil ? "当前没有可确认的已保存歌词版本，偏移暂不可写。" : nil
        case .savedVersion(let scope, _, let reason):
            return scope == nil ? (reason ?? "当前内容没有明确的持久歌词版本，偏移已禁用。") : reason
        }
    }

    private var controlTitle: String {
        switch target {
        case .active:
            return "当前歌词版本偏移"
        case .savedVersion(_, let versionID, _):
            if let versionID { return "编辑版本偏移 · \(versionID.uuidString.prefix(8))" }
            return "编辑版本偏移"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(controlTitle, systemImage: "clock.arrow.2.circlepath")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Spacer()
                Text(label)
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(LyricsDesignTokens.secondaryText)
            }
            HStack(spacing: 6) {
                Button("提前 0.10s") { adjust(0.1) }
                Button("延后 0.10s") { adjust(-0.1) }
                TextField("秒", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .onSubmit { commitInput() }
                Button("归零") { reset() }
                    .disabled(!isWritable || abs(offset) < 0.0001)
            }
            .font(.system(size: 11, design: .rounded))
            .disabled(!isWritable)
            if let disabledReason {
                Text(disabledReason)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("正值让歌词提前出现，负值让歌词延后出现；只影响歌词显示、自动滚动和逐字高亮，不改变播放进度。")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(LyricsDesignTokens.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            if case .active = target {
                Text(legacyHistoryNotice)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(LyricsDesignTokens.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { syncInput() }
        .onChange(of: scope) { _, _ in syncInput() }
        .onChange(of: offsetStore.activeOffset) { _, _ in syncInput() }
        .onChange(of: offsetStore.activeScope) { _, _ in syncInput() }
        .onChange(of: offsetStore.storageRevision) { _, _ in syncInput() }
    }

    private var label: String {
        if abs(offset) < 0.005 { return "0.00s" }
        return offset > 0 ? "提前 \(String(format: "%.2f", offset))s" : "延后 \(String(format: "%.2f", abs(offset)))s"
    }

    private var legacyHistoryNotice: String {
        if let value = settings.legacyLyricsPresentationOffset {
            return "旧版全局值 \(String(format: "%+.2f", value))s 仅保留为未分配历史设置，不会自动应用或翻转。"
        }
        return "旧版全局偏移不会自动应用；请按当前已保存歌词版本设置。"
    }

    private func adjust(_ delta: Double) {
        guard isWritable, let scope else { return }
        offsetStore.setValue(offset + delta, for: scope)
    }

    private func reset() {
        guard isWritable, let scope else { return }
        offsetStore.resetValue(for: scope)
    }

    private func commitInput() {
        guard isWritable,
              let scope,
              let value = Double(input.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else {
            syncInput()
            return
        }
        offsetStore.setValue(value, for: scope)
    }

    private func syncInput() {
        input = String(format: "%.2f", offset)
    }
}
