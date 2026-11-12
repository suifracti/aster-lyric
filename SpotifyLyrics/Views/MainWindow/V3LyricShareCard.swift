import AppKit
import SwiftUI

/// 分享卡 (F7): one lyric line as a 1080 × 1350 picture — the cover's
/// colours as the ground, the cover, the line and its translation, the song.
/// Made only when asked (lyric context menu); copied to the clipboard and
/// saved under ~/Pictures/Aster Lyric.
@MainActor
enum V3LyricShareCard {
    static let size = CGSize(width: 1080, height: 1350)

    /// Returns the saved file, or nil when the picture could not be made.
    static func make(line: LyricLine, track: Track) async -> URL? {
        let cover = await ArtworkImageLoader.shared.image(for: track.artworkURL)
        let text = line.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = line.translationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderer = ImageRenderer(content: V3LyricShareCardView(
            line: text, translation: translation?.isEmpty == true ? nil : translation,
            title: track.title, artist: track.artist, cover: cover,
            ground: cover.flatMap { thumbnail($0, side: 10) }))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        guard let image = renderer.nsImage else { return nil }
        return deliver(image, name: track.title)
    }

    /// Copies the picture and saves it under ~/Pictures/Aster Lyric.
    static func deliver(_ image: NSImage, name: String) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        guard let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aster Lyric", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(fileSafe(name)) \(stamp).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    static func fileSafe(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "歌词" : cleaned).prefix(60))
    }

    /// A tiny thumbnail, stretched up, is a soft colour field with no blur pass
    /// (ImageRenderer does not reliably apply blur).
    static func thumbnail(_ image: NSImage, side: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: side, height: side))
        result.addRepresentation(rep)
        return result
    }
}

struct V3LyricShareCardView: View {
    let line: String
    let translation: String?
    let title: String
    let artist: String
    let cover: NSImage?
    let ground: NSImage?

    /// Short lines big; a line of about 14 CJK characters still fits on one
    /// line (888 pt wide) instead of leaving one character alone.
    static func lineSize(_ line: String) -> CGFloat {
        switch line.count {
        case ...10: return 76
        case ...14: return 60
        case ...28: return 56
        default: return 48
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.12, green: 0.12, blue: 0.14)
            if let ground {
                // Its own frame: a square image filled to a tall card would
                // otherwise widen the whole stack and push the text off.
                Image(nsImage: ground).resizable().interpolation(.high).scaledToFill()
                    .frame(width: V3LyricShareCard.size.width, height: V3LyricShareCard.size.height)
                    .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let cover {
                        Image(nsImage: cover).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: 400, height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                Spacer(minLength: 60)
                Text(line)
                    .font(.system(size: Self.lineSize(line), weight: .bold))
                    .foregroundStyle(.white)
                    .lineSpacing(10)
                    .fixedSize(horizontal: false, vertical: true)
                if let translation {
                    Text(translation)
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(6)
                        .padding(.top, 26)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 60)
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(artist).font(.system(size: 28)).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
                    }
                    Spacer(minLength: 20)
                    Text("Aster · Lyric").font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(96)
            .frame(width: V3LyricShareCard.size.width, height: V3LyricShareCard.size.height, alignment: .topLeading)
        }
        .frame(width: V3LyricShareCard.size.width, height: V3LyricShareCard.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}
