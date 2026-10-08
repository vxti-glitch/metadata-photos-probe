import Foundation
import CryptoKit

public enum WholeFileDigest {
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Small buffered sequential reader. File size never determines allocation size.
final class BufferedFile {
    private let handle: FileHandle
    private var buffer = Data()
    private var index = 0
    private(set) var offset: UInt64 = 0
    init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func byte() throws -> UInt8? {
        if index == buffer.count {
            try Task.checkCancellation()
            buffer = try handle.read(upToCount: 65_536) ?? Data(); index = 0
            if buffer.isEmpty { return nil }
        }
        let value = buffer[index]; index += 1; offset += 1
        return value
    }
    func requiredByte() throws -> UInt8 {
        guard let value = try byte() else { throw ProbeError.malformed("Unexpected end of file") }
        return value
    }
    func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= 65_535 else { throw ProbeError.malformed("Invalid segment length") }
        var result = Data(); result.reserveCapacity(count)
        for _ in 0..<count { result.append(try requiredByte()) }
        return result
    }
}

struct JPEGInventory: Equatable {
    let signatures: [String]
    let scanCount: Int
    let limitations: [String]

    static func read(_ url: URL) throws -> JPEGInventory {
        let reader = try BufferedFile(url)
        guard try reader.requiredByte() == 0xff, try reader.requiredByte() == 0xd8 else { throw ProbeError.malformed("Missing JPEG SOI") }
        var signatures = [String](), limitations = [String](), scanCount = 0
        var pending: UInt8?
        var ended = false
        func signature(_ marker: UInt8, _ payload: Data) -> String {
            "\(marker):" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        }
        while !ended {
            let marker: UInt8
            if let stored = pending { marker = stored; pending = nil }
            else {
                guard try reader.requiredByte() == 0xff else { throw ProbeError.malformed("Missing JPEG marker") }
                var next = try reader.requiredByte()
                while next == 0xff { next = try reader.requiredByte() }
                marker = next
            }
            if marker == 0xd9 { ended = true; continue }
            guard marker != 0x00, marker != 0xd8, !(0xd0...0xd7).contains(marker), marker != 0x01 else {
                throw ProbeError.malformed("Unexpected standalone JPEG marker")
            }
            let length = Int(try reader.requiredByte()) << 8 | Int(try reader.requiredByte())
            guard length >= 2 else { throw ProbeError.malformed("JPEG segment length below two") }
            let payload = try reader.bytes(length - 2)
            let isEditedMetadata = marker == 0xe1 && (payload.starts(with: Data("Exif\0\0".utf8)) || payload.starts(with: Data("http://ns.adobe.com/xap/1.0/\0".utf8)))
            if !isEditedMetadata { signatures.append(signature(marker, payload)) }
            if marker == 0xe2 && payload.starts(with: Data("MPF\0".utf8)) {
                limitations.append("JPEG MPF/auxiliary images require additional item and offset verification.")
            }
            if marker == 0xeb { limitations.append("JPEG APP11/JUMBF is not qualified by this probe.") }
            if marker == 0xda {
                scanCount += 1
                var digest = SHA256(), chunk = Data()
                chunk.reserveCapacity(65_536)
                while true {
                    let value = try reader.requiredByte()
                    if value == 0xff {
                        var next = try reader.requiredByte()
                        var fills = 0
                        while next == 0xff { fills += 1; next = try reader.requiredByte() }
                        if next != 0 && !(0xd0...0xd7).contains(next) {
                            // Marker padding has no compressed-image semantics.
                            pending = next; break
                        }
                        chunk.append(0xff)
                        for _ in 0..<fills { chunk.append(0xff) }
                        chunk.append(next)
                    } else { chunk.append(value) }
                    if chunk.count >= 65_536 { digest.update(data: chunk); chunk.removeAll(keepingCapacity: true) }
                }
                digest.update(data: chunk)
                signatures.append("scan:" + digest.finalize().map { String(format: "%02x", $0) }.joined())
            }
        }
        guard scanCount > 0 else { throw ProbeError.malformed("JPEG has no scan") }
        if try reader.byte() != nil { limitations.append("JPEG has trailing data; additional resources are not qualified.") }
        return JPEGInventory(signatures: signatures, scanCount: scanCount, limitations: limitations)
    }
}

struct BoxInventory {
    let types: [String]
    let payloadHashes: [String]
    /// Top-level ISO BMFF inventory, intentionally not a full HEIF graph verifier.
    static func read(_ url: URL) throws -> BoxInventory {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let end = try handle.seekToEnd(); try handle.seek(toOffset: 0)
        var offset: UInt64 = 0, types = [String](), hashes = [String]()
        func exact(_ count: Int) throws -> Data {
            guard let data = try handle.read(upToCount: count), data.count == count else { throw ProbeError.malformed("Truncated ISO media box") }
            return data
        }
        func integer(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
        while offset < end {
            guard end - offset >= 8 else { throw ProbeError.malformed("Truncated box header") }
            let header = try exact(8)
            var size = integer(header.prefix(4)); var headerSize: UInt64 = 8
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            if size == 1 { size = integer(try exact(8)); headerSize = 16 }
            if size == 0 { size = end - offset }
            guard size >= headerSize, size <= end - offset else { throw ProbeError.malformed("Box exceeds file bounds") }
            types.append(type)
            guard types.count <= 10_000 else { throw ProbeError.malformed("Too many top-level boxes") }
            if type == "mdat" {
                var digest = SHA256(), remaining = size - headerSize
                while remaining > 0 {
                    try Task.checkCancellation()
                    let data = try exact(Int(min(remaining, 1_048_576)))
                    digest.update(data: data); remaining -= UInt64(data.count)
                }
                hashes.append(digest.finalize().map { String(format: "%02x", $0) }.joined())
            }
            offset += size; try handle.seek(toOffset: offset)
        }
        guard !types.isEmpty else { throw ProbeError.malformed("Empty ISO media container") }
        return BoxInventory(types: types, payloadHashes: hashes)
    }
}
