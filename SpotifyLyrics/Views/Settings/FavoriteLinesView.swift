import AppKit
import SwiftUI

/// 金句: the lines kept from the lyric context menu, newest first.
struct FavoriteLinesView: View {
    @ObservedObject private var store = V3FavoriteLines.shared
    @State private var copiedID: UUID?

    var openTrack: ((String) -> Void)? = nil
    var readPassage: (LibraryPassageTarget) -> Void = { MenuBarLyricsController.shared.openSettings(at: .init(reading: $0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("收藏的金句").font(.system(size: 24, weight: .semibold, design: .serif))
                .padding(.bottom, 14)
            if let error = store.errorMessage {
                HStack {
                    Text(error).font(.callout)
                    Button("重新读取") { store.reload() }.buttonStyle(.borderless)
                }
                .padding(.bottom, 8)
            }
            if store.entries.isEmpty && store.errorMessage == nil {
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
                Button { readPassage(entry.passage) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.text).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.leading)
                        Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain).help("在原词里阅读这句")
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


/// Captures the line and recording actually on screen when the listener saves it.
struct KeepLyricButton: View {
    @ObservedObject private var store = V3FavoriteLines.shared
    @State private var showsError = false
    let text: String
    let translation: String?
    let trackKey: String
    let title: String
    let artist: String
    let artworkURL: URL?
    var lyricsVersionID: UUID? = nil
    var lineIndex: Int? = nil

    var body: some View {
        let kept = store.contains(text: text, trackKey: trackKey)
        let action = kept ? "取消收藏这句" : "收藏这句"
        Button {
            store.toggle(text: text, translation: translation, title: title, artist: artist,
                         trackKey: trackKey, artworkURL: artworkURL, lyricsVersionID: lyricsVersionID, lineIndex: lineIndex)
            showsError = store.errorMessage != nil
        } label: {
            Image(systemName: kept ? "bookmark.fill" : "bookmark")
                .frame(width: 25, height: 25).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(action).help(action)
        .popover(isPresented: $showsError) {
            Text(store.errorMessage ?? "").font(.callout).padding(12)
        }
    }
}
