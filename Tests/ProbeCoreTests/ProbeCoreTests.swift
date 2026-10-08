import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import AVFoundation
import CoreVideo
@testable import ProbeCore

final class ProbeCoreTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testStreamingSHA256KnownVector() throws {
        let url = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try WholeFileDigest.sha256(url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPatchRejectsEmptyControlsAndOversizedInput() {
        for invalid in ["", " \n", "a\0b", String(repeating: "é", count: 129)] {
            XCTAssertThrowsError(try CameraPatch(make: invalid, model: "Valid").validate())
        }
        XCTAssertNoThrow(try CameraPatch(make: "Apple", model: "iPhone 15 Pro Max", lens: "Controlled Lens").validate())
    }

    func testJPEGParserIncludesEveryScanAndIgnoresOnlyTargetNamespaces() throws {
        let first = folder.appendingPathComponent("first.jpg"), second = folder.appendingPathComponent("second.jpg")
        try syntheticJPEG(exif: "source", pixel: 3).write(to: first)
        try syntheticJPEG(exif: "edited", pixel: 3).write(to: second)
        let inventory = try JPEGInventory.read(first)
        XCTAssertEqual(inventory.scanCount, 2)
        XCTAssertEqual(inventory.signatures, try JPEGInventory.read(second).signatures)
        try syntheticJPEG(exif: "edited", pixel: 4).write(to: second)
        XCTAssertNotEqual(inventory.signatures, try JPEGInventory.read(second).signatures)
    }

    func testJPEGParserRejectsTruncatedAndMalformedSegments() throws {
        let url = folder.appendingPathComponent("bad.jpg")
        let cases: [[UInt8]] = [[0xff, 0xd8, 0xff, 0xe1, 0, 1], [0xff, 0xd8, 0xff, 0xe1, 0, 10, 1], [0xff, 0xd8, 0xff, 0xd9], [0xff, 0xd8, 0xff, 0xda, 0, 2, 3]]
        for bytes in cases {
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try JPEGInventory.read(url))
        }
    }

    func testJPEGParserDoesNotCertifyTrailingOrAuxiliaryData() throws {
        let url = folder.appendingPathComponent("extra.jpg")
        var data = syntheticJPEG(exif: "x", pixel: 3)
        data.append(12); try data.write(to: url)
        XCTAssertFalse(try JPEGInventory.read(url).limitations.isEmpty)
    }

