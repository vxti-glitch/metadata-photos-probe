import Foundation
import CryptoKit

public struct HEICItemInventory: Codable, Sendable, Equatable {
    public let primaryItemID: UInt32
    public let exifItemID: UInt32
    public let nonExifItemSHA256: [String: String]
    public let itemGraphSHA256: String
    public let limitations: [String]
}

/// Narrow HEIF metadata-only writer. Original container/data bytes keep their offsets;
/// a new Exif item payload is appended and only its existing iloc locator is changed.
/// Uses no pixel decoder, encoder, third-party library or Photos-library mutation.
public enum HEICMetadataWriter {
    public static func inventory(_ url: URL) throws -> HEICItemInventory {
        let parsed = try HEICContainer(url)
        var hashes = [String: String]()
        for item in parsed.locations where item.id != parsed.exif.id {
            var digest = SHA256()
            for extent in item.extents { try parsed.hashRange(extent.absolute..<extent.absolute + extent.length, into: &digest) }
            hashes[String(item.id)] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var graph = parsed.meta
        for field in parsed.exif.mutableFields { graph.replaceSubrange(field.range, with: Data(repeating: 0, count: field.width)) }
        var digest = SHA256(); digest.update(data: parsed.ftyp); digest.update(data: graph)
        return HEICItemInventory(primaryItemID: parsed.primaryID, exifItemID: parsed.exif.id,
            nonExifItemSHA256: hashes, itemGraphSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            limitations: [parsed.sharedToneMapExif
                ? "The existing Exif item describes both the primary image and its directly related tone-map image; camera edits apply to both. Their references and all non-Exif item payloads are retained verbatim; other metadata namespaces are not synchronized."
                : "Only the selected primary Exif item is edited; other metadata namespaces are retained verbatim, not synchronized.",
                "Unreferenced original Exif bytes remain in the container; this is not a metadata-removal or provenance/authenticity operation."])
    }

    public static func write(source: URL, output: URL, patch: CameraPatch) throws {
        try patch.validate()
        guard source.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else { throw ProbeError.sameFile }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError.outputExists }
        let parsed = try HEICContainer(source)
        let originalHash = try WholeFileDigest.sha256(source)
        let oldExtent = parsed.exif.extents[0]
        guard oldExtent.length <= UInt64(HEICContainer.metadataLimit) else { throw ProbeError.unsupported("Exif item exceeds 16 MiB") }
        let original = try parsed.read(offset: oldExtent.absolute, count: Int(oldExtent.length))
        let changed = try HEICTIFFEditor.patch(original, camera: patch)
        guard changed.count <= HEICContainer.metadataLimit else { throw ProbeError.unsupported("Patched Exif exceeds 16 MiB") }
        let payloadOffset = try checkedAdd(parsed.fileSize, 8)
        var meta = parsed.meta
        for field in parsed.exif.mutableFields {
            let value: UInt64
            switch field.role {
            case .method, .base: value = 0
            case .offset: value = payloadOffset
            case .length: value = UInt64(changed.count)
            }
            try storeInteger(value, width: field.width, at: field.range.lowerBound, in: &meta, little: false)
        }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".heic-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw ProbeError.writeFailed("Cannot create HEIC staging file") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let destination = try FileHandle(forWritingTo: temporary); defer { try? destination.close() }
            var cursor: UInt64 = 0
            while cursor < parsed.fileSize {
                try Task.checkCancellation()
                let amount = Int(min(1_048_576, parsed.fileSize - cursor))
                try destination.write(contentsOf: parsed.read(offset: cursor, count: amount)); cursor += UInt64(amount)
            }
            var header = Data(repeating: 0, count: 8)
            try storeInteger(UInt64(changed.count + 8), width: 4, at: 0, in: &header, little: false)
            header.replaceSubrange(4..<8, with: Data("mdat".utf8))
            try destination.write(contentsOf: header); try destination.write(contentsOf: changed)
            try destination.seek(toOffset: parsed.metaOffset); try destination.write(contentsOf: meta)
            try destination.synchronize()
        }
        guard try WholeFileDigest.sha256(source) == originalHash,
              try HEICContainer.size(source) == parsed.fileSize else { throw ProbeError.writeFailed("HEIC source changed during processing") }
        guard try HEICContainer.size(temporary) == payloadOffset + UInt64(changed.count) else { throw ProbeError.writeFailed("HEIC staged size mismatch") }
        // Re-open both real files. Independent item payload/graph comparisons protect all
        // non-Exif image, thumbnail, auxiliary and opaque items, not merely mdat bytes.
        let before = try inventory(source), after = try inventory(temporary)
        guard before == after else { throw ProbeError.writeFailed("HEIC item payload or graph changed unexpectedly") }
        // Destination is exclusive; move never replaces a source/provider/existing file.
        try FileManager.default.moveItem(at: temporary, to: output)
    }
}

