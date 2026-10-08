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
            else { throw ProbeError.unsupported("Image type \(type)") }
            guard CGImageSourceGetCount(source) == 1 else { throw ProbeError.unsupported("Multi-image source is outside the controlled-fixture gate") }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw ProbeError.malformed("ImageIO properties unavailable") }
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            var metadata = [String: String]()
            metadata["make"] = tiff[kCGImagePropertyTIFFMake as String] as? String
            metadata["model"] = tiff[kCGImagePropertyTIFFModel as String] as? String
            metadata["lens"] = exif[kCGImagePropertyExifLensModel as String] as? String
            var structure = [String: String]()
            for (label, key) in [("width", kCGImagePropertyPixelWidth), ("height", kCGImagePropertyPixelHeight), ("orientation", kCGImagePropertyOrientation), ("depth", kCGImagePropertyDepth), ("colorModel", kCGImagePropertyColorModel), ("profile", kCGImagePropertyProfileName)] {
                structure[label] = properties[key as String].map { String(describing: $0) }
            }
            structure["orientation"] = structure["orientation"] ?? "1"
            structure["containerType"] = type
            var notes = ["Embedded metadata only; Photos display and source attribution require physical-device observation."]
            if kind == .jpeg { _ = try JPEGInventory.read(url) }
            else { _ = try BoxInventory.read(url); notes.append("HEIC item graph/auxiliary/HDR preservation is not fully qualified.") }
            return MediaInspection(kind: kind, byteCount: size, metadata: metadata, notes: notes, structure: structure)
        }
        let inventory = try BoxInventory.read(url)
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
        for item in try await containerMetadata(asset) {
            if let value = try await item.load(.stringValue) {
                metadata[item.identifier?.rawValue ?? String(describing: item.key)] = value
                if item.identifier == .quickTimeMetadataMake { metadata["make"] = value }
                if item.identifier == .quickTimeMetadataModel { metadata["model"] = value }
            }
        }
        return MediaInspection(kind: kind, byteCount: size, metadata: metadata,
            notes: ["QuickTime camera fields are embedded tags; whether Photos shows them is unverified.", "Passthrough is not proof of preservation of every container, HDR or opaque-track semantic."],
            structure: ["duration": canonicalTime(duration), "tracks": String(tracks.count), "trackTypes": tracks.map { $0.mediaType.rawValue }.joined(separator: ","), "boxes": inventory.types.joined(separator: ","), "metadataFormats": metadataFormats.map { $0.rawValue }.joined(separator: ",")])
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
            throw ProbeError.readbackFailed("Requested make/model are not present exactly. Actual inspected metadata: \(outputInspection.metadata). Metadata formats: \(outputInspection.structure["metadataFormats"] ?? "ImageIO").")
        }
        if let lens = patch.lens, outputInspection.metadata["lens"] != lens { throw ProbeError.readbackFailed("Requested lens is not present exactly") }
        let integrity = try await MediaIntegrity.compare(source: source, output: output, patch: patch)
        completed = true
        return ProcessingResult(outputURL: output, sourceInspection: sourceInspection, outputInspection: outputInspection, integrity: integrity)
    }

    private static func writeImage(source: URL, output: URL, patch: CameraPatch) throws {
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
        guard patch.lens == nil else { throw ProbeError.unsupported("A video lens-model field is not qualified; leave lens empty") }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ProbeError.writeFailed("Passthrough export unavailable")
        }
        let fileType: AVFileType = kind == .mp4 ? .mp4 : .mov
        guard session.supportedFileTypes.contains(fileType) else { throw ProbeError.unsupported("Same-container passthrough unavailable") }
        session.outputURL = output; session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false
        let existing = try await containerMetadata(asset)
        let replaced: Set<AVMetadataIdentifier> = [.quickTimeMetadataMake, .quickTimeMetadataModel]
        var items = existing.filter { !replaced.contains($0.identifier ?? AVMetadataIdentifier(rawValue: "")) }
        for (identifier, value) in [(AVMetadataIdentifier.quickTimeMetadataMake, patch.make), (.quickTimeMetadataModel, patch.model)] {
            let item = AVMutableMetadataItem()
            item.identifier = identifier; item.value = value as NSString
            item.dataType = "com.apple.metadata.datatype.UTF-8"
            items.append(item)
        }
        session.metadata = items
        let operation = ExportOperation(session: session)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.start(continuation)
            }
        }, onCancel: { operation.cancel() })
        try Task.checkCancellation()
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
    private static func videoKind(_ url: URL) throws -> MediaKind {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        guard data.count >= 12 else { throw ProbeError.malformed("Missing container brand") }
        // Controlled fixtures require ftyp at the beginning; no extension-based assumption.
        guard String(decoding: data[4..<8], as: UTF8.self) == "ftyp" else { throw ProbeError.unsupported("Non-leading ftyp is not qualified") }
        let brand = String(decoding: data[8..<12], as: UTF8.self)
        if brand == "qt  " { return .mov }
        if ["isom", "iso2", "mp41", "mp42", "avc1", "M4V ", "MSNV"].contains(brand) { return .mp4 }
        throw ProbeError.unsupported("Unqualified video brand \(brand)")
    }
}

/// The configured export session never leaves this lifecycle adapter. A lock serializes
/// starting/cancelling, including cancellation before the continuation is installed.
/// AVFoundation completes exports asynchronously; its callback is the only status reader.
private final class ExportOperation: @unchecked Sendable {
    private let session: AVAssetExportSession
    private let lock = NSLock()
    private var cancelled = false
    init(session: AVAssetExportSession) { self.session = session }
    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        session.exportAsynchronously { [self] in
            if session.status == .completed { continuation.resume() }
            else if session.status == .cancelled { continuation.resume(throwing: CancellationError()) }
            else { continuation.resume(throwing: session.error ?? ProbeError.writeFailed("Export did not complete")) }
        }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        session.cancelExport()
    }
}

func canonicalTime(_ time: CMTime) -> String {
    guard time.isNumeric, time.timescale > 0 else { return "invalid:\(time.flags.rawValue)" }
    func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 { var a = lhs, b = rhs; while b != 0 { let c = a % b; a = b; b = c }; return max(a, 1) }
    let divisor = Int64(gcd(time.value.magnitude, UInt64(time.timescale)))
    return "\(time.value / divisor)/\(Int64(time.timescale) / divisor)@\(time.epoch)"
}