    func testBoxParserRejectsOutOfBoundsAndExtendedTruncation() throws {
        let url = folder.appendingPathComponent("bad.heic")
        let cases: [[UInt8]] = [[0,0,0,20,109,100,97,116,1], [0,0,0,1,109,100,97,116,0,0], [0,0,0,4,109,100,97,116]]
        for bytes in cases {
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try BoxInventory.read(url))
        }
    }

    func testBoxParserHashesMediaWithoutReadingWholeFile() throws {
        let url = folder.appendingPathComponent("sample.heic")
        let data = Data([0,0,0,11,109,100,97,116,97,98,99])
        try data.write(to: url)
        let inventory = try BoxInventory.read(url)
        XCTAssertEqual(inventory.types, ["mdat"])
        XCTAssertEqual(inventory.payloadHashes, ["ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"])
    }

    func testTimeComparisonNormalizesRationalTimesWithoutFloatingPoint() {
        XCTAssertEqual(canonicalTime(CMTime(value: 30, timescale: 30)), canonicalTime(CMTime(value: 600, timescale: 600)))
        XCTAssertNotEqual(canonicalTime(CMTime(value: 1, timescale: 30)), canonicalTime(CMTime(value: 1, timescale: 29)))
    }

    func testJPEGWriteReadsBackCameraPreservesOriginalAndScans() async throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("edited.jpg")
        try makeImage(source, type: UTType.jpeg.identifier, orientation: 6)
        let originalHash = try WholeFileDigest.sha256(source)
        let result = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch(make: "Probe Maker", model: "Probe Model", lens: "Probe Lens"))
        XCTAssertEqual(result.outputInspection.metadata["make"], "Probe Maker")
        XCTAssertEqual(result.outputInspection.metadata["model"], "Probe Model")
        XCTAssertEqual(result.outputInspection.metadata["lens"], "Probe Lens")
        XCTAssertEqual(result.outputInspection.structure["orientation"], "6")
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil)! as NSDictionary
        let outputProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)! as NSDictionary
        let sourceEXIF = sourceProperties[kCGImagePropertyExifDictionary] as! NSDictionary
        let outputEXIF = outputProperties[kCGImagePropertyExifDictionary] as! NSDictionary
        XCTAssertEqual(sourceEXIF[kCGImagePropertyExifDateTimeOriginal] as? String, outputEXIF[kCGImagePropertyExifDateTimeOriginal] as? String)
        XCTAssertEqual(sourceEXIF[kCGImagePropertyExifFNumber] as? NSNumber, outputEXIF[kCGImagePropertyExifFNumber] as? NSNumber)
        XCTAssertEqual(try WholeFileDigest.sha256(source), originalHash)
        let compressed = result.integrity.checks.first { $0.name == "JPEG compressed scans and coding segments" }
        XCTAssertEqual(compressed?.status, .passed)
        XCTAssertNotEqual(result.integrity.status, .verified, "Opaque metadata is still explicitly unqualified")
    }

    func testJPEGApplicationLossRemainsBlockedWithoutMislabelingRecompression() async throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("output.jpg")
        try makeImage(output, type: UTType.jpeg.identifier, orientation: 1)
        let bytes = try Data(contentsOf: output)
        // Insert a real JPEG COM segment without altering the image's coding/scans.
        let comment = Data([0xff, 0xfe, 0, 9]) + Data("COMMENT".utf8)
        try (Data(bytes.prefix(2)) + comment + Data(bytes.dropFirst(2))).write(to: source)
        let result = try await MediaIntegrity.compare(source: source, output: output)
        XCTAssertEqual(result.checks.first { $0.name == "JPEG compressed scans and coding segments" }?.status, .passed)
        XCTAssertEqual(result.checks.first { $0.name == "JPEG non-target application/color blocks" }?.status, .failed)
        XCTAssertEqual(result.status, .mismatch, "Known non-target loss must remain blocked even when encoded pixels match")
    }

    func testIntegrityDetectsUnrequestedLensLossAndChanges() async throws {
        let source = folder.appendingPathComponent("source.jpg")
        try makeImage(source, type: UTType.jpeg.identifier, orientation: 1, lens: "Preserved Lens")
        for (index, lens) in [nil, "Unexpected Lens"].enumerated() {
            let output = folder.appendingPathComponent("changed-\(index).jpg")
            try makeImage(output, type: UTType.jpeg.identifier, orientation: 1, lens: lens)
            let patch = CameraPatch(make: "Source Maker", model: "Source Model", lens: nil)
            let compared = try await MediaIntegrity.compare(source: source, output: output, patch: patch)
            XCTAssertEqual(compared.status, .mismatch)
            XCTAssertEqual(compared.checks.first { $0.name == "retained embedded metadata" }?.status, .failed)
            XCTAssertEqual(compared.checks.first { $0.name == "ImageIO exposed non-target properties" }?.status, .failed)
        }
    }

    func testUndatedJPEGControlledCameraProbeRetainsKnownStructure() async throws {
        let source = folder.appendingPathComponent("undated.jpg"), output = folder.appendingPathComponent("undated-output.jpg")
        try makeImage(source, type: UTType.jpeg.identifier, orientation: 1, includeDate: false)
        let original = try WholeFileDigest.sha256(source)
        let result = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch(make: "Probe", model: "Undated Camera"))
        XCTAssertEqual(try WholeFileDigest.sha256(source), original)
        XCTAssertEqual(result.outputInspection.metadata["model"], "Undated Camera")
        XCTAssertEqual(result.outputInspection.metadata["lens"], "Source Lens", "An omitted lens edit must preserve the original lens")
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed }, "Undated fixture remains a separate experiment; real input dates must never be stripped to obtain this result")
        XCTAssertEqual(result.integrity.status, .incomplete, "Opaque tags remain unqualified even for the clean synthetic probe")
    }

    func testExactNoOpCopyProvesOpaqueFileBytesWithoutMakingPhotosClaims() async throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("unchanged.jpg")
        try makeImage(source, type: UTType.jpeg.identifier, orientation: 6)
        try FileManager.default.copyItem(at: source, to: output)
        let result = try await MediaIntegrity.compare(source: source, output: output)
        XCTAssertEqual(result.status, .verified)
        XCTAssertEqual(result.checks.first { $0.name == "exact complete file bytes" }?.status, .passed)
        XCTAssertTrue(result.limitations.isEmpty)
    }

    func testKnownTrackLossAndDurationChangeFailBeforeOpaqueSampleQualification() {
        func inspection(_ count: String, _ types: String, _ duration: String) -> MediaInspection {
            MediaInspection(kind: .mov, byteCount: 100, metadata: [:], notes: [],
                structure: ["tracks": count, "trackTypes": types, "duration": duration])
        }
        let source = inspection("2", "vide,soun", "1/1@0")
        let noAudio = inspection("1", "vide", "1/1@0")
        let loss = MediaIntegrity.videoStructureChecks(source: source, output: noAudio)
        XCTAssertEqual(loss.first { $0.name == "video exposed track inventory" }?.status, .failed)
        let changedType = inspection("2", "vide,meta", "1/1@0")
        XCTAssertEqual(MediaIntegrity.videoStructureChecks(source: source, output: changedType).first?.status, .failed)
        let shorter = inspection("2", "vide,soun", "1/2@0")
        XCTAssertEqual(MediaIntegrity.videoStructureChecks(source: source, output: shorter).last?.status, .failed)
    }

    func testIntegrityExcludesOnlyAnExplicitlyRequestedLensAndChecksItsValue() async throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("output.jpg")
        try makeImage(source, type: UTType.jpeg.identifier, orientation: 1, lens: "Old Lens")
        try makeImage(output, type: UTType.jpeg.identifier, orientation: 1, lens: "Requested Lens")
        let patch = CameraPatch(make: "Source Maker", model: "Source Model", lens: "Requested Lens")
        let accepted = try await MediaIntegrity.compare(source: source, output: output, patch: patch)
        XCTAssertEqual(accepted.checks.first { $0.name == "requested camera metadata" }?.status, .passed)
        XCTAssertEqual(accepted.checks.first { $0.name == "retained embedded metadata" }?.status, .passed)
        XCTAssertEqual(accepted.checks.first { $0.name == "ImageIO exposed non-target properties" }?.status, .passed)
        let exactReadback = try await MediaIntegrity.compare(source: source, output: output)
        XCTAssertEqual(exactReadback.status, .mismatch, "No patch means camera fields must be preserved exactly")
        let wrongPatch = CameraPatch(make: "Source Maker", model: "Source Model", lens: "Other Lens")
        let rejected = try await MediaIntegrity.compare(source: source, output: output, patch: wrongPatch)
        XCTAssertEqual(rejected.checks.first { $0.name == "requested camera metadata" }?.status, .failed)
    }

    func testExistingOutputAndSameSourceAreNeverOverwritten() async throws {
        let source = folder.appendingPathComponent("source.jpg")
        try makeImage(source, type: UTType.jpeg.identifier, orientation: 1)
        let original = try WholeFileDigest.sha256(source)
        do { _ = try await MetadataEngine.process(source: source, output: source, patch: CameraPatch()); XCTFail("Same source was accepted") }
        catch ProbeError.sameFile { }
        let output = folder.appendingPathComponent("existing.jpg")
        try Data("sentinel".utf8).write(to: output)
        do { _ = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch()); XCTFail("Existing output accepted") }
        catch ProbeError.outputExists { }
        XCTAssertEqual(try Data(contentsOf: output), Data("sentinel".utf8))
        XCTAssertEqual(try WholeFileDigest.sha256(source), original)
    }

    func testMalformedInputCannotLeaveOutput() async throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("edited.jpg")
        try Data([0xff,0xd8,0xff,0xe1,0,10]).write(to: source)
        do { _ = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch()); XCTFail("Malformed source accepted") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
    }

    func testHEICCopyHasExplicitIndependentGraphLimitation() async throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.heic.identifier) else { throw XCTSkip("HEIC encoder unavailable on this host") }
        let source = folder.appendingPathComponent("source.heic"), output = folder.appendingPathComponent("edited.heic")
        try makeImage(source, type: UTType.heic.identifier, orientation: 1)
        let original = try WholeFileDigest.sha256(source)
        do {
            let result = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch(make: "Probe", model: "HEIC Camera"))
            XCTAssertNotEqual(result.integrity.status, .verified)
            XCTAssertTrue(result.integrity.limitations.contains { $0.contains("item graph") })
        } catch ProbeError.writeFailed(let detail) {
            // ImageIO's HEIC metadata-only copy support varies; failure is a valid measured result, never an encoding fallback.
            XCTAssertFalse(detail.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            print("HEIC metadata-only write unsupported on this host: \(detail)")
        } catch ProbeError.readbackFailed(let detail) {
            XCTAssertTrue(detail.contains("make/model"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            print("HEIC metadata-only write rejected after independent camera readback: \(detail)")
        }
        XCTAssertEqual(try WholeFileDigest.sha256(source), original)
    }

    func testSameContainerMP4CameraAndCompressedSamples() async throws {
        try await assertVideoCameraAndSamples(.mp4)
    }

    func testSameContainerMOVCameraAndCompressedSamples() async throws {
        try await assertVideoCameraAndSamples(.mov)
    }

    private func assertVideoCameraAndSamples(_ kind: MediaKind) async throws {
        let source = folder.appendingPathComponent("source.\(kind.rawValue)")
        let output = folder.appendingPathComponent("output.\(kind.rawValue)")
        try await makeVideo(source, kind: kind)
        let original = try WholeFileDigest.sha256(source)
        let result: ProcessingResult
        do {
            result = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch(make: "Probe Maker", model: "Probe Video"))
        } catch ProbeError.readbackFailed(let detail) where kind == .mp4 {
            XCTAssertTrue(detail.contains("make/model"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try WholeFileDigest.sha256(source), original)
            print("MP4 metadata-only camera write unsupported on this host; no successful output retained: \(detail)")
            return
        }
        XCTAssertEqual(result.outputInspection.kind, kind)
        XCTAssertEqual(result.outputInspection.metadata["model"], "Probe Video")
        XCTAssertEqual(try WholeFileDigest.sha256(source), original)
        XCTAssertTrue(result.integrity.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed })
        XCTAssertEqual(result.integrity.status, .incomplete)
    }

    private func syntheticJPEG(exif: String, pixel: UInt8) -> Data {
        func segment(_ marker: UInt8, _ payload: Data) -> Data {
            let length = payload.count + 2
            return Data([0xff,marker,UInt8(length >> 8),UInt8(length & 255)]) + payload
        }
        var data = Data([0xff,0xd8])
        data += segment(0xe1, Data("Exif\0\0\(exif)".utf8))
        data += segment(0xdb, Data([1,2,3]))
        data += segment(0xda, Data([1]))
        data += Data([pixel,0xff,0,8,0xff,0xd0,9])
        data += segment(0xda, Data([2]))
        data += Data([4,5,0xff,0xd9])
        return data
    }

    private func makeImage(_ url: URL, type: String, orientation: Int, lens: String? = "Source Lens", includeDate: Bool = true) throws {
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        var exif: [String: Any] = [kCGImagePropertyExifFNumber as String: 2.8]
        if includeDate { exif[kCGImagePropertyExifDateTimeOriginal as String] = "2026:01:02 03:04:05" }
        if let lens { exif[kCGImagePropertyExifLensModel as String] = lens }
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Source Maker", kCGImagePropertyTIFFModel as String: "Source Model"],
            kCGImagePropertyExifDictionary as String: exif
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProbeError.writeFailed("Cannot generate test image") }
    }

    private func makeVideo(_ url: URL, kind: MediaKind) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: kind == .mp4 ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        guard writer.canAdd(input) else { throw ProbeError.writeFailed("Cannot generate test video") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProbeError.writeFailed("Cannot start video fixture") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else { writer.cancelWriting(); throw ProbeError.writeFailed("Video fixture stalled") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { throw ProbeError.writeFailed("Pixel buffer unavailable") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) {
                memset(address, Int32(frame * 70), CVPixelBufferGetBytesPerRow(buffer) * 32)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? ProbeError.writeFailed("Cannot append fixture frame") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProbeError.writeFailed("Video fixture unfinished") }
    }
}