private enum LocatorRole { case method, base, offset, length }
private struct LocatorField {
    let role: LocatorRole
    let range: Range<Int>
    var width: Int { range.count }
}
private struct HEICExtent { let absolute: UInt64; let length: UInt64 }
private struct HEICLocation {
    let id: UInt32
    let extents: [HEICExtent]
    let mutableFields: [LocatorField]
}
private struct HEICBox {
    let type: String
    let start: UInt64
    let size: UInt64
    let header: UInt64
    var payload: Range<UInt64> { (start + header)..<(start + size) }
}

private final class HEICContainer {
    static let metadataLimit = 16 * 1_048_576
    private let handle: FileHandle
    let fileSize: UInt64
    let ftyp: Data
    let meta: Data
    let metaOffset: UInt64
    let primaryID: UInt32
    let locations: [HEICLocation]
    let exif: HEICLocation
    let sharedToneMapExif: Bool

    static func size(_ url: URL) throws -> UInt64 {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular, let size = values[.size] as? NSNumber else { throw ProbeError.unsupported("HEIC input must be a regular file") }
        return size.uint64Value
    }

    init(_ url: URL) throws {
        fileSize = try Self.size(url)
        handle = try FileHandle(forReadingFrom: url)
        let size = fileSize
        let reader = handle
        func read(_ offset: UInt64, _ count: Int) throws -> Data { try fileData(reader, offset: offset, count: count, size: size) }
        var top = [HEICBox](), position: UInt64 = 0
        while position < size {
            let box = try fileBox(at: position, end: size, read: read)
            guard ["ftyp", "meta", "mdat", "free", "skip", "wide"].contains(box.type) else { throw ProbeError.unsupported("Unqualified HEIC top-level box \(box.type)") }
            top.append(box); position += box.size
            guard top.count <= 10_000 else { throw ProbeError.malformed("Too many HEIC top-level boxes") }
        }
        guard let typeBox = top.first(where: { $0.type == "ftyp" }), top.filter({ $0.type == "ftyp" }).count == 1,
              let metaBox = top.first(where: { $0.type == "meta" }), top.filter({ $0.type == "meta" }).count == 1,
              typeBox.size <= 4096, metaBox.size <= UInt64(Self.metadataLimit) else { throw ProbeError.unsupported("HEIC requires one bounded ftyp and meta box") }
        ftyp = try read(typeBox.start, Int(typeBox.size)); meta = try read(metaBox.start, Int(metaBox.size)); metaOffset = metaBox.start
        var brands = [String]()
        var brandOffset = Int(typeBox.header)
        while brandOffset + 4 <= ftyp.count {
            if brandOffset != Int(typeBox.header) + 4 { brands.append(String(decoding: ftyp[brandOffset..<brandOffset + 4], as: UTF8.self)) }
            brandOffset += 4
        }
        guard brands.contains("heic") || brands.contains("heix"), !brands.contains("msf1") else { throw ProbeError.unsupported("Only still HEVC HEIC brands are qualified") }
        let start = Int(metaBox.header)
        guard try integer(meta, at: start, width: 4) == 0 else { throw ProbeError.unsupported("Nonzero HEIC meta version/flags") }
        let children = try dataBoxes(meta, start: start + 4, end: meta.count)
        func unique(_ type: String) throws -> HEICBox {
            let matches = children.filter { $0.type == type }
            guard matches.count == 1 else { throw ProbeError.unsupported("HEIC requires exactly one \(type) box") }
            return matches[0]
        }
        guard !children.contains(where: { $0.type == "ipro" }) else { throw ProbeError.unsupported("Protected HEIC items are not editable") }
        let pitm = try unique("pitm"), iinf = try unique("iinf"), iloc = try unique("iloc"), iref = try unique("iref")
        var primary = Cursor(data: meta, position: Int(pitm.payload.lowerBound), end: Int(pitm.payload.upperBound))
        let primaryVersion = try primary.fullBoxVersion(allowed: [0, 1])
        primaryID = UInt32(try primary.number(primaryVersion == 0 ? 2 : 4)); try primary.finish()
        let info = try itemInfo(meta, box: iinf)
        guard ["hvc1", "grid"].contains(info[primaryID] ?? "") else { throw ProbeError.unsupported("Unsupported primary HEIC item type") }
        let exifIDs = info.filter { $0.value == "Exif" }.map(\.key)
        guard exifIDs.count == 1 else { throw ProbeError.unsupported("An existing unique Exif item is required; no implicit item creation") }
        let exifID = exifIDs[0]
        sharedToneMapExif = try checkExifReference(meta, box: iref, exifID: exifID, primaryID: primaryID, itemTypes: info)
        let idats = children.filter { $0.type == "idat" }
        guard idats.count <= 1 else { throw ProbeError.unsupported("Multiple idat boxes") }
        let idat = idats.first.map { (metaBox.start + $0.payload.lowerBound)..<(metaBox.start + $0.payload.upperBound) }
        locations = try itemLocations(meta, box: iloc, knownIDs: Set(info.keys), mdatRanges: top.filter { $0.type == "mdat" }.map(\.payload), idat: idat)
        guard let target = locations.first(where: { $0.id == exifID }), target.extents.count == 1,
              target.mutableFields.contains(where: { $0.role == .offset && $0.width > 0 }),
              target.mutableFields.contains(where: { $0.role == .length && $0.width > 0 }) else { throw ProbeError.unsupported("Exif requires one retargetable extent") }
        exif = target
    }
    deinit { try? handle.close() }
    func read(offset: UInt64, count: Int) throws -> Data { try fileData(handle, offset: offset, count: count, size: fileSize) }
    func hashRange(_ range: Range<UInt64>, into digest: inout SHA256) throws {
        var position = range.lowerBound
        while position < range.upperBound {
            try Task.checkCancellation()
            let amount = Int(min(1_048_576, range.upperBound - position))
            digest.update(data: try read(offset: position, count: amount)); position += UInt64(amount)
        }
    }
}

