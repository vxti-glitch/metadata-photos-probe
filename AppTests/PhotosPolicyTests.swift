import XCTest
import Photos
@testable import MetadataPhotosProbe

final class PhotosPolicyTests: XCTestCase {
    func testEditedCurrentSelectionDoesNotChooseOriginalOrAdjustmentBase() throws {
        let selected = try PhotosResourcePolicy.selectedIndex(types: [.adjustmentData, .photo, .adjustmentBasePhoto, .fullSizePhoto],
            isVideo: false, preferOriginal: false)
        XCTAssertEqual(selected, 3)
    }

    func testMissingCurrentWithAdjustmentsRefusesStaleOriginal() {
        XCTAssertThrowsError(try PhotosResourcePolicy.selectedIndex(types: [.photo, .adjustmentData],
            isVideo: false, preferOriginal: false))
    }

    func testUneditedVideoCurrentFallsBackToOriginal() throws {
        XCTAssertEqual(try PhotosResourcePolicy.selectedIndex(types: [.audio, .video],
            isVideo: true, preferOriginal: false), 1)
    }

    func testExplicitOriginalDoesNotChooseRenderedVideo() throws {
        XCTAssertEqual(try PhotosResourcePolicy.selectedIndex(types: [.fullSizeVideo, .adjustmentData, .video],
            isVideo: true, preferOriginal: true), 2)
    }

    func testDuplicateOrMissingPrimaryIsRejected() {
        XCTAssertThrowsError(try PhotosResourcePolicy.selectedIndex(types: [.photo, .photo], isVideo: false, preferOriginal: true))
        XCTAssertThrowsError(try PhotosResourcePolicy.selectedIndex(types: [.alternatePhoto, .audio], isVideo: false, preferOriginal: true))
    }

    func testPhotosSelectionAcquiresBusyGenerationBeforeExposingForm() {
        var events: [String] = []
        let expected = UUID()
        let accepted = PhotosAcquisitionOrdering.beginBeforeDismissal(begin: {
            events.append("acquire-busy-generation")
            return expected
        }, dismiss: { events.append("dismiss-picker") })
        XCTAssertEqual(accepted, expected)
        XCTAssertEqual(events, ["acquire-busy-generation", "dismiss-picker"])
    }

    func testRejectedPhotosSelectionDoesNotSupplyProviderGeneration() {
        var dismissed = false
        let accepted = PhotosAcquisitionOrdering.beginBeforeDismissal(begin: { nil }, dismiss: { dismissed = true })
        XCTAssertNil(accepted)
        XCTAssertTrue(dismissed)
    }

    @MainActor
    func testPendingCanceledPhotosImportBlocksClearAndDiscardsLateFile() async throws {
        let probe = ProbeViewModel()
        let generation = try XCTUnwrap(probe.beginPhotosAcquisition())
        XCTAssertTrue(probe.busy)
        XCTAssertNil(probe.beginPhotosAcquisition(), "A pending provider must retain its exclusive acquisition.")
        let staged = probe.stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        probe.cancel()
        probe.clearLocalData()
        XCTAssertTrue(probe.busy, "Cancel cannot expose clear while a provider can still create a file.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "Clear must remain gated until the provider finishes.")
        let result = ImportedMediaAsset(fileURL: staged, assetIdentifier: nil,
            representation: "Canceled provider fixture", resourceInventory: [], notes: [])
        probe.receivedPhoto(.success(result), acquisitionID: generation)
        XCTAssertFalse(probe.busy)
        XCTAssertNil(probe.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "A canceled callback must erase its staged copy.")
    }

    @MainActor
    func testStalePhotosCallbackCannotReleaseNewAcquisitionOrAcceptFile() async throws {
        let probe = ProbeViewModel()
        let active = try XCTUnwrap(probe.beginPhotosAcquisition())
        let staged = probe.stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let stale = ImportedMediaAsset(fileURL: staged, assetIdentifier: nil,
            representation: "Stale provider fixture", resourceInventory: [], notes: [])
        probe.receivedPhoto(.success(stale), acquisitionID: UUID())
        XCTAssertTrue(probe.busy, "A stale callback cannot release the active provider's busy state.")
        XCTAssertNil(probe.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        probe.cancel()
        probe.receivedPhoto(.failure(PhotosProbeError.canceled), acquisitionID: active)
        XCTAssertFalse(probe.busy)
    }
}
