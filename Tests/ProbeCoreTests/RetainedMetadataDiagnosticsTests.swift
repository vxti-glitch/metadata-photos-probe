import XCTest
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import ProbeCore

final class RetainedMetadataDiagnosticsTests: XCTestCase {
    func testSelectedTargetsRemainExcludedAndUnselectedDriftStillFails() {
        let checks = MediaIntegrity.retainedMetadataDifferenceChecks(
            before: ["iso": "100", "fNumber": "1.8"],
            after: ["iso": "200", "fNumber": "4"], excluding: ["iso"])
        XCTAssertEqual(checks.map(\.name), ["retained metadata field fNumber"])
        XCTAssertTrue(checks.allSatisfy { $0.status == .failed })
        XCTAssertTrue(MediaIntegrity.retainedMetadataDifferenceChecks(
            before: ["iso": "100"], after: ["iso": "200"], excluding: ["iso"]).isEmpty)
    }

    func testDocumentedAliasesUseOnlyLogicalFieldNames() {
        let checks = MediaIntegrity.retainedMetadataDifferenceChecks(before: [:], after: [
            "mdta/com.apple.quicktime.make": "private maker",
            "quickTimeUserData/©mod": "private model",
            "common/creationDate": "private time",
            "mdta/com.apple.quicktime.location.ISO6709": "private coordinates"
        ], excluding: [])
        XCTAssertEqual(Set(checks.map(\.name)), ["retained metadata field make", "retained metadata field model",
            "retained metadata field dateTimeOriginal", "retained metadata location tuple"])
    }

    func testSelectedCopyrightAndDescriptionExcludeEmittedAndOlderUserDataAliases() {
        for (field, suffixes) in [("copyright", ["©cpr", "%A9cpr", "©cpy", "%A9cpy"]),
                                  ("description", ["©des", "%A9des", "©cmt", "%A9cmt"])] {
            let aliases = Set(["", "udta/", "quickTimeUserData/"].flatMap { prefix in suffixes.map { prefix + $0 } })
            let exclusions = MediaIntegrity.retainedMetadataLegacyAliases(for: [field])
            XCTAssertTrue(aliases.isSubset(of: exclusions), "Selected \(field) must exclude each equivalent user-data spelling")
            let before = Dictionary(uniqueKeysWithValues: aliases.map { ($0, "original synthetic text") })
            let after = Dictionary(uniqueKeysWithValues: aliases.map { ($0, "edited synthetic text") })
            XCTAssertTrue(MediaIntegrity.retainedMetadataDifferenceChecks(before: before, after: after, excluding: exclusions).isEmpty)
        }
    }

    func testUnselectedCopyrightAndDescriptionAliasesStillFailWithSafeLogicalNames() {
        let exclusions = MediaIntegrity.retainedMetadataLegacyAliases(for: ["make", "model"])
        for (field, suffixes) in [("copyright", ["©cpr", "%A9cpr", "©cpy", "%A9cpy"]),
                                  ("description", ["©des", "%A9des", "©cmt", "%A9cmt"])] {
            for prefix in ["", "udta/", "quickTimeUserData/"] {
                for suffix in suffixes {
                    let alias = prefix + suffix
                    XCTAssertFalse(exclusions.contains(alias))
                    let checks = MediaIntegrity.retainedMetadataDifferenceChecks(
                        before: [alias: "original synthetic text"], after: [alias: "edited synthetic text"], excluding: exclusions)
                    XCTAssertEqual(checks.map(\.name), ["retained metadata field " + field])
                    XCTAssertTrue(checks.allSatisfy { $0.status == .failed })
                }
            }
        }
    }

    func testMaliciousKeysAndValuesNeverEnterDiagnosticNamesOrDetails() {
        let privateKey = "private://filename-and-GPS, retained metadata field iso"
        let privateValue = "private filename and precise coordinates"
        let checks = MediaIntegrity.retainedMetadataDifferenceChecks(before: [:], after: [
            privateKey: privateValue, "Optional(123)": privateValue, "nil": privateValue
        ], excluding: [])
        XCTAssertEqual(Set(checks.map(\.name)), ["retained metadata unrecognized key",
            "retained metadata numeric key", "retained metadata unnamed key"])
        for check in checks {
            XCTAssertFalse(check.name.contains(privateKey)); XCTAssertFalse(check.detail.contains(privateKey))
            XCTAssertFalse(check.name.contains(privateValue)); XCTAssertFalse(check.detail.contains(privateValue))
        }
    }

    func testRealUnselectedImageDriftKeepsMismatchAndAddsSafeFieldDiagnostic() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("synthetic-source.jpg")
        let output = folder.appendingPathComponent("synthetic-output.jpg")
        let pixels = Data(repeating: 128, count: 8 * 8 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let requested = MetadataPatch(values: ["iso": .number(200)])
        try StillContainerMetadata.write(source: source, output: output, kind: .jpeg,
            patch: MetadataPatch(values: ["iso": .number(200), "fNumber": .number(4)]))
        let result = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: requested)
        XCTAssertEqual(result.status, .mismatch)
        XCTAssertEqual(result.checks.first { $0.name == "retained embedded metadata" }?.status, .failed)
        XCTAssertEqual(result.checks.first { $0.name == "retained metadata field fNumber" }?.status, .failed)
        XCTAssertFalse(result.checks.contains { $0.name == "retained metadata field iso" })
    }
}
