import XCTest
import Foundation
@testable import ProbeCore

/// Binary fixtures deliberately contain diagnostic byte payloads, not playable HEVC
/// or authentic camera MakerNotes. They test item/TIFF preservation independently
/// of ImageIO; real encoded HEIC readback is covered by the image integration tests.
final class HEICMetadataWriterTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testRetargetedExifPreservesGPSOpaqueMakerNoteAndOriginalTIFFOffsets() throws {
        for little in [false, true] {
            let fixture = Fixture(little: little)
            let source = folder.appendingPathComponent("source-\(little).heic"), output = folder.appendingPathComponent("output-\(little).heic")
            try fixture.bytes.write(to: source)
            let before = try WholeFileDigest.sha256(source)
            try HEICMetadataWriter.write(source: source, output: output, patch: CameraPatch(make: "Changed maker", model: "Changed model", lens: "Changed lens"))
            let actual = try Data(contentsOf: output)
            let oldTIFF = fixture.tiff
            let editedTIFF = fixture.exifTIFF(in: actual)
            // The old body is never rebased or normalized. This includes every GPS
            // payload, opaque private byte and old thumbnail/IFD pointer position.
            XCTAssertEqual(Data(editedTIFF[8..<oldTIFF.count]), Data(oldTIFF[8...]))
            let root = Int(number(editedTIFF, 4, 4, little))
            XCTAssertEqual(ascii(editedTIFF, directory: root, tag: 0x010f, little: little), "Changed maker")
            XCTAssertEqual(ascii(editedTIFF, directory: root, tag: 0x0110, little: little), "Changed model")
            XCTAssertEqual(entry(editedTIFF, directory: root, tag: 0x8825, little: little), entry(oldTIFF, directory: 8, tag: 0x8825, little: little))
            XCTAssertEqual(entry(editedTIFF, directory: root, tag: 0x0112, little: little), entry(oldTIFF, directory: 8, tag: 0x0112, little: little))
            let exif = Int(number(entry(editedTIFF, directory: root, tag: 0x8769, little: little)!, 8, 4, little))
            XCTAssertEqual(ascii(editedTIFF, directory: exif, tag: 0xa434, little: little), "Changed lens")
            XCTAssertEqual(entry(editedTIFF, directory: exif, tag: 0x927c, little: little), entry(oldTIFF, directory: 74, tag: 0x927c, little: little))
            XCTAssertEqual(try HEICMetadataWriter.inventory(source), try HEICMetadataWriter.inventory(output))
            XCTAssertEqual(try WholeFileDigest.sha256(source), before)
        }
    }

    func testOmittedLensEditKeepsOriginalExifDirectoryAndLens() throws {
        let fixture = Fixture()
        let source = folder.appendingPathComponent("source.heic"), output = folder.appendingPathComponent("output.heic")
        try fixture.bytes.write(to: source)
        try HEICMetadataWriter.write(source: source, output: output, patch: CameraPatch(make: "New", model: "New"))
        let tiff = fixture.exifTIFF(in: try Data(contentsOf: output))
        let root = Int(number(tiff, 4, 4))
        XCTAssertEqual(entry(tiff, directory: root, tag: 0x8769), entry(fixture.tiff, directory: 8, tag: 0x8769))
        XCTAssertEqual(ascii(tiff, directory: 74, tag: 0xa434), "Old lens")
    }

    func testOutOfLineCameraValuesAreWordAlignedAfterOddTIFFAndStrings() throws {
        for little in [false, true] {
            // Existing values/IFDs are aligned; an opaque trailing byte makes
            // the original TIFF length odd without changing any field offset.
            let fixture = Fixture(little: little, oddTIFFLength: true)
            XCTAssertEqual(fixture.tiff.count % 2, 1)
            let source = folder.appendingPathComponent("odd-source-\(little).heic")
            let output = folder.appendingPathComponent("odd-output-\(little).heic")
            try fixture.bytes.write(to: source)
            let sourceHash = try WholeFileDigest.sha256(source)
            let patch = CameraPatch(make: "Maker6", model: "Model6", lens: "Lens44")
            XCTAssertEqual((patch.make.utf8.count + 1) % 2, 1)
            try HEICMetadataWriter.write(source: source, output: output, patch: patch)
            let tiff = fixture.exifTIFF(in: try Data(contentsOf: output))
            let root = Int(number(tiff, 4, 4, little))
            let exifPointer = try XCTUnwrap(entry(tiff, directory: root, tag: 0x8769, little: little))
            let exif = Int(number(exifPointer, 8, 4, little))
            XCTAssertEqual(root % 2, 0)
            XCTAssertEqual(exif % 2, 0)
            var offsets = [Int]()
            for (directory, tag, value) in [(root, UInt64(0x010f), patch.make), (root, UInt64(0x0110), patch.model), (exif, UInt64(0xa434), patch.lens!)] {
                let field = try XCTUnwrap(entry(tiff, directory: directory, tag: tag, little: little))
                let count = Int(number(field, 4, 4, little))
                let offset = Int(number(field, 8, 4, little))
                XCTAssertGreaterThan(count, 4)
                XCTAssertEqual(count % 2, 1)
                XCTAssertEqual(offset % 2, 0, "ASCII tag \(tag) must have an aligned Value Offset")
                XCTAssertEqual(ascii(tiff, directory: directory, tag: tag, little: little), value)
                offsets.append(offset)
            }
            // Padding is required both before the first value and between each
            // pair of odd-length strings; it must not overwrite original bytes.
            XCTAssertEqual(offsets, [fixture.tiff.count + 1, fixture.tiff.count + 9, fixture.tiff.count + 17])
            for offset in offsets { XCTAssertEqual(tiff[offset - 1], 0) }
            XCTAssertEqual(Data(tiff[8..<fixture.tiff.count]), Data(fixture.tiff[8...]))
            XCTAssertEqual(try HEICMetadataWriter.inventory(source), try HEICMetadataWriter.inventory(output))
            XCTAssertEqual(try WholeFileDigest.sha256(source), sourceHash)
        }
    }

    func testMissingOrMultipleExifItemsRefusedWithoutAnyOutput() throws {
        for (index, types) in [[UInt32(2): "mime"], [UInt32(3): "Exif"]].enumerated() {
            let fixture = Fixture(typeOverrides: types)
            try assertRejected(fixture.bytes, name: "ambiguous-\(index)")
        }
    }

    func testExifRejectsUnqualifiedMultipleImageAssociations() throws {
        for (index, targets) in [[UInt16(3)], [UInt16(1), UInt16(3)], []].enumerated() {
            try assertRejected(Fixture(exifTargets: targets).bytes, name: "association-\(index)")
        }
    }

    func testSharedPrimaryToneMapExifPreservesEveryItemAndReference() throws {
        for little in [false, true] {
            let references = little ? sharedToneMapReferences.replacing(type: "cdsc", from: 2, targets: [5, 1]) : sharedToneMapReferences
            let fixture = Fixture(little: little, sharedToneMap: true, referenceOverrides: references)
            let source = folder.appendingPathComponent("shared-source-\(little).heic")
            let output = folder.appendingPathComponent("shared-output-\(little).heic")
            try fixture.bytes.write(to: source)
            let sourceHash = try WholeFileDigest.sha256(source)
            let inventory = try HEICMetadataWriter.inventory(source)
            XCTAssertEqual(Set(inventory.nonExifItemSHA256.keys), Set(["1", "3", "4", "5", "6", "7"]))
            XCTAssertTrue(inventory.limitations.contains { $0.contains("camera edits apply to both") })
            try HEICMetadataWriter.write(source: source, output: output,
                patch: CameraPatch(make: "Shared maker", model: "Shared model", lens: "Shared lens"))
            let bytes = try Data(contentsOf: output)
            XCTAssertEqual(try HEICMetadataWriter.inventory(output), inventory)
            XCTAssertEqual(try WholeFileDigest.sha256(source), sourceHash)
            // Independent checks compare the original raw reference box, every
            // non-Exif item byte range, and the TIFF body, not just inventory.
            for boxType in ["iref", "iprp"] {
                let oldBox = try XCTUnwrap(fixture.bytes.range(of: Data(boxType.utf8)))
                let length = Int(number(fixture.bytes, oldBox.lowerBound - 4, 4))
                let range = (oldBox.lowerBound - 4)..<(oldBox.lowerBound - 4 + length)
                XCTAssertEqual(Data(bytes[range]), Data(fixture.bytes[range]))
            }
            for id in inventory.nonExifItemSHA256.keys {
                let item = UInt32(id)!
                let offset = fixture.itemOffsets[item]!
                let count = Int(number(fixture.bytes, fixture.lengthFields[item]!, 4))
                XCTAssertEqual(Data(bytes[offset..<offset + count]), Data(fixture.bytes[offset..<offset + count]))
            }
            let edited = fixture.exifTIFF(in: bytes)
            XCTAssertEqual(Data(edited[8..<fixture.tiff.count]), Data(fixture.tiff[8...]))
            let root = Int(number(edited, 4, 4, little))
            XCTAssertEqual(ascii(edited, directory: root, tag: 0x010f, little: little), "Shared maker")
            XCTAssertEqual(ascii(edited, directory: root, tag: 0x0110, little: little), "Shared model")
        }
    }

    func testSharedExifRejectsUnrelatedDuplicatedAndCyclicAssociations() throws {
        let valid = sharedToneMapReferences
        let cases: [(String, [Reference])] = [
            ("unrelated-description", valid.replacing(type: "cdsc", from: 2, targets: [1, 3])),
            ("duplicate-description-target", valid.replacing(type: "cdsc", from: 2, targets: [1, 1])),
            ("missing-primary-description", valid.replacing(type: "cdsc", from: 2, targets: [3, 5])),
            ("extra-description-target", valid.replacing(type: "cdsc", from: 2, targets: [1, 5, 4])),
            ("duplicate-description-box", valid + [("cdsc", 2, [1, 5])]),
            ("extra-exif-relationship", valid + [("auxl", 2, [1])]),
            ("reversed-tone-inputs", valid.replacing(type: "dimg", from: 5, targets: [3, 1])),
            ("duplicate-tone-inputs", valid.replacing(type: "dimg", from: 5, targets: [1, 1])),
            ("missing-tone-input", valid.replacing(type: "dimg", from: 5, targets: [1])),
            ("missing-gain-link", valid.filter { !($0.0 == "auxl" && $0.1 == 3) }),
            ("unrelated-gain-link", valid.replacing(type: "auxl", from: 3, targets: [6])),
            ("duplicate-gain-link", valid + [("auxl", 3, [1])]),
            ("duplicate-tone-reference", valid + [("dimg", 5, [1, 3])]),
            ("extra-tone-reference", valid + [("thmb", 5, [1])]),
            ("primary-grid-cycle", valid.replacing(type: "dimg", from: 1, targets: [5])),
            ("gain-grid-cycle", valid.replacing(type: "dimg", from: 3, targets: [3])),
            ("tile-cycle", valid + [("dimg", 6, [1])]),
            ("duplicate-grid-tile", valid.replacing(type: "dimg", from: 1, targets: [6, 6])),
            ("unknown-tone-input", valid.replacing(type: "dimg", from: 5, targets: [1, 99])),
            ("unqualified-primary-link", valid + [("thmb", 1, [3])])]
        for (name, references) in cases {
            try assertRejected(Fixture(sharedToneMap: true, referenceOverrides: references).bytes, name: name)
        }
    }

    func testSharedExifRejectsUnqualifiedItemTypes() throws {
        for (id, type) in [(UInt32(5), "iden"), (UInt32(3), "mime"), (UInt32(6), "grid")] {
            try assertRejected(Fixture(typeOverrides: [id: type], sharedToneMap: true).bytes, name: "shared-type-\(id)")
        }
    }

    func testMalformedIlocOffsetsLengthsCountsAndDataReferencesAreRefused() throws {
        let fixture = Fixture()
        let cases: [(String, Int, UInt64, Int)] = [
            ("outside-file", fixture.offsetFields[2]!, UInt64(fixture.bytes.count + 4096), 4),
            ("outside-mdat", fixture.offsetFields[1]!, 0, 4),
            ("oversized-length", fixture.lengthFields[3]!, UInt64.max >> 32, 4),
            ("zero-length", fixture.lengthFields[2]!, 0, 4),
            ("item-count", fixture.ilocCountField, 4097, 2),
            ("external-data", fixture.offsetFields[2]! - 4, 1, 2),
            ("extent-count", fixture.offsetFields[2]! - 2, 4097, 2)]
        for (name, offset, value, width) in cases {
            var data = fixture.bytes; put(value, width, offset, &data)
            try assertRejected(data, name: name)
        }
    }

    func testInventoryDetectsAuxiliaryPayloadAndPropertyGraphChanges() throws {
        let fixture = Fixture()
        let source = folder.appendingPathComponent("source.heic"), auxiliary = folder.appendingPathComponent("auxiliary.heic"), graph = folder.appendingPathComponent("graph.heic")
        try fixture.bytes.write(to: source)
        let expected = try HEICMetadataWriter.inventory(source)
        var payloadChanged = fixture.bytes
        payloadChanged[fixture.itemOffsets[3]!] ^= 0x40
        try payloadChanged.write(to: auxiliary)
        let actualPayload = try HEICMetadataWriter.inventory(auxiliary)
        XCTAssertNotEqual(expected.nonExifItemSHA256["3"], actualPayload.nonExifItemSHA256["3"])
        XCTAssertEqual(expected.nonExifItemSHA256["1"], actualPayload.nonExifItemSHA256["1"])
        var graphChanged = fixture.bytes
        graphChanged[fixture.propertyValueField] ^= 1
        try graphChanged.write(to: graph)
        let actualGraph = try HEICMetadataWriter.inventory(graph)
        XCTAssertNotEqual(expected.itemGraphSHA256, actualGraph.itemGraphSHA256)
        XCTAssertEqual(expected.nonExifItemSHA256, actualGraph.nonExifItemSHA256)
    }

    func testMalformedTIFFOffsetsCountsAndCyclesCannotLeaveAStagedFile() throws {
        let fixture = Fixture()
        let tiffOffset = fixture.itemOffsets[2]! + 10
        let cases: [(String, Int, UInt64, Int)] = [
            ("tiff-root-outside", tiffOffset + 4, 0xfffffff0, 4),
            ("tiff-entry-count", tiffOffset + 8, 4097, 2),
            ("gps-pointer-outside", tiffOffset + 8 + 2 + 4 * 12 + 8, 0xfffffff0, 4),
            ("tiff-cycle", tiffOffset + 8 + 2 + 5 * 12, 8, 4)]
        for (name, offset, value, width) in cases {
            var data = fixture.bytes; put(value, width, offset, &data)
            try assertRejected(data, name: name)
        }
    }

    private func assertRejected(_ data: Data, name: String) throws {
        let source = folder.appendingPathComponent("\(name).heic"), output = folder.appendingPathComponent("\(name)-output.heic")
        try data.write(to: source)
        let hash = try WholeFileDigest.sha256(source)
        XCTAssertThrowsError(try HEICMetadataWriter.write(source: source, output: output, patch: CameraPatch(make: "Changed", model: "Changed")))
        XCTAssertEqual(try WholeFileDigest.sha256(source), hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".heic-") })
    }
}

