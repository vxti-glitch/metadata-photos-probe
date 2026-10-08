import Foundation
import SwiftUI
import Photos
import ProbeCore

protocol ProbePhotosAccess: Sendable {
    func requestReadWriteAuthorization() async throws -> String
    func importAsset(identifier: String, preferOriginal: Bool, to directory: URL) async throws -> ImportedMediaAsset
    func commit(fileURL: URL, route: PhotoSaveRoute, existingAssetIdentifier: String?,
                adjustmentDescription: String, baselineSourceURL: URL?) async throws -> PhotoCommitResult
    func readBack(assetIdentifier: String, to directory: URL) async throws -> PhotosReadback
}

extension PhotosService: ProbePhotosAccess {
    func commit(fileURL: URL, route: PhotoSaveRoute, existingAssetIdentifier: String?,
                adjustmentDescription: String, baselineSourceURL: URL?) async throws -> PhotoCommitResult {
        try await save(fileURL: fileURL, route: route, existingAssetIdentifier: existingAssetIdentifier,
                       adjustmentDescription: adjustmentDescription, baselineSourceURL: baselineSourceURL)
    }
}

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var stage: ProbeStage = .preparedFiles
    @Published var route: PhotoSaveRoute = .resourceCreation
    @Published var source: ImportedMediaAsset?
    @Published var sourceInspection: MediaInspection?
    @Published var outputURL: URL?
    @Published var outputInspection: MediaInspection?
    @Published var comparison: IntegrityComparison?
    @Published var attempts: [ProbeAttempt] = []
    @Published var busy = false
    @Published var status = "Select one controlled file. Photos display and attribution are not checked automatically."
    @Published var errorMessage: String?
    @Published var make = "Apple"
    @Published var model = "iPhone 14 Pro"
    @Published var lens = ""
    @Published var baselineOrigin = "Unknown — record Camera, iCloud, Files or app origin"
    @Published var reportedBuild = ""
    @Published var stageAReviewed = false
    @Published var incompleteAcknowledged = false
    @Published var existingEditConsented = false
    @Published var shareURL: URL?
    @Published var selectedAttemptID: UUID?
    @Published var observationPhase: ObservationPhase = .immediate
    @Published var attribution: AttributionObservation = .notChecked
    @Published var attributionText = ""
    @Published var observedCamera: CameraObservation = .notChecked
    @Published var observedCameraText = ""
    @Published var screenshotReference = ""
    @Published var observationNotes = ""

    private let photos: any ProbePhotosAccess
    private let persistWriter: (Data, URL) throws -> Void
    private var work: Task<Void, Never>?
    private var photosAcquisitionID: UUID?
    private var photosAcquisitionCanceled = false
    private var outputPatch: CameraPatch?
    private var didCommitCurrentOutput = false
    let device = DeviceEvidence.capture()
    let workspace: URL

    init(workspaceOverride: URL? = nil, photos: any ProbePhotosAccess = PhotosService(),
         persistWriter: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: [.atomic]) }) {
        self.photos = photos
        self.persistWriter = persistWriter
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        workspace = workspaceOverride ?? base.appendingPathComponent("PhotosMetadataProbe", isDirectory: true)
        do {
            try prepareWorkspace()
            let url = workspace.appendingPathComponent("evidence.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw ProbeUIError.reportTooLarge }
                let saved = try JSONDecoder.probe.decode(ProbeEvidenceDocument.self, from: Data(contentsOf: url))
                attempts = saved.recoveredAttempts
                reportedBuild = saved.userReportedBuild
                selectedAttemptID = attempts.last?.id
            }
        } catch {
            errorMessage = "Local evidence recovery failed: \(error.localizedDescription)"
        }
    }

    var stagingDirectory: URL { workspace.appendingPathComponent("media", isDirectory: true) }
    var canTransform: Bool {
        !busy && ProbeSafetyPolicy.canTransform(stageAReviewed: stageAReviewed, sourcePresent: source != nil)
    }
    var canSave: Bool {
        guard !busy, !didCommitCurrentOutput, outputURL != nil, let comparison else { return false }
        guard stage == .preparedFiles || stageAReviewed else { return false }
        return ProbeSafetyPolicy.canSave(integrityStatus: comparison.status,
            incompleteAcknowledged: incompleteAcknowledged,
            existingRoute: route == .existingContentEdit,
            existingAssetSelected: source?.assetIdentifier != nil,
            existingEditConsented: existingEditConsented)
    }

    func importFiles(_ urls: [URL], asPreparedOutput: Bool) {
        guard let url = urls.first else { return }
        run(asPreparedOutput ? "Acquiring prepared output…" : "Acquiring source…") {
            let acquired = try await FilesImporter.stage(url: url, to: self.stagingDirectory)
            if asPreparedOutput { try await self.usePreparedOutput(acquired.fileURL) }
            else { try await self.acceptSource(acquired) }
        }
    }

    func beginPhotosAcquisition() -> UUID? {
        guard !busy else { return nil }
        let id = UUID()
        photosAcquisitionID = id
        photosAcquisitionCanceled = false
        busy = true
        errorMessage = nil
        status = "Downloading the selected Photos representation…"
        return id
    }

    func receivedPhoto(_ result: Result<ImportedMediaAsset, Error>, acquisitionID: UUID?) {
        guard let acquisitionID, acquisitionID == photosAcquisitionID else {
            discardAcquisition(result)
            return
        }
        let canceled = photosAcquisitionCanceled
        photosAcquisitionID = nil
        photosAcquisitionCanceled = false
        busy = false
        if canceled {
            discardAcquisition(result)
            status = "Canceled Photos acquisition; its staged copy was discarded."
            return
        }
        switch result {
        case .success(let value): run("Inspecting selected Photos representation…") { try await self.acceptSource(value) }
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    func acquirePhotoResource(preferOriginal: Bool) {
        guard let identifier = source?.assetIdentifier else { return }
        run("Retrieving the chosen Photos resource…") {
            _ = try await self.photos.requestReadWriteAuthorization()
            let acquired = try await self.photos.importAsset(identifier: identifier,
                preferOriginal: preferOriginal, to: self.stagingDirectory)
            try await self.acceptSource(acquired)
        }
    }

    func selectNoOp() {
        guard let source else { return }
        run("Comparing unchanged source bytes…") { try await self.usePreparedOutput(source.fileURL) }
    }

    func transform() {
        guard canTransform, let source, let sourceInspection else { return }
        let intended = ProbeSafetyPolicy.patch(make: make, model: model, lens: lens, kind: sourceInspection.kind)
        run("Writing metadata on this device…") {
            let output = self.stagingDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(source.fileURL.pathExtension)
            let result = try await MetadataEngine.process(source: source.fileURL, output: output, patch: intended)
            try Task.checkCancellation()
            self.outputURL = result.outputURL
            self.outputInspection = result.outputInspection
            self.comparison = result.integrity
            self.outputPatch = intended
            self.didCommitCurrentOutput = false
            self.incompleteAcknowledged = false
            self.status = "Metadata readback completed. Review the separate integrity checks before saving."
        }
    }

    func save() {
        guard canSave, let source, let sourceInspection, let outputURL, let outputInspection,
              let comparison else { return }
        let stageSnapshot = stage
        let routeSnapshot = route
        var attempt = ProbeAttempt(executionDevice: device, executionReportedBuild: reportedBuild,
            stage: stageSnapshot, sourceFileURL: source.fileURL, outputFileURL: outputURL,
            sourceRepresentation: source.representation,
            baselineOrigin: baselineOrigin, sourceInspection: sourceInspection,
            outputInspection: outputInspection, requestedPatch: outputPatch,
            stagedIntegrity: comparison, route: routeSnapshot,
            stageAReviewAcknowledged: stageAReviewed,
            incompleteIntegrityAcknowledged: incompleteAcknowledged, state: "Preparing commit")
        // Write intent before entering PhotoKit. An interrupted commit must never retry silently.
        attempt.state = "Commit requested; result unknown until completion"
        attempts.append(attempt)
        selectedAttemptID = attempt.id
        do { try persist() } catch { attempts.removeLast(); errorMessage = error.localizedDescription; return }
        didCommitCurrentOutput = true
        let attemptID = attempt.id
        run("Saving through the selected public PhotoKit route…") {
            do {
                _ = try await self.photos.requestReadWriteAuthorization()
                try Task.checkCancellation()
                let commit = try await self.photos.commit(fileURL: outputURL, route: routeSnapshot,
                    existingAssetIdentifier: source.assetIdentifier,
                    adjustmentDescription: self.adjustmentDescription(patch: attempt.requestedPatch, stage: stageSnapshot),
                    baselineSourceURL: source.fileURL)
                self.update(attemptID) {
                    $0.commit = commit
                    $0.state = "Photos commit confirmed; readback pending"
                }
                try self.persist()
                self.status = "Photos confirmed the save. Camera display and attribution still need your observation."
                do {
                    try await self.readBack(attemptID: attemptID)
                } catch {
                    self.update(attemptID) {
                        $0.state = "Photos commit confirmed; readback incomplete"
                        $0.error = error.localizedDescription
                    }
                    self.status = "Save confirmed; resource readback incomplete. Check Photos and use Retry readback."
                }
            } catch {
                self.update(attemptID) { $0.recordFailure(error) }
                let confirmed = self.attempts.first(where: { $0.id == attemptID })?.commit != nil
                self.status = confirmed ? "Photos save confirmed; local reporting failed. Preserve the asset identifier and export evidence when storage permits." :
                    "No confirmed save result. The library must be checked; this probe does not automatically retry."
                throw error
            }
            try self.persist()
        }
    }

    func retryReadback() {
        guard let id = selectedAttemptID, attempts.contains(where: { $0.id == id && $0.commit != nil }) else { return }
        run("Rechecking already saved resources — no new asset will be created…") {
            _ = try await self.photos.requestReadWriteAuthorization()
            try await self.readBack(attemptID: id)
            try self.persist()
        }
    }

    func addObservation() {
        guard !busy, let id = selectedAttemptID else { return }
        let observation = ManualObservation(phase: observationPhase, attribution: attribution,
            attributionText: String(attributionText.prefix(2000)), camera: observedCamera,
            cameraText: String(observedCameraText.prefix(2000)),
            screenshotReference: String(screenshotReference.prefix(1000)), notes: String(observationNotes.prefix(4000)))
        guard observation.hasMeaningfulObservation else {
            errorMessage = "Record what you actually checked in Apple Photos; unobserved values are not evidence."
            return
        }
        update(id) { $0.observations.append(observation) }
        do { try persist(); status = "Manual observation recorded as user-reported evidence." }
        catch { errorMessage = error.localizedDescription }
    }

    func exportEvidence() {
        guard !busy else { return }
        do {
            try persist()
            let target = workspace.appendingPathComponent("metadata-probe-evidence-\(UUID().uuidString).json")
            try JSONEncoder.probe.encode(document()).write(to: target, options: [.atomic])
            shareURL = target
        } catch { errorMessage = error.localizedDescription }
    }

    func exportProcessedFile() {
        guard !busy, let outputURL else { return }
        shareURL = outputURL
    }

    func cancel() {
        guard busy else { return }
        if photosAcquisitionID != nil {
            photosAcquisitionCanceled = true
            status = "Photos acquisition canceled. Waiting for the provider to finish before clearing local copies."
            return
        }
        work?.cancel()
        status = "Cancellation requested. A native call or committed Photos transaction may still finish."
    }

    func stageChanged() {
        clearOutput()
        existingEditConsented = false
    }

    func routeChanged() {
        stageAReviewed = false
        existingEditConsented = false
    }

    func clearLocalData() {
        guard !busy else { return }
        photosAcquisitionID = nil
        do {
            guard workspace.lastPathComponent == "PhotosMetadataProbe" else { throw ProbeUIError.invalidWorkspace }
            if FileManager.default.fileExists(atPath: workspace.path) { try FileManager.default.removeItem(at: workspace) }
            try prepareWorkspace()
            source = nil; sourceInspection = nil; clearOutput()
            attempts = []; selectedAttemptID = nil; shareURL = nil
            stageAReviewed = false; existingEditConsented = false
            status = "Local probe copies and reports removed. Photos assets and provider files were not changed."
        } catch { errorMessage = error.localizedDescription }
    }

    private func acceptSource(_ value: ImportedMediaAsset) async throws {
        let inspected = try await MetadataEngine.inspect(value.fileURL)
        try Task.checkCancellation()
        source = value; sourceInspection = inspected
        clearOutput(); stageAReviewed = false; existingEditConsented = false
        status = "Source inspected. Stage A: choose a prepared output or unchanged control."
    }

    private func discardAcquisition(_ result: Result<ImportedMediaAsset, Error>) {
        guard case .success(let acquired) = result,
              acquired.fileURL.deletingLastPathComponent().standardizedFileURL == stagingDirectory.standardizedFileURL else { return }
        do { try FileManager.default.removeItem(at: acquired.fileURL) }
        catch { errorMessage = "Could not discard canceled staged media: \(error.localizedDescription)" }
    }

    private func usePreparedOutput(_ candidate: URL) async throws {
        guard let source, let sourceInspection else { throw ProbeUIError.missingSource }
        let inspected = try await MetadataEngine.inspect(candidate)
        guard inspected.kind == sourceInspection.kind else { throw ProbeUIError.formatChange }
        let preparedPatch = inspected.metadata["make"].flatMap { make in
            inspected.metadata["model"].map { model in
                CameraPatch(make: make, model: model,
                    lens: inspected.metadata["lens"] != sourceInspection.metadata["lens"] ? inspected.metadata["lens"] : nil)
            }
        }
        let verified = try await MediaIntegrity.compare(source: source.fileURL, output: candidate, patch: preparedPatch)
        try Task.checkCancellation()
        outputURL = candidate; outputInspection = inspected; comparison = verified
        outputPatch = nil; didCommitCurrentOutput = false; incompleteAcknowledged = false
        status = "Prepared output compared. This does not count as an on-device metadata transformation."
    }

    private func readBack(attemptID: UUID) async throws {
        guard let attempt = attempts.first(where: { $0.id == attemptID }), let commit = attempt.commit,
              FileManager.default.fileExists(atPath: attempt.sourceFileURL.path),
              FileManager.default.fileExists(atPath: attempt.outputFileURL.path) else { throw ProbeUIError.missingCommit }
        let directory = workspace.appendingPathComponent("readback", isDirectory: true)
            .appendingPathComponent(attemptID.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        update(attemptID) { $0.beginReadback() }
        do {
        let result = try await photos.readBack(assetIdentifier: commit.assetIdentifier, to: directory)
        update(attemptID) { $0.readback = result }
        for resource in result.resources {
            guard ["jpg", "jpeg", "heic", "heif", "mp4", "mov"].contains(resource.url.pathExtension.lowercased()) else { continue }
            try Task.checkCancellation()
            let key = "\(resource.type):\(resource.filename)"
            let original = resource.typeRawValue == PHAssetResourceType.photo.rawValue ||
                resource.typeRawValue == PHAssetResourceType.video.rawValue
            let preservesOriginal = attempt.route == .existingContentEdit && original
            let reference = preservesOriginal ? attempt.sourceFileURL : attempt.outputFileURL
            let expected = preservesOriginal ? attempt.sourceInspection.metadata : attempt.outputInspection.metadata
            let inspected = try await MetadataEngine.inspect(resource.url)
            let comparison = try await MediaIntegrity.compare(source: reference, output: resource.url)
            update(attemptID) {
                $0.savedResourceInspections[key] = inspected
                $0.savedResourceIntegrity[key] = comparison
                $0.savedCameraChecks[key] = ["make", "model", "lens"].map { field in
                    guard let intended = expected[field] else {
                        return IntegrityCheck(name: "Saved \(field)", status: .notChecked, detail: "No expected value was available for this resource.")
                    }
                    let actual = inspected.metadata[field]
                    return IntegrityCheck(name: "Saved \(field)", status: actual == intended ? .passed : .failed,
                        detail: "Expected: \(intended). Read back: \(actual ?? "missing"). Photos UI remains a separate manual check.")
                }
            }
        }
        update(attemptID) { $0.state = "Resources checked; Photos UI and attribution unverified"; $0.finishedAt = Date() }
        status = "Saved resources checked. Open Apple Photos, inspect Info, then record the camera display and source label."
        } catch {
            update(attemptID) { $0.recordFailure(error) }
            try? persist()
            throw error
        }
    }

    private func clearOutput() {
        outputURL = nil; outputInspection = nil; comparison = nil; outputPatch = nil
        incompleteAcknowledged = false; didCommitCurrentOutput = false
    }

    private func adjustmentDescription(patch: CameraPatch?, stage: ProbeStage) -> String {
        struct Recipe: Encodable {
            let operation = "controlled-metadata-feasibility"
            let stage: ProbeStage
            let patch: CameraPatch?
            let reconstructionSupported = false
        }
        let recipe = Recipe(stage: stage, patch: patch)
        return (try? JSONEncoder.probe.encode(recipe)).flatMap { String(data: $0, encoding: .utf8) } ?? "Recipe encoding failed; no reconstruction supported"
    }

    private func update(_ id: UUID, _ body: (inout ProbeAttempt) -> Void) {
        guard let index = attempts.firstIndex(where: { $0.id == id }) else { return }
        body(&attempts[index])
    }

    private func run(_ message: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; errorMessage = nil; status = message
        work = Task {
            defer { self.busy = false; self.work = nil }
            do { try await operation() }
            catch is CancellationError { self.status = "Operation canceled; inspect any recorded commit before repeating." }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    private func prepareWorkspace() throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directory = workspace
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func document() -> ProbeEvidenceDocument {
        ProbeEvidenceDocument(exportedAt: Date(), device: device, userReportedBuild: reportedBuild, attempts: attempts)
    }

    private func persist() throws {
        let bytes = try JSONEncoder.probe.encode(document())
        guard bytes.count <= 8 * 1024 * 1024 else { throw ProbeUIError.reportTooLarge }
        try persistWriter(bytes, workspace.appendingPathComponent("evidence.json"))
    }
}

enum ProbeUIError: LocalizedError {
    case missingSource, formatChange, missingCommit, invalidWorkspace, reportTooLarge
    var errorDescription: String? {
        switch self {
        case .missingSource: return "Select the controlled original before selecting an output."
        case .formatChange: return "The prepared output must have the same format as its source. This probe will not convert it."
        case .missingCommit: return "No confirmed commit/current local files are available for this readback. Export existing evidence and start a new controlled test."
        case .invalidWorkspace: return "Refused to clear an unexpected directory."
        case .reportTooLarge: return "The local evidence report reached its 8 MB budget. Export and clear the probe before more experiments."
        }
    }
}

extension JSONEncoder {
    static var probe: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
extension JSONDecoder {
    static var probe: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
