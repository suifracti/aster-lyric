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
    struct MainWindowControls {
        let playerStatus: String
        let showLyrics: () -> Void
        let findLyrics: () -> Void
        let openSettings: () -> Void
    }

    var mainWindow: MainWindowControls? = nil
    let navigate: (SettingsLocation) -> Void

    var body: some View {
        ScrollView {
            Group {
                if let mainWindow { workbench(mainWindow) }
                else { settingsWorkspace }
            }
            .frame(maxWidth: mainWindow == nil ? 770 : 956, alignment: .leading)
            .padding(.horizontal, mainWindow == nil ? 28 : 38)
            .padding(.top, mainWindow == nil ? 22 : 54)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
        }
        .background(WorkspacePalette.paper)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { url in
                let type = url.pathExtension.lowercased()
                return url.isFileURL && (LocalLyricsFileKind(rawValue: type) != nil || ["asterdraft", "asterbook"].contains(type))
            }
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
        .alert("无法打开文件", isPresented: Binding(get: { openingError != nil }, set: { if !$0 { openingError = nil } })) {
            Button("好") { openingError = nil }
        } message: { Text(openingError ?? "") }
    }

    private var settingsWorkspace: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .firstTextBaseline) {
                Text("我的工作台").font(.system(size: 29, weight: .semibold, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) { fileActions }.fixedSize()
                    Menu { fileActions } label: { Label("文件", systemImage: "folder") }.fixedSize()
                }
            }
            archive
            Divider()
            Button { navigate(.init(.general)) } label: {
                HStack {
                    Label("播放来源与连接", systemImage: "cable.connector")
                    Spacer()
                    Text("Spotify / Apple Music").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private func workbench(_ controls: MainWindowControls) -> some View {
        VStack(alignment: .leading, spacing: 25) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    workbenchTitle.fixedSize()
                    Spacer(minLength: 6)
                    workbenchTools(controls).fixedSize()
                }
                VStack(alignment: .leading, spacing: 15) {
                    workbenchTitle
                    workbenchTools(controls)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    archive.frame(minWidth: 310)
                    desk.frame(width: 272)
                }
                VStack(alignment: .leading, spacing: 16) {
                    archiveHighlights
                    HStack(spacing: 8) { fileActions }.buttonStyle(.bordered)
                    archiveTools
                }
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(WorkspacePalette.ink)
                Text(controls.playerStatus).lineLimit(1).foregroundStyle(.secondary)
                    .accessibilityLabel("播放状态 \(controls.playerStatus)")
                Spacer(minLength: 5)
                Button("连接设置", action: { navigate(.init(.general)) }).fixedSize()
            }.font(.callout).buttonStyle(.borderless)
        }
        .accessibilityIdentifier("main.workbench")
    }

    private var workbenchTitle: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: "asterisk")
                .font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(WorkspacePalette.sleeve, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Aster · Lyric").font(.callout.weight(.medium)).foregroundStyle(WorkspacePalette.ink)
                Text("我的工作台").font(.system(size: 34, weight: .semibold, design: .serif))
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func workbenchTools(_ controls: MainWindowControls) -> some View {
        HStack(spacing: 9) {
            Button(action: controls.findLyrics) {
                HStack(spacing: 7) {
                    Label("找回一句", systemImage: "magnifyingglass")
                    Text("⌘K").font(.caption.monospaced()).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            Button("歌词窗口", systemImage: "waveform", action: controls.showLyrics)
            Button(action: controls.openSettings) { Image(systemName: "gearshape") }
                .help("设置").accessibilityLabel("设置")
        }
        .controlSize(.regular).buttonStyle(.bordered)
    }

    private var archive: some View {
        VStack(alignment: .leading, spacing: 15) {
            archiveHighlights
            archiveTools
        }
    }

    private var archiveHighlights: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceShelfCard(navigate: navigate)
            if let record = try? JSONDecoder().decode(LastOpenedLyricsRecord.self, from: lastOpenedData) {
                actionRow(record.passage == nil ? "上次打开的档案" : "继续阅读",
                          detail: [record.title, record.artist].filter { !$0.isEmpty }.joined(separator: " · "),
                          icon: "bookmark") {
                    if let passage = record.passage { navigate(.init(reading: passage)) }
                    else { navigate(.init(.library, trackKey: record.trackKey)) }
                }
            }
        }
    }

    private var archiveTools: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 8) {
            ForEach([SettingsCategory.favorites, .missingLyrics, .history, .statistics]) { category in
                actionRow(category.rawValue, detail: category.detail, icon: category.systemImage) { navigate(.init(category)) }
            }
        }
    }

    private var desk: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文件").font(.headline).accessibilityAddTraits(.isHeader).padding(.horizontal, 10)
                .padding(.top, 9).padding(.bottom, 3)
            actionRow("打开文件…", detail: "歌词、手稿或歌本", icon: "doc.text") {
                openFiles(LyricFileDocument.choose(multiple: true, includesEditableDocuments: true))
            }
            Divider().padding(.horizontal, 10)
            actionRow("写手稿", detail: "写词与编排段落", icon: "square.and.pencil") { newDocument(LyricManuscript()) }
            actionRow("编歌本", detail: "收录歌词和金句，排成印本", icon: "book.closed") { newDocument(LyricBook()) }
        }
        .padding(9)
        .background(.primary.opacity(0.042), in: RoundedRectangle(cornerRadius: 11))
    }

    private func actionRow(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(WorkspacePalette.ink).frame(width: 23)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium))
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var fileActions: some View {
        Button("写手稿", systemImage: "square.and.pencil") { newDocument(LyricManuscript()) }
        Button("编歌本", systemImage: "book.closed") { newDocument(LyricBook()) }
        Button("打开文件…", systemImage: "doc.text") {
            openFiles(LyricFileDocument.choose(multiple: true, includesEditableDocuments: true))
        }
            .help("打开 TXT、LRC、TTML、手稿或歌本，也可以从 Finder 拖到这里")
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
        let line = item.lineIndex.map { "第 \($0 + 1) 行" }
        let detail = [line, item.title, item.artist, item.translation].compactMap { $0 }.filter { !$0.isEmpty }
        return Self(id: "quote." + item.id.uuidString, group: .quotes, title: item.text, detail: detail.joined(separator: " · "),
                    icon: "quote.opening", location: .init(reading: item.passage))
    }

    static func suggestions(lastOpened: LastOpenedLyricsRecord?, favorites: [V3FavoriteLines.Entry]) -> [Self] {
        var rows: [Self] = []
        if let record = lastOpened {
            rows.append(Self(id: "record." + record.trackKey, group: .recent, title: record.title, detail: record.artist, icon: "book",
                             location: .init(reading: record.passage ?? .init(trackKey: record.trackKey))))
        }
        rows += favorites.prefix(2).map(quote)
        rows += [SettingsCategory.library, .favorites, .appearance].map(tool)
        return rows
    }

    static func matches(_ query: String, songs: [LibraryPassageHit], favorites: [V3FavoriteLines.Entry]) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let matchingQuotes = favorites.filter {
            $0.text.localizedStandardContains(term) || $0.translation?.localizedStandardContains(term) == true
        }
        var rows = matchingQuotes.map(quote)
        for hit in songs {
            let title = hit.entry.title, artist = hit.entry.artist
            if let source = hit.source {
                let target = hit.readingTarget(for: term)
                rows.append(Self(id: "passage." + hit.id, group: .songs, title: hit.excerpt ?? title,
                                 detail: [title, artist, source.label].filter { !$0.isEmpty }.joined(separator: " · "),
                                 icon: "text.quote", location: .init(reading: target)))
            }
            if hit.source == nil || hit.matchesMetadata {
                rows.append(Self(id: "song." + hit.id, group: .songs, title: title, detail: artist, icon: "music.note",
                                 location: .init(.library, trackKey: hit.id)))
            }
        }
        let quoteIDs = Set(matchingQuotes.map(\.id))
        rows += favorites.filter {
            !quoteIDs.contains($0.id) && [$0.title, $0.artist].contains { $0.localizedStandardContains(term) }
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
    let resultID: String?
    let library: PersonalLyricsLibraryService
    let open: (WorkspaceLookupRow) -> Void
    @ObservedObject private var favorites = V3FavoriteLines.shared
    @StateObject private var lookup = WorkspaceLookup()
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let results = WorkspaceLookupRow.matches(term, songs: lookup.songs(for: term), favorites: favorites.entries)
        ScrollViewReader { proxy in
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
                                    Button { open(item) } label: { WorkspaceResultLabel(item: item, selected: item.id == resultID) }
                                        .buttonStyle(.plain)
                                        .background(item.id == resultID ? WorkspacePalette.selection : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .id(item.id)
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
            .task(id: results.map(\.id)) {
                if let resultID, results.contains(where: { $0.id == resultID }) {
                    await Task.yield()
                    if !Task.isCancelled { proxy.scrollTo(resultID, anchor: .center) }
                }
            }
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
