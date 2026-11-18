import AppKit
import SwiftUI

enum WorkspacePalette {
    private static func tone(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let ink = tone(NSColor(srgbRed: 0.12, green: 0.32, blue: 0.28, alpha: 1),
                          NSColor(srgbRed: 0.64, green: 0.85, blue: 0.75, alpha: 1))
    static let selection = tone(NSColor(srgbRed: 0.84, green: 0.90, blue: 0.86, alpha: 1),
                                NSColor(srgbRed: 0.16, green: 0.25, blue: 0.22, alpha: 1))
    static let paper = tone(NSColor(srgbRed: 0.985, green: 0.977, blue: 0.96, alpha: 1),
                            NSColor(srgbRed: 0.108, green: 0.12, blue: 0.116, alpha: 1))
    static let sleeve = tone(NSColor(srgbRed: 0.12, green: 0.29, blue: 0.25, alpha: 1),
                             NSColor(srgbRed: 0.14, green: 0.27, blue: 0.23, alpha: 1))
}

/// A local workspace. Opening any of its destinations works while every player is closed.
struct SettingsWorkspace: View {
    @AppStorage(LastOpenedLyricsRecord.defaultsKey, store: .lyricsQ) private var lastOpenedData = Data()
    @Environment(\.openDocument) private var openDocument
    @Environment(\.newDocument) private var newDocument
    @State private var droppedOn = false
    @State private var openingError: String?
    let navigate: (SettingsLocation) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack(alignment: .firstTextBaseline) {
                    Text("我的工作台").font(.system(size: 29, weight: .semibold, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { newDocument(LyricManuscript()) } label: {
                        Label("写手稿", systemImage: "square.and.pencil")
                    }.help("新建歌词手稿")
                    Button { openFiles(LyricFileDocument.choose(multiple: true)) } label: {
                        Label("打开歌词…", systemImage: "doc.text")
                    }.help("打开 TXT、LRC 或 TTML 文件，也可以从 Finder 拖到这里")
                }
                WorkspaceShelfCard(navigate: navigate)
                if let record = try? JSONDecoder().decode(LastOpenedLyricsRecord.self, from: lastOpenedData) {
                    Button { navigate(.init(.library, trackKey: record.trackKey)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark").foregroundStyle(WorkspacePalette.ink)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("上次打开的档案").font(.caption).foregroundStyle(.secondary)
                                Text([record.title, record.artist].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.callout.weight(.medium)).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 8) {
                    ForEach([SettingsCategory.favorites, .missingLyrics, .history, .statistics]) { category in
                        Button { navigate(.init(category)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 17)).foregroundStyle(WorkspacePalette.ink)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(category.rawValue).font(.system(size: 13, weight: .medium))
                                    Text(category.detail).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 60)
                            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider()
                Button { navigate(.init(.general)) } label: {
                    HStack {
                        Label("播放来源与连接", systemImage: "cable.connector")
                        Spacer()
                        Text("Spotify / Apple Music").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 770, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .background(WorkspacePalette.paper)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && LocalLyricsFileKind(rawValue: $0.pathExtension.lowercased()) != nil }
            guard !files.isEmpty else { return false }
            openFiles(files)
            return true
        } isTargeted: { droppedOn = $0 }
        .overlay {
            if droppedOn {
                RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspacePalette.ink, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(5).allowsHitTesting(false)
            }
        }
        .alert("无法打开歌词文件", isPresented: Binding(get: { openingError != nil }, set: { if !$0 { openingError = nil } })) {
            Button("好") { openingError = nil }
        } message: { Text(openingError ?? "") }
    }

    private func openFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                do { try await openDocument(at: url) }
                catch { openingError = "\(url.lastPathComponent) · \(error.localizedDescription)" }
            }
        }
    }
}

struct WorkspaceShelfCard: View {
    @ObservedObject private var favorites = V3FavoriteLines.shared
    var compact = false
    let navigate: (SettingsLocation) -> Void

