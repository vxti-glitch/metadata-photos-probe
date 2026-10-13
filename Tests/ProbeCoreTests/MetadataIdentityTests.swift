import Foundation
import AVFoundation
import XCTest
@testable import ProbeCore

final class MetadataIdentityTests: XCTestCase {
    func testMissingIdentifierMapsUnwrappedSelectedQuickTimeKey() throws {
        let key: (any NSCopying & NSObjectProtocol)? = "com.apple.quicktime.make" as NSString
        let identity = try MetadataEngine.metadataIdentity(identifier: nil, key: key, keySpace: .quickTimeMetadata)
        XCTAssertEqual(identity, AVMetadataIdentifier.quickTimeMetadataMake.rawValue)
        // The old fallback creates an extra, non-target "Optional(...)" key.
        XCTAssertNotEqual(String(describing: key), identity)
        XCTAssertFalse(identity.contains("Optional("))
    }

    func testExistingIdentifierTakesPrecedenceOverRawKey() throws {
        let identity = try MetadataEngine.metadataIdentity(identifier: .quickTimeMetadataModel,
            key: "different raw key" as NSString, keySpace: .quickTimeMetadata)
        XCTAssertEqual(identity, AVMetadataIdentifier.quickTimeMetadataModel.rawValue)
    }

    func testSupportedMovieAndCameraRawKeysUseExistingTargetAliases() throws {
        let keys = VideoMetadataFields.keys.merging(VideoMetadataFields.trackKeys, uniquingKeysWith: { first, _ in first })
        for raw in keys.values {
            let identity = try MetadataEngine.metadataIdentity(identifier: nil, key: raw as NSString, keySpace: .quickTimeMetadata)
            XCTAssertEqual(identity, "mdta/" + raw, "Selected key must match an existing exact target alias")
        }
    }

    func testUnknownKeysStayDistinctAcrossNamespaces() throws {
        let key = "vendor.synthetic.unrequested" as NSString
        let first = try MetadataEngine.metadataIdentity(identifier: nil, key: key,
            keySpace: AVMetadataKeySpace(rawValue: "synthetic-one"))
        let second = try MetadataEngine.metadataIdentity(identifier: nil, key: key,
            keySpace: AVMetadataKeySpace(rawValue: "synthetic-two"))
        XCTAssertEqual(first, "synthetic-one/vendor.synthetic.unrequested")
        XCTAssertEqual(second, "synthetic-two/vendor.synthetic.unrequested")
        XCTAssertNotEqual(first, second)
        let before = [first: "retained", second: "retained"]
        let after = [first: "retained", second: "unrequested change"]
        XCTAssertNotEqual(before, after)
    }

    func testUnknownUnqualifiedKeyIsUnwrappedWithoutBeingDropped() throws {
        let key: (any NSCopying & NSObjectProtocol)? = "vendor.synthetic.unqualified" as NSString
        let identity = try MetadataEngine.metadataIdentity(identifier: nil, key: key, keySpace: nil)
        XCTAssertEqual(identity, "vendor.synthetic.unqualified")
        XCTAssertNotEqual(identity, String(describing: key))
    }

    func testMissingIdentityFailsInspectionClosed() {
        XCTAssertThrowsError(try MetadataEngine.metadataIdentity(identifier: nil, key: nil, keySpace: .quickTimeMetadata)) { error in
            guard case ProbeError.unsupported = error else {
                return XCTFail("Expected an unsupported identity instead of silently dropping metadata")
            }
        }
    }
}
