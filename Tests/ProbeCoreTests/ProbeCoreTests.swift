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

    func testReadOnlyImportedMovieCanBeEditedWithoutChangingSourcePermissions() async throws {
        for kind in [MediaKind.mp4, .mov] {
            let source = folder.appendingPathComponent("readonly-source.\(kind.rawValue)")
            let output = folder.appendingPathComponent("readonly-output.\(kind.rawValue)")
            try await makeVideo(source, kind: kind)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: source.path)
            let sourceHash = try WholeFileDigest.sha256(source)
            let inherited = folder.appendingPathComponent("unmodified-copy.\(kind.rawValue)")
            try FileManager.default.copyItem(at: source, to: inherited)
            let inheritedPermissions = try FileManager.default.attributesOfItem(atPath: inherited.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(inheritedPermissions?.intValue, 0o400, "Copying an imported source retains its read-only mode")
            let result = try await MetadataEngine.processMetadataPatch(source: source, output: output,
                patch: MetadataPatch(values: ["make": .string("Apple"), "model": .string("Readonly fixture")]))
            XCTAssertEqual(result.outputInspection.metadata["make"], "Apple")
            XCTAssertEqual(result.outputInspection.metadata["model"], "Readonly fixture")
            XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed })
            XCTAssertEqual(try WholeFileDigest.sha256(source), sourceHash)
            let permissions = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o400)
        }
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
        let structure = try BoxInventory.read(url, hashMediaPayload: false)
        XCTAssertEqual(structure.types, inventory.types)
        XCTAssertTrue(structure.payloadHashes.isEmpty, "Structural inspection must not scan media payloads")
    }

    func testVideoBrandDetectionHandlesExtendedFTYPAndFullBrandList() throws {
        let url = folder.appendingPathComponent("brands.mp4")
        func size(_ n: UInt64, width: Int) -> Data {
            Data((0..<width).map { UInt8((n >> ((width - 1 - $0) * 8)) & 255) })
        }
        let payload = Data("test".utf8) + Data(repeating: 0, count: 4) + Data("isom".utf8)
        try (size(1, width: 4) + Data("ftyp".utf8) + size(UInt64(payload.count + 16), width: 8) + payload).write(to: url)
        XCTAssertEqual(try MetadataEngine.videoKind(url), .mp4)
        let longPayload = Data("test".utf8) + Data(repeating: 0, count: 4) + Data(String(repeating: "test", count: 1100).utf8) + Data("qt  ".utf8)
        try (size(UInt64(longPayload.count + 8), width: 4) + Data("ftyp".utf8) + longPayload).write(to: url)
        XCTAssertEqual(try MetadataEngine.videoKind(url), .mov)
        for bytes in [size(12, width: 4) + Data("ftypisom".utf8), size(40, width: 4) + Data("ftyp".utf8) + payload,
                      size(21, width: 4) + Data("ftyp".utf8) + payload + Data([0])] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try MetadataEngine.videoKind(url))
        }
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
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed }, "Dated baseline must retain all independently inspected non-target metadata")
        XCTAssertNotEqual(result.integrity.status, .verified, "Opaque metadata is still explicitly unqualified")
    }

    func testAPP13RestorationPreservesOpaqueOriginalPayloadAndAllScans() throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("output.jpg")
        let sourceBytes = syntheticJPEG(exif: "source", pixel: 3)
        let outputBytes = syntheticJPEG(exif: "edited", pixel: 3)
        func withAPP13(_ bytes: Data, _ payload: Data) -> Data {
            let length = payload.count + 2
            let segment = Data([0xff, 0xed, UInt8(length >> 8), UInt8(length & 255)]) + payload
            return Data(bytes.prefix(2)) + segment + Data(bytes.dropFirst(2))
        }
        let opaque = Data([0, 1, 0xff, 0xda, 2, 3]) + Data("unknown opaque Photoshop/IPTC data".utf8)
        try withAPP13(sourceBytes, opaque).write(to: source)
        try withAPP13(outputBytes, Data("reconciled unwanted extra IPTC".utf8)).write(to: output)
        let sourceHash = try WholeFileDigest.sha256(source)
        let before = try JPEGInventory.read(source)
        try JPEGMetadataPreserver.restoreOriginalAPP13(source: source, output: output)
        let after = try JPEGInventory.read(output)
        XCTAssertEqual(before.applicationSignatures, after.applicationSignatures)
        XCTAssertEqual(before.codingSignatures, after.codingSignatures)
        XCTAssertEqual(after.scanCount, 2)
        XCTAssertEqual(try WholeFileDigest.sha256(source), sourceHash)
        XCTAssertFalse(try Data(contentsOf: output).range(of: opaque) == nil)
    }

    func testAPP13RestorationRejectsMalformedInputAndCleansTemporaryFile() throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("output.jpg")
        try syntheticJPEG(exif: "source", pixel: 3).write(to: source)
        let malformed = Data([0xff, 0xd8, 0xff, 0xed, 0, 10, 1])
        try malformed.write(to: output)
        XCTAssertThrowsError(try JPEGMetadataPreserver.restoreOriginalAPP13(source: source, output: output))
        XCTAssertEqual(try Data(contentsOf: output), malformed, "Failed staging must not replace even the engine output")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".app13-") })
        XCTAssertThrowsError(try JPEGMetadataPreserver.restoreOriginalAPP13(source: source, output: source))
    }

    func testAPP13RestorationBoundsLeadingSegmentCount() throws {
        let source = folder.appendingPathComponent("source.jpg"), output = folder.appendingPathComponent("output.jpg")
        var oversized = Data([0xff, 0xd8])
        for _ in 0..<10_001 { oversized.append(contentsOf: [0xff, 0xed, 0, 2]) }
        oversized.append(syntheticJPEG(exif: "source", pixel: 3).dropFirst(2))
        try oversized.write(to: source)
        let control = syntheticJPEG(exif: "output", pixel: 3)
        try control.write(to: output)
        do {
            try JPEGMetadataPreserver.restoreOriginalAPP13(source: source, output: output)
            XCTFail("Excessive leading segment count was accepted")
        } catch ProbeError.unsupported { }
        XCTAssertEqual(try Data(contentsOf: output), control)
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

        let pngSource = folder.appendingPathComponent("source.png"), pngOutput = folder.appendingPathComponent("unchanged.png")
        try makeImage(pngSource, type: UTType.png.identifier, orientation: 6)
        try FileManager.default.copyItem(at: pngSource, to: pngOutput)
        let pngResult = try await MediaIntegrity.compare(source: pngSource, output: pngOutput)
        XCTAssertEqual(pngResult.status, .verified, "An exact no-op copy proves the complete PNG bytes, including opaque EXIF")
        XCTAssertEqual(pngResult.checks.first { $0.name == "exact complete file bytes" }?.status, .passed)
        XCTAssertTrue(pngResult.limitations.isEmpty)
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

    func testVideoFingerprintResiliencePreservesCancellationAndIncompleteDetail() throws {
        XCTAssertThrowsError(try MediaIntegrity.videoFingerprintFailureDetail(
            CancellationError(), taskIsCancelled: false
        )) { XCTAssertTrue($0 is CancellationError) }

        // AVAssetReader can report an underlying framework error after its task
        // has been canceled. That must also abort instead of becoming exportable
        // incomplete evidence.
        XCTAssertThrowsError(try MediaIntegrity.videoFingerprintFailureDetail(
            ProbeError.malformed("reader stopped"), taskIsCancelled: true
        )) { XCTAssertTrue($0 is CancellationError) }

        let readerError = ProbeError.unsupported("Compressed reader unavailable")
        XCTAssertEqual(
            try MediaIntegrity.videoFingerprintFailureDetail(readerError, taskIsCancelled: false),
            readerError.localizedDescription
        )
        let privateError = NSError(domain: NSCocoaErrorDomain, code: 257,
            userInfo: [NSLocalizedDescriptionKey: "Cannot read /private/synthetic/source.mp4 at +12.34-056.78/"])
        let safeDetail = try MediaIntegrity.videoFingerprintFailureDetail(privateError, taskIsCancelled: false)
        XCTAssertTrue(safeDetail.contains(NSCocoaErrorDomain))
        XCTAssertTrue(safeDetail.contains("257"))
        XCTAssertFalse(safeDetail.contains("/private"))
        XCTAssertFalse(safeDetail.contains("+12.34"))
    }

    func testTrackScopedMetadataRequiresEveryVideoTrackToReadBack() {
        XCTAssertEqual(MediaIntegrity.videoTrackReadbackStatus([.passed, .passed], expectedTrackCount: 2), .passed)
        XCTAssertEqual(MediaIntegrity.videoTrackReadbackStatus([.passed, .failed], expectedTrackCount: 2), .failed)
        XCTAssertEqual(MediaIntegrity.videoTrackReadbackStatus([.passed, .notChecked], expectedTrackCount: 2), .notChecked)
        XCTAssertEqual(MediaIntegrity.videoTrackReadbackStatus([.passed], expectedTrackCount: 2), .notChecked)
        XCTAssertEqual(MediaIntegrity.videoTrackReadbackStatus([], expectedTrackCount: 0), .notChecked)
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
        let result = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch(make: "Probe", model: "HEIC Camera"))
        XCTAssertEqual(result.outputInspection.metadata["make"], "Probe")
        XCTAssertEqual(result.outputInspection.metadata["model"], "HEIC Camera")
        XCTAssertNotEqual(result.integrity.status, .verified)
        XCTAssertTrue(result.integrity.limitations.contains { $0.contains("item graph") })
        XCTAssertTrue(result.integrity.checks.contains { $0.name == "HEIC non-Exif item bytes" && $0.status == .passed })
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed })
        XCTAssertEqual(try WholeFileDigest.sha256(source), original)
    }

    func testSameContainerMP4CameraAndCompressedSamples() async throws {
        try await assertVideoCameraAndSamples(.mp4)
    }

    func testSameContainerMOVCameraAndCompressedSamples() async throws {
        try await assertVideoCameraAndSamples(.mov)
    }

    func testMOVCanAddCameraToSourceWithoutMetadata() async throws {
        try await assertVideoCameraAndSamples(.mov, includeMetadata: false)
    }

    private func assertVideoCameraAndSamples(_ kind: MediaKind, includeMetadata: Bool = true) async throws {
        let source = folder.appendingPathComponent("source.\(kind.rawValue)")
        let output = folder.appendingPathComponent("output.\(kind.rawValue)")
        try await makeVideo(source, kind: kind, includeMetadata: includeMetadata)
        let original = try WholeFileDigest.sha256(source)
        let result = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch(make: "Probe Maker", model: "Probe Video"))
        XCTAssertEqual(result.outputInspection.kind, kind)
        XCTAssertEqual(result.outputInspection.metadata["model"], "Probe Video")
        XCTAssertEqual(try WholeFileDigest.sha256(source), original)
        XCTAssertTrue(result.integrity.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed })
        XCTAssertEqual(result.integrity.status, .incomplete)
    }
    func testCompleteJPEGAndHEICFieldEditingWithoutRecompression() async throws {
        for kind in [MediaKind.jpeg, .heic, .png] {
            let source = folder.appendingPathComponent("full-source.\(kind.rawValue)"), output = folder.appendingPathComponent("full-output.\(kind.rawValue)")
            try makeImage(source, type: kind == .jpeg ? UTType.jpeg.identifier : kind == .heic ? UTType.heic.identifier : UTType.png.identifier, orientation: 6)
            let original = try WholeFileDigest.sha256(source)
            let patch = MetadataPatch(values: ["make": .string("Apple"), "model": .string("Full camera"), "lensMake": .string("Apple"), "lensModel": .string("Full lens 6.765mm f/1.78"), "iso": .number(800), "exposureTime": .number(1.0 / 120), "fNumber": .number(1.78), "exposureCompensation": .number(-0.5), "focalLength": .number(6.765), "focalLength35mm": .number(24), "meteringMode": .number(5), "flash": .number(16), "software": .string("17.5.1"), "hostComputer": .string("iPhone"), "dateTimeOriginal": .string("2026:04:05 06:07:08"), "createDate": .string("2026:04:05 06:07:08"), "modifyDate": .string("2026:04:05 06:07:08"), "offsetTime": .string("-04:00"), "offsetTimeOriginal": .string("-04:00"), "offsetTimeDigitized": .string("-04:00"), "latitude": .number(-12.5), "longitude": .number(44.25), "altitude": .number(-10.2), "imageDirection": .number(120.55)])
            let diagnostic = folder.appendingPathComponent("synthetic-diagnostic.\(kind.rawValue)")
            try StillContainerMetadata.write(source: source, output: diagnostic, kind: kind, patch: patch)
            let comparison = try await MediaIntegrity.compareMetadata(source: source, output: diagnostic, patch: patch)
            if comparison.status == .mismatch {
                print("Synthetic \(kind.rawValue) failed checks: \(comparison.checks.filter { $0.status == .failed })")
                for path in [source, diagnostic] {
                    if let image = CGImageSourceCreateWithURL(path as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) {
                        print("Synthetic \(path.lastPathComponent) ImageIO properties: \(canonicalValue(properties as NSDictionary))")
                    }
                }
            }
            let result = try await MetadataEngine.processMetadataPatch(source: source, output: output, patch: patch)
            try patch.validateReadback(result.outputInspection)
            XCTAssertEqual(result.outputInspection.kind, kind); XCTAssertEqual(result.outputInspection.structure, result.sourceInspection.structure)
            XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed }, "\(kind): \(result.integrity.checks)")
            if kind == .png {
                XCTAssertEqual(result.integrity.status, .incomplete, "PNG non-eXIf byte equality does not qualify opaque TIFF metadata")
                XCTAssertTrue(result.integrity.limitations.contains { $0.contains("Opaque PNG eXIf/TIFF") })
            }
            XCTAssertEqual(try WholeFileDigest.sha256(source), original)
        }
    }
    func testFullPatchRejectsUnrequestedMetadataAndLocationChanges() async throws {
        let source = folder.appendingPathComponent("strict-source.jpg")
        try makeImage(source, type: UTType.jpeg.identifier, orientation: 1)
        let expected = MetadataPatch(values: ["iso": .number(800)])
        for (name, unexpected) in [
            ("exposure", MetadataPatch(values: ["iso": .number(800), "fNumber": .number(4)])),
            ("gps", MetadataPatch(values: ["iso": .number(800), "latitude": .number(12.5), "longitude": .number(44.25)]))
        ] {
            let output = folder.appendingPathComponent("strict-\(name).jpg")
            try StillContainerMetadata.write(source: source, output: output, kind: .jpeg, patch: unexpected)
            let report = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: expected)
            XCTAssertEqual(report.checks.first { $0.name == "requested metadata" }?.status, .passed)
            XCTAssertEqual(report.status, .mismatch, "Known non-target changes must never become acknowledgment-exportable.")
            XCTAssertEqual(report.checks.first { $0.name == "retained embedded metadata" }?.status, .failed)
            XCTAssertEqual(report.checks.first { $0.name == "ImageIO non-target properties" }?.status, .failed)
            if name == "gps" {
                XCTAssertEqual(report.checks.first { $0.name == "exposed embedded location" }?.status, .failed)
            }
        }
    }

    func testSelectedMovieDateDoesNotExemptOtherHeaderDates() async throws {
        let source = folder.appendingPathComponent("date-isolation.mov"), output = folder.appendingPathComponent("date-drift.mov")
        try await makeVideo(source, kind: .mov)
        let expected = MetadataPatch(values: ["movieCreateDate": .string("2026-04-05T06:07:08Z")])
        let valid = folder.appendingPathComponent("date-valid.mov")
        _ = try await VideoMetadataWriter.write(source: source, output: valid, patch: expected)
        let validReport = try await MediaIntegrity.compareMetadata(source: source, output: valid, patch: expected)
        XCTAssertNotEqual(validReport.status, .mismatch)
        _ = try await VideoMetadataWriter.write(source: source, output: output, patch: MetadataPatch(values: [
            "movieCreateDate": .string("2026-04-05T06:07:08Z"),
            "trackModifyDate": .string("2001-01-01T00:00:00Z")
        ]))
        let report = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: expected)
        XCTAssertEqual(report.checks.first { $0.name == "requested metadata" }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.name == "retained embedded metadata" }?.status, .failed)
        XCTAssertEqual(report.status, .mismatch)
    }

    func testMapCoordinateEditDoesNotExemptUnselectedAltitude() async throws {
        let original = folder.appendingPathComponent("altitude-original.mov")
        let source = folder.appendingPathComponent("altitude-source.mov"), output = folder.appendingPathComponent("altitude-drift.mov")
        try await makeVideo(original, kind: .mov)
        _ = try await VideoMetadataWriter.write(source: original, output: source, patch: MetadataPatch(values: [
            "latitude": .number(12.5), "longitude": .number(44.25), "altitude": .number(10)
        ]))
        let expected = MetadataPatch(values: ["latitude": .number(35), "longitude": .number(-78)])
        let valid = folder.appendingPathComponent("altitude-valid.mov")
        _ = try await VideoMetadataWriter.write(source: source, output: valid, patch: expected)
        let validReport = try await MediaIntegrity.compareMetadata(source: source, output: valid, patch: expected)
        XCTAssertNotEqual(validReport.status, .mismatch)
        _ = try await VideoMetadataWriter.write(source: source, output: output, patch: MetadataPatch(values: [
            "latitude": .number(35), "longitude": .number(-78), "altitude": .number(100)
        ]))
        let report = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: expected)
        XCTAssertEqual(report.checks.first { $0.name == "requested metadata" }?.status, .passed)
        XCTAssertEqual(report.checks.first { $0.name == "retained embedded metadata" }?.status, .failed)
        XCTAssertEqual(report.status, .mismatch)
    }

    func testMovieFullProfileLensLocationDatesAndSelectedRemovalPreserveSamples() async throws {
        for kind in [MediaKind.mp4, .mov] {
            let source = folder.appendingPathComponent("full-video.\(kind.rawValue)"), output = folder.appendingPathComponent("full-edited.\(kind.rawValue)"), removed = folder.appendingPathComponent("full-removed.\(kind.rawValue)")
            try await makeVideo(source, kind: kind)
            let values: [String: MetadataValue] = ["make": .string("Apple"), "model": .string("iPhone 15 Pro Max"), "software": .string("17.5.1"), "lensModel": .string("Main Camera - 24 mm f/1.78"), "focalLength35mm": .number(24), "latitude": .number(-12.5), "longitude": .number(44.25), "altitude": .number(-10.2), "dateTimeOriginal": .string("2026-04-05T06:07:08-04:00"), "movieCreateDate": .string("2026-04-05T06:07:08-04:00"), "movieModifyDate": .string("2026-04-05T06:07:08-04:00"), "trackCreateDate": .string("2026-04-05T06:07:08-04:00"), "trackModifyDate": .string("2026-04-05T06:07:08-04:00"), "mediaCreateDate": .string("2026-04-05T06:07:08-04:00"), "mediaModifyDate": .string("2026-04-05T06:07:08-04:00")]
            var allValues = values
            allValues["altitude"] = .number(-10.2004)
            allValues["iso"] = .number(800); allValues["exposureTime"] = .number(1.0 / 120); allValues["fNumber"] = .number(1.78)
            let fullPatch = MetadataPatch(values: allValues)
            let result: ProcessingResult
            do { result = try await MetadataEngine.processMetadataPatch(source: source, output: output, patch: fullPatch) }
            catch {
                // Generated fixture only: production cleanup removes a rejected
                // output, so reproduce the writer result for exact alias evidence.
                let diagnostic = folder.appendingPathComponent("initial-edit-diagnostic.\(kind.rawValue)")
                do {
                    _ = try await VideoMetadataWriter.write(source: source, output: diagnostic, patch: fullPatch)
                    let before = try await MetadataEngine.inspect(source), after = try await MetadataEngine.inspect(diagnostic)
                    let changed = Set(before.metadata.keys).union(after.metadata.keys).filter { before.metadata[$0] != after.metadata[$0] }.sorted()
                    for key in changed { print("Synthetic initial \(kind.rawValue) metadata difference \(key): \(before.metadata[key] ?? "<absent>") -> \(after.metadata[key] ?? "<absent>")") }
                    print("Synthetic initial \(kind.rawValue) checks: \(try await MediaIntegrity.compareMetadata(source: source, output: diagnostic, patch: fullPatch).checks)")
                } catch { print("Synthetic initial edit diagnostic failed: \(error)") }
                throw error
            }
            XCTAssertTrue(result.integrity.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
            let removal = MetadataPatch(removals: ["lensModel", "latitude", "longitude", "altitude", "software", "trackCreateDate"])
            let deleted: ProcessingResult
            do { deleted = try await MetadataEngine.processMetadataPatch(source: output, output: removed, patch: removal) }
            catch {
                // Generated fixture only: identify the exact failing layer without
                // weakening production gates or logging user media/properties.
                let diagnostic = folder.appendingPathComponent("removal-diagnostic.\(kind.rawValue)")
                var stage = "writer"
                do {
                    _ = try await VideoMetadataWriter.write(source: output, output: diagnostic, patch: removal)
                    stage = "container readback"; print("Synthetic removed fields: \(try VideoMetadataWriter.inspect(diagnostic))")
                    stage = "Apple inspection"; let inspection = try await MetadataEngine.inspect(diagnostic)
                    stage = "target readback"; try removal.validateReadback(inspection)
                    stage = "integrity"
                    print("Synthetic removal source metadata: \(try await MetadataEngine.inspect(output).metadata)")
                    print("Synthetic removal checks: \(try await MediaIntegrity.compareMetadata(source: output, output: diagnostic, patch: removal).checks)")
                } catch { print("Synthetic removal failed stage \(stage): \(error)") }
                throw error
            }
            for key in removal.removals { XCTAssertNil(deleted.outputInspection.metadata[key]) }
            XCTAssertEqual(deleted.outputInspection.metadata["model"], "iPhone 15 Pro Max")
            XCTAssertTrue(deleted.integrity.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
        }
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

    private func makeVideo(_ url: URL, kind: MediaKind, includeMetadata: Bool = true) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: kind == .mp4 ? .mp4 : .mov)
        if includeMetadata {
            writer.metadata = [(.quickTimeMetadataMake, "Source Maker"), (.quickTimeMetadataModel, "Source Movie"),
                (.quickTimeMetadataLocationISO6709, "+12.5000-044.2500/")].map { identifier, value in
                let item = AVMutableMetadataItem(); item.identifier = identifier; item.value = value as NSString
                item.dataType = "com.apple.metadata.datatype.UTF-8"; return item
            }
        }
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