private typealias Reference = (String, UInt16, [UInt16])
private let sharedToneMapReferences: [Reference] = [
    ("dimg", 1, [6]), ("dimg", 3, [7]), ("auxl", 3, [1]),
    ("cdsc", 4, [3]), ("dimg", 5, [1, 3]), ("cdsc", 2, [1, 5])]
private extension Array where Element == Reference {
    func replacing(type: String, from: UInt16, targets: [UInt16]) -> [Reference] {
        map { $0.0 == type && $0.1 == from ? (type, from, targets) : $0 }
    }
}

private struct Fixture {
    let bytes: Data
    let tiff: Data
    let little: Bool
    let offsetFields: [UInt32: Int]
    let lengthFields: [UInt32: Int]
    let itemOffsets: [UInt32: Int]
    let ilocCountField: Int
    let propertyValueField: Int

    init(little: Bool = false, typeOverrides: [UInt32: String] = [:], exifTargets: [UInt16] = [1], oddTIFFLength: Bool = false,
         sharedToneMap: Bool = false, referenceOverrides: [Reference]? = nil) {
        self.little = little
        var originalTIFF = makeTIFF(little: little)
        if oddTIFFLength && originalTIFF.count % 2 == 0 { originalTIFF.append(0xa5) }
        tiff = originalTIFF
        let exif = Data([0,0,0,6]) + Data("Exif\0\0".utf8) + tiff
        var payloads: [(UInt32, Data)] = [(1, Data("coded-primary-diagnostic".utf8)), (2, exif), (3, Data("auxiliary-HDR-depth-diagnostic".utf8)), (4, Data("<unknown:opaque xmlns:unknown='urn:probe'>keep</unknown:opaque>".utf8))]
        var types: [(UInt32, String)] = [(1, sharedToneMap ? "grid" : "hvc1"), (2, "Exif"), (3, sharedToneMap ? "grid" : "hvc1"), (4, "mime")]
        if sharedToneMap {
            payloads += [(5, Data("tone-map-diagnostic".utf8)), (6, Data("primary-tile-diagnostic".utf8)), (7, Data("gain-map-tile-diagnostic".utf8))]
            types += [(5, "tmap"), (6, "hvc1"), (7, "hvc1")]
        }
        let ftyp = box("ftyp", Data("heic".utf8) + Data(repeating: 0, count: 4) + Data("mif1heic".utf8))
        var info = Data(repeating: 0, count: 4) + encoded(UInt64(types.count), 2)
        for (id, type) in types {
            let actualType = typeOverrides[id] ?? type
            var body = Data([2,0,0,0]) + encoded(UInt64(id), 2) + Data([0,0]) + Data(actualType.utf8) + Data([0])
            if actualType == "mime" { body.append(Data("application/rdf+xml\0".utf8)) }
            info.append(box("infe", body))
        }
        var references = Data(repeating: 0, count: 4)
        let selectedReferences = referenceOverrides ?? (sharedToneMap ? sharedToneMapReferences : [("cdsc", 2, exifTargets), ("auxl", 3, [1]), ("cdsc", 4, [1])])
        for (type, from, targets) in selectedReferences {
            references.append(box(type, encoded(UInt64(from), 2) + encoded(UInt64(targets.count), 2)
                + targets.reduce(Data()) { $0 + encoded(UInt64($1), 2) }))
        }
        let properties = box("iprp", box("ipco", box("ispe", Data(repeating: 0, count: 4) + encoded(16, 4) + encoded(8, 4))))
        let prefix = Data(repeating: 0, count: 4) + box("pitm", Data(repeating: 0, count: 4) + encoded(1, 2)) + box("iinf", info) + box("iref", references) + properties
        // iloc v0, four local items, fixed-width offsets/lengths, one extent each.
        let locationSize = 8 + 4 + 2 + 2 + payloads.count * 14
        let metaSize = 8 + prefix.count + locationSize
        var offsets = [UInt32: Int](), cursor = ftyp.count + metaSize + 8
        for (id, payload) in payloads { offsets[id] = cursor; cursor += payload.count }
        var location = Data(repeating: 0, count: 4) + Data([0x44,0]) + encoded(UInt64(payloads.count), 2)
        var fields = [UInt32: Int](), lengths = [UInt32: Int]()
        let locationStart = ftyp.count + 8 + prefix.count
        for (id, payload) in payloads {
            location.append(encoded(UInt64(id), 2)); location.append(encoded(0, 2)); location.append(encoded(1, 2))
            fields[id] = locationStart + 8 + location.count
            location.append(encoded(UInt64(offsets[id]!), 4))
            lengths[id] = locationStart + 8 + location.count
            location.append(encoded(UInt64(payload.count), 4))
        }
        let meta = box("meta", prefix + box("iloc", location))
        bytes = ftyp + meta + box("mdat", payloads.reduce(Data()) { $0 + $1.1 })
        offsetFields = fields; lengthFields = lengths; itemOffsets = offsets
        ilocCountField = locationStart + 8 + 6
        let ispe = bytes.range(of: Data("ispe".utf8))!.lowerBound
        propertyValueField = ispe + 8
    }