private struct Cursor {
    let data: Data
    var position: Int
    let end: Int
    mutating func number(_ width: Int) throws -> UInt64 {
        guard width >= 0, width <= 8, position <= end, width <= end - position else { throw ProbeError.malformed("Truncated HEIC field") }
        let value = try integer(data, at: position, width: width); position += width; return value
    }
    mutating func fullBoxVersion(allowed: [UInt8]) throws -> UInt8 {
        let value = try number(4), version = UInt8(value >> 24)
        guard allowed.contains(version), value & 0x00ff_ffff == 0 else { throw ProbeError.unsupported("Unqualified HEIC box version/flags") }
        return version
    }
    func finish() throws { guard position == end else { throw ProbeError.malformed("Trailing HEIC structure fields") } }
}

private func fileData(_ handle: FileHandle, offset: UInt64, count: Int, size: UInt64) throws -> Data {
    guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ProbeError.malformed("HEIC read exceeds file") }
    try handle.seek(toOffset: offset)
    var data = Data(); data.reserveCapacity(count)
    while data.count < count {
        guard let bytes = try handle.read(upToCount: count - data.count), !bytes.isEmpty else { throw ProbeError.malformed("Truncated HEIC file") }
        data.append(bytes)
    }
    return data
}
private func fileBox(at start: UInt64, end: UInt64, read: (UInt64, Int) throws -> Data) throws -> HEICBox {
    guard start <= end, end - start >= 8 else { throw ProbeError.malformed("Truncated HEIC box") }
    let data = try read(start, 8)
    var size = try integer(data, at: 0, width: 4), header: UInt64 = 8
    if size == 1 { guard end - start >= 16 else { throw ProbeError.malformed("Truncated large HEIC box") }; size = try integer(read(start + 8, 8), at: 0, width: 8); header = 16 }
    guard size != 0 else { throw ProbeError.unsupported("EOF-sized HEIC boxes cannot be extended safely") }
    guard size >= header, size <= end - start else { throw ProbeError.malformed("HEIC box exceeds container") }
    return HEICBox(type: String(decoding: data[4..<8], as: UTF8.self), start: start, size: size, header: header)
}
private func dataBoxes(_ data: Data, start: Int, end: Int) throws -> [HEICBox] {
    var boxes = [HEICBox](), position = UInt64(start)
    while position < UInt64(end) {
        let box = try fileBox(at: position, end: UInt64(end)) { offset, count in
            guard offset <= UInt64(data.count), UInt64(count) <= UInt64(data.count) - offset else { throw ProbeError.malformed("HEIC child out of bounds") }
            return Data(data[Int(offset)..<Int(offset) + count])
        }
        boxes.append(box); position += box.size
        guard boxes.count <= 10_000 else { throw ProbeError.malformed("Too many HEIC child boxes") }
    }
    return boxes
}
private func itemInfo(_ data: Data, box: HEICBox) throws -> [UInt32: String] {
    var cursor = Cursor(data: data, position: Int(box.payload.lowerBound), end: Int(box.payload.upperBound))
    let version = try cursor.fullBoxVersion(allowed: [0, 1])
    let count = try cursor.number(version == 0 ? 2 : 4)
    guard count <= 4096 else { throw ProbeError.unsupported("HEIC item count exceeds 4096") }
    let entries = try dataBoxes(data, start: cursor.position, end: cursor.end)
    guard entries.count == count else { throw ProbeError.malformed("HEIC item info count mismatch") }
    var result = [UInt32: String]()
    for entry in entries {
        guard entry.type == "infe" else { throw ProbeError.unsupported("Unknown HEIC item information entry") }
        var item = Cursor(data: data, position: Int(entry.payload.lowerBound), end: Int(entry.payload.upperBound))
        // The infe hidden flag is legitimate and must remain untouched.
        let full = try item.number(4), version = UInt8(full >> 24)
        guard [2, 3].contains(version), full & 0x00ff_fffe == 0 else { throw ProbeError.unsupported("Unqualified infe version/flags") }
        let id = UInt32(try item.number(version == 2 ? 2 : 4))
        guard try item.number(2) == 0 else { throw ProbeError.unsupported("Protected HEIC item") }
        let raw = try item.number(4)
        let type = String(bytes: (0..<4).map { UInt8((raw >> (24 - $0 * 8)) & 255) }, encoding: .ascii) ?? ""
        guard result[id] == nil, data[item.position..<item.end].contains(0) else { throw ProbeError.malformed("Duplicate item ID or missing item name terminator") }
        result[id] = type
    }
    return result
}
private struct HEICItemReference {
    let type: String
    let from: UInt32
    let targets: [UInt32]
}

