import SwiftUI

/// 封面墙 (F1/F2, after Folia's tilted wall and Namida's artist links): what
/// was listened to as a wall of covers, tilted a few degrees, scrolled in
/// both directions. Each song once, most recent first; pointing at a cover
/// lifts it, names it, and dims every cover that is not by the same singer.
struct ListeningCoverWall: View {
    let entries: [ListeningHistoryEntry]
    @State private var hoveredKey: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Tile: Identifiable, Equatable {
        let id: String
        let entry: ListeningHistoryEntry
        let plays: Int
        let artistKey: String
    }

    static func tiles(_ entries: [ListeningHistoryEntry]) -> [Tile] {
        var order: [String] = []
        var first: [String: ListeningHistoryEntry] = [:]
        var plays: [String: Int] = [:]
        for entry in entries {
            if first[entry.stableKey] == nil { first[entry.stableKey] = entry; order.append(entry.stableKey) }
            plays[entry.stableKey, default: 0] += 1
        }
        return order.compactMap { key in
            guard let entry = first[key] else { return nil }
            return Tile(id: key, entry: entry, plays: plays[key] ?? 1, artistKey: primaryArtist(entry.artist))
        }
    }

    /// The first named singer, so a feature does not split the link.
    static func primaryArtist(_ artist: String) -> String {
        let separators = CharacterSet(charactersIn: ",，、&/;；")
        let first = artist.components(separatedBy: separators).first ?? artist
        return first.replacingOccurrences(of: " feat.", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        let tiles = Self.tiles(entries)
        let columns = max(4, Int((Double(tiles.count) * 1.7).squareRoot().rounded(.up)))
        let hoveredArtist = tiles.first { $0.id == hoveredKey }?.artistKey
        ScrollView([.horizontal, .vertical]) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(108), spacing: 12), count: columns), spacing: 12) {
                ForEach(tiles) { tile in
                    ListeningWallTile(tile: tile, hovered: hoveredKey == tile.id,
                                      dimmed: hoveredArtist != nil && tile.artistKey != hoveredArtist)
                        .onHover { inside in
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                if inside { hoveredKey = tile.id } else if hoveredKey == tile.id { hoveredKey = nil }
                            }
                        }
                }
            }
            .padding(.horizontal, 70).padding(.vertical, 56)
            .rotationEffect(.degrees(reduceMotion ? 0 : -4))
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("封面墙，\(tiles.count) 首")
    }
}

private struct ListeningWallTile: View {
    let tile: ListeningCoverWall.Tile
    let hovered: Bool
    let dimmed: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.14))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if hovered {
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.entry.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(tile.plays > 1 ? "\(tile.entry.artist) · \(tile.plays) 次" : tile.entry.artist)
                        .font(.system(size: 9.5)).opacity(0.8).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(7)
                .transition(.opacity)
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(hovered ? 0.35 : 0.12), radius: hovered ? 14 : 4, y: hovered ? 8 : 2)
        .scaleEffect(hovered ? 1.12 : 1)
        .zIndex(hovered ? 1 : 0)
        .opacity(dimmed ? 0.3 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.entry.title)，\(tile.entry.artist)" + (tile.plays > 1 ? "，听了 \(tile.plays) 次" : ""))
        .task(id: tile.entry.artworkURL) {
            let loaded = await ArtworkImageLoader.shared.image(for: tile.entry.artworkURL)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
