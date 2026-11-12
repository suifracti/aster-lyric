import Foundation

/// Read-only access to the Spotify app's own metadata cache on this Mac.
///
/// The Spotify desktop client keeps a LevelDB per account
/// (`PersistentCache/Users/<account>-user/primary.ldb`). When it shows a song
/// with a Canvas it stores the clip's address there. We read those files as
/// plain bytes: we never open the database, take its lock or write anything,
/// and we ask no Spotify service for the Canvas. A song the client has not
/// loaded has no entry, and the client loads it a little after the song
/// starts, so callers look again later.
///
/// Written from the public format descriptions (LevelDB `table_format.md`,
/// `log_format.md`; Snappy `format_description.txt`).
enum SpotifyLocalCache {
    static var usersDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Spotify/PersistentCache/Users", isDirectory: true)
    }

    static func accountDatabases(in root: URL = usersDirectory) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries
            .filter { $0.lastPathComponent.hasSuffix("-user") }
            .map { $0.appendingPathComponent("primary.ldb", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            // The account used most recently first.
            .sorted { modified($0) > modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

// MARK: - Canvas

enum SpotifyCanvasLocator {
    /// The cache key the client uses for a track's Canvas:
    /// `!xmeta#cache#` + kind `01 30` + `#` + length + uri + `#`.
    static func cacheKey(trackURI: String) -> [UInt8]? {
        let uri = Array(trackURI.utf8)
        guard !uri.isEmpty, uri.count < 256 else { return nil }
        return Array("!xmeta#cache#".utf8) + [0x01, 0x30, UInt8(ascii: "#"), UInt8(uri.count)] + uri + [UInt8(ascii: "#")]
    }

    /// The clip for a Spotify track ID, or nil when the client has none cached.
    static func canvasURL(trackID: String, databases: [URL] = SpotifyLocalCache.accountDatabases()) -> URL? {
        let uri = "spotify:track:" + trackID
        guard let key = cacheKey(trackURI: uri) else { return nil }
        for database in databases {
            guard let value = LevelDBFileReader(directory: database).value(forKey: key),
                  let url = canvasURL(fromValue: value, trackURI: uri) else { continue }
            return url
        }
        return nil
    }

    /// The value wraps `...EntityCanvazResponse.Canvaz` in a protobuf `Any`:
    /// field 2 the clip address, 4 the kind, 5 the track uri. Only video kinds
    /// (1 video, 2 looping, 3 looping random) are used; images and GIFs are not.
    static func canvasURL(fromValue value: [UInt8], trackURI: String) -> URL? {
        let marker = Array("EntityCanvazResponse.Canvaz".utf8)
        guard let markerEnd = value.firstRange(of: marker)?.upperBound else { return nil }
        // After the type url comes the Any's field 2 (tag 0x12) with the message.
        var cursor = markerEnd
        guard cursor < value.count, value[cursor] == 0x12 else { return nil }
        cursor += 1
        guard let (length, afterLength) = ProtobufBytes.varint(value, at: cursor),
              afterLength + Int(length) <= value.count else { return nil }
        let message = Array(value[afterLength..<(afterLength + Int(length))])
        var address: String?, kind: UInt64?, entity: String?
        for field in ProtobufBytes.fields(message) {
            switch (field.number, field.payload) {
            case (2, .bytes(let bytes)): address = String(decoding: bytes, as: UTF8.self)
            case (4, .varint(let number)): kind = number
            case (5, .bytes(let bytes)): entity = String(decoding: bytes, as: UTF8.self)
            default: break
            }
        }
        guard entity == trackURI, let kind, (1...3).contains(kind), let address,
              address.hasPrefix("https://canvaz.scdn.co/upload/"), address.hasSuffix(".cnvs.mp4"),
              address.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) }),
              let url = URL(string: address) else { return nil }
        return url
    }
}

enum ProtobufBytes {
    enum Payload { case varint(UInt64), bytes([UInt8]), other }
    struct Field { let number: Int; let payload: Payload }

    static func varint(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0, shift: UInt64 = 0, index = start
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            value |= UInt64(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
        }
        return nil
    }

    static func fields(_ bytes: [UInt8]) -> [Field] {
        var result: [Field] = [], index = 0
        while index < bytes.count, let (tag, next) = varint(bytes, at: index) {
            index = next
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let (value, after) = varint(bytes, at: index) else { return result }
                result.append(Field(number: number, payload: .varint(value))); index = after
            case 1: index += 8; result.append(Field(number: number, payload: .other))
            case 2:
                guard let (length, after) = varint(bytes, at: index), after + Int(length) <= bytes.count else { return result }
                result.append(Field(number: number, payload: .bytes(Array(bytes[after..<(after + Int(length))]))))
                index = after + Int(length)
            case 5: index += 4; result.append(Field(number: number, payload: .other))
            default: return result
            }
        }
        return result
    }
}

// MARK: - LevelDB (read only)