private func checkExifReference(_ data: Data, box: HEICBox, exifID: UInt32, primaryID: UInt32, itemTypes: [UInt32: String]) throws -> Bool {
    var cursor = Cursor(data: data, position: Int(box.payload.lowerBound), end: Int(box.payload.upperBound))
    let version = try cursor.fullBoxVersion(allowed: [0, 1]), width = version == 0 ? 2 : 4
    let knownIDs = Set(itemTypes.keys)
    var references = [HEICItemReference]()
    for reference in try dataBoxes(data, start: cursor.position, end: cursor.end) {
        var ref = Cursor(data: data, position: Int(reference.payload.lowerBound), end: Int(reference.payload.upperBound))
        let from = UInt32(try ref.number(width)), count = try ref.number(2)
        guard knownIDs.contains(from), count <= 4096 else { throw ProbeError.malformed("Invalid HEIC item reference") }
        var targets = [UInt32]()
        for _ in 0..<Int(count) { let id = UInt32(try ref.number(width)); guard knownIDs.contains(id) else { throw ProbeError.malformed("Unknown referenced HEIC item") }; targets.append(id) }
        try ref.finish()
        references.append(HEICItemReference(type: reference.type, from: from, targets: targets))
    }
    let descriptions = references.filter { $0.from == exifID }
    guard descriptions.count == 1, let description = descriptions.first, description.type == "cdsc" else {
        throw ProbeError.unsupported("Exif requires exactly one descriptive reference")
    }
    if description.targets == [primaryID] { return false }
    // Qualify only the observed shared primary/tmap pattern. A cdsc list alone
    // does not prove that multiple described images represent the same capture.
    guard description.targets.count == 2, Set(description.targets).count == 2,
          description.targets.contains(primaryID),
          let toneMapID = description.targets.first(where: { $0 != primaryID }), itemTypes[toneMapID] == "tmap" else {
        throw ProbeError.unsupported("Exif has ambiguous association")
    }
    let toneReferences = references.filter { $0.from == toneMapID }
    guard toneReferences.count == 1, let toneInputs = toneReferences.first,
          toneInputs.type == "dimg", toneInputs.targets.count == 2, toneInputs.targets[0] == primaryID,
          toneInputs.targets[1] != primaryID, toneInputs.targets[1] != toneMapID else {
        throw ProbeError.unsupported("Shared Exif tone map requires ordered primary and gain-map inputs")
    }
    // HEIF tone-map inputs are ordered base image then gain map (AOM AVIF
    // 1.2 §4.2.2, also enforced by libavif's tone-map item reader). Payloads,
    // gain-map properties and recipes are opaque here and remain unchanged.
    let gainMapID = toneInputs.targets[1]
    let gainLinks = references.filter { $0.from == gainMapID && $0.type == "auxl" }
    guard gainLinks.count == 1, gainLinks[0].targets == [primaryID] else {
        throw ProbeError.unsupported("Shared Exif tone-map gain map must describe the same primary image")
    }
    // Only direct hvc1 images or grids of hvc1 tiles are qualified. Restricting
    // each dependency layer rules out cycles, nested tone maps and unrelated
    // representations without changing or normalizing any reference bytes.
    for imageID in [primaryID, gainMapID] {
        let outgoing = references.filter { $0.from == imageID }
        let allowed = imageID == gainMapID ? Set(["dimg", "auxl"]) : Set(["dimg"])
        guard outgoing.allSatisfy({ allowed.contains($0.type) }), Set(outgoing.map(\.type)).count == outgoing.count else {
            throw ProbeError.unsupported("Unqualified shared Exif image relationship")
        }
        let dependencies = outgoing.filter { $0.type == "dimg" }
        switch itemTypes[imageID] {
        case "hvc1":
            guard dependencies.isEmpty else { throw ProbeError.unsupported("Coded tone-map input has derived-image dependencies") }
        case "grid":
            guard dependencies.count == 1, !dependencies[0].targets.isEmpty,
                  Set(dependencies[0].targets).count == dependencies[0].targets.count else {
                throw ProbeError.unsupported("Shared Exif grid requires unique coded-image tiles")
            }
            for tileID in dependencies[0].targets {
                guard tileID != primaryID, tileID != gainMapID, itemTypes[tileID] == "hvc1",
                      !references.contains(where: { $0.from == tileID && $0.type == "dimg" }) else {
                    throw ProbeError.unsupported("Shared Exif grid contains an unqualified or cyclic dependency")
                }
            }
        default: throw ProbeError.unsupported("Unqualified shared Exif tone-map input type")
        }
    }
    return true
}
private func itemLocations(_ data: Data, box: HEICBox, knownIDs: Set<UInt32>, mdatRanges: [Range<UInt64>], idat: Range<UInt64>?) throws -> [HEICLocation] {
    var cursor = Cursor(data: data, position: Int(box.payload.lowerBound), end: Int(box.payload.upperBound))
    let version = try cursor.fullBoxVersion(allowed: [0, 1, 2])
    let first = try cursor.number(1), second = try cursor.number(1)
    let offsetWidth = Int(first >> 4), lengthWidth = Int(first & 15), baseWidth = Int(second >> 4), indexWidth = version == 0 ? 0 : Int(second & 15)
    guard [offsetWidth, lengthWidth, baseWidth, indexWidth].allSatisfy({ [0, 4, 8].contains($0) }), lengthWidth > 0 else { throw ProbeError.unsupported("Unqualified HEIC iloc field widths") }
    let count = try cursor.number(version < 2 ? 2 : 4)
    guard count <= 4096 else { throw ProbeError.unsupported("HEIC location count exceeds 4096") }
    var result = [HEICLocation](), seen = Set<UInt32>()
    for _ in 0..<Int(count) {
        let id = UInt32(try cursor.number(version < 2 ? 2 : 4))
        guard knownIDs.contains(id), seen.insert(id).inserted else { throw ProbeError.malformed("Unknown/duplicate HEIC locator ID") }
        var fields = [LocatorField](), method: UInt64 = 0
        if version > 0 { let start = cursor.position; method = try cursor.number(2); guard method <= 1 else { throw ProbeError.unsupported("Unqualified HEIC item construction method") }; fields.append(LocatorField(role: .method, range: start..<cursor.position)) }
        guard try cursor.number(2) == 0 else { throw ProbeError.unsupported("External HEIC item references") }
        let baseStart = cursor.position, base = try cursor.number(baseWidth)
        if baseWidth > 0 { fields.append(LocatorField(role: .base, range: baseStart..<cursor.position)) }
        let extentCount = try cursor.number(2)
        guard extentCount > 0, extentCount <= 4096 else { throw ProbeError.unsupported("Empty/excessive HEIC extent count") }
        var extents = [HEICExtent]()
        for _ in 0..<Int(extentCount) {
            if version > 0, indexWidth > 0 { guard try cursor.number(indexWidth) == 0 else { throw ProbeError.unsupported("Indexed HEIC extents") } }
            let offsetStart = cursor.position, offset = try cursor.number(offsetWidth)
            fields.append(LocatorField(role: .offset, range: offsetStart..<cursor.position))
            let lengthStart = cursor.position, length = try cursor.number(lengthWidth)
            fields.append(LocatorField(role: .length, range: lengthStart..<cursor.position))
            guard length > 0 else { throw ProbeError.unsupported("Zero-length HEIC extent cannot be appended safely") }
            var absolute = try checkedAdd(base, offset)
            if method == 1 { guard let idat else { throw ProbeError.malformed("HEIC idat missing") }; absolute = try checkedAdd(idat.lowerBound, absolute) }
            let end = try checkedAdd(absolute, length)
            let ranges = method == 1 ? (idat.map { [$0] } ?? []) : mdatRanges
            guard ranges.contains(where: { absolute >= $0.lowerBound && end <= $0.upperBound }) else { throw ProbeError.malformed("HEIC extent outside local media payload") }
            extents.append(HEICExtent(absolute: absolute, length: length))
        }
        result.append(HEICLocation(id: id, extents: extents, mutableFields: fields))
    }
    try cursor.finish()
    guard seen == knownIDs else { throw ProbeError.unsupported("HEIC item/location inventory differs") }
    return result
}

