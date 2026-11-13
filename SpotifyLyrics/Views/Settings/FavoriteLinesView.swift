import AppKit
import SwiftUI

/// 金句: the lines kept from the lyric context menu, newest first.
struct FavoriteLinesView: View {
    @ObservedObject private var store = V3FavoriteLines.shared
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("在歌词上右键「收藏这句」，就会出现在这里")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.bottom, 10)
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "quote.opening").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("还没有收藏的句子").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            row(entry)
                            if entry.id != store.entries.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .padding(28)
    }

    private func row(_ entry: V3FavoriteLines.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ListeningArtwork(url: entry.artworkURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                if let translation = entry.translation {
                    Text(translation).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("\(entry.title) · \(entry.artist) · \(v3ShortDateText(entry.addedAt))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(copiedID == entry.id ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copiedID = entry.id
            }
            Button("移除") { store.remove(entry.id) }
        }
        .controlSize(.small)
        .padding(.vertical, 11)
    }
}
