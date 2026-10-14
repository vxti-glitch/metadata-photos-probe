import Foundation
import XCTest
@testable import ProbeCore

final class IntegrityPolicyTests: XCTestCase {
    private func failed(_ name: String) -> IntegrityCheck {
        IntegrityCheck(name: name, status: .failed, detail: "Original diagnostic evidence")
    }

    func testStrictPolicyPreservesFailuresAndEvidence() {
        let original = IntegrityComparison(status: .mismatch, checks: [failed("retained embedded metadata")], limitations: [])
        let report = IntegrityPolicy.strict.applying(to: original)
        XCTAssertEqual(report.status, .mismatch)
        XCTAssertEqual(report.checks.first?.status, .failed)
        XCTAssertEqual(report.checks.first?.detail, "Original diagnostic evidence")
    }

    func testAdditionalMetadataOnlyBecomesHonestWarning() {
        let names = ["retained embedded metadata", "retained metadata unnamed key", "retained metadata numeric key",
                     "retained metadata unrecognized key", "retained metadata location tuple"] + MetadataPatch.allKeys.sorted().map { "retained metadata field " + $0 }
        let report = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
            IntegrityComparison(status: .mismatch, checks: names.map(failed), limitations: []))
        XCTAssertEqual(report.status, .warning)
        XCTAssertTrue(report.checks.allSatisfy { $0.status == .warning })
        XCTAssertTrue(report.checks.allSatisfy { $0.detail == "Original diagnostic evidence" })
    }

    func testEveryOtherFailureStillBlocksAlongsideMetadataWarning() {
        for name in ["container", "requested metadata", "requested camera metadata", "exposed embedded location",
                     "ImageIO non-target properties", "ImageIO exposed non-target properties", "image presentation",
                     "JPEG compressed scans and coding segments", "JPEG non-target application/color blocks",
                     "PNG compressed pixels and non-target chunks", "HEIC non-Exif item bytes", "HEIC item graph and properties",
                     "video track count", "track 1 compressed data / timing / format", "video compressed samples",
                     "requested video metadata", "requested image metadata", "retained metadata field futureUnknownField",
                     "retained metadata future diagnostic", "retained embedded metadata suffix", "unknown failure"] {
            let report = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
                IntegrityComparison(status: .mismatch, checks: [failed("retained embedded metadata"), failed(name)], limitations: []))
            XCTAssertEqual(report.status, .mismatch, name)
            XCTAssertEqual(report.checks.last?.status, .failed, name)
            XCTAssertEqual(report.checks.first?.status, .warning, name)
        }
    }

    func testIncompleteEvidenceStaysIncompleteWithWarningChecks() {
        for limitation in [true, false] {
            var checks = [failed("retained embedded metadata")]
            if !limitation { checks.append(IntegrityCheck(name: "video compressed samples", status: .notChecked, detail: "Unavailable")) }
            let report = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
                IntegrityComparison(status: .mismatch, checks: checks, limitations: limitation ? ["Opaque fields unqualified"] : []))
            XCTAssertEqual(report.status, .incomplete)
            XCTAssertEqual(report.checks.first?.status, .warning)
            XCTAssertEqual(report.limitations.count, limitation ? 1 : 0)
        }
        let alreadyIncomplete = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
            IntegrityComparison(status: .incomplete, checks: [], limitations: []))
        XCTAssertEqual(alreadyIncomplete.status, .incomplete)
    }

    func testWarningRoundTripsAndNeverBecomesVerified() throws {
        let report = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
            IntegrityComparison(status: .mismatch, checks: [failed("retained embedded metadata")], limitations: []))
        let decoded = try JSONDecoder().decode(IntegrityComparison.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.status, .warning)
        XCTAssertEqual(decoded.checks.first?.status, .warning)
        XCTAssertEqual(IntegrityPolicy.allowAdditionalMetadataChanges.applying(to: decoded).status, .warning)
        let clean = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
            IntegrityComparison(status: .verified, checks: [], limitations: []))
        XCTAssertEqual(clean.status, .verified)
    }

    func testUnexplainedMismatchAndUnauthorizedWarningCannotQualifyOutput() {
        let unexplained = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
            IntegrityComparison(status: .mismatch, checks: [], limitations: []))
        XCTAssertEqual(unexplained.status, .mismatch)
        let unauthorized = IntegrityPolicy.allowAdditionalMetadataChanges.applying(to:
            IntegrityComparison(status: .warning, checks: [IntegrityCheck(name: "container", status: .warning, detail: "Wrongly marked")], limitations: []))
        XCTAssertEqual(unauthorized.status, .mismatch)
        XCTAssertEqual(unauthorized.checks.first?.status, .failed)
    }
}
