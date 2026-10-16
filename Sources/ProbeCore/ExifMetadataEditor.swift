import Foundation

/// Classic TIFF editing without rebasing opaque MakerNotes or thumbnail offsets.
/// New directories are appended. Superseded targeted entries/values are erased,
/// with aliased payloads refused instead of damaging an unrelated retained tag.
enum ExifMetadataEditor {
    struct Field { let directory: UInt16; let tag: UInt16; let type: UInt16 }
    static let fields: [String: Field] = [
        "make": Field(directory: 0, tag: 0x010f, type: 2), "model": Field(directory: 0, tag: 0x0110, type: 2),
        "software": Field(directory: 0, tag: 0x0131, type: 2), "hostComputer": Field(directory: 0, tag: 0x013c, type: 2),
        "modifyDate": Field(directory: 0, tag: 0x0132, type: 2), "description": Field(directory: 0, tag: 0x010e, type: 2),
        "artist": Field(directory: 0, tag: 0x013b, type: 2), "copyright": Field(directory: 0, tag: 0x8298, type: 2),
        "title": Field(directory: 0, tag: 0x9c9b, type: 1), "keywords": Field(directory: 0, tag: 0x9c9e, type: 1),
        "lensMake": Field(directory: 0x8769, tag: 0xa433, type: 2), "lensModel": Field(directory: 0x8769, tag: 0xa434, type: 2),
        "iso": Field(directory: 0x8769, tag: 0x8827, type: 3), "exposureTime": Field(directory: 0x8769, tag: 0x829a, type: 5),
        "fNumber": Field(directory: 0x8769, tag: 0x829d, type: 5), "exposureCompensation": Field(directory: 0x8769, tag: 0x9204, type: 10),
        "focalLength": Field(directory: 0x8769, tag: 0x920a, type: 5), "focalLength35mm": Field(directory: 0x8769, tag: 0xa405, type: 3),
        "meteringMode": Field(directory: 0x8769, tag: 0x9207, type: 3), "flash": Field(directory: 0x8769, tag: 0x9209, type: 3),
        "dateTimeOriginal": Field(directory: 0x8769, tag: 0x9003, type: 2), "createDate": Field(directory: 0x8769, tag: 0x9004, type: 2),
        "offsetTime": Field(directory: 0x8769, tag: 0x9010, type: 2), "offsetTimeOriginal": Field(directory: 0x8769, tag: 0x9011, type: 2), "offsetTimeDigitized": Field(directory: 0x8769, tag: 0x9012, type: 2),
        "latitude": Field(directory: 0x8825, tag: 2, type: 5), "longitude": Field(directory: 0x8825, tag: 4, type: 5),
        "altitude": Field(directory: 0x8825, tag: 6, type: 5), "imageDirection": Field(directory: 0x8825, tag: 17, type: 5)
    ]
    struct Entry { let tag: UInt16; let type: UInt16; let count: Int; let raw: Data; let offset: Int; let payloadRange: Range<Int> }
    struct Directory { let entries: [Entry]; let next: UInt32 }
    struct TIFF {
        var bytes: Data
        let little: Bool
        var root: Int = 0
        init(_ data: Data) throws {
            bytes = data
            guard data.count >= 8, data.count <= 16 * 1_048_576 else { throw ProbeError.malformed("EXIF TIFF size") }
            if data.prefix(2) == Data("II".utf8) { little = true }
            else if data.prefix(2) == Data("MM".utf8) { little = false }
            else { throw ProbeError.malformed("EXIF byte order") }
            guard try n(2, 2) == 42 else { throw ProbeError.unsupported("BigTIFF EXIF is not qualified") }
            root = Int(try n(4, 4))
        }
        func n(_ offset: Int, _ width: Int) throws -> UInt32 {
            guard offset >= 0, width > 0, width <= 4, offset <= bytes.count, width <= bytes.count - offset else { throw ProbeError.malformed("EXIF integer out of bounds") }
            let sequence = Array(bytes[offset..<offset + width])
            return (little ? Array(sequence.reversed()) : sequence).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func directory(_ offset: Int) throws -> Directory {
            guard offset >= 8 else { throw ProbeError.malformed("EXIF directory overlaps header") }
            let count = Int(try n(offset, 2))
            guard count <= 4096, offset <= bytes.count, 2 + count * 12 + 4 <= bytes.count - offset else { throw ProbeError.malformed("EXIF directory length") }
            var entries = [Entry](), seen = Set<UInt16>()
            for index in 0..<count {
                let start = offset + 2 + index * 12, tag = UInt16(try n(start, 2)), type = UInt16(try n(start + 2, 2)), amount = Int(try n(start + 4, 4))
                let widths = [1:1, 2:1, 3:2, 4:4, 5:8, 6:1, 7:1, 8:2, 9:4, 10:8, 11:4, 12:8, 13:4]
                guard seen.insert(tag).inserted, let width = widths[Int(type)], amount <= bytes.count else { throw ProbeError.unsupported("Duplicate or unqualified EXIF tag") }
                let length = amount * width, valueOffset = length > 4 ? Int(try n(start + 8, 4)) : start + 8
                guard valueOffset <= bytes.count, length <= bytes.count - valueOffset else { throw ProbeError.malformed("EXIF payload outside item") }
                entries.append(Entry(tag: tag, type: type, count: amount, raw: bytes.subdata(in: start..<start + 12), offset: start, payloadRange: valueOffset..<valueOffset + length))
            }
            return Directory(entries: entries, next: try n(offset + 2 + count * 12, 4))
        }
        func allDirectories() throws -> [Int: Directory] {
            var pending = [root], result = [Int: Directory]()
            while let offset = pending.popLast() {
                guard result[offset] == nil, result.count < 32 else { throw ProbeError.malformed("Cyclic EXIF directories") }
                let d = try directory(offset); result[offset] = d
                for e in d.entries where [0x8769, 0x8825, 0xa005].contains(e.tag) {
                    guard e.type == 4, e.count == 1 else { throw ProbeError.malformed("EXIF subdirectory pointer") }
                    pending.append(Int(try n(e.offset + 8, 4)))
                }
                if d.next != 0 { pending.append(Int(d.next)) }
            }
            return result
        }
        func directoryFor(_ code: UInt16) throws -> Int? {
            if code == 0 { return root }
            let entry = try directory(root).entries.first { $0.tag == code }
            return try entry.map { Int(try n($0.offset + 8, 4)) }
        }
    }
    static let empty = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    static func number(_ value: UInt32, width: Int, little: Bool) -> Data {
        Data((0..<width).map { UInt8((value >> ((little ? $0 : width - 1 - $0) * 8)) & 255) })
    }
    static func rational(_ value: Double, signed: Bool, little: Bool) throws -> Data {
        guard value.isFinite, signed || value >= 0 else { throw ProbeError.invalidPatch }
        // Nanosecond shutters remain representable (1 / 1_000_000_000).
        // Reduce only when a UInt32 numerator cannot contain the scaled value.
        var denominator = 1_000_000_000.0
        let maximum = signed ? Double(Int32.max) : Double(UInt32.max)
        while abs(value) * denominator > maximum, denominator > 1 { denominator /= 10 }
        guard abs(value) * denominator <= maximum else { throw ProbeError.invalidPatch }
        let numerator = (value * denominator).rounded()
        guard (value == 0 || numerator != 0), abs(numerator / denominator - value) <= max(1e-12, abs(value) * 1e-6) else {
            throw ProbeError.unsupported("Requested numeric value cannot be represented faithfully as a 32-bit EXIF rational")
        }
        let n: UInt32 = signed ? UInt32(bitPattern: Int32(numerator)) : UInt32(numerator)
        return number(n, width: 4, little: little) + number(UInt32(denominator), width: 4, little: little)
    }
    static func patch(_ original: Data, patch: MetadataPatch) throws -> Data {
        try patch.validate()
        guard patch.targetedKeys.isSubset(of: Set(fields.keys)) else { throw ProbeError.unsupported("Requested field is not a still-image EXIF field") }
        for key in ["dateTimeOriginal", "createDate", "modifyDate"] {
            if let value = patch.values[key], value.text.range(of: "^\\d{4}:\\d{2}:\\d{2} \\d{2}:\\d{2}:\\d{2}$", options: .regularExpression) == nil {
                throw ProbeError.unsupported("Still-image dates require EXIF local wall time (YYYY:MM:DD HH:mm:ss) and separate time-zone offset fields; ISO dates are refused to avoid contradictory offsets")
            }
        }
        var t = try TIFF(original)
        let directories = try t.allDirectories(), originalRoot = try t.directory(t.root)
        guard !directories.values.contains(where: { directory in
            directory.entries.contains(where: { $0.tag == 0x014a || $0.type == 13 })
        }) else {
            // A retained SubIFD can alias a targeted payload. Erasing the old
            // value is unsafe until every referenced directory is inventoried.
            throw ProbeError.unsupported("EXIF SubIFD pointers require a qualified directory walker before editing")
        }
        var groups: [UInt16: [UInt16: Data]] = [:], nextValues = [UInt16: UInt32](), offsets = [UInt16: Int](), erased = Set<Int>()
        for group in [UInt16(0), 0x8769, 0x8825] {
            let offset = try t.directoryFor(group); offsets[group] = offset
            let d = try offset.map { try t.directory($0) }
            groups[group] = Dictionary(uniqueKeysWithValues: (d?.entries ?? []).map { ($0.tag, $0.raw) }); nextValues[group] = d?.next ?? 0
        }
        // A selected removal must not silently leave the same public tag in a
        // thumbnail/secondary directory. Those layouts require a wider rewrite.
        for key in patch.removals {
            let field = fields[key]!, expected = offsets[field.directory]
            guard !directories.contains(where: { $0.key != expected && $0.value.entries.contains(where: { $0.tag == field.tag }) }) else {
                throw ProbeError.unsupported("Selected \(key) also occurs in a secondary EXIF directory")
            }
        }
        var changedGroups = Set<UInt16>()
        func erase(_ tag: UInt16, _ group: UInt16) throws {
            guard let directoryOffset = offsets[group], let e = directories[directoryOffset]?.entries.first(where: { $0.tag == tag }) else { groups[group]?.removeValue(forKey: tag); return }
            if erased.contains(e.offset) { groups[group]?.removeValue(forKey: tag); return }
            let otherEntries = directories.values.flatMap(\.entries).filter { $0.offset != e.offset }
            if e.payloadRange.count > 4 {
                guard !otherEntries.contains(where: { $0.payloadRange.overlaps(e.payloadRange) }) else { throw ProbeError.unsupported("Target EXIF payload aliases another tag; removal/replacement is refused") }
                guard !directories.contains(where: { offset, directory in e.payloadRange.overlaps(offset..<offset + 2 + directory.entries.count * 12 + 4) }), !e.payloadRange.overlaps(0..<8) else { throw ProbeError.malformed("EXIF payload overlaps a directory/header") }
                t.bytes.replaceSubrange(e.payloadRange, with: Data(repeating: 0, count: e.payloadRange.count))
            }
            t.bytes.replaceSubrange(e.offset..<e.offset + 12, with: Data(repeating: 0, count: 12))
            erased.insert(e.offset)
            groups[group]?.removeValue(forKey: tag)
        }
        func set(_ tag: UInt16, _ type: UInt16, _ payload: Data, _ group: UInt16) throws {
            try erase(tag, group); changedGroups.insert(group)
            let width = type == 3 ? 2 : (type == 5 || type == 10 ? 8 : 1)
            var entry = number(UInt32(tag), width: 2, little: t.little) + number(UInt32(type), width: 2, little: t.little) + number(UInt32(payload.count / width), width: 4, little: t.little)
            if payload.count <= 4 { entry.append(payload); entry.append(Data(repeating: 0, count: 4 - payload.count)) }
            else { if t.bytes.count % 2 != 0 { t.bytes.append(0) }; entry.append(number(UInt32(t.bytes.count), width: 4, little: t.little)); t.bytes.append(payload) }
            groups[group]?[tag] = entry
        }
        for key in patch.targetedKeys.sorted() {
            let f = fields[key]!; try erase(f.tag, f.directory); changedGroups.insert(f.directory)
            let ref: UInt16? = key == "latitude" ? 1 : key == "longitude" ? 3 : key == "altitude" ? 5 : key == "imageDirection" ? 16 : nil
            if let ref { try erase(ref, f.directory) }
            guard let value = patch.values[key] else { continue }
            var payload: Data
            if ["title", "keywords"].contains(key) { payload = value.text.data(using: .utf16LittleEndian)! + Data([0, 0]) }
            else if f.type == 2 {
                let text = key.lowercased().contains("date") ? try MetadataPatch.exifDate(value.text) : value.text
                let sanitized = MetadataPatch.sanitizeText(text)
                guard sanitized.utf8.allSatisfy({ $0 < 128 }) else { throw ProbeError.unsupported("EXIF ASCII field \(key) cannot store non-ASCII text") }
                payload = Data(sanitized.utf8) + Data([0])
            } else if f.type == 3 { payload = number(UInt32(value.number!), width: 2, little: t.little) }
            else if ["latitude", "longitude"].contains(key) {
                let n = abs(value.number!), degrees = floor(n), minuteValue = (n - degrees) * 60, minutes = floor(minuteValue)
                payload = try rational(degrees, signed: false, little: t.little) + rational(minutes, signed: false, little: t.little) + rational((minuteValue - minutes) * 60, signed: false, little: t.little)
                try set(ref!, 2, Data((key == "latitude" ? (value.number! < 0 ? "S" : "N") : (value.number! < 0 ? "W" : "E")).utf8) + Data([0]), f.directory)
            } else {
                payload = try rational(key == "altitude" ? abs(value.number!) : value.number!, signed: f.type == 10, little: t.little)
                if key == "altitude" { try set(5, 1, Data([value.number! < 0 ? 1 : 0]), f.directory) }
                if key == "imageDirection" { try set(16, 2, Data([84, 0]), f.directory) }
            }
            try set(f.tag, f.type, payload, f.directory)
        }
        // GPSVersionID makes a newly introduced GPS directory self-contained.
        if changedGroups.contains(0x8825), !(groups[0x8825]?.isEmpty ?? true), groups[0x8825]?[0] == nil { try set(0, 1, Data([2, 3, 0, 0]), 0x8825) }
        func appendDirectory(_ group: UInt16) -> UInt32 {
            if t.bytes.count % 2 != 0 { t.bytes.append(0) }
            let offset = UInt32(t.bytes.count), entries = groups[group] ?? [:]
            t.bytes.append(number(UInt32(entries.count), width: 2, little: t.little))
            for key in entries.keys.sorted() { t.bytes.append(entries[key]!) }
            t.bytes.append(number(nextValues[group] ?? 0, width: 4, little: t.little)); return offset
        }
        for group in [UInt16(0x8769), 0x8825] where changedGroups.contains(group) {
            let offset = appendDirectory(group)
            groups[0]?[group] = number(UInt32(group), width: 2, little: t.little) + number(4, width: 2, little: t.little) + number(1, width: 4, little: t.little) + number(offset, width: 4, little: t.little)
        }
        nextValues[0] = originalRoot.next
        let newRoot = appendDirectory(0)
        t.bytes.replaceSubrange(4..<8, with: number(newRoot, width: 4, little: t.little))
        guard t.bytes.count <= 16 * 1_048_576 else { throw ProbeError.unsupported("Patched EXIF exceeds metadata budget") }
        return t.bytes
    }
    static func inspect(_ bytes: Data) throws -> [String: String] {
        let t = try TIFF(bytes); _ = try t.allDirectories(); var result = [String: String]()
        for (key, field) in fields {
            guard let offset = try t.directoryFor(field.directory), let entry = try t.directory(offset).entries.first(where: { $0.tag == field.tag }) else { continue }
            let payload = t.bytes.subdata(in: entry.payloadRange)
            if field.type == 2 { result[key] = String(data: payload.prefix(while: { $0 != 0 }), encoding: .utf8) }
            else if ["title", "keywords"].contains(key) { result[key] = String(data: payload, encoding: .utf16LittleEndian)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
            else if entry.type == 3, entry.count >= 1 { result[key] = String(try t.n(entry.payloadRange.lowerBound, 2)) }
            else if entry.type == 5 || entry.type == 10 {
                func r(_ index: Int) throws -> Double {
                    let start = entry.payloadRange.lowerBound + index * 8, numerator = try t.n(start, 4), denominator = try t.n(start + 4, 4)
                    guard denominator != 0 else { throw ProbeError.malformed("Zero EXIF rational denominator") }
                    return (entry.type == 10 ? Double(Int32(bitPattern: numerator)) : Double(numerator)) / Double(denominator)
                }
                var n = try r(0)
                if ["latitude", "longitude"].contains(key) {
                    guard entry.count == 3 else { throw ProbeError.malformed("GPS rational count") }
                    n += try r(1) / 60 + r(2) / 3600
                    let ref = try t.directory(offset).entries.first { $0.tag == (key == "latitude" ? 1 : 3) }
                    if let ref, let byte = t.bytes[ref.payloadRange].first, byte == 83 || byte == 87 { n = -n }
                }
                if key == "altitude", let ref = try t.directory(offset).entries.first(where: { $0.tag == 5 }), t.bytes[ref.payloadRange].first == 1 { n = -n }
                result[key] = MetadataValue.number(n).text
            }
        }
        return result
    }
}
