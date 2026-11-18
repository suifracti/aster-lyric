import Foundation

struct LibraryCompareVersion: Identifiable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let isCurrent: Bool
    let parentID: UUID?
    var translation: PersonalTranslationVersionItem?
    var source: LibraryPassageSource { translation == nil ? .original(id) : .translation(id) }
}

struct LibraryCompareRequest: Identifiable, Sendable {
    let id = UUID()
    let entry: PersonalLyricsLibraryEntry
    let base: LibraryCompareVersion
    let references: [LibraryCompareVersion]
    let firstReference: UUID
    let playing: Playing?

    struct Playing: Sendable {
        let identity: TrackIdentity
        let lyricsID: UUID
        let selectedID: UUID?
        let adoptable: Set<UUID>

        func matches(identity: TrackIdentity?, lyricsID: UUID?, preview: Bool) -> Bool {
            !preview && self.identity == identity && self.lyricsID == lyricsID
        }
    }

    init?(entry: PersonalLyricsLibraryEntry, baseID: UUID, versions: [LibraryCompareVersion], playing: Playing? = nil) {
        guard let base = versions.first(where: { $0.id == baseID }) else { return nil }
        let references = versions.filter { $0.id != baseID }.sorted { $0.updatedAt > $1.updatedAt }
        guard let initial = references.first(where: { $0.id == base.parentID })
                ?? references.first(where: \.isCurrent) ?? references.first else { return nil }
        self.entry = entry
        self.playing = playing
        self.base = base
        self.references = references
        firstReference = initial.id
    }
}

struct LibraryVersionComparison: Sendable {
    typealias Line = LibraryPassagePage.Line
    enum Change: String, Sendable {
        case same = "相同", text = "文字不同", layer = "附文不同", timing = "时间不同"
        case voice = "声部不同"
        case onlyBase = "底稿独有", onlyReference = "参照稿独有"
    }

    struct Row: Identifiable, Sendable {
        let id: Int
        let base: Line?
        let reference: Line?
        let change: Change
        let baseVoice: String?
        let referenceVoice: String?
    }

    let rows: [Row]
    let canPickTranslationLines: Bool

    /// Highlight complete user-visible characters. Long spoken paragraphs use
    /// the same prefix/suffix bounds without building a large difference table.
    static func changedCharacters(in text: String, comparedWith other: String) -> Set<Int> {
        guard text != other, !text.isEmpty else { return [] }
        let current = Array(text), previous = Array(other)
        var start = 0, end = current.count, priorEnd = previous.count
        while start < min(end, priorEnd), current[start] == previous[start] { start += 1 }
        while end > start, priorEnd > start, current[end - 1] == previous[priorEnd - 1] { end -= 1; priorEnd -= 1 }
        guard end > start else { return [] }
        guard end - start <= 512, priorEnd - start <= 512 else { return Set(start..<end) }
        let changes = current[start..<end].difference(from: previous[start..<priorEnd])
        return Set(changes.insertions.compactMap { change in
            guard case let .insert(offset, _, _) = change else { return nil }
            return start + offset
        })
    }

    init(base: LibraryPassagePage, reference: LibraryPassagePage, translations: Bool) {
        let sameOriginal = base.originalVersionID == reference.originalVersionID &&
            base.matchesOriginalVersion && reference.matchesOriginalVersion
        rows = Self.align(base.lines, reference.lines, translations: translations, sameOriginal: sameOriginal)
        canPickTranslationLines = translations && sameOriginal
    }

    /// Equal original lines anchor two different editions in order. On the same
    /// source, row indices distinguish identical choruses even when a translation is blank.
    static func align(_ base: [Line], _ reference: [Line], translations: Bool, sameOriginal: Bool) -> [Row] {
        let baseVoices = PassageVoicePresentation(lines: base)
        let referenceVoices = PassageVoicePresentation(lines: reference)
        var rows: [Row] = []
        func append(_ a: Line?, _ b: Line?) {
            let baseVoice = a.flatMap { baseVoices.label(for: $0.id) }
            let referenceVoice = b.flatMap { referenceVoices.label(for: $0.id) }
            let change: Change
            switch (a, b) {
            case (nil, _): change = .onlyReference
            case (_, nil): change = .onlyBase
            case let (a?, b?):
                if a.original != b.original || (translations && (a.translation ?? "") != (b.translation ?? "")) { change = .text }
                else if !translations && (a.background != b.background || a.reading != b.reading || a.translation != b.translation) { change = .layer }
                else if !translations && (a.startTime != b.startTime || a.endTime != b.endTime || a.timedSpans != b.timedSpans) { change = .timing }
                else if !translations && baseVoice != referenceVoice { change = .voice }
                else { change = .same }
            }
            rows.append(Row(id: rows.count, base: a, reference: b, change: change,
                            baseVoice: baseVoice, referenceVoice: referenceVoice))
        }

        if sameOriginal {
            let a = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
            let b = Dictionary(uniqueKeysWithValues: reference.map { ($0.id, $0) })
            for id in Set(a.keys).union(b.keys).sorted() { append(a[id], b[id]) }
            return rows
        }

        func anchor(_ line: Line) -> String {
            (line.original.isEmpty ? line.translation ?? "" : line.original).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let baseKeys = base.map(anchor), referenceKeys = reference.map(anchor)
        var removed = Set<Int>(), added = Set<Int>()
        if Set(baseKeys).isDisjoint(with: referenceKeys) {
            removed = Set(baseKeys.indices)
            added = Set(referenceKeys.indices)
        } else {
            for change in referenceKeys.difference(from: baseKeys) {
                switch change {
                case let .remove(offset, _, _): removed.insert(offset)
                case let .insert(offset, _, _): added.insert(offset)
                }
            }
        }
        var baseIndex = 0, referenceIndex = 0
        while baseIndex < base.count || referenceIndex < reference.count {
            let baseStart = baseIndex, referenceStart = referenceIndex
            while removed.contains(baseIndex) { baseIndex += 1 }
            while added.contains(referenceIndex) { referenceIndex += 1 }
            for offset in 0..<max(baseIndex - baseStart, referenceIndex - referenceStart) {
                append(baseStart + offset < baseIndex ? base[baseStart + offset] : nil,
                       referenceStart + offset < referenceIndex ? reference[referenceStart + offset] : nil)
            }
            guard baseIndex < base.count, referenceIndex < reference.count else { break }
            append(base[baseIndex], reference[referenceIndex])
            baseIndex += 1
            referenceIndex += 1
        }
        return rows
    }
}
