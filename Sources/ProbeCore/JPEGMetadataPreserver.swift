import Foundation

/// ImageIO may reconcile EXIF into Photoshop/IPTC even when the patch contains only
/// camera tags. Restore the original opaque leading APP13 blocks after its copy.
/// This never decodes or edits image scans. All other independent checks still apply.
enum JPEGMetadataPreserver {
    private static let headerLimit = 16 * 1_048_576
    private static let segmentLimit = 10_000

    static func restoreOriginalAPP13(source: URL, output: URL) throws {
        guard source.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else { throw ProbeError.sameFile }
        let sourceSize = try regularFileSize(source)
        let outputSize = try regularFileSize(output)
        let sourceDigest = try WholeFileDigest.sha256(source)
        let originals = try leadingAPP13(source)
        let originalSize = originals.reduce(0) { $0 + $1.count }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".app13-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw ProbeError.writeFailed("Cannot create APP13 staging file") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        var removedSize = 0
        do {
            let input = try FileHandle(forReadingFrom: output)
            defer { try? input.close() }
            let destination = try FileHandle(forWritingTo: temporary)
            defer { try? destination.close() }
            guard try exact(input, count: 2) == Data([0xff, 0xd8]) else { throw ProbeError.malformed("APP13 restoration requires JPEG SOI") }
            try destination.write(contentsOf: Data([0xff, 0xd8]))
            var headerBytes = 2, segments = 0
            while true {
                try Task.checkCancellation()
                let segment = try leadingSegment(input)
                headerBytes += segment.bytes.count; segments += 1
                try checkBounds(headerBytes: headerBytes, segments: segments)
                if segment.marker == 0xda {
                    for original in originals { try destination.write(contentsOf: original) }
                    try destination.write(contentsOf: segment.bytes)
                    while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                        try Task.checkCancellation()
                        try destination.write(contentsOf: bytes)
                    }
                    break
                }
                if segment.marker == 0xed { removedSize += segment.bytes.count }
                else { try destination.write(contentsOf: segment.bytes) }
            }
            try destination.synchronize()
        }
        guard try regularFileSize(source) == sourceSize,
              try WholeFileDigest.sha256(source) == sourceDigest else {
            throw ProbeError.writeFailed("Source changed during APP13 restoration")
        }
        guard try regularFileSize(output) == outputSize,
              try regularFileSize(temporary) == outputSize - Int64(removedSize) + Int64(originalSize) else {
            throw ProbeError.writeFailed("APP13 output byte-count verification failed")
        }
        // Both readers/writers are closed. Replace only the engine's new output.
        _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    }

    private static func leadingAPP13(_ url: URL) throws -> [Data] {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        guard try exact(input, count: 2) == Data([0xff, 0xd8]) else { throw ProbeError.malformed("APP13 source is not JPEG") }
        var result = [Data](), headerBytes = 2, segments = 0
        while true {
            try Task.checkCancellation()
            let segment = try leadingSegment(input)
            headerBytes += segment.bytes.count; segments += 1
            try checkBounds(headerBytes: headerBytes, segments: segments)
            if segment.marker == 0xda { return result }
            if segment.marker == 0xed { result.append(segment.bytes) }
        }
    }

    private static func checkBounds(headerBytes: Int, segments: Int) throws {
        guard headerBytes <= headerLimit, segments <= segmentLimit else {
            throw ProbeError.unsupported("JPEG leading metadata exceeds 16 MiB or 10,000 segments; no unbounded restoration")
        }
    }

    private static func leadingSegment(_ input: FileHandle) throws -> (marker: UInt8, bytes: Data) {
        guard try exact(input, count: 1)[0] == 0xff else { throw ProbeError.malformed("Missing leading JPEG marker") }
        var bytes = Data([0xff])
        var marker = try exact(input, count: 1)[0]
        while marker == 0xff {
            bytes.append(marker)
            guard bytes.count <= 65_536 else { throw ProbeError.unsupported("Unqualified JPEG marker padding") }
            marker = try exact(input, count: 1)[0]
        }
        bytes.append(marker)
        guard marker != 0x00, marker != 0xd8, marker != 0xd9, marker != 0x01, !(0xd0...0xd7).contains(marker) else {
            throw ProbeError.malformed("Unexpected standalone marker before JPEG scan")
        }
        let lengthBytes = try exact(input, count: 2)
        let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
        guard length >= 2 else { throw ProbeError.malformed("Invalid JPEG metadata segment length") }
        bytes.append(lengthBytes); bytes.append(try exact(input, count: length - 2))
        return (marker, bytes)
    }

    private static func exact(_ input: FileHandle, count: Int) throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            guard let bytes = try input.read(upToCount: count - data.count), !bytes.isEmpty else { throw ProbeError.malformed("Truncated leading JPEG metadata") }
            data.append(bytes)
        }
        return data
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw ProbeError.unsupported("A regular JPEG file is required") }
        return size.int64Value
    }
}