    func exifTIFF(in data: Data) -> Data {
        let offset = Int(number(data, offsetFields[2]!, 4))
        let count = Int(number(data, lengthFields[2]!, 4))
        let item = Data(data[offset..<offset + count])
        return Data(item[(4 + Int(number(item, 0, 4)))...])
    }
}

private func makeTIFF(little: Bool) -> Data {
    var data = Data(repeating: 0, count: 170)
    data.replaceSubrange(0..<2, with: Data((little ? "II" : "MM").utf8))
    put(42, 2, 2, &data, little); put(8, 4, 4, &data, little)
    put(5, 2, 8, &data, little); put(2, 2, 74, &data, little); put(5, 2, 104, &data, little)
    func payload(_ value: Data) -> Int {
        if data.count % 2 != 0 { data.append(0) }
        let offset = data.count; data.append(value); return offset
    }
    func record(_ position: Int, _ tag: UInt64, _ type: UInt64, _ count: UInt64, _ value: UInt64) {
        put(tag, 2, position, &data, little); put(type, 2, position + 2, &data, little)
        put(count, 4, position + 4, &data, little); put(value, 4, position + 8, &data, little)
    }
    let make = payload(Data("Old make\0".utf8)), model = payload(Data("Old model\0".utf8)), lens = payload(Data("Old lens\0".utf8))
    let note = Data("OPAQUE-PROBE-NOTE".utf8) + encoded(0x123456, 4)
    let noteOffset = payload(note)
    var lat = Data(), lon = Data()
    for numerator in [UInt64(12), 30, 0] { lat.append(encoded(numerator, 4, little)); lat.append(encoded(1, 4, little)) }
    for numerator in [UInt64(44), 15, 0] { lon.append(encoded(numerator, 4, little)); lon.append(encoded(1, 4, little)) }
    let latitude = payload(lat), longitude = payload(lon)
    record(10, 0x010f, 2, 9, UInt64(make)); record(22, 0x0110, 2, 10, UInt64(model))
    record(34, 0x0112, 3, 1, 0); put(6, 2, 42, &data, little)
    record(46, 0x8769, 4, 1, 74); record(58, 0x8825, 4, 1, 104)
    record(76, 0x927c, 7, UInt64(note.count), UInt64(noteOffset)); record(88, 0xa434, 2, 9, UInt64(lens))
    record(106, 0, 1, 4, 0); data.replaceSubrange(114..<118, with: Data([2,3,0,0]))
    record(118, 1, 2, 2, 0); data.replaceSubrange(126..<128, with: Data("N\0".utf8))
    record(130, 2, 5, 3, UInt64(latitude)); record(142, 3, 2, 2, 0); data.replaceSubrange(150..<152, with: Data("E\0".utf8))
    record(154, 4, 5, 3, UInt64(longitude))
    return data
}
private func entry(_ tiff: Data, directory: Int, tag: UInt64, little: Bool = false) -> Data? {
    for index in 0..<Int(number(tiff, directory, 2, little)) {
        let position = directory + 2 + index * 12
        if number(tiff, position, 2, little) == tag { return Data(tiff[position..<position + 12]) }
    }
    return nil
}
private func ascii(_ tiff: Data, directory: Int, tag: UInt64, little: Bool = false) -> String? {
    guard let field = entry(tiff, directory: directory, tag: tag, little: little), number(field, 2, 2, little) == 2 else { return nil }
    let count = Int(number(field, 4, 4, little))
    let data: Data
    if count <= 4 { data = Data(field[8..<8 + count]) }
    else { let offset = Int(number(field, 8, 4, little)); data = Data(tiff[offset..<offset + count]) }
    return String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
}
private func box(_ type: String, _ payload: Data) -> Data { encoded(UInt64(payload.count + 8), 4) + Data(type.utf8) + payload }
private func encoded(_ value: UInt64, _ width: Int, _ little: Bool = false) -> Data {
    Data((0..<width).map { UInt8((value >> ((little ? $0 : width - 1 - $0) * 8)) & 255) })
}
private func put(_ value: UInt64, _ width: Int, _ offset: Int, _ data: inout Data, _ little: Bool = false) { data.replaceSubrange(offset..<offset + width, with: encoded(value, width, little)) }
private func number(_ data: Data, _ offset: Int, _ width: Int, _ little: Bool = false) -> UInt64 {
    let bytes = data[offset..<offset + width]
    return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { ($0 << 8) | UInt64($1) }
}
