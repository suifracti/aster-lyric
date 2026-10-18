import SwiftUI

struct FloatingLyricsStatusView: View {
    let state: LyricsLoadState
    let message: String
    let title: String
    @Environment(\.lyricIslandAccent) private var islandAccent

    private var statusTitle: String {
        switch state {
        case .idle: return "等待歌曲"
        case .loading: return "正在加载歌词"
        case .loaded: return "歌词"
        case .alignmentQueued, .alignmentRunning: return "纯文本 / 未排轴"
        case .alignmentPreview: return "排轴预览"
        case .noLyrics: return "暂无歌词"
        case .noSelection: return "未选择歌词"
        case .noMatch: return "未找到歌词"
        case .candidates: return "候选待确认"
        case .failed: return "歌词加载失败"
        case .mockPreview: return "Mock Preview"
        }
    }

    private var symbol: String {
        switch state {
        case .loading, .alignmentRunning: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .noLyrics, .noSelection, .noMatch: return "text.page.slash"
        case .candidates: return "list.bullet.rectangle"
        case .alignmentQueued: return "clock.badge.exclamationmark"
        default: return "music.note"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(islandAccent)
                .frame(width: 2, height: 30)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Label(statusTitle, systemImage: symbol)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .candidates = state {
                    Text("请回到主窗口选择歌词候选")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