/// Looks up one key in a LevelDB directory another process is using. Each
/// table (.ldb) and write-ahead log (.log) is read as bytes; the newest
/// version (highest sequence number) wins and a deletion hides the key.
/// Files vanish while Spotify compacts; a file that fails to read is skipped.
struct LevelDBFileReader {
    let directory: URL
    private static let maximumFileBytes = 64 << 20

    struct Version { let sequence: UInt64; let value: [UInt8]?; }

    func value(forKey key: [UInt8]) -> [UInt8]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var best: Version?
        func consider(_ version: Version) {
            if best == nil || version.sequence > best!.sequence { best = version }
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(".ldb") || name.hasSuffix(".sst") {
                Self.tableLookup(url, key: key).forEach(consider)
            } else if name.hasSuffix(".log") {
                Self.logLookup(url, key: key).forEach(consider)
            }
        }
        return best?.value
    }

    // MARK: Tables

    private static func tableLookup(_ url: URL, key: [UInt8]) -> [Version] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 48, size <= UInt64(maximumFileBytes),
              let footer = read(handle, offset: size - 48, length: 48),
              Array(footer[40..<48]) == [0x57, 0xFB, 0x80, 0x8B, 0x24, 0x75, 0x47, 0xDB],
              let (_, afterMeta) = blockHandle(footer, at: 0),
              let (index, _) = blockHandle(footer, at: afterMeta),
              let indexBlock = readBlock(handle, fileSize: size, handle: index) else { return [] }
        var versions: [Version] = []
        var started = false
        // Index entries: separator key (>= every key in that block) → block.
        for entry in blockEntries(indexBlock) {
            guard let separator = splitInternalKey(entry.key) else { continue }
            if !started {
                guard compare(separator.user, key) >= 0 else { continue }
                started = true
            }
            guard let (dataHandle, _) = blockHandle(entry.value, at: 0),
                  let data = readBlock(handle, fileSize: size, handle: dataHandle) else { break }
            var pastKey = false
            for row in blockEntries(data) {
                guard let internalKey = splitInternalKey(row.key) else { continue }
                let order = compare(internalKey.user, key)
                if order < 0 { continue }
                if order > 0 { pastKey = true; break }
                versions.append(Version(sequence: internalKey.sequence, value: internalKey.type == 1 ? row.value : nil))
            }
            // Versions of one key can spill into the next block.
            if pastKey || compare(separator.user, key) > 0 { break }
        }
        return versions
    }

    private static func read(_ handle: FileHandle, offset: UInt64, length: Int) -> [UInt8]? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: length), data.count == length else { return nil }
        return [UInt8](data)
    }

    private static func blockHandle(_ bytes: [UInt8], at start: Int) -> ((offset: UInt64, size: UInt64), Int)? {
        guard let (offset, next) = ProtobufBytes.varint(bytes, at: start),
              let (size, end) = ProtobufBytes.varint(bytes, at: next) else { return nil }
        return ((offset, size), end)
    }

    /// A block is followed by one byte of compression type and a 4-byte CRC.
    private static func readBlock(_ handle: FileHandle, fileSize: UInt64, handle block: (offset: UInt64, size: UInt64)) -> [UInt8]? {
        guard block.size < UInt64(maximumFileBytes), block.offset + block.size + 5 <= fileSize,
              let raw = read(handle, offset: block.offset, length: Int(block.size) + 1) else { return nil }
        let contents = Array(raw[0..<Int(block.size)])
        switch raw[Int(block.size)] {
        case 0: return contents
        case 1: return Snappy.decompress(contents)
        default: return nil
        }
    }

    struct Entry { let key: [UInt8]; let value: [UInt8] }

    /// Keys share prefixes with the one before; a restart array ends the block.
    static func blockEntries(_ block: [UInt8]) -> [Entry] {
        guard block.count >= 4 else { return [] }
        let restarts = Int(UInt32(block[block.count - 4]) | UInt32(block[block.count - 3]) << 8
            | UInt32(block[block.count - 2]) << 16 | UInt32(block[block.count - 1]) << 24)
        let limit = block.count - 4 - restarts * 4
        guard limit >= 0 else { return [] }
        var entries: [Entry] = [], index = 0, previous: [UInt8] = []
        while index < limit {
            guard let (shared, a) = ProtobufBytes.varint(block, at: index),
                  let (unshared, b) = ProtobufBytes.varint(block, at: a),
                  let (valueLength, c) = ProtobufBytes.varint(block, at: b),
                  Int(shared) <= previous.count,
                  c + Int(unshared) + Int(valueLength) <= limit else { break }
            let key = Array(previous[0..<Int(shared)]) + Array(block[c..<(c + Int(unshared))])
            let valueStart = c + Int(unshared)
            entries.append(Entry(key: key, value: Array(block[valueStart..<(valueStart + Int(valueLength))])))
            previous = key
            index = valueStart + Int(valueLength)
        }
        return entries
    }

    /// An internal key is the user key plus 8 bytes: sequence << 8 | type.
    private static func splitInternalKey(_ key: [UInt8]) -> (user: ArraySlice<UInt8>, sequence: UInt64, type: UInt8)? {
        guard key.count >= 8 else { return nil }
        var tag: UInt64 = 0
        for (shift, byte) in key[(key.count - 8)...].enumerated() { tag |= UInt64(byte) << (8 * UInt64(shift)) }
        return (key[0..<(key.count - 8)], tag >> 8, UInt8(tag & 0xFF))
    }

    private static func compare(_ lhs: ArraySlice<UInt8>, _ rhs: [UInt8]) -> Int {
        for (a, b) in zip(lhs, rhs) where a != b { return a < b ? -1 : 1 }
        return lhs.count == rhs.count ? 0 : (lhs.count < rhs.count ? -1 : 1)
    }

    // MARK: Log

    /// 32 KiB blocks of records (CRC 4, length 2, type 1). Records join into
    /// write batches: sequence 8, count 4, then put/delete entries.
    private static func logLookup(_ url: URL, key: [UInt8]) -> [Version] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maximumFileBytes else { return [] }
        let bytes = [UInt8](data)
        var versions: [Version] = [], batch: [UInt8] = [], offset = 0
        let blockSize = 32 * 1024
        while offset + 7 <= bytes.count {
            let leftInBlock = blockSize - offset % blockSize
            if leftInBlock < 7 { offset += leftInBlock; continue }
            let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
            let type = bytes[offset + 6]
            let start = offset + 7
            guard start + length <= bytes.count, length <= leftInBlock - 7 else { break }
            let payload = bytes[start..<(start + length)]
            offset = start + length
            switch type {
            case 1: versions += batchLookup(Array(payload), key: key)
            case 2: batch = Array(payload)
            case 3: batch += payload
            case 4: batch += payload; versions += batchLookup(batch, key: key); batch = []
            default: batch = []   // zero padding at the end of a block
            }
        }
        return versions
    }

    private static func batchLookup(_ batch: [UInt8], key: [UInt8]) -> [Version] {
        guard batch.count >= 12 else { return [] }
        var sequence: UInt64 = 0
        for shift in 0..<8 { sequence |= UInt64(batch[shift]) << (8 * UInt64(shift)) }
        var versions: [Version] = [], index = 12
        while index < batch.count {
            let type = batch[index]; index += 1
            guard let (keyLength, a) = ProtobufBytes.varint(batch, at: index), a + Int(keyLength) <= batch.count else { break }
            let entryKey = Array(batch[a..<(a + Int(keyLength))])
            index = a + Int(keyLength)
            var value: [UInt8]?
            if type == 1 {
                guard let (valueLength, b) = ProtobufBytes.varint(batch, at: index), b + Int(valueLength) <= batch.count else { break }
                value = Array(batch[b..<(b + Int(valueLength))])
                index = b + Int(valueLength)
            } else if type != 0 { break }
            if entryKey == key { versions.append(Version(sequence: sequence, value: value)) }
            sequence += 1
        }
        return versions
    }
}