    var body: some View {
        let entry = favorites.entries.first
        return Button {
            if let entry { navigate(.init(reading: entry.passage)) } else { navigate(.init(.library)) }
        } label: {
            VStack(alignment: .leading, spacing: compact ? 8 : 13) {
                HStack {
                    Label(entry == nil ? "歌词档案" : "最近收藏", systemImage: entry == nil ? "books.vertical" : "quote.opening")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.80))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.body.weight(.medium))
                }
                Text(entry?.text ?? "我的歌词库")
                    .font(.system(size: compact ? 19 : (entry == nil ? 30 : 24), weight: .medium, design: .serif))
                    .lineLimit(3).multilineTextAlignment(.leading)
                Text(entry.map { [$0.title, $0.artist].filter { !$0.isEmpty }.joined(separator: " · ") }
                     ?? "浏览已保存的原词、译文和读音")
                    .font(.callout).foregroundStyle(.white.opacity(0.83)).lineLimit(2)
                if entry != nil {
                    Label("读这句的上下文", systemImage: "book")
                        .font(.caption.weight(.medium))
                }
            }
            .foregroundStyle(.white)
            .padding(compact ? 14 : 22)
            .frame(maxWidth: .infinity, minHeight: compact ? 98 : 140, alignment: .leading)
            .background(WorkspacePalette.sleeve, in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WorkspaceLookupRow: Identifiable {
    enum Group: String { case songs = "本机歌词库", quotes = "收藏的金句", tools = "设置与工具", recent = "继续阅读" }
    let id: String
    let group: Group
    let title: String
    let detail: String
    let icon: String
    let location: SettingsLocation

    private static func tool(_ page: SettingsCategory) -> Self {
        Self(id: "page." + page.id, group: .tools, title: page.rawValue, detail: page.detail, icon: page.systemImage, location: .init(page))
    }

    private static func quote(_ item: V3FavoriteLines.Entry) -> Self {
        Self(id: "quote." + item.id.uuidString, group: .quotes, title: item.text, detail: [item.title, item.artist].filter { !$0.isEmpty }.joined(separator: " · "),
             icon: "quote.opening", location: .init(reading: item.passage))
    }

    static func suggestions(lastOpened: LastOpenedLyricsRecord?, favorites: [V3FavoriteLines.Entry]) -> [Self] {
        var rows: [Self] = []
        if let record = lastOpened {
            rows.append(Self(id: "record." + record.trackKey, group: .recent, title: record.title, detail: record.artist, icon: "book",
                             location: .init(reading: .init(trackKey: record.trackKey))))
        }
        rows += favorites.prefix(2).map(quote)
        rows += [SettingsCategory.library, .favorites, .appearance].map(tool)
        return rows
    }

    static func matches(_ query: String, songs: [LibraryPassageHit], favorites: [V3FavoriteLines.Entry]) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var rows: [Self] = []
        for hit in songs {
            let title = hit.entry.title, artist = hit.entry.artist
            if let source = hit.source {
                let target = LibraryPassageTarget(trackKey: hit.id, source: source, find: term)
                rows.append(Self(id: "passage." + hit.id, group: .songs, title: hit.excerpt ?? title,
                                 detail: [title, artist, source.label].filter { !$0.isEmpty }.joined(separator: " · "),
                                 icon: "text.quote", location: .init(reading: target)))
            }
            if hit.source == nil || hit.matchesMetadata {
                rows.append(Self(id: "song." + hit.id, group: .songs, title: title, detail: artist, icon: "music.note",
                                 location: .init(.library, trackKey: hit.id)))
            }
        }
        rows += favorites.filter { item in
            [item.text, item.translation ?? "", item.title, item.artist].contains { $0.localizedStandardContains(term) }
        }.map(quote)
        let surfaces = AppearanceSurface.allCases.filter { $0.matches(term) }
        rows += surfaces.map { surface in
            Self(id: "surface." + surface.rawValue, group: .tools, title: surface.title, detail: surface.detail,
                 icon: surface.symbol, location: .init(appearance: surface))
        }
        let primary = SettingsCategory.primaryCases
        rows += (primary + SettingsCategory.allCases.filter { !primary.contains($0) }).filter {
            $0.matches(term) && ($0 != .appearance || surfaces.isEmpty)
        }.map(tool)
        return rows
    }
}

@MainActor
final class WorkspaceLookup: ObservableObject {
    @Published private(set) var result: (term: String, songs: [LibraryPassageHit], failed: Bool)?
    func search(_ term: String, library: PersonalLyricsLibraryService) async {
        guard !term.isEmpty else { result = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(140))
            let songs = try await library.searchPassages(matching: term)
            try Task.checkCancellation()
            result = (term, songs, false)
        } catch {
            if !Task.isCancelled { result = (term, [], true) }
        }
    }

    func songs(for term: String) -> [LibraryPassageHit] { result?.term == term ? result?.songs ?? [] : [] }
}

struct SettingsLocalSearch: View {
    let query: String
    let library: PersonalLyricsLibraryService
    let navigate: (SettingsLocation) -> Void
    @ObservedObject private var favorites = V3FavoriteLines.shared
    @StateObject private var lookup = WorkspaceLookup()
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let results = WorkspaceLookupRow.matches(term, songs: lookup.songs(for: term), favorites: favorites.entries)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("搜索本机资料").font(.system(size: 24, weight: .semibold, design: .serif)).padding(.bottom, 18)
                if term.isEmpty {
                    Text("输入歌曲名、歌词片段或设置名称").foregroundStyle(.secondary)
                } else {
                    ForEach([WorkspaceLookupRow.Group.tools, .quotes, .songs], id: \.self) { group in
                        let items = results.filter { $0.group == group }
                        if !items.isEmpty || group == .songs {
                            Text(group.rawValue).font(.caption.weight(.semibold)).foregroundStyle(WorkspacePalette.ink)
                                .padding(.top, 12).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
                            ForEach(items) { item in
                                Button { navigate(item.location) } label: { WorkspaceResultLabel(item: item) }
                                    .buttonStyle(.plain)
                            }
                            if group == .songs && items.isEmpty {
                                if lookup.result?.term != term {
                                    ProgressView().controlSize(.small).accessibilityLabel("正在搜索本机歌词库")
                                } else {
                                    Text(lookup.result?.failed == true ? "暂时读不到歌词库" : "没有找到匹配的歌曲或歌词")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(26).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(WorkspacePalette.paper)
        .task(id: term) { await lookup.search(term, library: library) }
    }
}

struct WorkspaceResultLabel: View {
    let item: WorkspaceLookupRow
    var selected = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon).foregroundStyle(WorkspacePalette.ink).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Image(systemName: selected ? "return" : "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7).contentShape(Rectangle())
    }
}
