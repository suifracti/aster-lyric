import Foundation

struct LibraryCompareVersion: Identifiable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let isCurrent: Bool
    let parentID: UUID?
    var translation: PersonalTranslationVersionItem?
    var canRealignSource = false
    var source: LibraryPassageSource { translation == nil ? .original(id) : .translation(id) }
}

struct LibraryCompareRequest: Identifiable, Sendable {
    let id = UUID()
    let entry: PersonalLyricsLibraryEntry
    let base: LibraryCompareVersion
    let references: [LibraryCompareVersion]
    let firstReference: UUID
    let playing: Playing?
    private let readingLineIndex: Int?

    struct Playing: Sendable {
        let identity: TrackIdentity
        let lyricsID: UUID
        let selectedID: UUID?
        let adoptable: Set<UUID>

        func matches(identity: TrackIdentity?, lyricsID: UUID?, preview: Bool) -> Bool {
            !preview && self.identity == identity && self.lyricsID == lyricsID
        }
    }

    init?(entry: PersonalLyricsLibraryEntry, baseID: UUID, versions: [LibraryCompareVersion],
          playing: Playing? = nil, reading: LibraryPassageTarget? = nil) {
        guard let base = versions.first(where: { $0.id == baseID }) else { return nil }
        let references = versions.filter { $0.id != baseID }.sorted { $0.updatedAt > $1.updatedAt }
        guard let initial = references.first(where: { $0.id == base.parentID })
                ?? references.first(where: \.isCurrent) ?? references.first else { return nil }
        self.entry = entry
        self.playing = playing
        self.base = base
        self.references = references
        firstReference = initial.id
        readingLineIndex = reading?.readingLine(for: baseID, trackKey: entry.id)
    }

    func readingRow(in comparison: LibraryVersionComparison, baseID: UUID, referenceID: UUID) -> LibraryVersionComparison.Row? {
        guard let readingLineIndex else { return nil }
        if baseID == base.id { return comparison.rows.first { $0.baseLines.contains { $0.id == readingLineIndex } } }
        if referenceID == base.id { return comparison.rows.first { $0.referenceLines.contains { $0.id == readingLineIndex } } }
        return nil
    }

    func readingLine(for original: UUID) -> Int? {
        original == base.id ? readingLineIndex : nil
    }
}

struct LibraryOriginalComparison: Sendable {
    typealias Line = LibraryPassagePage.Line
    enum Difference: String, CaseIterable, Identifiable, Sendable {
        case text = "正文", timing = "时间", layers = "附文与声部"
        var id: Self { self }
    }

    struct Row: Identifiable, Sendable {
        let id: Int
        let lines: [[Line]]
        let voiceLabels: [[String?]]

        func differs(in kinds: Set<Difference>) -> Bool {
            guard let first = lines.first(where: { !$0.isEmpty }) else { return false }
            return lines.contains { group in
                if kinds.contains(.text) && group.map(\.original) != first.map(\.original) { return true }
                guard !group.isEmpty else { return false }
                if kinds.contains(.timing),
                   group.map(\.startTime) != first.map(\.startTime) ||
                    group.map(\.endTime) != first.map(\.endTime) ||
                    group.map(\.timedSpans) != first.map(\.timedSpans) { return true }
                return kinds.contains(.layers) && (group.map(\.translation) != first.map(\.translation)
                    || group.map(\.reading) != first.map(\.reading) || group.map(\.romanization) != first.map(\.romanization)
                    || group.map(\.background) != first.map(\.background) || group.map(\.performerID) != first.map(\.performerID))
            }
        }
    }

    let rows: [Row]

    init(editions: [[Line]], alignment: LibraryVersionComparison.Alignment) {
        var groups = (editions.first ?? []).map { [[$0]] }
        for (index, lines) in editions.dropFirst().enumerated() {
            let spine = groups.enumerated().map { offset, group in
                let anchor = group.first(where: { !$0.isEmpty }) ?? []
                return Line(id: offset, original: anchor.map(\.original).joined(), startTime: anchor.first?.startTime)
            }
            let matched = Self.match(spine, lines, alignment: alignment)
            groups = matched.map { left, right in
                var row = Array(repeating: [Line](), count: index + 1)
                for group in groups[left] {
                    for column in group.indices { row[column].append(contentsOf: group[column]) }
                }
                return row + [Array(lines[right])]
            }
        }
        let voices = editions.map { PassageVoicePresentation(lines: $0) }
        rows = groups.enumerated().map { index, lines in
            let labels = zip(lines, voices).map { group, voice in group.map { voice.label(for: $0.id) } }
            return Row(id: index, lines: lines, voiceLabels: labels)
        }
    }

