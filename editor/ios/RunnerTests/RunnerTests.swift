import Flutter
import UIKit
import XCTest
import ProbeCore
import ImageIO
import UniformTypeIdentifiers
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

  func testBridgeRejectsPathIdentifiersAndMalformedCameraFields() throws {
    XCTAssertThrowsError(try NativeMediaBridge.identifier(["sessionId": "../../outside"], "sessionId"))
    XCTAssertThrowsError(try NativeMediaBridge.patch(["patch": ["make": "", "model": "Camera"]]))
    XCTAssertThrowsError(try NativeMediaBridge.patch(["patch": ["make": "Maker", "model": "Camera", "lens": 12]]))
    let patch = try NativeMediaBridge.patch(["patch": ["make": "Maker", "model": "Camera", "lens": ""]])
    XCTAssertNil(patch.lens)
  }

  func testRealJPEGImportProcessRecoveryAndFrozenExportToken() async throws {
    let provider = folder.appendingPathComponent("provider.jpg")
    let data = jpeg()
    try data.write(to: provider)
    let providerDigest = try WholeFileDigest.sha256(provider)
    let root = folder.appendingPathComponent("sessions", isDirectory: true)
    let store = NativeSessionStore(root: root)
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
    let recoveredStore = NativeSessionStore(root: root)
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
      let store = NativeSessionStore(root: root)
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
      do { try await NativeSessionStore(root: root).clear(); XCTFail("Unsafe journal was accepted") }
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
      do { _ = try await NativeSessionStore(root: root).list(); XCTFail("Invalid journal recovered") }
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
      _ = try await NativeSessionStore(root: root).exportURL(sessionID: session.id, processingID: processing.id, acknowledgeIncomplete: true)
      XCTFail("Changed output was exported under a preserved quality claim")
    } catch NativeMediaError.processing { }
  }

  func testFailedProcessingClearsPriorActiveOutputAndRecoversHistory() async throws {
    let root = folder.appendingPathComponent("failed-operation", isDirectory: true)
    let session = try persistedSession(root: root, status: .verified)
    let store = NativeSessionStore(root: root, processOperation: { _, output, _ in
      try Data("partial staged bytes".utf8).write(to: output)
      throw NativeMediaError.processing
    })
    do {
      _ = try await store.process(sessionID: session.id, patch: CameraPatch(make: "Changed", model: "Changed"))
      XCTFail("A deliberately failed engine returned a processed session")
    } catch NativeMediaError.processing { }
    let recovered = try await NativeSessionStore(root: root).list()
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
    let store = NativeSessionStore(root: root, previewRoot: previews)
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
    let recovered = try await NativeSessionStore(root: root).list()
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
        _ = try await NativeSessionStore(root: root).exportURL(sessionID: session.id, processingID: session.processing!.id, acknowledgeIncomplete: true)
        XCTFail("A misleading verified summary bypassed native checks")
      } catch NativeMediaError.processing { }
    }
  }

  func testOversizedStagedOutputIsRemovedBeforeJournalCommit() async throws {
    let root = folder.appendingPathComponent("oversized-output", isDirectory: true)
    let session = try persistedSession(root: root, status: .verified)
    let inspection = session.inspection
    let limit: Int64 = 8192
    let store = NativeSessionStore(root: root, mediaSizeLimit: limit, processOperation: { _, output, _ in
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
    let recovered = try await NativeSessionStore(root: root).list()
    XCTAssertNil(recovered[0].processing)
    let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(session.id.uuidString).path)
    XCTAssertEqual(Set(files), Set([session.sourceName, session.processing!.outputName]))
  }

  func testRecoveredActualIncompleteReportIsPublishedBeforeAcknowledgmentRefusal() async throws {
    let provider = folder.appendingPathComponent("recovery-source.jpg")
    try jpeg().write(to: provider)
    let root = folder.appendingPathComponent("real-recovery", isDirectory: true)
    let store = NativeSessionStore(root: root)
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
    let recoveredStore = NativeSessionStore(root: root)
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
    let recovered = NativeSessionStore(root: root)
    _ = try await recovered.exportURL(sessionID: first.id, processingID: sharedID, acknowledgeIncomplete: true)
    do {
      _ = try await recovered.exportURL(sessionID: second.id, processingID: sharedID, acknowledgeIncomplete: true)
      XCTFail("A different session reused the first session's qualified output")
    } catch NativeMediaError.processing { }
  }

  private func jpeg() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8))
    return renderer.jpegData(withCompressionQuality: 0.95) { context in
      UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
    }
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