private enum HEICTIFFEditor {
    static func patch(_ item: Data, camera: CameraPatch) throws -> Data {
        guard item.count >= 12 else { throw ProbeError.malformed("Short HEIF Exif item") }
        let header = try integer(item, at: 0, width: 4)
        guard header <= UInt64(item.count - 12) else { throw ProbeError.malformed("Exif TIFF header offset exceeds item") }
        let prefix = 4 + Int(header)
        var tiff = Data(item[prefix...])
        let little: Bool
        if tiff.prefix(2) == Data("II".utf8) { little = true }
        else if tiff.prefix(2) == Data("MM".utf8) { little = false }
        else { throw ProbeError.malformed("Exif byte order") }
        guard try integer(tiff, at: 2, width: 2, little: little) == 42 else { throw ProbeError.unsupported("Only classic TIFF Exif is qualified") }
        let originalRoot = Int(try integer(tiff, at: 4, width: 4, little: little))
        var visited = Set<Int>()
        try validateIFD(tiff, at: originalRoot, little: little, visited: &visited)
        let root = try readIFD(tiff, at: originalRoot, little: little)
        var rootEntries = root.entries
        try replaceASCII(tag: 0x010f, value: camera.make, entries: &rootEntries, tiff: &tiff, little: little)
        try replaceASCII(tag: 0x0110, value: camera.model, entries: &rootEntries, tiff: &tiff, little: little)
        if let lens = camera.lens {
            let exifEntry = root.entries.first { (try? integer($0, at: 0, width: 2, little: little)) == 0x8769 }
            let oldExif = try exifEntry.map { Int(try integer($0, at: 8, width: 4, little: little)) }
            let directory = try oldExif.map { try readIFD(tiff, at: $0, little: little) } ?? (entries: [], next: UInt64(0))
            var entries = directory.entries
            try replaceASCII(tag: 0xa434, value: lens, entries: &entries, tiff: &tiff, little: little)
            let newExif = try appendIFD(entries, next: directory.next, to: &tiff, little: little)
            var pointer = Data(repeating: 0, count: 12)
            try storeInteger(0x8769, width: 2, at: 0, in: &pointer, little: little)
            try storeInteger(4, width: 2, at: 2, in: &pointer, little: little)
            try storeInteger(1, width: 4, at: 4, in: &pointer, little: little)
            try storeInteger(UInt64(newExif), width: 4, at: 8, in: &pointer, little: little)
            rootEntries.removeAll { (try? integer($0, at: 0, width: 2, little: little)) == 0x8769 }; rootEntries.append(pointer)
        }
        let newRoot = try appendIFD(rootEntries, next: root.next, to: &tiff, little: little)
        try storeInteger(UInt64(newRoot), width: 4, at: 4, in: &tiff, little: little)
        return Data(item.prefix(prefix)) + tiff
    }

