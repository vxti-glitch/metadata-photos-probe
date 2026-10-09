import Foundation
import ProbeCore
import Dispatch
#if os(macOS)
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import AVFoundation
import CoreVideo

private struct FixtureRecord: Codable {
    let format: MediaKind
    let variant: String
    var sourceFilename: String?
    var editedFilename: String?
    var sourceSHA256: String?
    var editedSHA256: String?
    var sourceInspection: MediaInspection?
    var processing: ProcessingResult?
    var sourceError: String?
    var processingError: String?
}

private struct Manifest: Codable {
    let schemaVersion = 1
    let generatedAt: Date
    let generatorOS: String
    let statement: String
    let patch: CameraPatch
    let files: [FixtureRecord]
}

struct FixtureGenerator {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw ProbeError.unsupported("Usage: swift run ProbeFixtureGenerator OUTPUT_FOLDER")
            }
            let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw ProbeError.outputExists }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let patch = CameraPatch(make: "Feasibility Test Maker", model: "Controlled Synthetic Model")
            var records = [FixtureRecord]()
            // Preserve this diagnostic probe's original four-format scope.
            // New editor formats must not silently select an old fallback encoder.
            let fixtures = [MediaKind.jpeg, .heic, .mp4, .mov].map { ($0, true) } + [(MediaKind.jpeg, false)]
            for (kind, includeDate) in fixtures {
                let variant = includeDate ? "baseline" : "undated-camera-control"
                let suffix = includeDate ? "" : "-undated"
                let source = folder.appendingPathComponent("original\(suffix).\(kind.rawValue)")
                let edited = folder.appendingPathComponent("processed\(suffix).\(kind.rawValue)")
                var record = FixtureRecord(format: kind, variant: variant)
                do {
                    if kind.isImage { try makeImage(source, kind: kind, includeDate: includeDate) }
                    else { try await makeVideo(source, kind: kind) }
                    record.sourceFilename = source.lastPathComponent
                    record.sourceSHA256 = try WholeFileDigest.sha256(source)
                    record.sourceInspection = try await MetadataEngine.inspect(source)
                    guard record.sourceInspection?.kind == kind else {
                        throw ProbeError.writeFailed("Fixture header does not match the declared format")
                    }
                } catch {
                    record.sourceError = error.localizedDescription
                    try? FileManager.default.removeItem(at: source)
                    records.append(record)
                    continue
                }
                do {
                    record.processing = try await MetadataEngine.process(source: source, output: edited, patch: patch)
                    record.editedFilename = edited.lastPathComponent
                    record.editedSHA256 = try WholeFileDigest.sha256(edited)
                } catch { record.processingError = error.localizedDescription }
                records.append(record)
            }
            let manifest = Manifest(generatedAt: Date(), generatorOS: ProcessInfo.processInfo.operatingSystemVersionString,
                statement: "These are small, generated synthetic fixtures, not camera captures or authentic camera provenance. Originals were encoded once solely to create fixtures; processing uses only the engine's metadata-only routes. The undated JPEG is a separate synthetic control, not removal of dates from any real input; the dated baseline and its integrity findings remain recorded. No Photos save, Photos display, device quality or attribution result is established by this manifest. Unsupported encoders/writers are recorded without conversion fallback. Real iPhone camera fixtures, rotated media, audio/HDR/auxiliary and existing-edited media remain separate tests.",
                patch: patch, files: records)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            print("Controlled fixtures and manifest: \(folder.path)")
            for record in records {
                print("\(record.format.rawValue) \(record.variant): original=\(record.sourceFilename ?? "unavailable"), processed=\(record.editedFilename ?? "unsupported"), integrity=\(record.processing?.integrity.status.rawValue ?? "not tested")")
            }
        } catch {
            FileHandle.standardError.write(Data(("Fixture generation failed: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    private static func makeImage(_ url: URL, kind: MediaKind, includeDate: Bool) throws {
        let type = kind == .jpeg ? UTType.jpeg.identifier : UTType.heic.identifier
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type) else { throw ProbeError.unsupported("\(kind.rawValue) encoder unavailable") }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 160, height: 96, bitsPerComponent: 8, bytesPerRow: 640, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw ProbeError.writeFailed("Image fixture allocation failed") }
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
        context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 16, y: 12, width: 48, height: 24))
        guard let image = context.makeImage() else { throw ProbeError.writeFailed("Image fixture unavailable") }
        var exif: [String: Any] = [kCGImagePropertyExifFNumber as String: 2.8, kCGImagePropertyExifFocalLength as String: 24.0, kCGImagePropertyExifLensModel as String: "Synthetic Source Lens"]
        if includeDate { exif[kCGImagePropertyExifDateTimeOriginal as String] = "2026:01:02 03:04:05" }
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Synthetic Source Maker", kCGImagePropertyTIFFModel as String: "Synthetic Source Model"],
            kCGImagePropertyExifDictionary as String: exif
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProbeError.writeFailed("\(kind.rawValue) fixture encoding failed") }
    }

    private static func makeVideo(_ url: URL, kind: MediaKind) async throws {
        // H.264 is used explicitly for both containers to keep this baseline reproducible.
        // HEVC/HDR are real-camera fixture gates, never a hidden fallback.
        let writer = try AVAssetWriter(outputURL: url, fileType: kind == .mp4 ? .mp4 : .mov)
        var completed = false
        defer { if !completed { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96])
        guard writer.canAdd(input) else { throw ProbeError.unsupported("H.264 \(kind.rawValue) fixture encoder unavailable") }
        writer.add(input)
        let make = AVMutableMetadataItem(); make.identifier = .quickTimeMetadataMake; make.value = "Synthetic Source Maker" as NSString; make.dataType = "com.apple.metadata.datatype.UTF-8"
        let model = AVMutableMetadataItem(); model.identifier = .quickTimeMetadataModel; model.value = "Synthetic Source Video" as NSString; model.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [make, model]
        guard writer.startWriting() else { throw writer.error ?? ProbeError.writeFailed("Video fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<15 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else { throw writer.error ?? ProbeError.writeFailed("Fixture writer stalled") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA, nil, &optionalBuffer) == kCVReturnSuccess, let buffer = optionalBuffer else { throw ProbeError.writeFailed("Video fixture buffer unavailable") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) {
                memset(address, Int32(frame * 12), CVPixelBufferGetBytesPerRow(buffer) * 96)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? ProbeError.writeFailed("Video fixture append failed") }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProbeError.writeFailed("Video fixture unfinished") }
        completed = true
    }
}
Task {
    await FixtureGenerator.main()
    exit(0)
}
dispatchMain()
#else
print("ProbeFixtureGenerator requires macOS. Run it in the macOS build workflow.")
#endif
