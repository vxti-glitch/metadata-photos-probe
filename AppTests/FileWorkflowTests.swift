import XCTest
import UIKit
import ProbeCore
@testable import MetadataPhotosProbe

@MainActor
final class FileWorkflowTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func image(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension("jpg")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        try data.write(to: url); return url
    }

    private func model(photos: CountingFilePhotos, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) async throws -> ProbeViewModel {
        let value = ProbeViewModel(workspaceOverride: folder.appendingPathComponent("PhotosMetadataProbe"), photos: photos, persistWriter: writer)
        let url = try image("baseline")
        value.source = ImportedMediaAsset(fileURL: url, assetIdentifier: nil, representation: "Controlled Files fixture", resourceInventory: [], notes: [])
        value.sourceInspection = try await MetadataEngine.inspect(url)
        value.selectNoOp(); await idle(value)
        return value
    }

    private func idle(_ model: ProbeViewModel) async {
        for _ in 0..<500 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy)
    }

    func testFileTrialPersistedWithoutPhotoKitCommitAndExportCanCancel() async throws {
        let photos = CountingFilePhotos()
        let value = try await model(photos: photos)
        XCTAssertEqual(value.fileTrials.count, 1); XCTAssertTrue(value.attempts.isEmpty)
        let id = try XCTUnwrap(value.beginFilesExport())
        XCTAssertTrue(value.busy)
        value.finishFilesExport(id: UUID(), completed: true)
        XCTAssertTrue(value.busy, "Stale exporter callback cannot release this lease")
        value.finishFilesExport(id: id, completed: false)
        XCTAssertFalse(value.busy); XCTAssertNil(value.fileTrials[0].exportCompletedAt)
        let recovered = ProbeViewModel(workspaceOverride: value.workspace, photos: photos)
        XCTAssertEqual(recovered.fileTrials.count, 1)
        XCTAssertEqual(recovered.fileTrials[0].exportState, "Files export canceled or dismissed")
        let commits = await photos.commits
        XCTAssertEqual(commits, 0)
    }

    func testReturnedOriginalUsesFrozenReferenceAndDoesNotChangeCurrentSource() async throws {
        let returnedURL = try image("returned")
        let photos = CountingFilePhotos(returnedURL: returnedURL)
        let value = try await model(photos: photos)
        let baseline = try XCTUnwrap(value.source?.fileURL), output = try XCTUnwrap(value.outputURL)
        let trialID = try XCTUnwrap(value.selectedFileTrialID)
        let candidateURL = value.stagingDirectory.appendingPathComponent("picker.jpg")
        try FileManager.default.copyItem(at: returnedURL, to: candidateURL)
        let candidate = ImportedMediaAsset(fileURL: candidateURL, assetIdentifier: "returned", representation: "Picker current", resourceInventory: [], notes: [])
        let acquisition = try XCTUnwrap(value.beginPhotosAcquisition())
        value.receivedReturnedPhoto(.success(candidate), acquisitionID: acquisition, trialID: trialID)
        await idle(value)
        XCTAssertEqual(value.source?.fileURL, baseline); XCTAssertEqual(value.outputURL, output)
        XCTAssertEqual(value.fileTrials[0].returnedIntegrity?.status, .verified)
        XCTAssertEqual(value.fileTrials[0].returnedInspection?.location?.state, .notFound)
        XCTAssertEqual(value.fileTrials[0].returnedAsset?.librarySnapshot?.latitude, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
        let commits = await photos.commits; XCTAssertEqual(commits, 0)
    }

    func testRepeatedExportOfSameTrialIgnoresOldOperationCompletion() async throws {
        let value = try await model(photos: CountingFilePhotos())
        let first = try XCTUnwrap(value.beginFilesExport())
        value.finishFilesExport(id: first, completed: false)
        let second = try XCTUnwrap(value.beginFilesExport())
        XCTAssertNotEqual(first, second)
        value.finishFilesExport(id: first, completed: true)
        XCTAssertTrue(value.busy); XCTAssertNil(value.fileTrials[0].exportCompletedAt)
        value.finishFilesExport(id: second, completed: false)
        XCTAssertFalse(value.busy)
    }

    func testExportPersistenceFailureDoesNotLaunchExporterOrCommit() async throws {
        let photos = CountingFilePhotos()
        let value = try await model(photos: photos, writer: { _, _ in throw NSError(domain: "Storage full", code: 1) })
        XCTAssertNil(value.beginFilesExport()); XCTAssertFalse(value.busy); XCTAssertNotNil(value.errorMessage)
        let commits = await photos.commits; XCTAssertEqual(commits, 0)
    }

    func testManualExternalObservationDoesNotClaimAutomaticAttribution() async throws {
        let photos = CountingFilePhotos()
        let value = try await model(photos: photos)
        value.addFileObservation(); XCTAssertTrue(value.fileTrials[0].observations.isEmpty)
        value.attribution = .absent; value.addFileObservation()
        XCTAssertEqual(value.fileTrials[0].observations.first?.attribution, .absent)
        XCTAssertNil(value.fileTrials[0].returnedIntegrity)
        XCTAssertTrue(value.attempts.isEmpty)
        value.resetObservationForm(); XCTAssertEqual(value.attribution, .notChecked)
    }

    func testLegacyEvidenceWithoutFileTrialsOrEmbeddedLocationStillDecodes() throws {
        let device = DeviceEvidence.capture()
        let document = ProbeEvidenceDocument(exportedAt: Date(), device: device, userReportedBuild: "legacy", attempts: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.probe.encode(document)) as! [String: Any]
        json["schemaVersion"] = 2; json.removeValue(forKey: "fileTrials")
        let recovered = try JSONDecoder.probe.decode(ProbeEvidenceDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(recovered.fileTrials); XCTAssertEqual(recovered.userReportedBuild, "legacy")
        let media = Data(#"{"kind":"jpeg","byteCount":1,"metadata":{},"notes":[],"structure":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MediaInspection.self, from: media).location)
    }
}

private actor CountingFilePhotos: ProbePhotosAccess {
    private(set) var commits = 0
    let returnedURL: URL?
    init(returnedURL: URL? = nil) { self.returnedURL = returnedURL }
    func requestReadWriteAuthorization() async throws -> String { "authorized" }
    func importAsset(identifier: String, preferOriginal: Bool, to directory: URL) async throws -> ImportedMediaAsset {
        guard preferOriginal, let returnedURL else { throw PhotosProbeError.missingResource }
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try FileManager.default.copyItem(at: returnedURL, to: output)
        return ImportedMediaAsset(fileURL: output, assetIdentifier: identifier, representation: "Photos original resource", resourceInventory: [], notes: [],
            librarySnapshot: PhotosLibrarySnapshot(creationDate: nil, latitude: 0, longitude: 0, altitude: 0, sourceType: "fixture"))
    }
    func commit(fileURL: URL, route: PhotoSaveRoute, existingAssetIdentifier: String?, adjustmentDescription: String, baselineSourceURL: URL?) async throws -> PhotoCommitResult {
        commits += 1; throw PhotosProbeError.unsupported("A file export must never commit")
    }
    func readBack(assetIdentifier: String, to directory: URL) async throws -> PhotosReadback { throw PhotosProbeError.missingResource }
}
