import XCTest
import Foundation
@testable import ProbeCore

final class FullMetadataTests: XCTestCase {
    private func scriptPatch() -> MetadataPatch {
        MetadataPatch(values: ["make": .string("Apple"), "model": .string("iPhone 15 Pro Max"), "hostComputer": .string("iPhone"), "software": .string("17.5.1"), "lensMake": .string("Apple"), "lensModel": .string("iPhone 15 Pro Max back triple camera 6.765mm f/1.78"), "fNumber": .number(1.78), "exposureCompensation": .number(-0.5), "focalLength": .number(6.765), "focalLength35mm": .number(24), "meteringMode": .number(5), "flash": .number(16), "exposureTime": .number(1.0 / 120), "iso": .number(800), "dateTimeOriginal": .string("2026:01:02 03:04:05"), "createDate": .string("2026:01:02 03:04:05"), "modifyDate": .string("2026:01:02 03:04:05"), "offsetTime": .string("-04:00"), "offsetTimeOriginal": .string("-04:00"), "offsetTimeDigitized": .string("-04:00"), "latitude": .number(-12.5), "longitude": .number(44.25), "altitude": .number(-10.2), "imageDirection": .number(120.55), "title": .string("Résumé"), "keywords": .string("travel;portrait"), "description": .string("Synthetic description"), "artist": .string("Synthetic artist"), "copyright": .string("Synthetic copyright")])
    }
    func testAllScriptStillFieldsReadBackWithNumericAndGPSReferences() throws {
        let patch = scriptPatch(), output = try ExifMetadataEditor.patch(ExifMetadataEditor.empty, patch: patch)
        let fields = try ExifMetadataEditor.inspect(output)
        let inspection = MediaInspection(kind: .jpeg, byteCount: Int64(output.count), metadata: fields, notes: [], structure: [:])
        XCTAssertNoThrow(try patch.validateReadback(inspection))
        XCTAssertEqual(fields["latitude"], "-12.5"); XCTAssertEqual(fields["longitude"], "44.25")
        XCTAssertEqual(fields["altitude"], "-10.2"); XCTAssertEqual(fields["title"], "Résumé")
        XCTAssertEqual(Set(fields.keys), Set(patch.values.keys))
    }
    func testSelectedRemovalScrubsOldValuesAndRetainsOtherTags() throws {
        let first = try ExifMetadataEditor.patch(ExifMetadataEditor.empty, patch: scriptPatch())
        let patch = MetadataPatch(values: ["model": .string("Replacement")], removals: ["description", "latitude", "altitude", "iso", "lensModel"])
        let output = try ExifMetadataEditor.patch(first, patch: patch), fields = try ExifMetadataEditor.inspect(output)
        for key in patch.removals { XCTAssertNil(fields[key]) }
        XCTAssertEqual(fields["model"], "Replacement"); XCTAssertEqual(fields["longitude"], "44.25"); XCTAssertEqual(fields["fNumber"], "1.78")
        for retired in ["Synthetic description", "iPhone 15 Pro Max back triple camera", "iPhone 15 Pro Max\0"] { XCTAssertNil(output.range(of: Data(retired.utf8))) }
        XCTAssertEqual(try ExifMetadataEditor.inspect(first)["model"], "iPhone 15 Pro Max", "Source bytes remain immutable")
    }
    func testSubIFDAliasingTargetPayloadIsRefusedBeforeErasure() throws {
        var bytes = Data(repeating: 0, count: 105)
        bytes.replaceSubrange(0..<2, with: Data("II".utf8))
        func put(_ value: UInt32, width: Int, at position: Int) {
            bytes.replaceSubrange(position..<position + width, with: ExifMetadataEditor.number(value, width: width, little: true))
        }
        func entry(_ position: Int, tag: UInt32, type: UInt32, count: UInt32, value: UInt32) {
            put(tag, width: 2, at: position); put(type, width: 2, at: position + 2)
            put(count, width: 4, at: position + 4); put(value, width: 4, at: position + 8)
        }
        put(42, width: 2, at: 2); put(8, width: 4, at: 4); put(2, width: 2, at: 8)
        entry(10, tag: 0x010f, type: 2, count: 5, value: 100)
        entry(22, tag: 0x014a, type: 4, count: 1, value: 50)
        put(1, width: 2, at: 50)
        entry(52, tag: 0x013b, type: 2, count: 5, value: 100)
        bytes.replaceSubrange(100..<105, with: Data("Old!\0".utf8))
        let original = bytes
        XCTAssertThrowsError(try ExifMetadataEditor.patch(bytes, patch: MetadataPatch(values: ["make": .string("New")]))) { error in
            guard case ProbeError.unsupported(let reason) = error else { return XCTFail("Unexpected failure: \(error)") }
            XCTAssertTrue(reason.contains("SubIFD"))
        }
        XCTAssertEqual(bytes, original)
    }
    func testPrimitiveJSONRoundTripAndUnknownTypeRejection() throws {
        let json = Data("{\"values\":{\"iso\":800,\"make\":\"Apple\"},\"removals\":[\"software\"]}".utf8)
        let patch = try JSONDecoder().decode(MetadataPatch.self, from: json)
        try patch.validate(); XCTAssertEqual(try JSONDecoder().decode(MetadataPatch.self, from: JSONEncoder().encode(patch)), patch)
        XCTAssertThrowsError(try JSONDecoder().decode(MetadataPatch.self, from: Data("{\"values\":{\"iso\":true},\"removals\":[]}".utf8)))
    }
    func testInvalidFieldRangesAndConflictingOperationsRejected() {
        for p in [MetadataPatch(values: ["iso": .number(0)]), MetadataPatch(values: ["iso": .number(2.5)]), MetadataPatch(values: ["width": .number(12)]), MetadataPatch(values: ["make": .number(1)]), MetadataPatch(values: ["latitude": .number(91)]), MetadataPatch(values: ["offsetTime": .string("EST")]), MetadataPatch(values: ["createDate": .string("2026:02:30 03:04:05")]), MetadataPatch(values: ["make": .string("Apple")], removals: ["make"]), MetadataPatch(removals: ["model", "model"])] {
            XCTAssertThrowsError(try p.validate())
        }
    }
    func testFractionalISODatesAndMaximumOffsets() throws {
        XCTAssertNoThrow(try MetadataPatch(values: ["movieCreateDate": .string("2026-01-02T03:04:05.123Z"), "offsetTime": .string("+14:00")]).validate())
        XCTAssertThrowsError(try MetadataPatch(values: ["offsetTime": .string("+14:59")]).validate())
    }
    func testStillISODateWithSeparateOffsetIsRefusedInsteadOfChangingCaptureInstant() throws {
        XCTAssertThrowsError(try ExifMetadataEditor.patch(ExifMetadataEditor.empty, patch: MetadataPatch(values: ["dateTimeOriginal": .string("2026-01-02T03:04:05-04:00"), "offsetTimeOriginal": .string("-04:00")])))
        let bytes = try ExifMetadataEditor.patch(ExifMetadataEditor.empty, patch: MetadataPatch(values: ["dateTimeOriginal": .string("2026:01:02 03:04:05"), "offsetTimeOriginal": .string("-04:00")]))
        let readback = try ExifMetadataEditor.inspect(bytes)
        XCTAssertEqual(readback["dateTimeOriginal"], "2026:01:02 03:04:05"); XCTAssertEqual(readback["offsetTimeOriginal"], "-04:00")
    }
    func testNanosecondAndCommonShuttersDoNotQuantizeToZero() throws {
        for shutter in [1e-9, 1.0 / 240, 1.0 / 120, 1.0 / 1000] {
            let patch = MetadataPatch(values: ["exposureTime": .number(shutter)])
            let bytes = try ExifMetadataEditor.patch(ExifMetadataEditor.empty, patch: patch)
            let fields = try ExifMetadataEditor.inspect(bytes)
            let read = try XCTUnwrap(fields["exposureTime"].flatMap(Double.init))
            XCTAssertGreaterThan(read, 0)
            XCTAssertLessThanOrEqual(abs(read - shutter), MetadataPatch.numericTolerance(for: "exposureTime", value: shutter))
            XCTAssertThrowsError(try patch.validateReadback(MediaInspection(kind: .jpeg, byteCount: 1, metadata: ["exposureTime": "0"], notes: [], structure: [:])))
        }
    }
    func testJPEGMPFAndJUMBFRequireDedicatedOffsetAwareWriter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        for (marker, payload) in [(UInt8(0xe2), Data("MPF\0placeholder".utf8)), (UInt8(0xeb), Data("JUMBF placeholder".utf8))] {
            let source = dir.appendingPathComponent("source-\(marker).jpg"), output = dir.appendingPathComponent("output-\(marker).jpg")
            let count = payload.count + 2
            let bytes = Data([255,216,255,marker,UInt8(count >> 8),UInt8(count & 255)]) + payload + Data([255,218,0,3,1,1,2,255,217])
            try bytes.write(to: source)
            XCTAssertThrowsError(try StillContainerMetadata.write(source: source, output: output, kind: .jpeg, patch: MetadataPatch(values: ["make": .string("Apple")])))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
    func testReadbackRejectsMissingChangedAndUnremovedValues() {
        let patch = MetadataPatch(values: ["iso": .number(800)], removals: ["make"])
        for fields in [[String: String](), ["iso": "801"], ["iso": "800", "make": "Apple"]] {
            XCTAssertThrowsError(try patch.validateReadback(MediaInspection(kind: .jpeg, byteCount: 1, metadata: fields, notes: [], structure: [:])))
        }
    }
    func testSupportedFieldRegistryDoesNotPromiseStillOnlyVideoTags() {
        XCTAssertTrue(MetadataPatch.supportedKeys(for: .png).contains("iso"))
        XCTAssertTrue(MetadataPatch.supportedKeys(for: .mov).contains("lensModel"))
        XCTAssertTrue(MetadataPatch.supportedKeys(for: .mp4).contains("iso"))
        XCTAssertTrue(MetadataPatch.supportedKeys(for: .mp4).contains("exposureTime"))
        XCTAssertTrue(MetadataPatch.supportedKeys(for: .mp4).contains("fNumber"))
        XCTAssertFalse(MetadataPatch.supportedKeys(for: .mp4).contains("flash"))
        XCTAssertFalse(MetadataPatch.allKeys.contains("frameRate")); XCTAssertFalse(MetadataPatch.allKeys.contains("codec"))
    }
    func testPNGChunkRewritePreservesCompressedPayloadAndAllOtherChunks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png"), output = dir.appendingPathComponent("output.png")
        var bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        bytes.append(StillContainerMetadata.pngChunk("IHDR", Data([0,0,0,1,0,0,0,1,8,6,0,0,0])))
        bytes.append(StillContainerMetadata.pngChunk("IDAT", Data([120,156,99,0,0,0,1,0,1])))
        bytes.append(StillContainerMetadata.pngChunk("IEND", Data()))
        try bytes.write(to: source)
        try StillContainerMetadata.write(source: source, output: output, kind: .png, patch: scriptPatch())
        XCTAssertEqual(try StillContainerMetadata.pngFingerprint(source), try StillContainerMetadata.pngFingerprint(output))
        XCTAssertEqual(try StillContainerMetadata.metadata(output, kind: .png)["iso"], "800")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testPNGInvalidCRCAndCompetingMetadataRemovalFailClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png"), output = dir.appendingPathComponent("output.png")
        var bytes = Data([137, 80, 78, 71, 13, 10, 26, 10]) + StillContainerMetadata.pngChunk("IHDR", Data(repeating: 0, count: 13))
        bytes += StillContainerMetadata.pngChunk("tEXt", Data("Description\0Sensitive".utf8))
        bytes += StillContainerMetadata.pngChunk("IDAT", Data([1,2,3])) + StillContainerMetadata.pngChunk("IEND", Data())
        try bytes.write(to: source)
        XCTAssertThrowsError(try StillContainerMetadata.write(source: source, output: output, kind: .png, patch: MetadataPatch(removals: ["description"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        bytes[bytes.count - 1] ^= 1; try bytes.write(to: source)
        XCTAssertThrowsError(try StillContainerMetadata.layout(source, kind: .png))
    }
    func testVideoGPSRepresentationSignedCoordinatesAndAltitudeRemoval() throws {
        let patch = MetadataPatch(values: ["latitude": .number(-12.5), "longitude": .number(44.25), "altitude": .number(-10.2)])
        let values = try VideoMetadataFields.values(patch, existing: [:], track: false)
        let text = try XCTUnwrap(values[VideoMetadataFields.locationKey] ?? nil)
        XCTAssertEqual(text, "-12.500000+044.250000-10.200000/")
        XCTAssertEqual(VideoMetadataFields.decodeLocation(text), ["latitude": "-12.5", "longitude": "44.25", "altitude": "-10.2"])
        let removed = try VideoMetadataFields.values(MetadataPatch(removals: ["altitude"]), existing: ["latitude": "-12.5", "longitude": "44.25"], track: false)
        XCTAssertNil(VideoMetadataFields.decodeLocation(try XCTUnwrap(removed[VideoMetadataFields.locationKey] ?? nil))["altitude"])
    }
    func testVideoFractionalAltitudeRoundtripMatchesValidatedTolerance() throws {
        for altitude in [-10.2004, 12.345678901, -0.0000007, 99999.87654321] {
            let patch = MetadataPatch(values: ["latitude": .number(-12.5), "longitude": .number(44.25), "altitude": .number(altitude)])
            let values = try VideoMetadataFields.values(patch, existing: [:], track: false)
            let decoded = VideoMetadataFields.decodeLocation(try XCTUnwrap(values[VideoMetadataFields.locationKey] ?? nil))
            let actual = try XCTUnwrap(decoded["altitude"].flatMap(Double.init))
            XCTAssertEqual(actual, altitude, accuracy: MetadataPatch.numericTolerance(for: "altitude", value: altitude))
            try patch.validateReadback(MediaInspection(kind: .mp4, byteCount: 0, metadata: decoded, notes: [], structure: [:]))
        }
    }
    func testVideoDatesRejectWallTimesWithoutExplicitISOInstant() throws {
        for key in VideoMetadataFields.dateKeys.union(["dateTimeOriginal"]) {
            XCTAssertThrowsError(try VideoMetadataFields.values(MetadataPatch(values: [key: .string("2026:04:05 06:07:08")]), existing: [:], track: false))
            XCTAssertThrowsError(try VideoMetadataFields.values(MetadataPatch(values: [key: .string("2026-04-05T06:07:08")]), existing: [:], track: false))
            XCTAssertNoThrow(try VideoMetadataFields.values(MetadataPatch(values: [key: .string("2026-04-05T06:07:08-04:00")]), existing: [:], track: false))
        }
        for text in ["2026-02-30T06:07:08Z", "2026-02-29T06:07:08-04:00", "2026-04-05T24:07:08Z", "2026-04-05T06:07:08+14:01"] {
            XCTAssertThrowsError(try MetadataPatch.date(text))
            XCTAssertThrowsError(try VideoMetadataFields.values(MetadataPatch(values: ["dateTimeOriginal": .string(text)]), existing: [:], track: false))
        }
        XCTAssertNoThrow(try MetadataPatch.date("2024-02-29T06:07:08.123+05:30"))
    }
}
