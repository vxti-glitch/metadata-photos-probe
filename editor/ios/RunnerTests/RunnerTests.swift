import Flutter
import UIKit
import XCTest
import ProbeCore
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo
import MapKit
@testable import Runner

@MainActor
class RunnerTests: XCTestCase {
  private var folder: URL!
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: folder)
  }

  func testLicenseDenialBlocksProcessingAndRecoveredExportNatively() async throws {
    let provider = folder.appendingPathComponent("licensed.jpg")
    let sourceBytes = try jpeg()
    try sourceBytes.write(to: provider)
    let root = folder.appendingPathComponent("licensed-sessions")
    let setup = NativeSessionStore(authorize: {}, root: root, processOperation: Self.verifiedCopy)
    let original = try await setup.importFile(provider)
    let processed = try await setup.process(sessionID: original.id, patch: CameraPatch(make: "Same", model: "Same"))
    let processing = try XCTUnwrap(processed.processing)
    let denied = NativeSessionStore(authorize: {
      throw NativeMediaError.unsupported("License required")
    }, root: root)
    do {
      _ = try await denied.processMetadata(sessionID: original.id, patch: MetadataPatch())
      XCTFail("Unlicensed metadata processing accepted")
    } catch NativeMediaError.unsupported { }
    do {
      _ = try await denied.process(sessionID: original.id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTFail("Unlicensed processing accepted")
    } catch NativeMediaError.unsupported { }
    do {
      _ = try await denied.exportCopyURL(sessionID: original.id, processingID: processing.id, acknowledgeIncomplete: true)
      XCTFail("Unlicensed recovered export accepted")
    } catch NativeMediaError.unsupported { }
    let unchanged = try await setup.list()
    XCTAssertEqual(unchanged.first?.processing?.id, processing.id)
    XCTAssertEqual(try Data(contentsOf: provider), sourceBytes)
  }

  func testLicenseExpiryDuringProcessingDoesNotPublishOrCommitOutput() async throws {
    let provider = folder.appendingPathComponent("expiry.jpg")
    try jpeg().write(to: provider)
    let publicFolder = folder.appendingPathComponent("published")
    let checks = LicenseTestAuthorization(allowedChecks: 1)
    let store = NativeSessionStore(authorize: { try await checks.check() },
      root: folder.appendingPathComponent("expiry-sessions"), autoExportRoot: publicFolder,
      processOperation: Self.verifiedCopy)
    let imported = try await store.importFile(provider)
    do {
      _ = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTFail("Expired processing accepted")
    } catch NativeMediaError.unsupported { }
    XCTAssertFalse(FileManager.default.fileExists(atPath: publicFolder.path))
    let sessions = try await store.list()
    XCTAssertNil(sessions.first?.processing)
  }

  func testLicenseExpiryImmediatelyBeforeAutoSaveIsNotSwallowed() async throws {
    let provider = folder.appendingPathComponent("auto-expiry.jpg")
    try jpeg().write(to: provider)
    let publicFolder = folder.appendingPathComponent("auto-expiry-public")
    let checks = LicenseTestAuthorization(allowedChecks: 2)
    let store = NativeSessionStore(authorize: { try await checks.check() },
      root: folder.appendingPathComponent("auto-expiry-sessions"), autoExportRoot: publicFolder,
      processOperation: Self.verifiedCopy)
    let imported = try await store.importFile(provider)
    do {
      _ = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTFail("License expiry was swallowed as an automatic-save warning")
    } catch NativeMediaError.unsupported { }
    XCTAssertFalse(FileManager.default.fileExists(atPath: publicFolder.path))
    let sessions = try await store.list()
    let saved = try XCTUnwrap(sessions.first?.processing)
    XCTAssertNil(saved.autoExportFolder)
    do {
      _ = try await store.exportCopyURL(sessionID: imported.id, processingID: saved.id, acknowledgeIncomplete: true)
      XCTFail("Expired license exported private output")
    } catch NativeMediaError.unsupported { }
  }

  func testSupportEmailHasOnlyTheFixedRecipientAndPercentEncodedSubject() throws {
    let url = NativeMediaBridge.supportEmailURL
    XCTAssertEqual(url.absoluteString, "mailto:support@aurelarchive.win?subject=Metadata%20Editor%20Support")
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "mailto")
    XCTAssertEqual(components.path, "support@aurelarchive.win")
    XCTAssertNil(components.host)
    XCTAssertNil(components.fragment)
    XCTAssertEqual(components.queryItems, [URLQueryItem(name: "subject", value: "Metadata Editor Support")])
  }

  func testLocationPickerRequiresAChosenPinBeforeApply() throws {
    let picker = LocationPickerViewController(initialLat: nil, initialLng: nil) { _ in }
    _ = picker.view
    let apply = try XCTUnwrap(picker.navigationItem.rightBarButtonItem)
    let map = try XCTUnwrap(picker.view.subviews.compactMap { $0 as? MKMapView }.first)
    XCTAssertFalse(apply.isEnabled)
    XCTAssertTrue(map.annotations.isEmpty)

    let selected = CLLocationCoordinate2D(latitude: 35.779590, longitude: -78.638179)
    picker.setPin(at: selected)
    XCTAssertTrue(apply.isEnabled)
    XCTAssertEqual(map.annotations.count, 1)
    XCTAssertEqual(map.annotations[0].coordinate.latitude, selected.latitude, accuracy: 0.000001)
    XCTAssertEqual(map.annotations[0].coordinate.longitude, selected.longitude, accuracy: 0.000001)

    picker.setPin(at: CLLocationCoordinate2D(latitude: 91, longitude: 0))
    XCTAssertEqual(map.annotations.count, 1)
    XCTAssertEqual(map.annotations[0].coordinate.latitude, selected.latitude, accuracy: 0.000001)
  }

  func testLocationPickerRestoresOnlyValidExistingCoordinates() throws {
    let existing = LocationPickerViewController(initialLat: 40.7128, initialLng: -74.0060) { _ in }
    _ = existing.view
    XCTAssertTrue(try XCTUnwrap(existing.navigationItem.rightBarButtonItem).isEnabled)

    let invalid = LocationPickerViewController(initialLat: 95, initialLng: -74.0060) { _ in }
    _ = invalid.view
    XCTAssertFalse(try XCTUnwrap(invalid.navigationItem.rightBarButtonItem).isEnabled)
    let map = try XCTUnwrap(invalid.view.subviews.compactMap { $0 as? MKMapView }.first)
    XCTAssertTrue(map.annotations.isEmpty)
  }

  func testLocationPickerAppearanceAcceptsOnlySupportedModes() throws {
    XCTAssertEqual(try NativeMediaBridge.locationAppearance("system"), .unspecified)
    XCTAssertEqual(try NativeMediaBridge.locationAppearance("light"), .light)
    XCTAssertEqual(try NativeMediaBridge.locationAppearance("dark"), .dark)
    XCTAssertThrowsError(try NativeMediaBridge.locationAppearance("sepia"))
    XCTAssertThrowsError(try NativeMediaBridge.locationAppearance(nil))
  }

  func testOpaqueVideoLocationFailureExplainsAltitudeChoiceWithoutLeakingDetail() {
    let opaque = NativeMediaBridge.flutterError(ProbeError.unsupported(
      "ISO location is opaque; explicitly set or remove latitude, longitude, and altitude together"))
    XCTAssertEqual(opaque.code, "unsupported")
    XCTAssertEqual(opaque.message,
      "This video's location cannot be changed safely with only a map pin. In Manual editing, set Altitude along with the map location, or select Remove for latitude, longitude, and altitude together.")

    let timed = NativeMediaBridge.flutterError(ProbeError.unsupported(
      "Location editing is refused for a movie containing timed metadata tracks"))
    XCTAssertEqual(timed.message,
      "This video has a timed metadata track, so its location cannot be changed safely. Leave Location unchanged or choose another video.")
  }

  func testCanceledOperationRetainsLeaseAndIgnoresStaleCompletion() throws {
    let gate = NativeOperationGate()
    let first = try gate.begin()
    gate.requestCancellation()
    XCTAssertTrue(gate.busy)
    XCTAssertTrue(gate.canceled)
    XCTAssertThrowsError(try gate.begin())
    XCTAssertFalse(gate.finish(UUID()))
    XCTAssertTrue(gate.isCurrent(first))
    XCTAssertTrue(gate.finish(first))
    let second = try gate.begin()
    XCTAssertNotEqual(first, second)
    XCTAssertFalse(gate.finish(first))
    XCTAssertTrue(gate.isCurrent(second))
    XCTAssertTrue(gate.finish(second))
  }

  func testReservationBridgeAcceptsOnlyBoundedUniqueIdentifiers() throws {
    let id = UUID().uuidString
    XCTAssertEqual(try NativeMediaBridge.reservationIdentifiers(["sessionIds": [id]]), [UUID(uuidString: id)!])
    let invalidArguments: [[String: Any]] = [
      ["sessionIds": []], ["sessionIds": [id, id]], ["sessionIds": ["../../outside"]],
      ["sessionIds": Array(repeating: id, count: 51)], ["sessionIds": [id], "name": "IMG_1234.JPG"]
    ]
    for arguments in invalidArguments { XCTAssertThrowsError(try NativeMediaBridge.reservationIdentifiers(arguments)) }
  }

  func testReservationsSurviveRelaunchAndEachBatchFileUsesItsReviewedName() async throws {
    let provider = folder.appendingPathComponent("reserve.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("reserve-sessions", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root, processOperation: Self.verifiedCopy)
    let first = try await store.importFile(provider)
    let second = try await store.importFile(provider)
    let ids = [first.id, second.id]
    let names = try await store.reserveOutputNames(sessionIDs: ids)
    XCTAssertEqual(Set(names.values).count, 2)
    let repeated = try await store.reserveOutputNames(sessionIDs: Array(ids.reversed()))
    XCTAssertEqual(names, repeated)
    let recovered = NativeSessionStore(authorize: {}, root: root, processOperation: Self.verifiedCopy)
    let restored = try await recovered.reserveOutputNames(sessionIDs: ids)
    XCTAssertEqual(names, restored)
    for id in ids {
      let changed = try await recovered.process(sessionID: id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTAssertEqual(changed.processing?.outputDisplayName, names[id.uuidString])
      XCTAssertNil(changed.reservedOutputDisplayName)
    }
    let next = try await recovered.reserveOutputNames(sessionIDs: ids)
    XCTAssertTrue(Set(next.values).isDisjoint(with: Set(names.values)))
    try await recovered.delete(first.id)
    try await recovered.clear()
    let empty = try await recovered.list()
    XCTAssertTrue(empty.isEmpty)
  }

  func testReservationRetainedAfterProcessingFailureAndPublicCollisionNeverRenames() async throws {
    let provider = folder.appendingPathComponent("failure.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("failure-sessions", isDirectory: true)
    let publicFolder = folder.appendingPathComponent("Public", isDirectory: true)
    try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: false)
    let failing = NativeSessionStore(authorize: {}, root: root, autoExportRoot: publicFolder, processOperation: { _, _, _ in
      throw NativeMediaError.processing
    })
    let imported = try await failing.importFile(provider)
    let names = try await failing.reserveOutputNames(sessionIDs: [imported.id])
    let name = try XCTUnwrap(names[imported.id.uuidString])
    do {
      _ = try await failing.process(sessionID: imported.id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTFail("Failure unexpectedly succeeded")
    } catch NativeMediaError.processing { }
    let afterFailure = try await failing.reserveOutputNames(sessionIDs: [imported.id])
    XCTAssertEqual(afterFailure, names)
    let collision = publicFolder.appendingPathComponent(name.lowercased())
    let bytes = Data("external consumer file".utf8)
    try bytes.write(to: collision)
    let retry = NativeSessionStore(authorize: {}, root: root, autoExportRoot: publicFolder, processOperation: Self.verifiedCopy)
    do {
      _ = try await retry.process(sessionID: imported.id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTFail("A reserved-name collision was silently renamed or accepted")
    } catch NativeMediaError.storage { }
    XCTAssertEqual(try Data(contentsOf: collision), bytes)
    let collisionState = try await retry.list()
    XCTAssertEqual(collisionState.first?.reservedOutputDisplayName, name)
    XCTAssertNil(collisionState.first?.processing)
    try FileManager.default.removeItem(at: collision)
    let changed = try await retry.process(sessionID: imported.id, patch: CameraPatch(make: "Same", model: "Same"))
    XCTAssertEqual(changed.processing?.outputDisplayName, name)
  }

  func testReservationLoadRejectsUnsafeWrongExtensionDuplicatesAndOutputReuse() async throws {
    for mode in ["unsafe", "extension", "duplicate", "existing"] {
      let root = folder.appendingPathComponent("invalid-\(mode)", isDirectory: true)
      let session = try persistedSession(root: root, status: .verified)
      let manifest = root.appendingPathComponent("manifest.json")
      var map = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
      var items = try XCTUnwrap(map["sessions"] as? [[String: Any]])
      items[0]["reservedOutputDisplayName"] = mode == "unsafe" ? "../IMG_1234.JPG" : mode == "extension" ? "IMG_1234.MP4" : "IMG_1234.JPG"
      if mode == "duplicate" {
        var duplicate = items[0]
        let id = UUID()
        duplicate["id"] = id.uuidString
        try FileManager.default.copyItem(at: root.appendingPathComponent(session.id.uuidString), to: root.appendingPathComponent(id.uuidString))
        items.append(duplicate)
      }
      if mode == "existing" {
        var processing = try XCTUnwrap(items[0]["processing"] as? [String: Any])
        processing["outputDisplayName"] = "IMG_1234.JPG"
        items[0]["processing"] = processing
      }
      map["sessions"] = items
      let bytes = try JSONSerialization.data(withJSONObject: map)
      try bytes.write(to: manifest)
      do { _ = try await NativeSessionStore(authorize: {}, root: root).list(); XCTFail("Invalid reservation loaded: \(mode)") }
      catch NativeMediaError.storage { }
      XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }
  }

  func testOldJournalWithoutReservationRemainsLoadableAndCanReserve() async throws {
    let root = folder.appendingPathComponent("old-journal", isDirectory: true)
    let session = try persistedSession(root: root, status: .verified)
    let store = NativeSessionStore(authorize: {}, root: root)
    let recovered = try await store.list()
    XCTAssertNil(recovered.first?.reservedOutputDisplayName)
    let reserved = try await store.reserveOutputNames(sessionIDs: [session.id])
    XCTAssertEqual(reserved.count, 1)
    XCTAssertTrue(reserved.values.first?.hasSuffix(".JPG") == true)
  }

  func testCollisionCreatedDuringProcessingKeepsReservationAndDiscardsPrivateStaging() async throws {
    let provider = folder.appendingPathComponent("late-collision.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("late-collision-sessions", isDirectory: true)
    let publicFolder = folder.appendingPathComponent("LatePublic", isDirectory: true)
    try FileManager.default.createDirectory(at: publicFolder, withIntermediateDirectories: false)
    let store = NativeSessionStore(authorize: {}, root: root, autoExportRoot: publicFolder, processOperation: { source, output, patch in
      let processed = try await Self.verifiedCopy(source, output, patch)
      let map = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
      let sessions = map["sessions"] as! [[String: Any]]
      let name = sessions[0]["reservedOutputDisplayName"] as! String
      try Data("late external file".utf8).write(to: publicFolder.appendingPathComponent(name))
      return processed
    })
    let imported = try await store.importFile(provider)
    let names = try await store.reserveOutputNames(sessionIDs: [imported.id])
    do {
      _ = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTFail("Collision during processing was accepted")
    } catch NativeMediaError.storage { }
    let rows = try await store.list()
    XCTAssertNil(rows.first?.processing)
    XCTAssertEqual(rows.first?.reservedOutputDisplayName, names[imported.id.uuidString])
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(imported.id.uuidString).path)
    XCTAssertFalse(files.contains { $0.hasPrefix("output-") })
  }

  func testFailedFinalCommitDoesNotConsumePersistedReservation() async throws {
    let provider = folder.appendingPathComponent("failed-reservation-commit.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("failed-reservation-commit", isDirectory: true)
    let snapshot = folder.appendingPathComponent("reserved-snapshot.json")
    let outside = folder.appendingPathComponent("foreign-journal.json")
    try Data("external journal".utf8).write(to: outside)
    let store = NativeSessionStore(authorize: {}, root: root, processOperation: { source, output, patch in
      let result = try await Self.verifiedCopy(source, output, patch)
      let manifest = root.appendingPathComponent("manifest.json")
      try FileManager.default.copyItem(at: manifest, to: snapshot)
      try FileManager.default.removeItem(at: manifest)
      try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
      return result
    })
    let imported = try await store.importFile(provider)
    let names = try await store.reserveOutputNames(sessionIDs: [imported.id])
    do {
      _ = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Same", model: "Same"))
      XCTFail("Invalid journal destination accepted")
    } catch { }
    XCTAssertEqual(try Data(contentsOf: outside), Data("external journal".utf8))
    let manifest = root.appendingPathComponent("manifest.json")
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.copyItem(at: snapshot, to: manifest)
    let recovered = NativeSessionStore(authorize: {}, root: root)
    let rows = try await recovered.list()
    XCTAssertNil(rows.first?.processing)
    XCTAssertEqual(rows.first?.reservedOutputDisplayName, names[imported.id.uuidString])
    let restored = try await recovered.reserveOutputNames(sessionIDs: [imported.id])
    XCTAssertEqual(restored, names)
  }

  func testBridgeRejectsPathIdentifiersAndMalformedCameraFields() throws {
    XCTAssertThrowsError(try NativeMediaBridge.identifier(["sessionId": "../../outside"], "sessionId"))
    XCTAssertThrowsError(try NativeMediaBridge.patch(["patch": ["make": "", "model": "Camera"]]))
    XCTAssertThrowsError(try NativeMediaBridge.patch(["patch": ["make": "Maker", "model": "Camera", "lens": 12]]))
    let patch = try NativeMediaBridge.patch(["patch": ["make": "Maker", "model": "Camera", "lens": ""]])
    XCTAssertNil(patch.lens)
  }

  func testFilesystemConfinementIgnoresDirectoryHintButRejectsSiblingAndSymlink() throws {
    let path = folder.appendingPathComponent("owned", isDirectory: true).path
    let hintedDirectory = URL(fileURLWithPath: path, isDirectory: true)
    let unhintedDirectory = URL(fileURLWithPath: path, isDirectory: false)
    XCTAssertNotEqual(hintedDirectory, unhintedDirectory)
    XCTAssertTrue(NativeFileSystem.samePath(hintedDirectory, unhintedDirectory))
    try FileManager.default.createDirectory(at: hintedDirectory, withIntermediateDirectories: false)
    let file = hintedDirectory.appendingPathComponent("source.jpg")
    try jpeg().write(to: file)
    XCTAssertTrue(NativeFileSystem.samePath(file.deletingLastPathComponent(), hintedDirectory))
    XCTAssertTrue(NativeFileSystem.isDescendant(file, of: unhintedDirectory))
    XCTAssertFalse(NativeFileSystem.isDescendant(folder.appendingPathComponent("owned-sibling/source.jpg"), of: hintedDirectory))
    XCTAssertFalse(NativeFileSystem.isDescendant(hintedDirectory, of: unhintedDirectory))
    let link = hintedDirectory.appendingPathComponent("link.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertFalse(NativeFileSystem.samePath(link.resolvingSymlinksInPath(), link))
  }

  func testEitherDirectoryHintImportsProcessesAndRecoversTheSameOwnedOutput() async throws {
    let provider = folder.appendingPathComponent("directory-hint-source.jpg")
    try jpeg().write(to: provider)
    for hint in [false, true] {
      let path = folder.appendingPathComponent("hint-\(hint)").path
      let root = URL(fileURLWithPath: path, isDirectory: hint)
      let previews = folder.appendingPathComponent("hint-preview-\(hint)", isDirectory: true)
      let store = NativeSessionStore(authorize: {}, root: root, previewRoot: previews)
      let imported = try await store.importFile(provider)
      let processed = try await store.process(sessionID: imported.id,
        patch: CameraPatch(make: "Directory hint maker", model: "Directory hint model"))
      let processing = try XCTUnwrap(processed.processing)
      let output = try await store.exportURL(sessionID: imported.id, processingID: processing.id, acknowledgeIncomplete: true)
      let alternateRoot = URL(fileURLWithPath: path, isDirectory: !hint)
      let recoveredStore = NativeSessionStore(authorize: {}, root: alternateRoot, previewRoot: previews)
      let recovered = try await recoveredStore.list()
      XCTAssertEqual(recovered.count, 1)
      XCTAssertEqual(recovered[0].processing?.id, processing.id)
      let recoveredOutput = try await recoveredStore.exportURL(sessionID: imported.id,
        processingID: processing.id, acknowledgeIncomplete: true)
      XCTAssertTrue(NativeFileSystem.samePath(output, recoveredOutput))
      XCTAssertEqual(try WholeFileDigest.sha256(recoveredOutput), processing.outputSHA256)
    }
  }

  func testRealJPEGImportProcessRecoveryAndFrozenExportToken() async throws {
    let provider = folder.appendingPathComponent("provider.jpg")
    let data = jpeg()
    try data.write(to: provider)
    let providerDigest = try WholeFileDigest.sha256(provider)
    let root = folder.appendingPathComponent("sessions", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let original = try await store.importFile(provider)
    XCTAssertEqual(original.inspection.kind, .jpeg)
    let patch = CameraPatch(make: "Synthetic maker", model: "Synthetic model")
    let changed = try await store.process(sessionID: original.id, patch: patch)
    let processing = try XCTUnwrap(changed.processing)
    XCTAssertEqual(processing.outputInspection.metadata["make"], patch.make)
    XCTAssertEqual(processing.outputInspection.metadata["model"], patch.model)
    XCTAssertNotEqual(processing.integrity.status, .mismatch)
    let export = try await store.exportURL(sessionID: original.id, processingID: processing.id, acknowledgeIncomplete: true)
    let independent = try await MediaIntegrity.compare(source: provider, output: export, patch: patch)
    XCTAssertNotEqual(independent.status, .mismatch)
    XCTAssertEqual(try WholeFileDigest.sha256(provider), providerDigest)
    do {
      _ = try await store.exportURL(sessionID: original.id, processingID: UUID(), acknowledgeIncomplete: true)
      XCTFail("An unfrozen output token was accepted")
    } catch NativeMediaError.invalidArgument { }
    let recoveredStore = NativeSessionStore(authorize: {}, root: root)
    let recovered = try await recoveredStore.list()
    XCTAssertEqual(recovered.count, 1)
    XCTAssertEqual(recovered[0].processing?.id, processing.id)
    let recoveredExport = try await recoveredStore.exportURL(sessionID: original.id, processingID: processing.id, acknowledgeIncomplete: true)
    XCTAssertEqual(try WholeFileDigest.sha256(recoveredExport), processing.outputSHA256)
    let bridge = try changed.bridgeMap()
    let encoded = try JSONSerialization.data(withJSONObject: bridge)
    let text = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(text.contains(root.path))
    XCTAssertFalse(text.contains(export.path))
    XCTAssertFalse(text.contains("sourceName"))
    try await store.delete(original.id)
    let afterDeletion = try await store.list()
    XCTAssertTrue(afterDeletion.isEmpty)
    XCTAssertEqual(try WholeFileDigest.sha256(provider), providerDigest)
  }

  func testNativeExportQualityGateCannotBeBypassed() async throws {
    for status in [IntegrityStatus.incomplete, .mismatch, .verified] {
      let root = folder.appendingPathComponent(status.rawValue, isDirectory: true)
      let session = try persistedSession(root: root, status: status)
      let store = NativeSessionStore(authorize: {}, root: root)
      let processing = try XCTUnwrap(session.processing)
      do {
        _ = try await store.exportURL(sessionID: session.id, processingID: processing.id, acknowledgeIncomplete: false)
        XCTAssertEqual(status, .verified)
      } catch NativeMediaError.unsupported { XCTAssertEqual(status, .incomplete) }
        catch NativeMediaError.processing { XCTAssertEqual(status, .mismatch) }
      if status != .mismatch {
        _ = try await store.exportURL(sessionID: session.id, processingID: processing.id, acknowledgeIncomplete: true)
      } else {
        do {
          _ = try await store.exportURL(sessionID: session.id, processingID: processing.id, acknowledgeIncomplete: true)
          XCTFail("Acknowledgment bypassed a failed integrity check")
        } catch NativeMediaError.processing { }
      }
    }
  }

  func testJournalRejectsTraversalAndSymlinkWithoutDeletingProvider() async throws {
    let outside = folder.appendingPathComponent("outside.jpg")
    try jpeg().write(to: outside)
    let hash = try WholeFileDigest.sha256(outside)
    for symlink in [false, true] {
      let root = folder.appendingPathComponent(symlink ? "symlink" : "traversal", isDirectory: true)
      let session = try persistedSession(root: root, status: .verified)
      let manifest = root.appendingPathComponent("manifest.json")
      if symlink {
        let source = root.appendingPathComponent(session.id.uuidString).appendingPathComponent(session.sourceName)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
      } else {
        var map = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var entries = try XCTUnwrap(map["sessions"] as? [[String: Any]])
        entries[0]["sourceName"] = "../../outside.jpg"
        map["sessions"] = entries
        try JSONSerialization.data(withJSONObject: map).write(to: manifest)
      }
      let before = try Data(contentsOf: manifest)
      do { try await NativeSessionStore(authorize: {}, root: root).clear(); XCTFail("Unsafe journal was accepted") }
      catch NativeMediaError.storage { }
      XCTAssertEqual(try Data(contentsOf: manifest), before)
      XCTAssertEqual(try WholeFileDigest.sha256(outside), hash)
    }
  }

  func testCorruptAndOversizedJournalsAreNotSilentlyReplaced() async throws {
    for oversized in [false, true] {
      let root = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let bytes = oversized ? Data(repeating: 0x20, count: NativeSessionStore.maximumManifestBytes + 1) : Data("not JSON".utf8)
      let manifest = root.appendingPathComponent("manifest.json")
      try bytes.write(to: manifest)
      do { _ = try await NativeSessionStore(authorize: {}, root: root).list(); XCTFail("Invalid journal recovered") }
      catch NativeMediaError.storage { }
      XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }
  }

  func testOutputTamperingBlocksExport() async throws {
    let root = folder.appendingPathComponent("tamper", isDirectory: true)
    let session = try persistedSession(root: root, status: .verified)
    let processing = try XCTUnwrap(session.processing)
    let output = root.appendingPathComponent(session.id.uuidString).appendingPathComponent(processing.outputName)
    try Data("changed bytes".utf8).write(to: output)
    do {
      _ = try await NativeSessionStore(authorize: {}, root: root).exportURL(sessionID: session.id, processingID: processing.id, acknowledgeIncomplete: true)
      XCTFail("Changed output was exported under a preserved quality claim")
    } catch NativeMediaError.processing { }
  }

  func testFailedProcessingClearsPriorActiveOutputAndRecoversHistory() async throws {
    let root = folder.appendingPathComponent("failed-operation", isDirectory: true)
    let session = try persistedSession(root: root, status: .verified)
    let store = NativeSessionStore(authorize: {}, root: root, processOperation: { _, output, _ in
      try Data("partial staged bytes".utf8).write(to: output)
      throw NativeMediaError.processing
    })
    do {
      _ = try await store.process(sessionID: session.id, patch: CameraPatch(make: "Changed", model: "Changed"))
      XCTFail("A deliberately failed engine returned a processed session")
    } catch NativeMediaError.processing { }
    let recovered = try await NativeSessionStore(authorize: {}, root: root).list()
    XCTAssertNil(recovered[0].processing)
    XCTAssertEqual(recovered[0].history.map(\.id), [session.processing!.id])
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(session.id.uuidString).path)
    XCTAssertEqual(Set(files), Set([session.sourceName, session.processing!.outputName]))
    do {
      _ = try await store.exportURL(sessionID: session.id, processingID: session.processing!.id, acknowledgeIncomplete: true)
      XCTFail("Prior output remained active after a failed replacement")
    } catch NativeMediaError.notFound { }
  }

  func testThumbnailIsBoundedSeparateAndRemovedWithSession() async throws {
    let provider = folder.appendingPathComponent("large-provider.jpg")
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600))
    let bytes = renderer.jpegData(withCompressionQuality: 0.95) { context in
      UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
    }
    try bytes.write(to: provider)
    let originalHash = try WholeFileDigest.sha256(provider)
    let root = folder.appendingPathComponent("preview-session", isDirectory: true)
    let previews = folder.appendingPathComponent("preview-cache", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root, previewRoot: previews)
    let session = try await store.importFile(provider)
    let map = try await store.bridgeMap(session)
    let path = try XCTUnwrap(map["previewPath"] as? String)
    let preview = URL(fileURLWithPath: path)
    XCTAssertEqual(preview.deletingLastPathComponent().resolvingSymlinksInPath(), previews.resolvingSymlinksInPath())
    XCTAssertNotEqual(preview, provider)
    let image = try XCTUnwrap(CGImageSourceCreateWithURL(preview as CFURL, nil))
    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
    XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth as String] as! NSNumber).intValue, 512)
    XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelHeight as String] as! NSNumber).intValue, 512)
    XCTAssertEqual(try WholeFileDigest.sha256(provider), originalHash)
    try await store.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
    XCTAssertEqual(try WholeFileDigest.sha256(provider), originalHash)
  }

  func testBoundedPhotoStreamRejectsOverflowAndHonorsCancellation() throws {
    let target = folder.appendingPathComponent("bounded-stream.jpg")
    let stream = try NativePhotoStream(target: target, maximumBytes: 8)
    stream.accept(Data(repeating: 1, count: 6))
    stream.accept(Data(repeating: 2, count: 4))
    XCTAssertNotNil(stream.finish(nil))
    XCTAssertEqual(try Data(contentsOf: target).count, 6)
    let canceledTarget = folder.appendingPathComponent("canceled-stream.jpg")
    let canceled = try NativePhotoStream(target: canceledTarget, maximumBytes: 8)
    canceled.accept(Data(repeating: 1, count: 2))
    canceled.cancel()
    canceled.accept(Data(repeating: 3, count: 4))
    XCTAssertTrue(canceled.finish(nil) is CancellationError)
    XCTAssertEqual(try Data(contentsOf: canceledTarget).count, 2)
  }

  func testRecoveryRemovesInterruptedOwnedImportsAndPartialOutputs() async throws {
    let root = folder.appendingPathComponent("orphan-recovery", isDirectory: true)
    let session = try persistedSession(root: root, status: .verified)
    let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
    try Data("private partial source".utf8).write(to: orphan.appendingPathComponent("source.jpg"))
    let partial = root.appendingPathComponent(session.id.uuidString).appendingPathComponent("output-\(UUID().uuidString).jpg")
    try Data().write(to: partial)
    let recovered = try await NativeSessionStore(authorize: {}, root: root).list()
    XCTAssertEqual(recovered.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(session.id.uuidString).appendingPathComponent(session.sourceName).path))
  }

  func testRecoveredVerifiedSummaryCannotHideFailedOrUncheckedChecks() async throws {
    for check in ["failed", "notChecked", "empty"] {
      let root = folder.appendingPathComponent("inconsistent-\(check)", isDirectory: true)
      let session = try persistedSession(root: root, status: .verified)
      let manifest = root.appendingPathComponent("manifest.json")
      var map = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
      var entries = try XCTUnwrap(map["sessions"] as? [[String: Any]])
      var processing = try XCTUnwrap(entries[0]["processing"] as? [String: Any])
      var integrity = try XCTUnwrap(processing["integrity"] as? [String: Any])
      integrity["checks"] = check == "empty" ? [] : [["name": "hidden problem", "status": check, "detail": "Synthetic regression"]]
      processing["integrity"] = integrity; entries[0]["processing"] = processing; map["sessions"] = entries
      try JSONSerialization.data(withJSONObject: map).write(to: manifest)
      do {
        _ = try await NativeSessionStore(authorize: {}, root: root).exportURL(sessionID: session.id, processingID: session.processing!.id, acknowledgeIncomplete: true)
        XCTFail("A misleading verified summary bypassed native checks")
      } catch NativeMediaError.processing { }
    }
  }

  func testOversizedStagedOutputIsRemovedBeforeJournalCommit() async throws {
    let root = folder.appendingPathComponent("oversized-output", isDirectory: true)
    let session = try persistedSession(root: root, status: .verified)
    let inspection = session.inspection
    let limit: Int64 = 8192
    let store = NativeSessionStore(authorize: {}, root: root, mediaSizeLimit: limit, processOperation: { _, output, _ in
      XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
      let file = try FileHandle(forWritingTo: output)
      try file.truncate(atOffset: UInt64(limit + 1)); try file.close()
      struct Result: Encodable {
        let outputURL: URL
        let sourceInspection: MediaInspection
        let outputInspection: MediaInspection
        let integrity: IntegrityComparison
      }
      return try JSONDecoder().decode(ProcessingResult.self, from: JSONEncoder().encode(Result(outputURL: output,
        sourceInspection: inspection, outputInspection: inspection,
        integrity: IntegrityComparison(status: .verified, checks: [IntegrityCheck(name: "synthetic", status: .passed, detail: "Synthetic boundary")], limitations: []))))
    })
    do { _ = try await store.process(sessionID: session.id, patch: CameraPatch()); XCTFail("Oversized output was committed") }
    catch NativeMediaError.storage { }
    let recovered = try await NativeSessionStore(authorize: {}, root: root).list()
    XCTAssertNil(recovered[0].processing)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(session.id.uuidString).path)
    XCTAssertEqual(Set(files), Set([session.sourceName, session.processing!.outputName]))
  }

  func testRecoveredActualIncompleteReportIsPublishedBeforeAcknowledgmentRefusal() async throws {
    let provider = folder.appendingPathComponent("recovery-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("real-recovery", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let source = try await store.importFile(provider)
    let changed = try await store.process(sessionID: source.id, patch: CameraPatch(make: "Changed maker", model: "Changed model"))
    let processed = try XCTUnwrap(changed.processing)
    XCTAssertEqual(processed.integrity.status, .incomplete)
    let manifest = root.appendingPathComponent("manifest.json")
    var map = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    var entries = try XCTUnwrap(map["sessions"] as? [[String: Any]])
    var processing = try XCTUnwrap(entries[0]["processing"] as? [String: Any])
    var integrity = try XCTUnwrap(processing["integrity"] as? [String: Any])
    integrity["status"] = "verified"; integrity["limitations"] = []
    processing["integrity"] = integrity; entries[0]["processing"] = processing; map["sessions"] = entries
    try JSONSerialization.data(withJSONObject: map).write(to: manifest)
    let recoveredStore = NativeSessionStore(authorize: {}, root: root)
    do {
      _ = try await recoveredStore.exportURL(sessionID: source.id, processingID: processed.id, acknowledgeIncomplete: false)
      XCTFail("Recovered quality limitations were ignored")
    } catch NativeMediaError.unsupported { }
    let corrected = try await recoveredStore.list()
    XCTAssertEqual(corrected[0].processing?.integrity.status, .incomplete)
    XCTAssertFalse(corrected[0].processing!.integrity.limitations.isEmpty)
    _ = try await recoveredStore.exportURL(sessionID: source.id, processingID: processed.id, acknowledgeIncomplete: true)
  }

  func testQualificationCacheCannotCrossSessionWithSameProcessingIdentifier() async throws {
    let root = folder.appendingPathComponent("cache-binding", isDirectory: true)
    let first = try persistedSession(root: root, status: .verified)
    var second = try persistedSession(root: root, status: .verified)
    let originalSecond = second.processing!
    let sharedID = first.processing!.id
    let secondDirectory = root.appendingPathComponent(second.id.uuidString)
    let sharedName = "output-\(sharedID.uuidString).jpg"
    try FileManager.default.moveItem(at: secondDirectory.appendingPathComponent(originalSecond.outputName),
      to: secondDirectory.appendingPathComponent(sharedName))
    second.processing = NativeProcessing(id: sharedID, createdAt: originalSecond.createdAt,
      patch: CameraPatch(make: "False recovered maker", model: "False recovered model"), outputName: sharedName,
      outputInspection: originalSecond.outputInspection, integrity: originalSecond.integrity,
      outputSHA256: originalSecond.outputSHA256)
    struct Journal: Encodable { let schemaVersion = 1; let sessions: [NativeSession] }
    try JSONEncoder().encode(Journal(sessions: [first, second])).write(to: root.appendingPathComponent("manifest.json"))
    let recovered = NativeSessionStore(authorize: {}, root: root)
    _ = try await recovered.exportURL(sessionID: first.id, processingID: sharedID, acknowledgeIncomplete: true)
    do {
      _ = try await recovered.exportURL(sessionID: second.id, processingID: sharedID, acknowledgeIncomplete: true)
      XCTFail("A different session reused the first session's qualified output")
    } catch NativeMediaError.processing { }
  }

  func testQualificationCacheFollowsCurrentOutputReplacementDeleteAndClear() async throws {
    let provider = folder.appendingPathComponent("cache-lifecycle-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("cache-lifecycle", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let first = try await store.importFile(provider)
    var processingIDs = Set<UUID>()
    for index in 0..<3 {
      let result = try await store.process(sessionID: first.id,
        patch: CameraPatch(make: "Synthetic maker \(index)", model: "Synthetic model \(index)"))
      processingIDs.insert(try XCTUnwrap(result.processing).id)
      let count = await store.cachedQualificationCount
      XCTAssertEqual(count, 1, "Replacing an output retained a previous qualification report")
    }
    XCTAssertEqual(processingIDs.count, 3)
    let second = try await store.importFile(provider)
    _ = try await store.process(sessionID: second.id, patch: CameraPatch(make: "Second maker", model: "Second model"))
    let twoLive = await store.cachedQualificationCount
    XCTAssertEqual(twoLive, 2)
    try await store.delete(first.id)
    let afterDeletion = await store.cachedQualificationCount
    XCTAssertEqual(afterDeletion, 1)
    let recovered = NativeSessionStore(authorize: {}, root: root)
    _ = try await recovered.list()
    let beforeRequalification = await recovered.cachedQualificationCount
    XCTAssertEqual(beforeRequalification, 0)
    try await store.clear()
    let afterClear = await store.cachedQualificationCount
    XCTAssertEqual(afterClear, 0)
  }

  private func jpeg() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8))
    return renderer.jpegData(withCompressionQuality: 0.95) { context in
      UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
    }
  }

  private func png() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8))
    return renderer.pngData { context in
      UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
    }
  }

  func testFullPatchBridgeValidationAndPresetBounds() throws {
    let patch = try NativeMediaBridge.metadataPatch(["patch": ["values": ["iso": 400, "exposureTime": 0.01, "model": "Phone"], "removals": ["software"]]])
    XCTAssertTrue(patch.targetedKeys.contains("iso"))
    XCTAssertThrowsError(try NativeMediaBridge.metadataPatch(["patch": ["values": ["iso": true], "removals": []]]))
    XCTAssertThrowsError(try NativeMediaBridge.metadataPatch(["patch": ["values": ["unknownField": "x"], "removals": []]]))
    XCTAssertThrowsError(try NativeMediaBridge.metadataPatch(["patch": ["values": ["model": "Phone"], "removals": ["model"]]]))
    let preset: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "name": "Camera", "patch": ["values": ["iso": 200], "removals": []]]
    XCTAssertNoThrow(try NativeSessionStore.validatePreset(preset))
    var malformed = preset; malformed["name"] = ""
    XCTAssertThrowsError(try NativeSessionStore.validatePreset(malformed))
    XCTAssertThrowsError(try NativeSessionStore.validateEditorState(["presets": Array(repeating: 1, count: 501)]))
    XCTAssertThrowsError(try NativeSessionStore.validateEditorState(["text": String(repeating: "a", count: 8193)]))
    var nested: Any = "end"
    for _ in 0..<14 { nested = ["child": nested] }
    XCTAssertThrowsError(try NativeSessionStore.validateEditorState(nested))
  }

  func testImportedReadOnlyMP4ProcessesThroughNativeStore() async throws {
    let provider = folder.appendingPathComponent("synthetic-provider.mp4")
    try await syntheticMP4(provider)
    let providerHash = try WholeFileDigest.sha256(provider)
    let root = folder.appendingPathComponent("video-sessions", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let imported = try await store.importFile(provider)
    let source = root.appendingPathComponent(imported.id.uuidString).appendingPathComponent(imported.sourceName)
    let originalPermissions = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(originalPermissions?.intValue, 0o400)
    let patch = MetadataPatch(values: [
      "make": .string("Apple"), "model": .string("Synthetic camera"), "software": .string("17.5.1"),
      "lensModel": .string("Main Camera - 24 mm f/1.78"), "focalLength35mm": .number(24),
      "iso": .number(800), "exposureTime": .number(1.0 / 120), "fNumber": .number(1.78),
      "latitude": .number(-12.5), "longitude": .number(44.25), "altitude": .number(-10.2004),
      "dateTimeOriginal": .string("2026-04-05T06:07:08-04:00"),
      "movieCreateDate": .string("2026-04-05T06:07:08-04:00"), "movieModifyDate": .string("2026-04-05T06:07:08-04:00"),
      "trackCreateDate": .string("2026-04-05T06:07:08-04:00"), "trackModifyDate": .string("2026-04-05T06:07:08-04:00"),
      "mediaCreateDate": .string("2026-04-05T06:07:08-04:00"), "mediaModifyDate": .string("2026-04-05T06:07:08-04:00")
    ])
    let changed: NativeSession
    do { changed = try await store.processMetadata(sessionID: imported.id, patch: patch) }
    catch {
      try await reportSyntheticVideoFailure(source: source, patch: patch, label: "profile")
      throw error
    }
    let output = try XCTUnwrap(changed.processing)
    XCTAssertEqual(output.outputInspection.kind, .mp4)
    XCTAssertEqual(output.outputInspection.metadata["model"], "Synthetic camera")
    try patch.validateReadback(output.outputInspection)
    XCTAssertFalse(output.integrity.checks.contains { $0.status == .failed })
    XCTAssertTrue(output.integrity.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
    let exported = try await store.exportCopyURL(sessionID: imported.id, processingID: output.id, acknowledgeIncomplete: true)
    let removal = MetadataPatch(values: ["model": .string("Replacement camera")], removals: ["iso", "exposureTime", "fNumber", "lensModel", "latitude", "longitude", "altitude", "software", "trackCreateDate"])
    let cleared: NativeSession
    do { cleared = try await store.processMetadata(sessionID: imported.id, patch: removal) }
    catch {
      // Also exercise actual removal from the first edited file independently.
      try await reportSyntheticVideoFailure(source: exported, patch: removal, label: "removal")
      throw error
    }
    let clearedOutput = try XCTUnwrap(cleared.processing)
    try removal.validateReadback(clearedOutput.outputInspection)
    XCTAssertFalse(clearedOutput.integrity.checks.contains { $0.status == .failed })
    let editedImport = try await store.importFile(exported)
    let removedEdited: NativeSession
    do { removedEdited = try await store.processMetadata(sessionID: editedImport.id, patch: removal) }
    catch {
      try await reportSyntheticVideoFailure(source: exported, patch: removal, label: "edited-removal")
      throw error
    }
    let removedOutput = try XCTUnwrap(removedEdited.processing)
    try removal.validateReadback(removedOutput.outputInspection)
    XCTAssertTrue(removedOutput.integrity.checks.contains { $0.name.contains("compressed data") && $0.status == .passed })
    XCTAssertEqual(try WholeFileDigest.sha256(source), imported.sourceSHA256)
    XCTAssertEqual(try WholeFileDigest.sha256(provider), providerHash)
    let sourcePermissions = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(sourcePermissions?.intValue, 0o400)
  }

  private func reportSyntheticVideoFailure(source: URL, patch: MetadataPatch, label: String) async throws {
    let diagnostic = folder.appendingPathComponent("synthetic-\(label)-diagnostic.mp4")
    do {
      _ = try await VideoMetadataWriter.write(source: source, output: diagnostic, patch: patch)
      let before = try await MetadataEngine.inspect(source), after = try await MetadataEngine.inspect(diagnostic)
      for key in Set(before.metadata.keys).union(after.metadata.keys).sorted() where before.metadata[key] != after.metadata[key] {
        print("Synthetic iOS \(label) metadata \(key): \(before.metadata[key] ?? "<absent>") -> \(after.metadata[key] ?? "<absent>")")
      }
      let comparison = try await MediaIntegrity.compareMetadata(source: source, output: diagnostic, patch: patch)
      print("Synthetic iOS \(label) failed checks: \(comparison.checks.filter { $0.status == .failed })")
    } catch { print("Synthetic iOS \(label) diagnostic failed: \(error)") }
  }

  func testPNGScreenshotImportFullProfileReservedFilenameExportAndRecovery() async throws {
    let provider = folder.appendingPathComponent("Screenshot.PNG")
    let original = png()
    try original.write(to: provider)
    let root = folder.appendingPathComponent("screenshot-sessions", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let imported = try await store.importFile(provider)
    XCTAssertEqual(imported.inspection.kind, .png)
    XCTAssertNil(imported.inspection.metadata["model"])
    let names = try await store.reserveOutputNames(sessionIDs: [imported.id])
    let expectedName = try XCTUnwrap(names[imported.id.uuidString])
    XCTAssertNotNil(expectedName.range(of: "^IMG_[0-9]{4}\\.PNG$", options: .regularExpression))
    let patch = MetadataPatch(values: ["make": .string("Apple"), "model": .string("iPhone 15 Pro"),
      "iso": .number(400), "exposureTime": .number(1.0 / 120), "fNumber": .number(1.78),
      "software": .string("17.5.1"), "lensModel": .string("Main Camera"),
      "dateTimeOriginal": .string("2026:04:05 06:07:08"), "createDate": .string("2026:04:05 06:07:08"),
      "modifyDate": .string("2026:04:05 06:07:08"), "offsetTimeOriginal": .string("-04:00")])
    let changed = try await store.processMetadata(sessionID: imported.id, patch: patch)
    let output = try XCTUnwrap(changed.processing)
    XCTAssertEqual(output.outputDisplayName, expectedName)
    XCTAssertEqual(output.outputInspection.kind, .png)
    try patch.validateReadback(output.outputInspection)
    XCTAssertFalse(output.integrity.checks.contains { $0.status == .failed })
    XCTAssertTrue(output.integrity.checks.contains { $0.name == "PNG compressed pixels and non-target chunks" && $0.status == .passed })
    do {
      _ = try await store.exportCopyURL(sessionID: imported.id, processingID: output.id, acknowledgeIncomplete: false)
      XCTFail("Opaque PNG EXIF qualification must still require acknowledgment")
    } catch NativeMediaError.unsupported { }
    let exported = try await store.exportCopyURL(sessionID: imported.id, processingID: output.id, acknowledgeIncomplete: true)
    XCTAssertEqual(exported.lastPathComponent, expectedName)
    XCTAssertEqual(try WholeFileDigest.sha256(exported), output.outputSHA256)
    let recovered = NativeSessionStore(authorize: {}, root: root)
    let recoveredExport = try await recovered.exportCopyURL(sessionID: imported.id, processingID: output.id, acknowledgeIncomplete: true)
    XCTAssertEqual(try WholeFileDigest.sha256(recoveredExport), output.outputSHA256)
    XCTAssertEqual(try Data(contentsOf: provider), original)
  }

  private func syntheticMP4(_ url: URL, fileType: AVFileType = .mp4) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    var finished = false
    defer { if !finished { writer.cancelWriting() } }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 32, AVVideoHeightKey: 32])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
    guard writer.canAdd(input) else { throw ProbeError.writeFailed("Synthetic MP4 input unavailable") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? ProbeError.writeFailed("Synthetic MP4 writer failed") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<3 {
      let deadline = Date().addingTimeInterval(10)
      while !input.isReadyForMoreMediaData {
        guard Date() < deadline, writer.status == .writing else { throw ProbeError.writeFailed("Synthetic MP4 writer stalled") }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      var pixelBuffer: CVPixelBuffer?
      guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
        let pixelBuffer else { throw ProbeError.writeFailed("Synthetic MP4 buffer unavailable") }
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(base, Int32(frame * 50), CVPixelBufferGetBytesPerRow(pixelBuffer) * 32)
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
        throw writer.error ?? ProbeError.writeFailed("Synthetic MP4 append failed")
      }
    }
    input.markAsFinished(); await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? ProbeError.writeFailed("Synthetic MP4 unfinished") }
    finished = true
  }

  func testEditorStateAndPresetExportPersistWithoutChangingSource() async throws {
    let root = folder.appendingPathComponent("state", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let state: [String: Any] = ["schemaVersion": 1, "presets": [], "queue": [["id": UUID().uuidString, "status": "pending"]]]
    try await store.saveEditorState(state)
    let restored = try await NativeSessionStore(authorize: {}, root: root).loadEditorState()
    XCTAssertEqual(restored["schemaVersion"] as? Int, 1)
    XCTAssertEqual((restored["queue"] as? [[String: Any]])?.count, 1)
    let preset: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString, "name": "My preset", "patch": ["values": ["iso": 320], "removals": []]]
    let exported = try await store.presetExportURL(preset)
    XCTAssertEqual(exported.lastPathComponent, "Metadata-Preset.json")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any])
    XCTAssertNoThrow(try NativeSessionStore.validatePreset(object))
    let originalPresetBytes = try Data(contentsOf: exported)
    var oversized = preset
    oversized["extra"] = Array(repeating: String(repeating: "x", count: 8192), count: 4)
    XCTAssertNoThrow(try NativeSessionStore.validatePreset(oversized), "Individual JSON fields stay within their bounds")
    do {
      _ = try await store.presetExportURL(oversized)
      XCTFail("Exported a preset that exceeds the import file size limit")
    } catch NativeMediaError.invalidArgument { }
    XCTAssertEqual(try Data(contentsOf: exported), originalPresetBytes, "Oversized export must retain the previous valid preset")
    try await store.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
    let afterClear = try await store.loadEditorState()
    XCTAssertEqual(afterClear["schemaVersion"] as? Int, 1, "Cleaning media should preserve saved settings")
  }

  func testFullMetadataProcessingFilenameRecoveryAndCloudOriginalVerification() async throws {
    let provider = folder.appendingPathComponent("full-source.jpg")
    try jpeg().write(to: provider)
    let sourceHash = try WholeFileDigest.sha256(provider)
    let root = folder.appendingPathComponent("full-pipeline", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let source = try await store.importFile(provider)
    let patch = MetadataPatch(values: ["make": .string("Apple"), "model": .string("iPhone 15 Pro Max"),
      "lensModel": .string("Main camera"), "iso": .number(400), "exposureTime": .number(1.0 / 120),
      "fNumber": .number(1.78), "focalLength": .number(6.765), "focalLength35mm": .number(24),
      "latitude": .number(10), "longitude": .number(20)], removals: [])
    let changed = try await store.processMetadata(sessionID: source.id, patch: patch)
    let output = try XCTUnwrap(changed.processing)
    XCTAssertNil(output.patch)
    XCTAssertNotNil(output.metadataPatch)
    let name = try XCTUnwrap(output.outputDisplayName)
    XCTAssertNotNil(name.range(of: "^IMG_[0-9]{4}\\.JPG$", options: .regularExpression))
    let exported = try await store.exportCopyURL(sessionID: source.id, processingID: output.id, acknowledgeIncomplete: true)
    XCTAssertEqual(exported.lastPathComponent, name)
    XCTAssertEqual(try WholeFileDigest.sha256(exported), output.outputSHA256)
    let verification = try await store.verifyOriginal(sessionID: source.id, processingID: output.id, providerURL: exported)
    XCTAssertEqual(verification["exactMatch"] as? Bool, true)
    let different = try await store.verifyOriginal(sessionID: source.id, processingID: output.id, providerURL: provider)
    XCTAssertEqual(different["exactMatch"] as? Bool, false)
    let recovered = NativeSessionStore(authorize: {}, root: root)
    let recoveredExport = try await recovered.exportCopyURL(sessionID: source.id, processingID: output.id, acknowledgeIncomplete: true)
    XCTAssertEqual(recoveredExport.lastPathComponent, name)
    XCTAssertEqual(try WholeFileDigest.sha256(provider), sourceHash)
    try await recovered.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
    XCTAssertEqual(try WholeFileDigest.sha256(provider), sourceHash)
  }

  func testFilenameValidationRejectsTraversalAndInvalidExtensions() throws {
    for name in ["../IMG_1234.JPG", "IMG_1234.EXE", "IMG_123.JPG", "IMG_1234.JPG/other", "output-uuid.jpg"] {
      XCTAssertThrowsError(try NativeSessionStore.validateOutputDisplayName(name))
    }
    XCTAssertNoThrow(try NativeSessionStore.validateOutputDisplayName("IMG_4827.HEIC"))
    XCTAssertEqual(NativeSessionStore.outputExtension(kind: .jpeg, original: "PNG"), "jpg")
    XCTAssertEqual(NativeSessionStore.outputExtension(kind: .jpeg, original: "JPEG"), "jpeg")
    XCTAssertEqual(NativeSessionStore.outputExtension(kind: .png, original: "jpg"), "png")
    XCTAssertEqual(NativeSessionStore.outputExtension(kind: .mov, original: "mp4"), "mov")
  }

  func testReplacingExportedOutputsRemovesRetiredConsumerLinks() async throws {
    let provider = folder.appendingPathComponent("history-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("history-links", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root)
    let imported = try await store.importFile(provider)
    var firstExport: URL?
    for index in 0..<12 {
      let changed = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Maker \(index)", model: "Model \(index)"))
      let output = try XCTUnwrap(changed.processing)
      let url = try await store.exportCopyURL(sessionID: imported.id, processingID: output.id, acknowledgeIncomplete: true)
      if firstExport == nil { firstExport = url }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstExport!.path), "Trimmed history retained a consumer hard link")
    let exports = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Exports").path)
    XCTAssertEqual(exports.count, 11, "Current output plus ten history outputs must bound consumer links")
    let current = try await store.list()
    XCTAssertEqual(current.first?.history.count, 10)
  }

  func testAutomaticProcessedMediaFolderCreationAndCollisionAvoidance() async throws {
    let provider = folder.appendingPathComponent("auto-folder-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("auto-folder-sessions", isDirectory: true)
    let autoFolder = folder.appendingPathComponent("Processed Media", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root, autoExportRoot: autoFolder, processOperation: Self.verifiedCopy)
    let imported = try await store.importFile(provider)
    let patch = CameraPatch(make: "Auto maker", model: "Auto model")
    let changed = try await store.process(sessionID: imported.id, patch: patch)
    let output = try XCTUnwrap(changed.processing)
    let displayName = try XCTUnwrap(output.outputDisplayName)

    let autoFile = autoFolder.appendingPathComponent(displayName)

    XCTAssertTrue(FileManager.default.fileExists(atPath: autoFile.path), "Output was not saved to Processed Media folder")
    XCTAssertEqual(try WholeFileDigest.sha256(autoFile), output.outputSHA256)
    XCTAssertNotNil(output.autoExportFolder)
    // Files users may edit their exported copy. This must never change the
    // private frozen output, as an automatic public hard link would do.
    let privateOutput = try await store.exportURL(sessionID: imported.id, processingID: output.id, acknowledgeIncomplete: false)
    try Data("Changed public copy".utf8).write(to: autoFile)
    XCTAssertEqual(try WholeFileDigest.sha256(privateOutput), output.outputSHA256)

    // Process again with different patch to verify collision-safe distinct naming
    let patch2 = CameraPatch(make: "Auto maker 2", model: "Auto model 2")
    let changed2 = try await store.process(sessionID: imported.id, patch: patch2)
    let output2 = try XCTUnwrap(changed2.processing)
    let displayName2 = try XCTUnwrap(output2.outputDisplayName)

    XCTAssertNotEqual(displayName, displayName2)
    let autoFile2 = autoFolder.appendingPathComponent(displayName2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: autoFile2.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: autoFile.path), "Previous processed file in Processed Media was overwritten")

    // Clear session store - persistent Processed Media files must remain untouched
    try await store.clear()
    XCTAssertTrue(FileManager.default.fileExists(atPath: autoFile.path), "User media in Processed Media must not be deleted on session clear")
    XCTAssertTrue(FileManager.default.fileExists(atPath: autoFile2.path), "User media in Processed Media must not be deleted on session clear")
  }

  func testNativeBatchItemsValidation() throws {
    XCTAssertThrowsError(try NativeMediaBridge.parseBatchItems(["items": []]))
    let overLimit = (0..<101).map { _ in ["sessionId": UUID().uuidString, "processingId": UUID().uuidString, "acknowledgeIncomplete": NSNumber(value: true)] }
    XCTAssertThrowsError(try NativeMediaBridge.parseBatchItems(["items": overLimit]))
    let id1 = UUID().uuidString, out1 = UUID().uuidString
    let duplicateSessions = [
      ["sessionId": id1, "processingId": out1, "acknowledgeIncomplete": NSNumber(value: true)],
      ["sessionId": id1, "processingId": UUID().uuidString, "acknowledgeIncomplete": NSNumber(value: false)]
    ]
    XCTAssertThrowsError(try NativeMediaBridge.parseBatchItems(["items": duplicateSessions]))
    let nonBoolean = [["sessionId": id1, "processingId": out1, "acknowledgeIncomplete": 123]]
    XCTAssertThrowsError(try NativeMediaBridge.parseBatchItems(["items": nonBoolean]))

    let valid = [
      ["sessionId": id1, "processingId": out1, "acknowledgeIncomplete": NSNumber(value: true)],
      ["sessionId": UUID().uuidString, "processingId": UUID().uuidString, "acknowledgeIncomplete": NSNumber(value: false)]
    ]
    let parsed = try NativeMediaBridge.parseBatchItems(["items": valid])
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed[0].id.uuidString.lowercased(), id1.lowercased())
    XCTAssertEqual(parsed[0].acknowledged, true)
    XCTAssertEqual(parsed[1].acknowledged, false)
  }

  func testBatchProcessingAcrossMultipleFilesAndFormats() async throws {
    let root = folder.appendingPathComponent("batch-multi-format-sessions", isDirectory: true)
    let autoFolder = folder.appendingPathComponent("batch-processed-media", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: root, autoExportRoot: autoFolder)
    let f1 = folder.appendingPathComponent("batch-photo1.jpg")
    let f2 = folder.appendingPathComponent("batch-photo2.jpg")
    let f3 = folder.appendingPathComponent("batch-graphic.png")
    try jpeg().write(to: f1)
    try jpeg().write(to: f2)
    try png().write(to: f3)

    let s1 = try await store.importFile(f1)
    let s2 = try await store.importFile(f2)
    let s3 = try await store.importFile(f3)

    XCTAssertEqual(s1.inspection.kind, .jpeg)
    XCTAssertEqual(s2.inspection.kind, .jpeg)
    XCTAssertEqual(s3.inspection.kind, .png)


    let p1 = try await store.process(sessionID: s1.id, patch: CameraPatch(make: "Batch Make 1", model: "Batch Model 1"))
    let out1 = try XCTUnwrap(p1.processing)
    let name1 = try XCTUnwrap(out1.outputDisplayName)
    let auto1 = autoFolder.appendingPathComponent(name1)

    let p2 = try await store.process(sessionID: s2.id, patch: CameraPatch(make: "Batch Make 2", model: "Batch Model 2"))
    let out2 = try XCTUnwrap(p2.processing)
    let name2 = try XCTUnwrap(out2.outputDisplayName)
    let auto2 = autoFolder.appendingPathComponent(name2)

    let p3 = try await store.process(sessionID: s3.id, patch: CameraPatch(make: "Batch Make 3", model: "Batch Model 3"))
    let out3 = try XCTUnwrap(p3.processing)
    let name3 = try XCTUnwrap(out3.outputDisplayName)
    let auto3 = autoFolder.appendingPathComponent(name3)

    XCTAssertNotEqual(name1, name2)
    XCTAssertNotEqual(name1, name3)
    XCTAssertNotEqual(name2, name3)

    for (url, output) in [(auto1, out1), (auto2, out2), (auto3, out3)] {
      let qualified = NativeSessionStore.isFullyVerified(output.integrity)
      XCTAssertEqual(FileManager.default.fileExists(atPath: url.path), qualified)
      XCTAssertEqual(output.autoExportFolder != nil, qualified)
      if qualified { XCTAssertEqual(try WholeFileDigest.sha256(url), output.outputSHA256) }
    }
  }

  func testIncompleteProcessingCannotAutomaticallyPublishOrClaimFilesSaving() async throws {
    let provider = folder.appendingPathComponent("incomplete-source.jpg")
    try jpeg().write(to: provider)
    let autoFolder = folder.appendingPathComponent("incomplete-public", isDirectory: true)
    let store = NativeSessionStore(authorize: {}, root: folder.appendingPathComponent("incomplete-sessions"), autoExportRoot: autoFolder,
      processOperation: { source, output, patch in
        let result = try await Self.verifiedCopy(source, output, patch)
        return ProcessingResult(outputURL: output, sourceInspection: result.sourceInspection, outputInspection: result.outputInspection,
          integrity: IntegrityComparison(status: .incomplete,
            checks: [IntegrityCheck(name: "synthetic unfinished check", status: .notChecked, detail: "Boundary fixture")],
            limitations: ["Synthetic incomplete verifier"]))
      })
    let imported = try await store.importFile(provider)
    let changed = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Synthetic", model: "Synthetic"))
    let processing = try XCTUnwrap(changed.processing)
    XCTAssertNil(processing.autoExportFolder)
    let map = try changed.bridgeMap()
    XCTAssertNil((map["processing"] as? [String: Any])?["autoExportFolder"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: autoFolder.path))
    do {
      _ = try await store.exportCopyURL(sessionID: imported.id, processingID: processing.id, acknowledgeIncomplete: false)
      XCTFail("Unacknowledged incomplete output was exported")
    } catch NativeMediaError.unsupported { }
    _ = try await store.exportCopyURL(sessionID: imported.id, processingID: processing.id, acknowledgeIncomplete: true)
  }

  func testMetadataWarningExportsButDoesNotAutomaticallyPublishAndRecoversByRechecking() async throws {
    let provider = folder.appendingPathComponent("warning-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("warning-sessions")
    let autoFolder = folder.appendingPathComponent("warning-files")
    let store = NativeSessionStore(authorize: {}, root: root, autoExportRoot: autoFolder, metadataProcessOperation: { source, output, patch in
      let result = try await MetadataEngine.processMetadataPatch(source: source, output: output, patch: patch)
      let warning = IntegrityComparison(status: .warning,
        checks: result.integrity.checks.map { check in
          check.name == "retained embedded metadata" ? IntegrityCheck(name: check.name, status: .warning, detail: "Other details changed") : check
        }, limitations: [])
      return ProcessingResult(outputURL: output, sourceInspection: result.sourceInspection, outputInspection: result.outputInspection, integrity: warning)
    })
    let imported = try await store.importFile(provider)
    let changed = try await store.processMetadata(sessionID: imported.id, patch: MetadataPatch(values: ["make": .string("Apple"), "model": .string("Test phone")]))
    let output = try XCTUnwrap(changed.processing)
    XCTAssertEqual(output.integrity.status, .warning)
    XCTAssertNil(output.autoExportFolder)
    XCTAssertFalse(FileManager.default.fileExists(atPath: autoFolder.path))
    _ = try await store.exportURL(sessionID: changed.id, processingID: output.id, acknowledgeIncomplete: false)
    let recovered = NativeSessionStore(authorize: {}, root: root, autoExportRoot: autoFolder)
    // Reinspection replaces the injected receipt with actual JPEG evidence.
    // Genuine limitations still require acknowledgment; the warning cannot
    // carry an implicit acknowledgment into a recovered project.
    let recoveredURL = try await recovered.exportURL(sessionID: changed.id, processingID: output.id, acknowledgeIncomplete: true)
    let sessions = try await recovered.list()
    let report = try XCTUnwrap(sessions.first?.processing?.integrity)
    let expectedPatch = try XCTUnwrap(output.metadataPatch)
    let expected = try await MediaIntegrity.compareMetadata(source: provider, output: recoveredURL,
      patch: expectedPatch, integrityPolicy: .allowAdditionalMetadataChanges)
    XCTAssertEqual(report.status, expected.status)
    XCTAssertEqual(report.checks.map { $0.name + ":" + $0.status.rawValue }.sorted(),
      expected.checks.map { $0.name + ":" + $0.status.rawValue }.sorted())
    XCTAssertEqual(report.limitations.sorted(), expected.limitations.sorted())
    XCTAssertTrue(NativeSessionStore.isConsistentReport(report, allowMetadataWarnings: true))
    XCTAssertFalse(report.checks.contains { $0.status == .failed })
    let needsAcknowledgment = report.status == .incomplete || !report.limitations.isEmpty || report.checks.contains { $0.status == .notChecked }
    if needsAcknowledgment {
      do {
        _ = try await recovered.exportURL(sessionID: changed.id, processingID: output.id, acknowledgeIncomplete: false)
        XCTFail("Recomputed incomplete checks were exported without acknowledgment")
      } catch NativeMediaError.unsupported { }
    } else {
      _ = try await recovered.exportURL(sessionID: changed.id, processingID: output.id, acknowledgeIncomplete: false)
    }
  }

  func testRealMovieMetadataWarningRemainsExportableAfterRecovery() async throws {
    let provider = folder.appendingPathComponent("additional-date-source.mov")
    try await syntheticMP4(provider, fileType: .mov)
    let original = try WholeFileDigest.sha256(provider)
    let root = folder.appendingPathComponent("movie-warning-sessions")
    let store = NativeSessionStore(authorize: {}, root: root, metadataProcessOperation: { source, output, expected in
      let actual = MetadataPatch(values: ["movieCreateDate": .string("2026-04-05T06:07:08Z"), "trackModifyDate": .string("2001-01-01T00:00:00Z")])
      _ = try await VideoMetadataWriter.write(source: source, output: output, patch: actual)
      let sourceInspection = try await MetadataEngine.inspect(source)
      let outputInspection = try await MetadataEngine.inspect(output)
      try expected.validateReadback(outputInspection)
      let report = try await MediaIntegrity.compareMetadata(source: source, output: output, patch: expected, integrityPolicy: .allowAdditionalMetadataChanges)
      return ProcessingResult(outputURL: output, sourceInspection: sourceInspection, outputInspection: outputInspection, integrity: report)
    })
    let imported = try await store.importFile(provider)
    let changed = try await store.processMetadata(sessionID: imported.id, patch: MetadataPatch(values: ["movieCreateDate": .string("2026-04-05T06:07:08Z")]))
    let output = try XCTUnwrap(changed.processing)
    XCTAssertNotEqual(output.integrity.status, .mismatch)
    XCTAssertNotEqual(output.integrity.status, .verified)
    XCTAssertEqual(output.integrity.checks.first { $0.name == "retained embedded metadata" }?.status, .warning)
    _ = try await store.exportURL(sessionID: changed.id, processingID: output.id, acknowledgeIncomplete: output.integrity.status == .incomplete)
    let recovered = NativeSessionStore(authorize: {}, root: root)
    _ = try await recovered.exportURL(sessionID: changed.id, processingID: output.id, acknowledgeIncomplete: output.integrity.status == .incomplete)
    let sessions = try await recovered.list()
    let recomputed = try XCTUnwrap(sessions.first?.processing?.integrity)
    XCTAssertEqual(recomputed.checks.first { $0.name == "retained embedded metadata" }?.status, .warning)
    XCTAssertNotEqual(recomputed.status, .verified)
    XCTAssertFalse(recomputed.checks.contains { $0.status == .failed })
    XCTAssertEqual(try WholeFileDigest.sha256(provider), original)
  }

  func testMixedMetadataWarningAndFailedMediaReceiptCannotBecomeAnOutput() async throws {
    let provider = folder.appendingPathComponent("mixed-failure-source.jpg")
    try jpeg().write(to: provider)
    let store = NativeSessionStore(authorize: {}, root: folder.appendingPathComponent("mixed-failure-sessions"), metadataProcessOperation: { source, output, patch in
      let result = try await MetadataEngine.processMetadataPatch(source: source, output: output, patch: patch)
      let report = IntegrityComparison(status: .warning, checks: [
        IntegrityCheck(name: "retained embedded metadata", status: .warning, detail: "Other details changed"),
        IntegrityCheck(name: "encoded tracks", status: .failed, detail: "Media differs")], limitations: [])
      return ProcessingResult(outputURL: output, sourceInspection: result.sourceInspection, outputInspection: result.outputInspection, integrity: report)
    })
    let imported = try await store.importFile(provider)
    do {
      _ = try await store.processMetadata(sessionID: imported.id, patch: MetadataPatch(values: ["make": .string("Apple")]))
      XCTFail("Mixed failed media receipt was accepted")
    } catch ProbeError.integrityMismatch { }
    let sessions = try await store.list()
    XCTAssertNil(sessions.first?.processing)
  }

  func testAdditionalDetailsWarningReportIsAcceptedOnlyForFullEditorMetadata() {
    let warning = IntegrityCheck(name: "retained embedded metadata", status: .warning, detail: "Other details changed")
    let passed = IntegrityCheck(name: "encoded tracks", status: .passed, detail: "Matched")
    let report = IntegrityComparison(status: .warning, checks: [passed, warning], limitations: [])
    XCTAssertTrue(NativeSessionStore.isConsistentReport(report, allowMetadataWarnings: true))
    XCTAssertFalse(NativeSessionStore.isConsistentReport(report, allowMetadataWarnings: false))
    XCTAssertFalse(NativeSessionStore.isFullyVerified(report))
    let forged = IntegrityComparison(status: .warning, checks: [IntegrityCheck(name: "encoded tracks", status: .warning, detail: "Mismatch")], limitations: [])
    XCTAssertFalse(NativeSessionStore.isConsistentReport(forged, allowMetadataWarnings: true))
    let incomplete = IntegrityComparison(status: .incomplete, checks: [warning, IntegrityCheck(name: "opaque", status: .notChecked, detail: "Unknown")], limitations: ["Limited"])
    XCTAssertTrue(NativeSessionStore.isConsistentReport(incomplete, allowMetadataWarnings: true))
    XCTAssertFalse(NativeSessionStore.isConsistentReport(IntegrityComparison(status: .warning, checks: incomplete.checks, limitations: incomplete.limitations), allowMetadataWarnings: true))
  }

  func testFailedOrInconsistentProcessingReportsCannotBecomeActiveOutputs() async throws {
    let failed = IntegrityCheck(name: "synthetic preservation mismatch", status: .failed, detail: "Fixture")
    let unchecked = IntegrityCheck(name: "synthetic omitted check", status: .notChecked, detail: "Fixture")
    let reports = [
      IntegrityComparison(status: .verified, checks: [failed], limitations: []),
      IntegrityComparison(status: .incomplete, checks: [failed], limitations: []),
      IntegrityComparison(status: .verified, checks: [unchecked], limitations: []),
      IntegrityComparison(status: .verified, checks: [], limitations: [])
    ]
    let provider = folder.appendingPathComponent("inconsistent-source.jpg")
    try jpeg().write(to: provider)
    for (index, report) in reports.enumerated() {
      let autoFolder = folder.appendingPathComponent("inconsistent-public-\(index)")
      let store = NativeSessionStore(authorize: {}, root: folder.appendingPathComponent("inconsistent-session-\(index)"), autoExportRoot: autoFolder,
        processOperation: { source, output, patch in
          let result = try await Self.verifiedCopy(source, output, patch)
          return ProcessingResult(outputURL: output, sourceInspection: result.sourceInspection,
            outputInspection: result.outputInspection, integrity: report)
        })
      let imported = try await store.importFile(provider)
      do {
        _ = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Synthetic", model: "Synthetic"))
        XCTFail("Failed or inconsistent report became a frozen output")
      } catch ProbeError.integrityMismatch { }
      let sessions = try await store.list()
      XCTAssertNil(sessions.first?.processing)
      XCTAssertFalse(FileManager.default.fileExists(atPath: autoFolder.path))
    }
  }

  func testFailedAutomaticSavingKeepsPrivateOutputAndDoesNotClaimSuccess() async throws {
    let provider = folder.appendingPathComponent("unavailable-auto-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("auto-failure-sessions")
    let outside = folder.appendingPathComponent("outside-auto", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let linkedFolder = folder.appendingPathComponent("linked-auto", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
    let store = NativeSessionStore(authorize: {}, root: root, autoExportRoot: linkedFolder, processOperation: Self.verifiedCopy)
    let imported = try await store.importFile(provider)
    let changed = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Synthetic", model: "Synthetic"))
    let output = try XCTUnwrap(changed.processing)
    XCTAssertNil(output.autoExportFolder)
    XCTAssertTrue(changed.notes.contains { $0.contains("Automatic Files saving could not finish") })
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    _ = try await store.exportURL(sessionID: imported.id, processingID: output.id, acknowledgeIncomplete: false)
  }

  func testFailedJournalCommitCannotPublishAProcessedCopy() async throws {
    let provider = folder.appendingPathComponent("commit-failure-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("commit-failure-sessions")
    let autoFolder = folder.appendingPathComponent("commit-failure-public")
    let outsideJournal = folder.appendingPathComponent("outside-journal.json")
    let sentinel = Data("Untouched external journal".utf8)
    try sentinel.write(to: outsideJournal)
    let store = NativeSessionStore(authorize: {}, root: root, autoExportRoot: autoFolder,
      processOperation: { source, output, patch in
        let result = try await Self.verifiedCopy(source, output, patch)
        let manifest = root.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outsideJournal)
        return result
      })
    let imported = try await store.importFile(provider)
    do {
      _ = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Synthetic", model: "Synthetic"))
      XCTFail("An unsafe journal destination accepted a processing commit")
    } catch NativeMediaError.storage { }
    XCTAssertFalse(FileManager.default.fileExists(atPath: autoFolder.path))
    XCTAssertEqual(try Data(contentsOf: outsideJournal), sentinel)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(imported.id.uuidString).path)
    XCTAssertEqual(files, [imported.sourceName], "Failed output staging was retained")
  }

  func testErrorTaxonomyDoesNotExposePrivateErrorContent() throws {
    let privateDetail = "file:///private/media/Private Clip.mp4 GPS=10.123,20.456"
    let failures: [(Error, String)] = [
      (ProbeError.unsupported(privateDetail), "unsupported"),
      (ProbeError.malformed(privateDetail), "malformed"),
      (ProbeError.writeFailed(privateDetail), "processing"),
      (ProbeError.readbackFailed(privateDetail), "readback"),
      (ProbeError.integrityMismatch(privateDetail), "integrity"),
      (NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [NSLocalizedDescriptionKey: privateDetail]), "storage"),
      (NSError(domain: privateDetail, code: -1, userInfo: [NSLocalizedDescriptionKey: privateDetail]), "processing")
    ]
    for (failure, code) in failures {
      let mapped = NativeMediaBridge.flutterError(failure)
      XCTAssertEqual(mapped.code, code)
      XCTAssertFalse((mapped.message ?? "").contains(privateDetail))
      let details = try XCTUnwrap(mapped.details as? [String: Any])
      XCTAssertEqual(details["stage"] as? String, code)
      XCTAssertFalse(String(describing: details).contains(privateDetail))
    }
    do {
      _ = try NativeMediaBridge.metadataPatch(["patch": ["values": ["make": 123], "removals": []]])
      XCTFail("Malformed field payload was accepted")
    } catch NativeMediaError.invalidArgument { }
  }

  func testIntegrityDiagnosticsUseOnlyClosedSafeCheckIdentifiers() throws {
    let names = "retained embedded metadata, track 1 compressed data / timing / format, AVFoundation target iso, ImageIO target software, retained embedded metadata"
    let mapped = NativeMediaBridge.flutterError(ProbeError.integrityMismatch(names))
    let details = try XCTUnwrap(mapped.details as? [String: Any])
    XCTAssertEqual(details["stage"] as? String, "integrity")
    XCTAssertEqual(details["failedChecks"] as? [String], ["retained_metadata", "video_samples_track_1", "video_target_iso", "image_target_software"])
    XCTAssertEqual(NativeMediaBridge.safeIntegrityCheckIDs("Processing report status mismatch"), ["report_status"])
    XCTAssertEqual(NativeMediaBridge.safeIntegrityCheckIDs("Processing returned an inconsistent integrity report"), ["report_consistency"])
  }

  func testRetainedDifferenceDiagnosticsKeepBaseGateAndClosedIdentifiers() throws {
    let names = "retained embedded metadata, retained metadata field iso, retained metadata numeric key, retained metadata unnamed key, retained metadata unrecognized key, retained metadata location tuple"
    let mapped = NativeMediaBridge.flutterError(ProbeError.integrityMismatch(names))
    let details = try XCTUnwrap(mapped.details as? [String: Any])
    XCTAssertEqual(details["stage"] as? String, "integrity")
    XCTAssertEqual(details["failedChecks"] as? [String], ["retained_metadata", "retained_metadata_field_iso",
      "retained_metadata_numeric_key", "retained_metadata_unnamed_key", "retained_metadata_unrecognized_key", "retained_metadata_location_tuple"])
  }

  func testRetainedDifferenceDiagnosticsRejectPrivateInjectedFieldNames() {
    let names = "retained metadata field file:///private/clip.mov, retained metadata field latitude=12.123456, retained metadata numeric key: secret, retained metadata field iso"
    XCTAssertEqual(NativeMediaBridge.safeIntegrityCheckIDs(names), ["retained_metadata_field_iso"])
  }

  func testIntegrityDiagnosticsRejectPrivateUnknownOversizedAndPartialTokens() {
    for names in [
      "file:///private/media/Private Clip.mp4 GPS=10.123,20.456",
      "retained embedded metadata: Private Clip.mp4",
      "track 0 compressed data / timing / format",
      "track 65 compressed data / timing / format",
      "track 01 compressed data / timing / format",
      "AVFoundation target Private Clip.mp4",
      "AVFoundation target lensMake",
      "ImageIO target movieCreateDate",
      String(repeating: "private", count: 2_000),
      Array(repeating: "requested metadata", count: 129).joined(separator: ", ")
    ] {
      XCTAssertTrue(NativeMediaBridge.safeIntegrityCheckIDs(names).isEmpty)
    }
    let bounded = (1...64).map { "track \($0) compressed data / timing / format" }.joined(separator: ", ")
    XCTAssertEqual(NativeMediaBridge.safeIntegrityCheckIDs(bounded).count, 32)
    XCTAssertEqual(NativeMediaBridge.safeIntegrityCheckIDs("unknown private token, video exposed duration"), ["video_duration"])
  }

  func testSessionFailureRetainsSafeFailingCheckNamesWithoutPublishingOutput() async throws {
    let provider = folder.appendingPathComponent("synthetic-failing-report.jpg")
    try jpeg().write(to: provider)
    let store = NativeSessionStore(authorize: {}, root: folder.appendingPathComponent("synthetic-report-sessions"),
      processOperation: { source, output, patch in
        let result = try await Self.verifiedCopy(source, output, patch)
        return ProcessingResult(outputURL: output, sourceInspection: result.sourceInspection,
          outputInspection: result.outputInspection, integrity: IntegrityComparison(status: .incomplete,
            checks: [IntegrityCheck(name: "retained embedded metadata", status: .failed,
              detail: "Private filename and GPS must never cross the error channel")], limitations: []))
      })
    let imported = try await store.importFile(provider)
    do {
      _ = try await store.process(sessionID: imported.id, patch: CameraPatch(make: "Synthetic", model: "Synthetic"))
      XCTFail("A failed integrity report became an active output")
    } catch ProbeError.integrityMismatch(let names) {
      XCTAssertEqual(names, "retained embedded metadata")
      let details = NativeMediaBridge.flutterError(ProbeError.integrityMismatch(names)).details as? [String: Any]
      XCTAssertEqual(details?["failedChecks"] as? [String], ["retained_metadata"])
      XCTAssertFalse(String(describing: details).contains("Private filename"))
    }
    let sessions = try await store.list()
    XCTAssertNil(sessions.first?.processing)
    let files = try FileManager.default.contentsOfDirectory(atPath: folder
      .appendingPathComponent("synthetic-report-sessions").appendingPathComponent(imported.id.uuidString).path)
    XCTAssertEqual(files, [imported.sourceName])
  }

  func testPhotoStreamPreservesSafeNativeErrorCodeForDiagnostics() throws {
    let stream = try NativePhotoStream(target: folder.appendingPathComponent("photo-error.jpg"), maximumBytes: 8)
    let managerError = NSError(domain: "PHPhotosErrorDomain", code: 3302,
      userInfo: [NSLocalizedDescriptionKey: "Private Photos resource name"])
    let failure = try XCTUnwrap(stream.finish(managerError))
    let mapped = NativeMediaBridge.flutterError(failure)
    XCTAssertEqual(mapped.code, "storage")
    let details = try XCTUnwrap(mapped.details as? [String: Any])
    XCTAssertEqual(details["nativeDomain"] as? String, "PHPhotosErrorDomain")
    XCTAssertEqual(details["nativeCode"] as? Int, 3302)
    XCTAssertFalse((mapped.message ?? "").contains("Private Photos resource name"))
  }

  func testUnknownHostDeviceDoesNotInventCameraProfile() {
    let unknown = NativeMediaBridge.hostDevice(identifier: "iPhone99,99")
    XCTAssertNil(unknown["profileId"])
    XCTAssertEqual(unknown["model"], "iPhone")
    let known = NativeMediaBridge.hostDevice(identifier: "iPhone16,2")
    XCTAssertEqual(known["profileId"], "apple-iphone-15-pro-max")
  }

  // A controlled journal/publication boundary fixture. This does not assert
  // that arbitrary JPEG metadata edits qualify as fully verified media.
  nonisolated private static func verifiedCopy(_ source: URL, _ output: URL, _ patch: CameraPatch) async throws -> ProcessingResult {
    try FileManager.default.copyItem(at: source, to: output)
    let inspection = try await MetadataEngine.inspect(source)
    return ProcessingResult(outputURL: output, sourceInspection: inspection, outputInspection: inspection,
      integrity: IntegrityComparison(status: .verified,
        checks: [IntegrityCheck(name: "synthetic exact copy", status: .passed, detail: "Controlled fixture")], limitations: []))
  }

  private func persistedSession(root: URL, status: IntegrityStatus) throws -> NativeSession {
    let id = UUID(), processingID = UUID()
    let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceName = "source.jpg", outputName = "output-\(processingID.uuidString).jpg"
    let source = directory.appendingPathComponent(sourceName), output = directory.appendingPathComponent(outputName)
    let raw = jpeg()
    let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(raw as CFData, nil))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImageFromSource(destination, imageSource, 0, [kCGImagePropertyTIFFDictionary:
      [kCGImagePropertyTIFFMake: "Synthetic maker", kCGImagePropertyTIFFModel: "Synthetic model"]] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    try FileManager.default.copyItem(at: source, to: output)
    let bytes = try Data(contentsOf: source)
    let inspection = MediaInspection(kind: .jpeg, byteCount: Int64(bytes.count), metadata: ["make": "Synthetic maker", "model": "Synthetic model"], notes: [], structure: [:])
    let checkStatus: CheckStatus = status == .mismatch ? .failed : (status == .incomplete ? .notChecked : .passed)
    let processing = NativeProcessing(id: processingID, createdAt: Date(), patch: CameraPatch(make: "Synthetic maker", model: "Synthetic model"), outputName: outputName,
      outputInspection: inspection, integrity: IntegrityComparison(status: status,
        checks: [IntegrityCheck(name: "synthetic fixture gate", status: checkStatus, detail: "Controlled test")], limitations: []),
      outputSHA256: try WholeFileDigest.sha256(output))
    let session = NativeSession(id: id, displayName: "Synthetic.jpg", origin: "Synthetic", createdAt: Date(),
      sourceName: sourceName, sourceSHA256: try WholeFileDigest.sha256(source), inspection: inspection,
      details: [:], notes: [], processing: processing, history: [])
    struct Journal: Encodable { let schemaVersion = 1; let sessions: [NativeSession] }
    try JSONEncoder().encode(Journal(sessions: [session])).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    return session
  }
}
private actor LicenseTestAuthorization {
  private var remaining: Int
  init(allowedChecks: Int) { remaining = allowedChecks }
  func check() throws {
    guard remaining > 0 else { throw NativeMediaError.unsupported("License expired") }
    remaining -= 1
  }
}
