import XCTest
@testable import MetadataPhotosProbe
import ProbeCore

final class ProbeEvidenceTests: XCTestCase {
    func testKnownIntegrityFailureCannotBeAcknowledgedIntoSave() {
        XCTAssertFalse(ProbeSafetyPolicy.canSave(integrityStatus: .mismatch, incompleteAcknowledged: true,
            existingRoute: false, existingAssetSelected: false, existingEditConsented: false))
    }
    func testUnverifiedIntegrityRequiresExplicitDiagnosticConsent() {
        XCTAssertFalse(ProbeSafetyPolicy.canSave(integrityStatus: .incomplete, incompleteAcknowledged: false,
            existingRoute: false, existingAssetSelected: false, existingEditConsented: false))
        XCTAssertTrue(ProbeSafetyPolicy.canSave(integrityStatus: .incomplete, incompleteAcknowledged: true,
            existingRoute: false, existingAssetSelected: false, existingEditConsented: false))
    }
    func testExistingEditRequiresBothTargetAndConsentEvenWithVerifiedBytes() {
        XCTAssertFalse(ProbeSafetyPolicy.canSave(integrityStatus: .verified, incompleteAcknowledged: false,
            existingRoute: true, existingAssetSelected: false, existingEditConsented: true))
        XCTAssertFalse(ProbeSafetyPolicy.canSave(integrityStatus: .verified, incompleteAcknowledged: false,
            existingRoute: true, existingAssetSelected: true, existingEditConsented: false))
        XCTAssertTrue(ProbeSafetyPolicy.canSave(integrityStatus: .verified, incompleteAcknowledged: false,
            existingRoute: true, existingAssetSelected: true, existingEditConsented: true))
    }
    func testNativeTransformationNeedsRecordedStageAReviewAndSource() {
        XCTAssertFalse(ProbeSafetyPolicy.canTransform(stageAReviewed: false, sourcePresent: true))
        XCTAssertFalse(ProbeSafetyPolicy.canTransform(stageAReviewed: true, sourcePresent: false))
        XCTAssertTrue(ProbeSafetyPolicy.canTransform(stageAReviewed: true, sourcePresent: true))
    }
    func testUnobservedFormIsNotEvidence() {
        let value = ManualObservation(phase: .immediate, attribution: .notChecked, attributionText: "",
            camera: .notChecked, cameraText: "", screenshotReference: "", notes: "")
        XCTAssertFalse(value.hasMeaningfulObservation)
    }
    func testManualAttributionRemainsAnObservationWhenRoundTripped() throws {
        let observed = ManualObservation(phase: .relaunched, attribution: .present,
            attributionText: "Saved from Photos Metadata Probe", camera: .differs,
            cameraText: "Original camera is still displayed", screenshotReference: "control-03.png", notes: "")
        let decoded = try JSONDecoder.probe.decode(ManualObservation.self, from: JSONEncoder.probe.encode(observed))
        XCTAssertEqual(decoded.attribution, .present)
        XCTAssertEqual(decoded.camera, .differs)
        XCTAssertEqual(decoded.phase, .relaunched)
        XCTAssertEqual(decoded.screenshotReference, "control-03.png")
    }
}