    private struct Span {
        let key: String
        let credit: String?
        let start: TimeInterval?
    }

    private static func spans(_ lines: [Line]) -> [[Span]] {
        let normalized = lines.map { line in
            String(line.original.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let roles = lines.map { LyricsCreditOnly.role($0.original) }
        return lines.indices.map { start in
            var result = [Span(key: normalized[start], credit: roles[start], start: lines[start].startTime)]
            guard roles[start] == nil, !normalized[start].isEmpty else { return result }
            var key = normalized[start]
            for end in (start + 1)..<min(start + 4, lines.count) {
                guard roles[end] == nil, !normalized[end].isEmpty else { break }
                key += normalized[end]
                result.append(Span(key: key, credit: nil, start: lines[start].startTime))
            }
            return result
        }
    }

    /// Keep the order of both versions. An exact phrase can cross up to four
    /// adjacent lines, and it outranks a fuzzy match to just one of its fragments.
    fileprivate static func match(_ base: [Line], _ peer: [Line],
                              alignment: LibraryVersionComparison.Alignment) -> [(Range<Int>, Range<Int>)] {
        if alignment == .line || base.count * peer.count > 250_000 {
            var left = 0, right = 0
            return LibraryVersionComparison.align(base, peer, translations: false, sameOriginal: false, alignment: alignment)
                .map { row in
                    let nextLeft = left + (row.base == nil ? 0 : 1)
                    let nextRight = right + (row.reference == nil ? 0 : 1)
                    defer { left = nextLeft; right = nextRight }
                    return (left..<nextLeft, right..<nextRight)
                }
        }

        let left = spans(base), right = spans(peer)
        struct Step { var score = 0; var left = 0; var right = 0 }
        let width = peer.count + 1
        var table = Array(repeating: Step(), count: (base.count + 1) * width)
        for i in stride(from: base.count, through: 0, by: -1) {
            for j in stride(from: peer.count, through: 0, by: -1) {
                if i == base.count && j == peer.count { continue }
                let index = i * width + j
                var choice = i < base.count ? Step(score: table[index + width].score, left: 1) :
                    Step(score: table[index + 1].score, right: 1)
                if j < peer.count, table[index + 1].score > choice.score {
                    choice = Step(score: table[index + 1].score, right: 1)
                }
                if i < base.count && j < peer.count {
                    for (a, lhs) in left[i].enumerated() {
                        for (b, rhs) in right[j].enumerated() {
                            let split = a + b > 0
                            let score = matchScore(lhs, rhs, split: split, alignment: alignment)
                            guard score > 0 else { continue }
                            let total = table[(i + a + 1) * width + j + b + 1].score + score - (a + b) * 18
                            if total > choice.score {
                                choice = Step(score: total, left: a + 1, right: b + 1)
                            }
                        }
                    }
                }
                table[index] = choice
            }
        }

        var result: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        while i < base.count || j < peer.count {
            let step = table[i * width + j]
            result.append((i..<(i + step.left), j..<(j + step.right)))
            i += step.left
            j += step.right
        }
        return result
    }

    private static func matchScore(_ left: Span, _ right: Span, split: Bool,
                                   alignment: LibraryVersionComparison.Alignment) -> Int {
        if left.credit != nil || right.credit != nil { return left.credit == right.credit ? 220 : 0 }
        if left.key.isEmpty || right.key.isEmpty { return left.key == right.key ? 20 : 0 }
        let difference = left.start.flatMap { a in right.start.flatMap { b in
            a.isFinite && b.isFinite ? abs(a - b) : nil
        } }
        let penalty = difference.map { Int(min($0, 10) * 5) } ?? 0
        if left.key == right.key && (alignment != .time || difference.map({ $0 <= 3 }) != false) {
            return 240 + min(left.key.count, 40) - penalty
        }
        guard !split else { return 0 }
        if alignment == .time {
            return difference.map { $0 <= 0.75 ? 60 - penalty : 0 } ?? 0
        }
        let length = max(left.key.count, right.key.count)
        guard min(left.key.count, right.key.count) >= 4,
              min(left.key.count, right.key.count) * 5 >= length * 3,
              difference.map({ $0 < 2 }) == true || left.key.prefix(2) == right.key.prefix(2)
                || left.key.suffix(2) == right.key.suffix(2) else { return 0 }
        let common = left.key.count - LibraryVersionComparison.changedCharacters(in: left.key, comparedWith: right.key).count
        return common * 5 >= length * 3 ? 80 - penalty : 0
    }
}

struct LibraryVersionComparison: Sendable {
    typealias Line = LibraryPassagePage.Line
    enum Alignment: String, CaseIterable, Identifiable, Sendable {
        case text = "按正文", time = "按时间", line = "按行号"
        var id: Self { self }
    }
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
        var baseContinuation: [Line] = []
        var referenceContinuation: [Line] = []

        var baseLines: [Line] { base.map { [$0] + baseContinuation } ?? [] }
        var referenceLines: [Line] { reference.map { [$0] + referenceContinuation } ?? [] }
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

    init(base: LibraryPassagePage, reference: LibraryPassagePage, translations: Bool, alignment: Alignment = .text) {
        let sameOriginal = base.originalVersionID == reference.originalVersionID &&
            base.matchesOriginalVersion && reference.matchesOriginalVersion
        if translations && !sameOriginal {
            rows = LibraryOriginalComparison.match(base.lines, reference.lines, alignment: alignment).enumerated().map { index, pair in
                let left = base.lines[pair.0], right = reference.lines[pair.1]
                let change: Change
                if left.isEmpty { change = .onlyReference }
                else if right.isEmpty { change = .onlyBase }
                else if left.map(\.original) != right.map(\.original) ||
                    left.map({ $0.translation ?? "" }) != right.map({ $0.translation ?? "" }) { change = .text }
                else { change = .same }
                return Row(id: index, base: left.first, reference: right.first, change: change,
                           baseVoice: nil, referenceVoice: nil,
                           baseContinuation: Array(left.dropFirst()), referenceContinuation: Array(right.dropFirst()))
            }
        } else {
            rows = Self.align(base.lines, reference.lines, translations: translations, sameOriginal: sameOriginal,
                              alignment: alignment)
        }
        canPickTranslationLines = translations && sameOriginal
    }

    /// Equal original lines anchor two different editions in order. On the same
    /// source, row indices distinguish identical choruses even when a translation is blank.
    static func align(_ base: [Line], _ reference: [Line], translations: Bool, sameOriginal: Bool,
                      alignment: Alignment = .text) -> [Row] {
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

        if sameOriginal || alignment == .line {
            let a = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
            let b = Dictionary(uniqueKeysWithValues: reference.map { ($0.id, $0) })
            for id in Set(a.keys).union(b.keys).sorted() { append(a[id], b[id]) }
            return rows
        }

        func anchor(_ line: Line) -> String {
            let text = line.original.isEmpty ? line.translation ?? "" : line.original
            let folded = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
            return String(folded
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        func credit(_ line: Line) -> String? {
            guard let separator = line.original.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
            switch line.original[..<separator].trimmingCharacters(in: .whitespaces) {
            case "词", "詞", "作词", "作詞": return "作词"
            case "曲", "作曲": return "作曲"
            case "编曲", "編曲": return "编曲"
            default: return nil
            }
        }
        let baseKeys = base.map(anchor), referenceKeys = reference.map(anchor)
        if alignment == .time {
            var a = 0, b = 0
            while a < base.count || b < reference.count {
                let left = a < base.count ? base[a] : nil
                let right = b < reference.count ? reference[b] : nil
                if let start = left?.startTime, let other = right?.startTime,
                   abs(start - other) <= 0.75, (min(start, other) > 0 || baseKeys[a] == referenceKeys[b]) {
                    append(left, right)
                    a += 1
                    b += 1
                } else if let left, right == nil || (left.startTime ?? -.infinity) <= (right?.startTime ?? -.infinity) {
                    append(left, nil)
                    a += 1
                } else {
                    append(nil, right)
                    b += 1
                }
            }
            return rows
        }
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
            var next = referenceStart
            for index in baseStart..<baseIndex {
                let key = baseKeys[index]
                let role = credit(base[index])
                let match = (next..<min(referenceIndex, next + 8)).first { peer in
                    let other = referenceKeys[peer]
                    guard role == credit(reference[peer]), min(key.count, other.count) >= 4 else { return false }
                    let common = key.count - changedCharacters(in: key, comparedWith: other).count
                    return common * 5 >= max(key.count, other.count) * 3
                }
                if let match {
                    for peer in next..<match { append(nil, reference[peer]) }
                    append(base[index], reference[match])
                    next = match + 1
                } else {
                    append(base[index], nil)
                }
            }
            for peer in next..<referenceIndex { append(nil, reference[peer]) }
            guard baseIndex < base.count, referenceIndex < reference.count else { break }
            append(base[baseIndex], reference[referenceIndex])
            baseIndex += 1
            referenceIndex += 1
        }
        return rows
    }
}
