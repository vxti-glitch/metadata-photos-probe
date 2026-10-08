import XCTest
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import ProbeCore

final class LocationAndContainerTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testGPSHemisphereAndZeroCoordinates() {
        let zero = EmbeddedLocationEvidence.image(gps: ["Latitude": 0, "Longitude": 0, "LatitudeRef": "N", "LongitudeRef": "E"])
        XCTAssertEqual(zero.state, .present); XCTAssertEqual(zero.latitude, 0); XCTAssertEqual(zero.longitude, 0)
        let south = EmbeddedLocationEvidence.image(gps: ["Latitude": 12.5, "Longitude": 44.25, "LatitudeRef": "S", "LongitudeRef": "W"])
        XCTAssertEqual(south.latitude, -12.5); XCTAssertEqual(south.longitude, -44.25)
    }

    func testMissingAndMalformedGPSAreNotCoordinates() {
        XCTAssertEqual(EmbeddedLocationEvidence.image(gps: nil).state, .notFound)
        for fields: [String: Any] in [
            ["Latitude": 91, "Longitude": 1, "LatitudeRef": "N", "LongitudeRef": "E"],
            ["Latitude": true, "Longitude": 1, "LatitudeRef": "N", "LongitudeRef": "E"],
            ["Latitude": 1, "Longitude": 1], ["Latitude": Double.nan, "LatitudeRef": "N"]] {
            let result = EmbeddedLocationEvidence.image(gps: fields)
            XCTAssertEqual(result.state, .incomplete)
        }
    }

    func testVideoLocationSignedAndConflictingValues() {
        let valid = EmbeddedLocationEvidence.video(metadata: ["mdta/com.apple.quicktime.location.ISO6709": "+00.0000-000.0000/"])
        XCTAssertEqual(valid.state, .present); XCTAssertEqual(valid.latitude, 0); XCTAssertEqual(valid.longitude, 0)
        let conflict = EmbeddedLocationEvidence.video(metadata: ["a.location.ISO6709": "+12.0+044.0/", "b.location.ISO6709": "+13.0+044.0/"])
        XCTAssertEqual(conflict.state, .incomplete); XCTAssertNil(conflict.latitude)
        XCTAssertEqual(EmbeddedLocationEvidence.video(metadata: ["location.ISO6709": "+91.0+044.0/"]).state, .incomplete)
    }

    func testJPEGCameraChangePreservesEmbeddedGPSAndOrientation() async throws { try await checkImage(.jpeg) }
    func testHEICCameraChangePreservesGPSItemsLensAndOrientation() async throws { try await checkImage(.heic) }

    private func checkImage(_ kind: MediaKind) async throws {
        let source = folder.appendingPathComponent("source.\(kind.rawValue)"), output = folder.appendingPathComponent("edited.\(kind.rawValue)")
        let type = kind == .jpeg ? UTType.jpeg.identifier : UTType.heic.identifier
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type) else { throw XCTSkip("Encoder unavailable") }
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let destination = CGImageDestinationCreateWithURL(source as CFURL, type as CFString, 1, nil)!
        let gps: [String: Any] = ["Latitude": 12.5, "LatitudeRef": "S", "Longitude": 44.25, "LongitudeRef": "W", "Altitude": 23.0, "AltitudeRef": 0]
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Source", kCGImagePropertyTIFFModel: "Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Old lens", kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try await MetadataEngine.inspect(source), hash = try WholeFileDigest.sha256(source)
        let result = try await MetadataEngine.process(source: source, output: output, patch: CameraPatch(make: "Probe", model: "Changed", lens: "New lens"))
        XCTAssertEqual(before.location?.state, .present)
        XCTAssertEqual(result.outputInspection.location, before.location)
        XCTAssertEqual(result.outputInspection.metadata["lens"], "New lens")
        XCTAssertEqual(result.outputInspection.structure["orientation"], before.structure["orientation"])
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed })
        XCTAssertEqual(try WholeFileDigest.sha256(source), hash)
        if kind == .heic { XCTAssertEqual(try HEICMetadataWriter.inventory(source), try HEICMetadataWriter.inventory(output)) }
    }

    func testHEICWriterMalformedHeadersLeaveSourceAndDestinationAlone() throws {
        let source = folder.appendingPathComponent("invalid.heic"), output = folder.appendingPathComponent("output.heic")
        for bytes in [Data(), Data([0,0,0,20,109,101,116,97]), Data([0,0,0,1,109,101,116,97])] {
            try bytes.write(to: source)
            let original = try WholeFileDigest.sha256(source)
            XCTAssertThrowsError(try HEICMetadataWriter.write(source: source, output: output, patch: CameraPatch()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try WholeFileDigest.sha256(source), original)
        }
    }

    func testVideoWriterRefusesFragmentsAndMalformedInputWithoutOutput() async throws {
        let source = folder.appendingPathComponent("invalid.mp4"), output = folder.appendingPathComponent("output.mp4")
        let ftyp = Data([0,0,0,20]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 4) + Data("isom".utf8)
        for bytes in [Data(), Data([0,0,0,1,109,111,111,118]), ftyp + Data([0,0,0,8]) + Data("moof".utf8)] {
            try bytes.write(to: source)
            let original = try WholeFileDigest.sha256(source)
            do { _ = try await VideoMetadataWriter.write(source: source, output: output, patch: CameraPatch()); XCTFail("Invalid/fragmented file accepted") }
            catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
            XCTAssertEqual(try WholeFileDigest.sha256(source), original)
        }
    }

    func testWritersRefuseReplacingExistingOutput() async throws {
        let source = folder.appendingPathComponent("source"), output = folder.appendingPathComponent("existing")
        try Data([1,2,3]).write(to: source); try Data([4,5,6]).write(to: output)
        XCTAssertThrowsError(try HEICMetadataWriter.write(source: source, output: output, patch: CameraPatch()))
        do { _ = try await VideoMetadataWriter.write(source: source, output: output, patch: CameraPatch()); XCTFail("Overwrite permitted") } catch {}
        XCTAssertEqual(try Data(contentsOf: source), Data([1,2,3])); XCTAssertEqual(try Data(contentsOf: output), Data([4,5,6]))
    }
}
