import Foundation
import CryptoKit

/// File-backed JPEG APP1 and PNG eXIf replacement. Every non-target byte is
/// copied verbatim, including JPEG scans and PNG IDAT/alpha/profile chunks.
enum StillContainerMetadata {
    struct Region { let offset: UInt64; let length: UInt64; let data: Data }
    struct Layout { let exif: Data?; let region: Region; let competingMetadata: Bool }
    static func read(_ handle: FileHandle, _ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, count <= 16 * 1_048_576 else { throw ProbeError.unsupported("Metadata read budget exceeded") }
        try handle.seek(toOffset: offset)
        let result = try handle.read(upToCount: count) ?? Data()
        guard result.count == count else { throw ProbeError.malformed("Truncated image segment") }
        return result
    }
    static func be32(_ data: Data) -> UInt32 { data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    static func n32(_ number: UInt32) -> Data { ExifMetadataEditor.number(number, width: 4, little: false) }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }
    static func crc(_ data: Data, state: UInt32 = 0xffffffff) -> UInt32 {
        var value = state
        for byte in data { value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 255)] }
        return value
    }
    static func pngChunk(_ type: String, _ payload: Data) -> Data {
        let body = Data(type.utf8) + payload
        return n32(UInt32(payload.count)) + body + n32(crc(body) ^ 0xffffffff)
    }
    static func layout(_ url: URL, kind: MediaKind) throws -> Layout {
        let size = UInt64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var found: Data?, region: Region?, competing = false
        if kind == .jpeg {
            guard try read(file, 0, 2) == Data([255, 216]) else { throw ProbeError.malformed("JPEG signature") }
            var cursor: UInt64 = 2, segments = 0
            while cursor < size {
                segments += 1; guard segments <= 100000 else { throw ProbeError.unsupported("JPEG marker count") }
                let start = cursor
                guard try read(file, cursor, 1)[0] == 255 else { throw ProbeError.malformed("JPEG marker boundary") }
                while cursor < size, try read(file, cursor, 1)[0] == 255 { cursor += 1 }
                guard cursor < size else { throw ProbeError.malformed("JPEG marker missing") }
                let marker = try read(file, cursor, 1)[0]; cursor += 1
                if marker == 0xda || marker == 0xd9 { break }
                if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
                let bytes = try read(file, cursor, 2), length = Int(bytes[0]) * 256 + Int(bytes[1])
                guard length >= 2, UInt64(length) <= size - cursor else { throw ProbeError.malformed("JPEG segment length") }
                if marker == 0xe1 {
                    let payload = try read(file, cursor + 2, length - 2)
                    if payload.starts(with: Data([69, 120, 105, 102, 0, 0])) {
                        guard found == nil else { throw ProbeError.unsupported("Multiple JPEG EXIF blocks") }
                        found = Data(payload.dropFirst(6)); region = Region(offset: start, length: cursor + UInt64(length) - start, data: Data())
                    } else { competing = true }
                }
                if marker == 0xed { competing = true }
                cursor += UInt64(length)
            }
            return Layout(exif: found, region: region ?? Region(offset: 2, length: 0, data: Data()), competingMetadata: competing)
        }
        guard kind == .png, try read(file, 0, 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw ProbeError.malformed("PNG signature") }
        var cursor: UInt64 = 8, insertion: UInt64?, count = 0, ended = false
        while cursor < size {
            count += 1; guard count <= 100000, size - cursor >= 12 else { throw ProbeError.malformed("PNG chunk count/size") }
            let header = try read(file, cursor, 8), length = UInt64(be32(header)), type = String(decoding: header[4..<8], as: UTF8.self)
            guard length <= size - cursor - 12, length <= 0x7fffffff else { throw ProbeError.malformed("PNG chunk exceeds file") }
            if type == "acTL" { throw ProbeError.unsupported("Animated PNG is outside still-image editing") }
            if type == "IDAT", insertion == nil { insertion = cursor }
            if ["tEXt", "iTXt", "zTXt"].contains(type) { competing = true }
            // Verify every original chunk CRC, streaming large IDAT payloads.
            var state = crc(Data(header[4..<8])), position = cursor + 8, remaining = length
            while remaining > 0 {
                try Task.checkCancellation(); let amount = Int(min(remaining, 1_048_576))
                state = crc(try read(file, position, amount), state: state); position += UInt64(amount); remaining -= UInt64(amount)
            }
            guard (state ^ 0xffffffff) == be32(try read(file, cursor + 8 + length, 4)) else { throw ProbeError.malformed("PNG chunk CRC mismatch") }
            if type == "eXIf" {
                guard found == nil, length <= 16 * 1_048_576 else { throw ProbeError.unsupported("Multiple/oversized PNG EXIF") }
                found = try read(file, cursor + 8, Int(length)); region = Region(offset: cursor, length: length + 12, data: Data())
            }
            cursor += length + 12
            if type == "IEND" { guard length == 0, cursor == size else { throw ProbeError.malformed("PNG data after IEND") }; ended = true; break }
        }
        guard ended, let insertion else { throw ProbeError.malformed("PNG requires IDAT and IEND") }
        return Layout(exif: found, region: region ?? Region(offset: insertion, length: 0, data: Data()), competingMetadata: competing)
    }
    static func metadata(_ url: URL, kind: MediaKind) throws -> [String: String] {
        if kind == .heic { return try ExifMetadataEditor.inspect(HEICMetadataWriter.exif(url)) }
        guard let exif = try layout(url, kind: kind).exif else { return [:] }
        return try ExifMetadataEditor.inspect(exif)
    }
    static func write(source: URL, output: URL, kind: MediaKind, patch: MetadataPatch) throws {
        if kind == .heic { try HEICMetadataWriter.write(source: source, output: output, patch: patch); return }
        let parsed = try layout(source, kind: kind)
        if kind == .jpeg, !patch.targetedKeys.isEmpty {
            let inventory = try JPEGInventory.read(source)
            guard inventory.limitations.isEmpty else { throw ProbeError.unsupported("JPEG auxiliary/trailing/JUMBF data requires an offset/authentication-aware writer; no unsafe APP1 rewrite") }
        }
        guard patch.removals.isEmpty || !parsed.competingMetadata else {
            throw ProbeError.unsupported("Removal is refused because additional XMP/IPTC/text metadata may contain copies of the selected fields")
        }
        let exif = try ExifMetadataEditor.patch(parsed.exif ?? ExifMetadataEditor.empty, patch: patch)
        let replacement: Data
        if kind == .jpeg {
            let payload = Data([69, 120, 105, 102, 0, 0]) + exif
            guard payload.count <= 65533 else { throw ProbeError.unsupported("JPEG EXIF exceeds APP1 capacity") }
            replacement = Data([255, 225, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 255)]) + payload
        } else { replacement = pngChunk("eXIf", exif) }
        try rewrite(source: source, output: output, regions: [Region(offset: parsed.region.offset, length: parsed.region.length, data: replacement)])
    }
    static func rewrite(source: URL, output: URL, regions: [Region]) throws {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else { throw ProbeError.sameFile }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError.outputExists }
        let sourceHash = try WholeFileDigest.sha256(source)
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let size = try input.seekToEnd()
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw ProbeError.writeFailed("Cannot create staged image") }
        let destination = try FileHandle(forWritingTo: output); defer { try? destination.close() }
        var completed = false; defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        var cursor: UInt64 = 0
        func copy(to end: UInt64) throws {
            guard end >= cursor, end <= size else { throw ProbeError.malformed("Image rewrite range") }
            while cursor < end {
                try Task.checkCancellation(); let amount = Int(min(1_048_576, end - cursor))
                try destination.write(contentsOf: read(input, cursor, amount)); cursor += UInt64(amount)
            }
        }
        for region in regions.sorted(by: { $0.offset < $1.offset }) {
            guard region.offset <= size, region.length <= size - region.offset else { throw ProbeError.malformed("Image replacement range") }
            try copy(to: region.offset); try destination.write(contentsOf: region.data); cursor += region.length
        }
        try copy(to: size); try destination.synchronize()
        guard try WholeFileDigest.sha256(source) == sourceHash else { throw ProbeError.writeFailed("Source changed during metadata edit") }
        completed = true
    }
    static func pngFingerprint(_ url: URL) throws -> String {
        _ = try layout(url, kind: .png)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let size = try input.seekToEnd(); var cursor: UInt64 = 8, digest = SHA256()
        while cursor < size {
            let header = try read(input, cursor, 8), length = UInt64(be32(header)) + 12
            if String(decoding: header[4..<8], as: UTF8.self) != "eXIf" {
                var position = cursor, remaining = length
                while remaining > 0 { try Task.checkCancellation(); let amount = Int(min(remaining, 1_048_576)); digest.update(data: try read(input, position, amount)); remaining -= UInt64(amount); position += UInt64(amount) }
            }
            cursor += length
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
