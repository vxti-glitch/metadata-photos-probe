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
}
