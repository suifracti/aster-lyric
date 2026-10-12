#if DEBUG
import SwiftUI

/// Minimal product-facing explanation before Assist capture starts.
/// No ScreenCaptureKit / Speech / DP jargon.
/// Hosted once from `MainLyricsWindowView` (V3 + classic layouts).
struct AssistExplainSheet: View {
    @ObservedObject var state: PlaybackState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("边听边排轴")
                .font(.title2.weight(.semibold))
            Text("在听歌时生成少量可靠时间建议，方便你在编辑器里补齐。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("仅 Spotify Desktop 播放源支持实时捕获", systemImage: "waveform")
                Label("不捕获麦克风", systemImage: "mic.slash")
                Label("捕获音频临时写入本机 WAV 分段，任务结束后清理", systemImage: "trash")
                Label("自动建议可能不完整", systemImage: "exclamationmark.triangle")
                Label("只有你确认保存后才会写入时间轴版本", systemImage: "checkmark.seal")
            }
            .font(.body)

            Text("这是辅助草稿，不是默认全自动完成。")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)

            Spacer(minLength: 8)

            HStack {
                Button("取消") {
                    state.cancelListeningAssist()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("assist.sheet.cancel")
                Spacer()
                Button("开始") {
                    state.confirmListeningAssistAndCapture(seconds: 55)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("assist.sheet.start")
            }
        }
        .padding(28)
        .frame(width: 440, height: 360)
        .interactiveDismissDisabled(false)
    }
}
#endif
