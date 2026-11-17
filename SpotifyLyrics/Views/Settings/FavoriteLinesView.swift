import AppKit
import SwiftUI

struct FavoriteLinesView: View {
    @ObservedObject private var store = V3FavoriteLines.shared
    @AppStorage("favorites.browse.asBook.v1", store: .lyricsQ) private var asBook = true
    @AppStorage("favorites.browse.entry.v1", store: .lyricsQ) private var selectedEntry = ""
    @State private var query = ""
    @State private var notice: String?
    @State private var pageArtwork: NSImage?

    var openTrack: ((String) -> Void)? = nil
    var readPassage: (LibraryPassageTarget) -> Void = { MenuBarLyricsController.shared.openSettings(at: .init(reading: $0)) }

    private var results: [V3FavoriteLines.Entry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            [entry.text, entry.translation ?? "", entry.title, entry.artist].contains { text in
                text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }

    var body: some View {
        let entries = results
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收藏的金句").font(.system(size: 26, weight: .semibold, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !store.entries.isEmpty {
                    Picker("查看方式", selection: $asBook) {
                        Text("翻阅").tag(true)
                        Text("列表").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 104)
                }
            }
            if let error = store.errorMessage {
                HStack {
                    Text(error).font(.callout)
                    Button("重新读取") { store.reload() }.buttonStyle(.borderless)
                }
            }
            if !store.entries.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("查找句子、译文、歌曲或歌手", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除查找")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(WorkspacePalette.ink).textSelection(.enabled) }
            if entries.isEmpty {
                if store.errorMessage == nil || !store.entries.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: store.entries.isEmpty ? "bookmark" : "magnifyingglass").font(.title).foregroundStyle(.secondary)
                        Text(store.entries.isEmpty ? "还没有收藏的句子" : "没有找到这句").font(.headline)
                        Text(store.entries.isEmpty ? "在歌词上右键选择「收藏这句」，或在读词时点书签。" : "试试歌名、歌手，或原词里的几个字。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if asBook {
                let index = entries.firstIndex { $0.id.uuidString == selectedEntry } ?? 0
                book(entries[index], index: index, entries: entries)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                            if entry.id != entries.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 800, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.paper)
        .onChange(of: query) { _, _ in notice = nil }
    }

    private func book(_ entry: V3FavoriteLines.Entry, index: Int, entries: [V3FavoriteLines.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack(spacing: 10) {
                            ListeningArtwork(url: entry.artworkURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.callout.weight(.semibold))
                                if !entry.artist.isEmpty { Text(entry.artist).font(.caption).opacity(0.85) }
                            }
                            Spacer()
                            Text(v3ShortDateText(entry.addedAt)).font(.caption).opacity(0.8)
                        }
                        Divider().overlay(.white.opacity(0.24))
                        Spacer(minLength: 5)
                        Text(entry.text).font(.system(size: 27, weight: .medium, design: .serif))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let translation = entry.translation, !translation.isEmpty {
                            Text(translation).font(.callout).foregroundStyle(.white.opacity(0.84)).textSelection(.enabled)
                        }
                    }
                    .padding(22).frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .leading).foregroundStyle(.white)
                    .background(alignment: .trailing) {
                        if let pageArtwork {
                            Image(nsImage: pageArtwork).resizable().scaledToFill()
                                .frame(width: geometry.size.width * 0.52, height: geometry.size.height)
                                .clipped().saturation(0.7).opacity(0.17)
                                .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
                                .accessibilityHidden(true)
                        }
                    }
                    .background(WorkspacePalette.sleeve).clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .task(id: entry.artworkURL) {
                pageArtwork = nil
                let image = await ArtworkImageLoader.shared.image(for: entry.artworkURL)
                if !Task.isCancelled { pageArtwork = image }
            }
            HStack(spacing: 9) {
                Button { select(entries[index - 1]) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0).accessibilityLabel("上一张").help("上一张")
                Text("\(index + 1) / \(entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { select(entries[index + 1]) } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 == entries.count).accessibilityLabel("下一张").help("下一张")
                Spacer(minLength: 5)
                actions(for: entry)
                Button("读原词") { open(entry) }
                Button("接下一句") { open(entry, recall: true) }
                    .buttonStyle(.borderedProminent).tint(WorkspacePalette.sleeve)
            }
            .controlSize(.small)
        }
    }

    private func row(_ entry: V3FavoriteLines.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ListeningArtwork(url: entry.artworkURL)
            Button { open(entry) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text).font(.system(size: 16, weight: .medium, design: .serif))
                    if let translation = entry.translation, !translation.isEmpty {
                        Text(translation).font(.callout).foregroundStyle(.secondary)
                    }
                    Text([entry.title, entry.artist, v3ShortDateText(entry.addedAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("在原词里阅读这句")
            actions(for: entry)
        }
        .padding(.vertical, 12)
    }

    private func actions(for entry: V3FavoriteLines.Entry) -> some View {
        Menu {
            if !asBook {
                Button("翻阅这句", systemImage: "book") { select(entry); asBook = true }
                Button("接下一句", systemImage: "text.bubble") { open(entry, recall: true) }
            }
            if let openTrack {
                Button("打开歌曲档案", systemImage: "music.note") { select(entry); openTrack(entry.trackKey) }
            }
            Button("复制原句", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                notice = "已复制原句"
            }
            Button("做成分享卡", systemImage: "photo.on.rectangle") {
                let cover = ArtworkImageLoader.shared.cachedImage(for: entry.artworkURL)
                let url = V3LyricShareCard.make(text: entry.text, translation: entry.translation,
                    title: entry.title, artist: entry.artist, cover: cover)
                notice = url.map { "已复制分享卡，并存入「\($0.deletingLastPathComponent().lastPathComponent)」。" } ?? "分享卡生成失败。"
            }
            Divider()
            Button("移除收藏", systemImage: "bookmark.slash") { store.remove(entry.id); notice = nil }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("更多金句操作").accessibilityLabel("更多金句操作")
    }

    private func select(_ entry: V3FavoriteLines.Entry) {
        selectedEntry = entry.id.uuidString
        notice = nil
    }

    private func open(_ entry: V3FavoriteLines.Entry, recall: Bool = false) {
        select(entry)
        var target = entry.passage
        target.recallNextLine = recall
        readPassage(target)
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
