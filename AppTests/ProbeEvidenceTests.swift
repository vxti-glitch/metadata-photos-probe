import XCTest
@testable import MetadataPhotosProbe
import ProbeCore

final class ProbeEvidenceTests: XCTestCase {
    private func fixtureAttempt() -> ProbeAttempt {
        let inspection = MediaInspection(kind: .jpeg, byteCount: 1, metadata: ["make": "Apple", "model": "Control"], notes: [], structure: [:])
        return ProbeAttempt(stage: .preparedFiles, sourceFileURL: URL(fileURLWithPath: "/control.jpg"),
            outputFileURL: URL(fileURLWithPath: "/output.jpg"), sourceRepresentation: "Fixture", baselineOrigin: "Synthetic",
            sourceInspection: inspection, outputInspection: inspection, requestedPatch: nil,
            stagedIntegrity: IntegrityComparison(status: .verified, checks: [], limitations: []), route: .resourceCreation,
            stageAReviewAcknowledged: false, incompleteIntegrityAcknowledged: false, state: "Prepared")
    }

    func testVideoPatchDropsLensFromEarlierImage() {
        XCTAssertNil(ProbeSafetyPolicy.patch(make: "Apple", model: "Camera", lens: "Old image lens", kind: .mp4).lens)
        XCTAssertEqual(ProbeSafetyPolicy.patch(make: "Apple", model: "Camera", lens: "Image lens", kind: .heic).lens, "Image lens")
    }

    func testFreshReadbackRemovesAllStaleResourceResults() {
        var attempt = fixtureAttempt()
        attempt.savedResourceInspections["removed"] = attempt.sourceInspection
        attempt.savedResourceIntegrity["removed"] = attempt.stagedIntegrity
        attempt.savedCameraChecks["removed"] = [IntegrityCheck(name: "Camera", status: .passed, detail: "Old")]
        attempt.error = "Earlier failure"
        attempt.beginReadback()
        XCTAssertTrue(attempt.savedResourceInspections.isEmpty)
        XCTAssertTrue(attempt.savedResourceIntegrity.isEmpty)
        XCTAssertTrue(attempt.savedCameraChecks.isEmpty)
        XCTAssertNil(attempt.readback)
        XCTAssertNil(attempt.error)
        attempt.recordFailure(NSError(domain: "fixture", code: 1))
        XCTAssertTrue(attempt.savedCameraChecks.isEmpty)
    }

    func testHistoricalEvidenceRetainsOriginalDeviceAfterNewExport() throws {
        let old = DeviceEvidence(model: "iPhone", hardwareIdentifier: "iPhone16,2", osVersion: "27.2", osDescription: "Old OS",
            appVersion: "0.1", appBuild: "1", bundleIdentifier: "probe", simulator: false)
        let current = DeviceEvidence(model: "iPhone", hardwareIdentifier: "iPhone16,2", osVersion: "28.0", osDescription: "New OS",
            appVersion: "0.2", appBuild: "2", bundleIdentifier: "probe", simulator: false)
        let legacy = ProbeEvidenceDocument(exportedAt: Date(), device: old, userReportedBuild: "Original build", attempts: [fixtureAttempt()])
        let restored = try JSONDecoder.probe.decode(ProbeEvidenceDocument.self, from: JSONEncoder.probe.encode(legacy)).recoveredAttempts
        let newExport = ProbeEvidenceDocument(exportedAt: Date(), device: current, userReportedBuild: "Current build", attempts: restored)
        let decoded = try JSONDecoder.probe.decode(ProbeEvidenceDocument.self, from: JSONEncoder.probe.encode(newExport))
        XCTAssertEqual(decoded.attempts[0].executionDevice?.osVersion, "27.2")
        XCTAssertEqual(decoded.attempts[0].executionDevice?.appBuild, "1")
        XCTAssertEqual(decoded.attempts[0].executionReportedBuild, "Original build")
    }

    @MainActor
    func testConfirmedCommitSurvivesInjectedJournalFailureWithoutDuplicateRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("PhotosMetadataProbe")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let fake = SuccessfulPhotosFixture()
        var writes = 0
        let model = ProbeViewModel(workspaceOverride: directory, photos: fake, persistWriter: { data, url in
            writes += 1
            if writes > 1 { throw NSError(domain: "SimulatedStorageFull", code: 28) }
            try data.write(to: url, options: [.atomic])
        })
        let attempt = fixtureAttempt()
        model.source = ImportedMediaAsset(fileURL: attempt.sourceFileURL, assetIdentifier: nil, representation: "Fixture", resourceInventory: [], notes: [])
        model.sourceInspection = attempt.sourceInspection
        model.outputURL = attempt.outputFileURL
        model.outputInspection = attempt.outputInspection
        model.comparison = attempt.stagedIntegrity
        model.save()
        for _ in 0..<100 {
            if !model.busy { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.attempts.first?.commit?.assetIdentifier, "confirmed-fixture")
        XCTAssertEqual(model.attempts.first?.state, "Photos commit confirmed; report or readback incomplete")
        XCTAssertFalse(model.canSave)
        model.save()
        let commitCount = await fake.commitCount
        XCTAssertEqual(commitCount, 1)
    }
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

private actor SuccessfulPhotosFixture: ProbePhotosAccess {
    private(set) var commitCount = 0
    func requestReadWriteAuthorization() async throws -> String { "authorized" }
    func importAsset(identifier: String, preferOriginal: Bool, to directory: URL) async throws -> ImportedMediaAsset { throw PhotosProbeError.missingResource }
    func commit(fileURL: URL, route: PhotoSaveRoute, existingAssetIdentifier: String?, adjustmentDescription: String,
                baselineSourceURL: URL?) async throws -> PhotoCommitResult {
        commitCount += 1
        return PhotoCommitResult(assetIdentifier: "confirmed-fixture", route: route, supportedRenderedTypes: [], notes: [])
    }
    func readBack(assetIdentifier: String, to directory: URL) async throws -> PhotosReadback { throw PhotosProbeError.missingResource }
}
