import SwiftUI

struct CapsuleLyricsStatusView: View {
    let status: String
    let compact: Bool
    @Environment(\.lyricIslandAccent) private var islandAccent

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(islandAccent)
                .frame(width: 4, height: 4)
                .accessibilityHidden(true)
            Label {
                Text(status)
                    .lineLimit(1)
            } icon: {
                Image(systemName: compact ? "music.note" : "text.quote")
            }
        }
        .font(.system(size: compact ? 11 : 13, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .help(status)
    }
}
