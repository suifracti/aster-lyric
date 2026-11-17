import AppKit
import SwiftUI

/// 金句: the lines kept from the lyric context menu, newest first.
struct FavoriteLinesView: View {
    @ObservedObject private var store = V3FavoriteLines.shared
    @State private var copiedID: UUID?

    var openTrack: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("收藏的金句").font(.system(size: 24, weight: .semibold, design: .serif))
                .padding(.bottom, 14)
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "quote.opening").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("还没有收藏的句子").font(.headline).foregroundStyle(.secondary)
                    Text("在歌词上右键，选择「收藏这句」。").font(.callout).foregroundStyle(.secondary)
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
                HStack(spacing: 7) {
                    if let openTrack {
                        Button { openTrack(entry.trackKey) } label: {
                            Label(entry.title, systemImage: "music.note")
                        }
                        .buttonStyle(.borderless).help("打开歌曲档案")
                    } else {
                        Text(entry.title)
                    }
                    Text([entry.artist, v3ShortDateText(entry.addedAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .font(.caption).lineLimit(1)
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
