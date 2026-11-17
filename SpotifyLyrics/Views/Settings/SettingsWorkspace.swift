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
    @ObservedObject private var favorites = V3FavoriteLines.shared
    @AppStorage(LastOpenedLyricsRecord.defaultsKey, store: .lyricsQ) private var lastOpenedData = Data()
    let navigate: (SettingsLocation) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                Text("我的工作台").font(.system(size: 29, weight: .semibold, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                shelfCard
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
    }

    private var shelfCard: some View {
        let entry = favorites.entries.first
        return Button {
            navigate(.init(.library, trackKey: entry?.trackKey))
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label(entry == nil ? "歌词档案" : "最近收藏", systemImage: entry == nil ? "books.vertical" : "quote.opening")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.80))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.body.weight(.medium))
                }
                Text(entry?.text ?? "我的歌词库")
                    .font(.system(size: entry == nil ? 30 : 24, weight: .medium, design: .serif))
                    .lineLimit(3).multilineTextAlignment(.leading)
                Text(entry.map { [$0.title, $0.artist].filter { !$0.isEmpty }.joined(separator: " · ") }
                     ?? "浏览已保存的原词、译文和读音")
                    .font(.callout).foregroundStyle(.white.opacity(0.83)).lineLimit(2)
                if entry != nil {
                    Label("打开歌曲档案", systemImage: "music.note.list")
                        .font(.caption.weight(.medium))
                }
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .background(WorkspacePalette.sleeve, in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsLocalSearch: View {
    let query: String
    let library: PersonalLyricsLibraryService
    let navigate: (SettingsLocation) -> Void
    @ObservedObject private var favorites = V3FavoriteLines.shared

    private enum Songs {
        case loading, found([PersonalLyricsLibraryEntry]), failed
    }
    @State private var songs: Songs = .loading
    @State private var resultQuery = ""

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var pages: [SettingsCategory] {
        guard !term.isEmpty else { return [] }
        let primary = SettingsCategory.primaryCases
        return (primary + SettingsCategory.allCases.filter { !primary.contains($0) }).filter { $0.matches(term) }
    }
    private var quotes: [V3FavoriteLines.Entry] {
        guard !term.isEmpty else { return [] }
        return favorites.entries.filter {
            [$0.text, $0.translation ?? "", $0.title, $0.artist].contains { $0.localizedStandardContains(term) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("搜索本机资料").font(.system(size: 24, weight: .semibold, design: .serif))
                    .padding(.bottom, 18)
                if term.isEmpty {
                    Text("输入歌曲名、歌词片段或设置名称").foregroundStyle(.secondary)
                } else {
                    if !pages.isEmpty {
                        heading("设置与工具")
                        ForEach(pages) { page in
                            result(page.rawValue, detail: page.detail, icon: page.systemImage, location: .init(page))
                        }
                    }
                    if !quotes.isEmpty {
                        heading("收藏的金句")
                        ForEach(quotes) { quote in
                            result(quote.text, detail: "\(quote.title) · \(quote.artist)", icon: "quote.opening",
                                   location: .init(.library, trackKey: quote.trackKey))
                        }
                    }
                    heading("本机歌词库")
                    if term != resultQuery {
                        ProgressView().controlSize(.small).accessibilityLabel("正在搜索本机歌词库")
                    } else {
                        switch songs {
                        case .loading: ProgressView().controlSize(.small)
                        case .failed: Text("暂时读不到歌词库").foregroundStyle(.secondary)
                        case let .found(entries):
                            if entries.isEmpty { Text("没有找到匹配的歌曲或歌词").font(.callout).foregroundStyle(.secondary) }
                            ForEach(entries) { entry in
                                result(entry.title, detail: entry.artist, icon: "music.note",
                                       location: .init(.library, trackKey: entry.trackStableKey))
                            }
                        }
                    }
                }
            }
            .padding(26).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(WorkspacePalette.paper)
        .task(id: term) {
            let requested = term
            guard !requested.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let matches = try await library.searchSavedEntries(matching: requested)
                try Task.checkCancellation()
                songs = .found(matches)
            } catch {
                guard !Task.isCancelled else { return }
                songs = .failed
            }
            resultQuery = requested
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(WorkspacePalette.ink)
            .padding(.top, 12).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
    }

    private func result(_ title: String, detail: String, icon: String, location: SettingsLocation) -> some View {
        Button { navigate(location) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).foregroundStyle(WorkspacePalette.ink).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(2)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