    private static func readIFD(_ data: Data, at offset: Int, little: Bool) throws -> (entries: [Data], next: UInt64) {
        guard offset >= 8 else { throw ProbeError.malformed("TIFF IFD overlaps header") }
        let count = Int(try integer(data, at: offset, width: 2, little: little))
        guard count <= 4096, offset <= data.count, 2 + count * 12 + 4 <= data.count - offset else { throw ProbeError.malformed("TIFF IFD count/offset out of bounds") }
        var entries = [Data](), tags = Set<UInt64>()
        for index in 0..<count {
            let entry = Data(data[offset + 2 + index * 12..<offset + 14 + index * 12])
            let tag = try integer(entry, at: 0, width: 2, little: little)
            guard tags.insert(tag).inserted else { throw ProbeError.unsupported("Duplicate TIFF tags") }
            entries.append(entry)
        }
        return (entries, try integer(data, at: offset + 2 + count * 12, width: 4, little: little))
    }
    private static func validateIFD(_ data: Data, at offset: Int, little: Bool, visited: inout Set<Int>) throws {
        guard visited.insert(offset).inserted, visited.count <= 32 else { throw ProbeError.malformed("Cyclic/excessive TIFF directories") }
        let directory = try readIFD(data, at: offset, little: little)
        for entry in directory.entries {
            let type = Int(try integer(entry, at: 2, width: 2, little: little))
            let widths = [1:1, 2:1, 3:2, 4:4, 5:8, 6:1, 7:1, 8:2, 9:4, 10:8, 11:4, 12:8, 13:4]
            guard let width = widths[type] else { throw ProbeError.unsupported("Unknown TIFF field type") }
            let count = try integer(entry, at: 4, width: 4, little: little), length = count * UInt64(width)
            let pointer = try integer(entry, at: 8, width: 4, little: little)
            if length > 4 { guard pointer <= UInt64(data.count), length <= UInt64(data.count) - pointer else { throw ProbeError.malformed("TIFF field payload out of bounds") } }
            let tag = try integer(entry, at: 0, width: 2, little: little)
            if [0x8769, 0x8825, 0xa005].contains(tag) {
                guard type == 4, count == 1, pointer > 0 else { throw ProbeError.malformed("Invalid TIFF directory pointer") }
                try validateIFD(data, at: Int(pointer), little: little, visited: &visited)
            }
        }
        if directory.next != 0 { try validateIFD(data, at: Int(directory.next), little: little, visited: &visited) }
    }
    private static func replaceASCII(tag: UInt64, value: String, entries: inout [Data], tiff: inout Data, little: Bool) throws {
        guard value.utf8.allSatisfy({ $0 < 128 }) else { throw ProbeError.unsupported("HEIC TIFF camera tags require ASCII in this probe") }
        let bytes = Data(value.utf8) + Data([0])
        var entry = Data(repeating: 0, count: 12)
        try storeInteger(tag, width: 2, at: 0, in: &entry, little: little); try storeInteger(2, width: 2, at: 2, in: &entry, little: little)
        try storeInteger(UInt64(bytes.count), width: 4, at: 4, in: &entry, little: little)
        if bytes.count <= 4 { entry.replaceSubrange(8..<8 + bytes.count, with: bytes) }
        else {
            // TIFF Value Offsets are word-aligned, including ASCII payloads.
            // Each preceding string may itself have an odd byte count.
            if tiff.count % 2 != 0 { tiff.append(0) }
            try storeInteger(UInt64(tiff.count), width: 4, at: 8, in: &entry, little: little)
            tiff.append(bytes)
        }
        entries.removeAll { (try? integer($0, at: 0, width: 2, little: little)) == tag }; entries.append(entry)
    }
    private static func appendIFD(_ entries: [Data], next: UInt64, to tiff: inout Data, little: Bool) throws -> Int {
        guard entries.count <= 4096 else { throw ProbeError.unsupported("Too many patched TIFF entries") }
        if tiff.count % 2 != 0 { tiff.append(0) }
        let offset = tiff.count
        var directory = Data(repeating: 0, count: 2)
        try storeInteger(UInt64(entries.count), width: 2, at: 0, in: &directory, little: little)
        let sorted = entries.sorted { (try! integer($0, at: 0, width: 2, little: little)) < (try! integer($1, at: 0, width: 2, little: little)) }
        for entry in sorted { directory.append(entry) }
        var tail = Data(repeating: 0, count: 4); try storeInteger(next, width: 4, at: 0, in: &tail, little: little)
        directory.append(tail); tiff.append(directory); return offset
    }
}

private func integer(_ data: Data, at offset: Int, width: Int, little: Bool = false) throws -> UInt64 {
    guard offset >= 0, width >= 0, width <= 8, offset <= data.count, width <= data.count - offset else { throw ProbeError.malformed("Binary integer out of bounds") }
    let bytes = data[offset..<offset + width]
    return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { ($0 << 8) | UInt64($1) }
}
private func storeInteger(_ value: UInt64, width: Int, at offset: Int, in data: inout Data, little: Bool) throws {
    guard width > 0, width <= 8, offset >= 0, offset <= data.count, width <= data.count - offset,
          width == 8 || value < (UInt64(1) << (width * 8)) else { throw ProbeError.unsupported("Binary locator/offset cannot represent patched value") }
    for index in 0..<width { data[offset + index] = UInt8((value >> ((little ? index : width - 1 - index) * 8)) & 255) }
}
private func checkedAdd(_ first: UInt64, _ second: UInt64) throws -> UInt64 {
    let (value, overflow) = first.addingReportingOverflow(second)
    guard !overflow else { throw ProbeError.malformed("HEIC offset overflow") }
    return value
}
