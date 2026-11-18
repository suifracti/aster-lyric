import SwiftUI

struct LyricBookPicker: View {
    private enum Source { case archive, quotes }
    let library: PersonalLyricsLibraryService
    let collected: Set<LibraryPassageTarget>
    let add: (LyricBook.Chapter) -> Void
    @ObservedObject private var favorites = V3FavoriteLines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.archive
    @State private var query = ""
    @State private var songs: [LibraryPassageHit] = []
    @State private var additions: Set<LibraryPassageTarget> = []
    @State private var loading = false
    @State private var adding: Task<Void, Never>?
    @State private var failure: String?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var quotes: [V3FavoriteLines.Entry] {
        guard !term.isEmpty else { return favorites.entries }
        return favorites.entries.filter { [$0.text, $0.translation ?? "", $0.title, $0.artist].contains { $0.localizedStandardContains(term) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收进歌本").font(.headline)
                Spacer()
                Picker("来自", selection: $source) {
                    Text("歌词库").tag(Source.archive)
                    Text("金句").tag(Source.quotes)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(source == .archive ? "查找歌曲或已存歌词" : "查找收藏的金句", text: $query).textFieldStyle(.plain)
            }
            .padding(8).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            Group {
                if source == .archive, loading, songs.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if source == .archive ? songs.isEmpty : quotes.isEmpty {
                    Text(term.isEmpty ? (source == .archive ? "歌词库还没有可收录的版本" : "还没有收藏金句") : "没有找到匹配内容")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if source == .archive {
                                ForEach(songs) { hit in
                                    let target = hit.readingTarget(for: term)
                                    let origin = LibraryPassageTarget(trackKey: target.trackKey, source: target.source)
                                    let information = [hit.entry.artist, hit.source?.label, hit.excerpt].compactMap { $0 }
                                        .filter { !$0.isEmpty }.joined(separator: " · ")
                                    row(hit.entry.title, subtitle: information, symbol: "music.note", origin: origin) {
                                        loadSong(origin)
                                    }
                                }
                            } else {
                                ForEach(quotes) { quote in
                                    row(quote.text, subtitle: [quote.title, quote.artist].filter { !$0.isEmpty }.joined(separator: " · "),
                                        symbol: "quote.opening", origin: quote.passage) {
                                        add(.init(quote: quote))
                                        additions.insert(quote.passage)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if adding != nil { ProgressView().controlSize(.small).accessibilityLabel("读取版本") }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 416, height: 390)
        .padding(17)
        .background(WorkspacePalette.paper)
        .task(id: (source == .archive ? "archive:" : "quotes:") + term) {
            if source == .archive { await search(term) }
        }
        .onDisappear { adding?.cancel() }
    }

    private func row(_ title: String, subtitle: String, symbol: String, origin: LibraryPassageTarget,
                     perform: @escaping () -> Void) -> some View {
        let alreadyCollected = collected.contains(origin) || additions.contains(origin)
        return Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(WorkspacePalette.ink).frame(width: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(2)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 3)
                Image(systemName: alreadyCollected ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(WorkspacePalette.ink)
            }
            .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyCollected || adding != nil)
        .accessibilityLabel(alreadyCollected ? "已收录 \(title)" : "收录 \(title)")
    }

    private func search(_ term: String) async {
        songs = []
        failure = nil
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            if !term.isEmpty { try await Task.sleep(for: .milliseconds(155)) }
            let hits = try await library.bookSources(matching: term)
            try Task.checkCancellation()
            songs = hits
        } catch is CancellationError {} catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func loadSong(_ origin: LibraryPassageTarget) {
        guard adding == nil else { return }
        failure = nil
        adding = Task {
            defer { adding = nil }
            do {
                guard let page = try await library.readPassage(origin, recordOpening: false), !page.lines.isEmpty else {
                    failure = "这份版本里没有可收录的歌词。"
                    return
                }
                try Task.checkCancellation()
                add(.init(page: page, source: origin.source))
                additions.insert(origin)
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}
