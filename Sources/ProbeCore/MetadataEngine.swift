import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

public enum MetadataEngine {
    public static func inspect(_ url: URL) async throws -> MediaInspection {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { throw ProbeError.unsupported("A regular file is required") }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ProbeError.malformed("Empty input") }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(source) as String? {
            let kind: MediaKind
            if type == UTType.jpeg.identifier { kind = .jpeg }
            else if type == UTType.heic.identifier { kind = .heic }
            else if type == UTType.png.identifier { kind = .png }
            else { throw ProbeError.unsupported("Image type \(type)") }
            guard CGImageSourceGetCount(source) == 1 else { throw ProbeError.unsupported("Multi-image source is outside the controlled-fixture gate") }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ProbeError.malformed("ImageIO properties unavailable") }
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            var metadata = [String: String]()
            metadata["make"] = tiff[kCGImagePropertyTIFFMake as String] as? String
            metadata["model"] = tiff[kCGImagePropertyTIFFModel as String] as? String
            metadata["lens"] = exif[kCGImagePropertyExifLensModel as String] as? String
            // A separate bounded TIFF reader exposes the complete supported field
            // set; ImageIO independently supplies presentation/location evidence.
            if let full = try? StillContainerMetadata.metadata(url, kind: kind) {
                metadata.merge(full, uniquingKeysWith: { _, new in new }); metadata["lens"] = metadata["lensModel"] ?? metadata["lens"]
            }
            var structure = [String: String]()
            for (label, key) in [("width", kCGImagePropertyPixelWidth), ("height", kCGImagePropertyPixelHeight), ("orientation", kCGImagePropertyOrientation), ("depth", kCGImagePropertyDepth), ("colorModel", kCGImagePropertyColorModel), ("profile", kCGImagePropertyProfileName)] {
                structure[label] = properties[key as String].map { String(describing: $0) }
            }
            structure["orientation"] = structure["orientation"] ?? "1"
            structure["containerType"] = type
            var notes = ["Embedded metadata only; Photos display and source attribution require physical-device observation."]
            if kind == .jpeg {
                _ = try JPEGInventory.read(url)
                if let layout = try? StillContainerMetadata.layout(url, kind: .jpeg), layout.competingMetadata {
                    structure["competingMetadata"] = "true"
                    notes.append("Additional XMP/IPTC metadata present; removal restricted to avoid unscrubbed duplicate copies.")
                }
            } else if kind == .heic {
                _ = try BoxInventory.read(url, hashMediaPayload: false); notes.append("HEIC item graph/auxiliary/HDR preservation is not fully qualified.")
            } else {
                let layout = try StillContainerMetadata.layout(url, kind: .png)
                if layout.competingMetadata {
                    structure["competingMetadata"] = "true"
                    notes.append("Additional PNG text metadata present; removal restricted to avoid unscrubbed duplicate copies.")
                }
            }
            return MediaInspection(kind: kind, byteCount: size, metadata: metadata, notes: notes, structure: structure,
                location: EmbeddedLocationEvidence.image(gps: properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]))
        }
        let inventory = try BoxInventory.read(url, hashMediaPayload: false)
        guard inventory.types.contains("ftyp"), inventory.types.contains("moov"), inventory.types.contains("mdat") else {
            throw ProbeError.unsupported("Expected a file-backed MP4 or MOV container")
        }
        let kind = try videoKind(url)
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable), !(try await asset.load(.hasProtectedContent)) else {
            throw ProbeError.unsupported("Unreadable or protected video")
        }
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video }) else { throw ProbeError.unsupported("No video track") }
        let duration = try await asset.load(.duration)
        let metadataFormats = try await asset.load(.availableMetadataFormats)
        var metadata = [String: String]()
        let indexedAliases = (try? VideoMetadataWriter.indexedMovieMetadataAliases(url)) ?? [:]
        var resolvedIdentities = Set<String>()
        for item in try await containerMetadata(asset) {
            if let value = try await item.load(.stringValue) {
                let rawIdentity = try metadataIdentity(identifier: item.identifier, key: item.key, keySpace: item.keySpace)
                let identity = canonicalVideoMetadataIdentity(rawIdentity, value: value, aliases: indexedAliases)
                if identity != rawIdentity { resolvedIdentities.insert(identity) }
                if resolvedIdentities.contains(identity), let prior = metadata[identity], prior != value {
                    throw ProbeError.unsupported("Conflicting indexed movie metadata values")
                }
                metadata[identity] = value
                if item.identifier == .quickTimeMetadataMake { metadata["make"] = value }
                if item.identifier == .quickTimeMetadataModel { metadata["model"] = value }
            }
        }
        if let full = try? VideoMetadataWriter.inspect(url) { metadata.merge(full, uniquingKeysWith: { _, new in new }); metadata["lens"] = metadata["lensModel"] ?? metadata["lens"] }
        return MediaInspection(kind: kind, byteCount: size, metadata: metadata,
            notes: ["QuickTime camera fields are embedded tags; whether Photos shows them is unverified.", "Metadata-only container rewriting and sample checks do not certify every HDR or opaque-track semantic."],
            structure: ["duration": canonicalTime(duration), "tracks": String(tracks.count), "trackTypes": tracks.map { $0.mediaType.rawValue }.joined(separator: ","), "boxes": inventory.types.joined(separator: ","), "metadataFormats": metadataFormats.map { $0.rawValue }.joined(separator: ",")],
            location: EmbeddedLocationEvidence.video(metadata: metadata))
    }
    public static func processMetadataPatch(source: URL, output: URL, patch: MetadataPatch, integrityPolicy: IntegrityPolicy = .strict) async throws -> ProcessingResult {
        try patch.validate()
        guard source.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else { throw ProbeError.sameFile }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError.outputExists }
        let before = try await inspect(source)
        guard patch.targetedKeys.isSubset(of: Set(MetadataPatch.supportedKeys(for: before.kind))) else { throw ProbeError.unsupported("One or more selected fields are unavailable for this format") }
        var completed = false; defer {
            if !completed, FileManager.default.fileExists(atPath: output.path) { try? FileManager.default.removeItem(at: output) }
        }
        if patch.targetedKeys.isEmpty { try FileManager.default.copyItem(at: source, to: output) }
        else if before.kind.isImage { try StillContainerMetadata.write(source: source, output: output, kind: before.kind, patch: patch) }
        else { _ = try await VideoMetadataWriter.write(source: source, output: output, patch: patch) }
        let after = try await inspect(output)
        guard after.kind == before.kind else { throw ProbeError.readbackFailed("Container format changed") }
        try patch.validateReadback(after)
        let integrity = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: patch, integrityPolicy: integrityPolicy)
        guard integrity.status != .mismatch else {
            let names = integrity.checks.filter { $0.status == .failed }.map(\.name).joined(separator: ", ")
            throw ProbeError.integrityMismatch(names)
        }
        completed = true
        return ProcessingResult(outputURL: output, sourceInspection: before, outputInspection: after, integrity: integrity)
    }

    public static func process(source: URL, output: URL, patch: CameraPatch) async throws -> ProcessingResult {
        try patch.validate()
        guard source.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath() else { throw ProbeError.sameFile }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError.outputExists }
        let sourceInspection = try await inspect(source)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        if sourceInspection.kind.isImage { try writeImage(source: source, output: output, patch: patch) }
        else { try await writeVideo(source: source, output: output, kind: sourceInspection.kind, patch: patch) }
        let outputInspection = try await inspect(output)
        guard outputInspection.kind == sourceInspection.kind else { throw ProbeError.readbackFailed("Container format changed") }
        guard outputInspection.metadata["make"] == patch.make, outputInspection.metadata["model"] == patch.model else {
            throw ProbeError.readbackFailed("Requested make/model are not present exactly")
        }
        if let lens = patch.lens, outputInspection.metadata["lens"] != lens { throw ProbeError.readbackFailed("Requested lens is not present exactly") }
        let integrity = try await MediaIntegrity.compare(source: source, output: output, patch: patch)
        guard integrity.status != .mismatch else {
            let names = integrity.checks.filter { $0.status == .failed }.map(\.name).joined(separator: ", ")
            throw ProbeError.integrityMismatch(names)
        }
        completed = true
        return ProcessingResult(outputURL: output, sourceInspection: sourceInspection, outputInspection: outputInspection, integrity: integrity)
    }

    private static func writeImage(source: URL, output: URL, patch: CameraPatch) throws {
        if let inspection = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(inspection) as String? {
            if type == UTType.heic.identifier {
                try HEICMetadataWriter.write(source: source, output: output, patch: patch)
                return
            } else if type == UTType.png.identifier {
                var values: [String: MetadataValue] = [
                    "make": .string(patch.make),
                    "model": .string(patch.model)
                ]
                if let lens = patch.lens {
                    values["lensModel"] = .string(lens)
                }
                try StillContainerMetadata.write(source: source, output: output, kind: .png, patch: MetadataPatch(values: values, removals: []))
                return
            }
        }
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(image),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw ProbeError.writeFailed("ImageIO source or destination could not be opened")
        }
        // Supply only deliberate changes. Copying the entire original metadata into
        // a merge request can make ImageIO reserialize/reconcile unrelated namespaces.
        // MergeMetadata retains the source fields; independent checks still reject loss.
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake, patch.make as CFString),
              CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, patch.model as CFString) else {
            throw ProbeError.writeFailed("ImageIO does not support requested camera tags for this source")
        }
        if let lens = patch.lens {
            guard CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel, lens as CFString) else {
                throw ProbeError.writeFailed("ImageIO lens tag unsupported")
            }
        }
        let options = [kCGImageDestinationMetadata as String: metadata, kCGImageDestinationMergeMetadata as String: true] as [String: Any]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, image, options as CFDictionary, &error) else {
            let detail = error.map { String(describing: $0.takeRetainedValue()) } ?? "Metadata-only copy unsupported; no re-encoding fallback"
            throw ProbeError.writeFailed(detail)
        }
        // CopyImageSource completes the file itself. Do not call Finalize after it.
        if type as String == UTType.jpeg.identifier {
            try JPEGMetadataPreserver.restoreOriginalAPP13(source: source, output: output)
        }
    }

    private static func writeVideo(source: URL, output: URL, kind: MediaKind, patch: CameraPatch) async throws {
        _ = try await VideoMetadataWriter.write(source: source, output: output, patch: patch)
        try Task.checkCancellation()
    }

    /// An absent AVFoundation identifier does not make the raw key optional text.
    /// Preserve its namespace and use Apple's mapping when an equivalent exists.
    /// This keeps selected-field aliases stable without ignoring unknown metadata.
    static func metadataIdentity(identifier: AVMetadataIdentifier?, key: (any NSCopying & NSObjectProtocol)?, keySpace: AVMetadataKeySpace?) throws -> String {
        if let identifier { return identifier.rawValue }
        guard let key else { throw ProbeError.unsupported("Metadata item has no key or identifier") }
        if let keySpace {
            if let identifier = AVMetadataItem.identifier(forKey: key, keySpace: keySpace) {
                return identifier.rawValue
            }
            return keySpace.rawValue + "/" + String(describing: key)
        }
        return String(describing: key)
    }

    /// Resolve only identities corroborated by the original container's unique
    /// key table and scalar bytes. Always keep Apple's independently read value.
    static func canonicalVideoMetadataIdentity(_ identity: String, value: String,
        aliases: [String: (identity: String, value: String)]) -> String {
        guard let evidence = aliases[identity], evidence.identity.hasPrefix("mdta/"), evidence.value == value else { return identity }
        return evidence.identity
    }

    /// Read each advertised keyspace, including QuickTime mdta. Common metadata is
    /// an incomplete view and must not be used as the preservation inventory.
    private static func containerMetadata(_ asset: AVAsset) async throws -> [AVMetadataItem] {
        let formats = try await asset.load(.availableMetadataFormats)
        if formats.isEmpty { return try await asset.load(.metadata) }
        var items = [AVMetadataItem]()
        for format in formats { items += try await asset.loadMetadata(for: format) }
        return items
    }

    /// Detect the container brand independently of the filename.
    static func videoKind(_ url: URL) throws -> MediaKind {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let fileSize = try handle.seekToEnd(); try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8 else { throw ProbeError.malformed("Missing container brand") }
        // Controlled fixtures require ftyp at the beginning; no extension-based assumption.
        guard String(decoding: header[4..<8], as: UTF8.self) == "ftyp" else { throw ProbeError.unsupported("Non-leading ftyp is not qualified") }
        var boxSize = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var headerSize: UInt64 = 8
        if boxSize == 1 {
            let extended = try handle.read(upToCount: 8) ?? Data()
            guard extended.count == 8 else { throw ProbeError.malformed("Truncated extended ftyp size") }
            boxSize = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; headerSize = 16
        }
        guard boxSize >= headerSize + 8, boxSize <= fileSize else { throw ProbeError.malformed("Invalid ftyp bounds") }
        guard boxSize <= 16 * 1_048_576 else { throw ProbeError.unsupported("Container brand list exceeds metadata budget") }
        let data = try handle.read(upToCount: Int(boxSize - headerSize)) ?? Data()
        guard data.count == Int(boxSize - headerSize), (data.count - 8) % 4 == 0 else { throw ProbeError.malformed("Truncated container brand list") }
        let brand = String(decoding: data[0..<4], as: UTF8.self)
        var brands = [brand]
        var offset = 8
        while offset + 4 <= data.count {
            brands.append(String(decoding: data[offset..<offset + 4], as: UTF8.self))
            offset += 4
        }
        if brands.contains("qt  ") { return .mov }
        let mp4Brands: Set<String> = [
            "isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9",
            "mp41", "mp42", "avc1", "avc3", "M4V ", "M4A ", "M4P ", "M4B ",
            "MSNV", "dash", "isml", "dby1", "NDAS", "XAVC", "hevc", "hvc1",
            "3gp4", "3gp5", "3gp6", "3gp7", "3g2a", "CAEP", "CDes", "f4v ", "kddi"
        ]
        if !Set(brands).isDisjoint(with: mp4Brands) || brands.contains(where: { $0.hasPrefix("mp4") || $0.hasPrefix("iso") || $0.hasPrefix("3gp") }) {
            return .mp4
        }
        throw ProbeError.unsupported("Unqualified video brand \(brand)")
    }
}

func canonicalTime(_ time: CMTime) -> String {
    guard time.isNumeric, time.timescale > 0 else { return "invalid:\(time.flags.rawValue)" }
    func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 { var a = lhs, b = rhs; while b != 0 { let c = a % b; a = b; b = c }; return max(a, 1) }
    let divisor = Int64(gcd(time.value.magnitude, UInt64(time.timescale)))
    return "\(time.value / divisor)/\(Int64(time.timescale) / divisor)@\(time.epoch)"
}
