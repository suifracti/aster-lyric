import AppKit
import CoreText

enum LyricBookPrint {
    // A5, in PostScript points. Each piece of text is drawn into the same
    // Core Text frame used to paginate it, including CJK and mixed scripts.
    static let size = CGSize(width: 420, height: 595)
    private static let width: CGFloat = 332, left: CGFloat = 44, bottom: CGFloat = 54
    private static let ink = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.15, alpha: 1)
    private static let green = NSColor(srgbRed: 0.15, green: 0.34, blue: 0.29, alpha: 1)
    private static let muted = NSColor(srgbRed: 0.32, green: 0.36, blue: 0.35, alpha: 1)

    private struct Block {
        let text: NSAttributedString
        var after: CGFloat = 6
        var startPage = false
        var keepNext = false
        var chapter: UUID?
        var link: UUID?
    }

    private struct Sheet {
        var frames: [CTFrame] = []
        var anchors: [UUID: CGFloat] = [:]
        var links: [UUID: CGRect] = [:]
    }

    private static func type(_ value: String, size: CGFloat, color: NSColor, serif: Bool = false,
                             medium: Bool = false) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size, weight: medium ? .semibold : .regular)
        let font = serif ? base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base : base
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(2, size * 0.19)
        return NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func stack(_ pieces: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in pieces where !piece.string.isEmpty {
            if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: piece.attributes(at: 0, effectiveRange: nil))) }
            result.append(piece)
        }
        return result
    }

    private static func lineText(_ line: LyricBook.Line, book: LyricBook, quote: Bool) -> NSAttributedString {
        let layers = line.text(for: book)
        var pieces: [NSAttributedString] = []
        if let guide = layers.reading { pieces.append(type(guide, size: 9, color: green)) }
        pieces.append(type(layers.main, size: quote ? 21 : 13, color: ink, serif: true))
        if let translation = layers.translation { pieces.append(type(translation, size: quote ? 12 : 10.5, color: muted)) }
        if let backing = layers.background { pieces.append(type("♪ " + backing, size: 10, color: muted)) }
        return stack(pieces)
    }

    private static func content(_ book: LyricBook) -> [Block] {
        var blocks: [Block] = []
        var previous: LyricBook.Chapter.Kind?
        for chapter in book.chapters {
            let startsPage = chapter.kind == .song || previous == .song
            let firstBlock = blocks.count
            if chapter.kind == .song {
                blocks.append(Block(text: stack([type(chapter.title, size: 26, color: ink, serif: true, medium: true),
                    type(chapter.byline, size: 12, color: green), type(chapter.edition, size: 9, color: muted)]), after: 18, keepNext: true))
            }
            if chapter.kind == .song, !chapter.note.isEmpty { blocks.append(Block(text: type(chapter.note, size: 11, color: green), after: 15)) }
            for row in chapter.readingRows {
                if let voice = row.voice {
                    blocks.append(Block(text: type(voice, size: 9, color: green), after: 3, keepNext: true))
                }
                let text = lineText(row.line, book: book, quote: chapter.kind == .quote)
                blocks.append(Block(text: text, after: chapter.kind == .song ? 7 : 9))
            }
            if chapter.kind == .quote {
                blocks.append(Block(text: type(chapter.byline, size: 11, color: green), after: chapter.note.isEmpty ? 24 : 6))
                if !chapter.note.isEmpty { blocks.append(Block(text: type(chapter.note, size: 11, color: muted), after: 23)) }
            }
            if let first = blocks.indices.dropFirst(firstBlock).first(where: { blocks[$0].text.length > 0 }) {
                blocks[first].chapter = chapter.id
                blocks[first].startPage = startsPage
            }
            previous = chapter.kind
        }
        return blocks
    }

    private static func paginate(_ blocks: [Block], top: CGFloat = 529) throws -> [Sheet] {
        var pages = [Sheet()]
        var y = top
        func next() { pages.append(Sheet()); y = top }
        for block in blocks {
            if block.text.length == 0 {
                if !pages[pages.count - 1].frames.isEmpty { y -= block.after }
                continue
            }
            if block.startPage, !pages[pages.count - 1].frames.isEmpty { next() }
            let layout = CTFramesetterCreateWithAttributedString(block.text)
            var offset = 0
            while offset < block.text.length {
                let remaining = CFRange(location: offset, length: block.text.length - offset)
                let measured = CTFramesetterSuggestFrameSizeWithConstraints(layout, remaining, nil,
                    CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), nil)
                let needed = ceil(measured.height) + 3
                let room = y - bottom
                let fitsOnNewPage = needed <= top - bottom
                if !pages[pages.count - 1].frames.isEmpty,
                   room < 27 || (fitsOnNewPage && needed + (block.keepNext ? 30 : 0) > room) { next() }
                let height = min(needed, y - bottom)
                let rect = CGRect(x: left, y: y - height, width: width, height: height)
                let path = CGPath(rect: rect, transform: nil)
                let frame = CTFramesetterCreateFrame(layout, remaining, path, nil)
                let count = CTFrameGetVisibleStringRange(frame).length
                guard count > 0 else {
                    if !pages[pages.count - 1].frames.isEmpty { next(); continue }
                    throw CocoaError(.fileWriteUnknown)
                }
                if offset == 0, let id = block.chapter { pages[pages.count - 1].anchors[id] = y }
                if let id = block.link { pages[pages.count - 1].links[id] = rect }
                pages[pages.count - 1].frames.append(frame)
                offset += count
                y -= height + block.after
                if offset < block.text.length { next() }
            }
        }
        return pages.filter { !$0.frames.isEmpty }
    }

    private static func contents(_ book: LyricBook, pages: [Sheet], preceding: Int) -> [Block] {
        let pageIndex = Dictionary(uniqueKeysWithValues: pages.enumerated().flatMap { index, page in
            page.anchors.keys.map { ($0, index) }
        })
        var entries = [Block(text: type("目录", size: 27, color: ink, serif: true, medium: true), after: 23, keepNext: true)]
        for chapter in book.chapters {
            guard let first = pageIndex[chapter.id] else { continue }
            let full = chapter.titleInContents
            let title = full.count > 48 ? String(full.prefix(48)) + "…" : full
            let label = NSMutableAttributedString(attributedString: type("\(preceding + first + 1)　", size: 11, color: green))
            label.append(type(title, size: 14, color: ink, serif: true))
            entries.append(Block(text: stack([label, type(chapter.byline, size: 10, color: muted)]), after: 12, link: chapter.id))
        }
        return entries
    }

    static func data(for book: LyricBook) throws -> Data {
        let covers = try paginate([
            Block(text: type(book.displayTitle, size: 36, color: ink, serif: true, medium: true), after: 15),
            Block(text: type(book.author, size: 14, color: green), after: 29),
            Block(text: type(book.introduction, size: 13, color: muted, serif: true))
        ], top: 432)
        let body = try paginate(content(book))
        var index: [Sheet] = []
        if book.chapters.count > 1 {
            let estimate = try paginate(contents(book, pages: body, preceding: covers.count + 1))
            index = try paginate(contents(book, pages: body, preceding: covers.count + estimate.count))
            if estimate.count != index.count { index = try paginate(contents(book, pages: body, preceding: covers.count + index.count)) }
        }
        let sheets = covers + index + body
        let buffer = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: buffer),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                kCGPDFContextTitle: book.displayTitle, kCGPDFContextAuthor: book.author, kCGPDFContextCreator: "Aster · Lyric"
              ] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        for (i, page) in sheets.enumerated() {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            if i == 0 {
                context.setFillColor(green.cgColor)
                context.fill(CGRect(x: left, y: 474, width: 36, height: 2))
            } else {
                drawLabel(book.displayTitle, x: left, y: 556, width: width - 15, context: context)
                drawLabel(String(i + 1), x: left, y: 26, width: width, context: context)
            }
            for frame in page.frames { CTFrameDraw(frame, context) }
            for (chapter, y) in page.anchors {
                context.addDestination(chapter.uuidString as CFString, at: CGPoint(x: left, y: y + 12))
            }
            for (chapter, bounds) in page.links {
                context.setDestination(chapter.uuidString as CFString, for: bounds)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return buffer as Data
    }

    private static func drawLabel(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, context: CGContext) {
        let line = CTLineCreateWithAttributedString(type(value.replacingOccurrences(of: "\n", with: " "), size: 9, color: muted))
        let ellipsis = CTLineCreateWithAttributedString(type("…", size: 9, color: muted))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateTruncatedLine(line, width, .end, ellipsis) ?? line, context)
    }
}