// MARK: - Snappy

enum Snappy {
    static func decompress(_ input: [UInt8]) -> [UInt8]? {
        guard let (length, start) = ProtobufBytes.varint(input, at: 0), length <= UInt64(64 << 20) else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(Int(length))
        var index = start
        while index < input.count {
            let tag = input[index]; index += 1
            switch tag & 3 {
            case 0:
                var literal = Int(tag >> 2) + 1
                if literal > 60 {
                    let extra = literal - 60
                    guard index + extra <= input.count else { return nil }
                    literal = 0
                    for byte in 0..<extra { literal |= Int(input[index + byte]) << (8 * byte) }
                    literal += 1
                    index += extra
                }
                guard index + literal <= input.count else { return nil }
                output += input[index..<(index + literal)]
                index += literal
            case 1:
                guard index < input.count else { return nil }
                let count = 4 + Int((tag >> 2) & 7)
                let offset = Int(tag >> 5) << 8 | Int(input[index]); index += 1
                guard copy(&output, offset: offset, count: count) else { return nil }
            case 2:
                guard index + 2 <= input.count else { return nil }
                let offset = Int(input[index]) | Int(input[index + 1]) << 8; index += 2
                guard copy(&output, offset: offset, count: Int(tag >> 2) + 1) else { return nil }
            default:
                guard index + 4 <= input.count else { return nil }
                var offset = 0
                for byte in 0..<4 { offset |= Int(input[index + byte]) << (8 * byte) }
                index += 4
                guard copy(&output, offset: offset, count: Int(tag >> 2) + 1) else { return nil }
            }
        }
        return output.count == Int(length) ? output : nil
    }

    /// Copies may overlap what they write (a run), so byte by byte.
    private static func copy(_ output: inout [UInt8], offset: Int, count: Int) -> Bool {
        guard offset > 0, offset <= output.count else { return false }
        let start = output.count - offset
        for position in 0..<count { output.append(output[start + position]) }
        return true
    }
}
