import XCTest
import Foundation
import ImageIO
import CoreGraphics
@testable import ProbeCore

/// Valid, metadata-free PNGs model screenshots instead of camera-origin EXIF.
/// Compressed scanlines are fixed synthetic RGB/RGBA/indexed pixels. The writer
/// must retain these bytes, transparency, color and resolution chunks exactly.
final class PNGScreenshotTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func hex(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }
    private func screenshot(colorType: UInt8, text: Bool = false) -> Data {
        var bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        bytes += StillContainerMetadata.pngChunk("IHDR", Data([0,0,0,2,0,0,0,2,8,colorType,0,0,0]))
        bytes += StillContainerMetadata.pngChunk("sRGB", Data([0]))
        bytes += StillContainerMetadata.pngChunk("gAMA", StillContainerMetadata.n32(45455))
        bytes += StillContainerMetadata.pngChunk("pHYs", StillContainerMetadata.n32(11811) + StillContainerMetadata.n32(11811) + Data([1]))
        if colorType == 3 {
            bytes += StillContainerMetadata.pngChunk("PLTE", Data([255,0,0,0,0,255]))
            bytes += StillContainerMetadata.pngChunk("tRNS", Data([0,128]))
        }
        if text { bytes += StillContainerMetadata.pngChunk("tEXt", Data("Comment\0Synthetic screenshot".utf8)) }
        let payload = colorType == 2 ? hex("789c63f8cfc0c000c20cff8100001fee05fb") :
            colorType == 6 ? hex("789c63f8cf0004ff191a402418000036e00879") : hex("789c636060044200000c0003")
        // Split the valid zlib stream across two IDATs to exercise preservation
        // of chunk boundaries, rather than merely equivalent decoded pixels.
        bytes += StillContainerMetadata.pngChunk("IDAT", Data(payload.prefix(5)))
        bytes += StillContainerMetadata.pngChunk("IDAT", Data(payload.dropFirst(5)))
        bytes += StillContainerMetadata.pngChunk("IEND", Data())
        return bytes
    }
    private func profilePatch() -> MetadataPatch {
        MetadataPatch(values: [
            "make": .string("Apple"), "model": .string("iPhone 15 Pro"),
            "software": .string("17.5.1"), "hostComputer": .string("iPhone"),
            "lensMake": .string("Apple"), "lensModel": .string("Main Camera"),
            "iso": .number(400), "exposureTime": .number(1.0 / 120),
            "fNumber": .number(1.78), "focalLength": .number(6.765),
            "focalLength35mm": .number(24), "flash": .number(16), "meteringMode": .number(5),
            "dateTimeOriginal": .string("2026:04:05 06:07:08"),
            "createDate": .string("2026:04:05 06:07:08"), "modifyDate": .string("2026:04:05 06:07:08"),
            "offsetTime": .string("-04:00"), "offsetTimeOriginal": .string("-04:00"),
            "offsetTimeDigitized": .string("-04:00")
        ])
    }
    func testMetadataFreeRGBRGBAAndPaletteScreenshotsAcceptFullProfileWithoutConversion() async throws {
        for colorType in [UInt8(2), 6, 3] {
            let source = folder.appendingPathComponent("screenshot-\(colorType).png")
            let output = folder.appendingPathComponent("IMG_000\(colorType).PNG")
            let original = screenshot(colorType: colorType)
            try original.write(to: source)
            XCTAssertNil(try StillContainerMetadata.layout(source, kind: .png).exif)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
            let originalImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            XCTAssertEqual(originalImage.width, 2); XCTAssertEqual(originalImage.height, 2)
            let result = try await MetadataEngine.processMetadataPatch(source: source, output: output, patch: profilePatch())
            try profilePatch().validateReadback(result.outputInspection)
            XCTAssertEqual(result.outputInspection.kind, .png)
            XCTAssertEqual(result.outputInspection.structure, result.sourceInspection.structure)
            XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed }, "\(result.integrity.checks)")
            XCTAssertEqual(result.integrity.status, .incomplete, "Opaque TIFF qualification remains disclosed")
            XCTAssertEqual(try StillContainerMetadata.pngFingerprint(source), try StillContainerMetadata.pngFingerprint(output))
            XCTAssertEqual(try Data(contentsOf: source), original)
            let editedSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let editedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(editedSource, 0, nil))
            XCTAssertEqual(editedImage.alphaInfo, originalImage.alphaInfo)
            XCTAssertEqual(editedImage.bitsPerComponent, originalImage.bitsPerComponent)
        }
    }
    func testScreenshotTextChunksSurviveProfileAddAndSafeRemovalRemainsExplicit() async throws {
        let source = folder.appendingPathComponent("screenshot.png"), output = folder.appendingPathComponent("edited.png")
        let original = screenshot(colorType: 6, text: true)
        try original.write(to: source)
        let result = try await MetadataEngine.processMetadataPatch(source: source, output: output, patch: profilePatch())
        XCTAssertFalse(result.integrity.checks.contains { $0.status == .failed })
        XCTAssertEqual(try StillContainerMetadata.pngFingerprint(source), try StillContainerMetadata.pngFingerprint(output))
        let scrubbed = folder.appendingPathComponent("scrubbed.png")
        do {
            _ = try await MetadataEngine.processMetadataPatch(source: output, output: scrubbed, patch: MetadataPatch(removals: ["software"]))
            XCTFail("Opaque text copies must not be advertised as scrubbed")
        } catch ProbeError.unsupported { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scrubbed.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testScreenshotSelectedRemovalPreservesTransparencyAndRetainedFields() async throws {
        let source = folder.appendingPathComponent("screenshot.png"), edited = folder.appendingPathComponent("edited.png"), removed = folder.appendingPathComponent("removed.png")
        let original = screenshot(colorType: 6)
        try original.write(to: source)
        _ = try await MetadataEngine.processMetadataPatch(source: source, output: edited, patch: profilePatch())
        let result = try await MetadataEngine.processMetadataPatch(source: edited, output: removed, patch: MetadataPatch(removals: ["iso", "lensModel", "software", "dateTimeOriginal"]))
        XCTAssertNil(result.outputInspection.metadata["iso"])
        XCTAssertNil(result.outputInspection.metadata["lensModel"])
        XCTAssertEqual(result.outputInspection.metadata["model"], "iPhone 15 Pro")
        XCTAssertEqual(try StillContainerMetadata.pngFingerprint(source), try StillContainerMetadata.pngFingerprint(removed))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
