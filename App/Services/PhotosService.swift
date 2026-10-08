import Foundation
import Photos
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import CoreLocation
import CryptoKit

/// PhotoKit owns library transactions. This adapter never writes into the Photos library filesystem.
/// Attribution is deliberately absent from these results: only the physical Photos UI can supply it.
actor PhotosService {
    func requestReadWriteAuthorization() async throws -> String {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { throw PhotosProbeError.accessDenied }
        return status == .limited ? "limited" : "authorized"
    }

    func importAsset(identifier: String, preferOriginal: Bool, to directory: URL) async throws -> ImportedMediaAsset {
        try requireReadWrite()
        let asset = try fetch(identifier)
        try rejectLivePhoto(asset)
        let resources = PHAssetResource.assetResources(for: asset)
        let renderedType: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        let index = try PhotosResourcePolicy.selectedIndex(types: resources.map(\.type),
            isVideo: asset.mediaType == .video, preferOriginal: preferOriginal)
        let chosen = resources[index]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = destination(for: chosen, in: directory)
        try await extract(chosen, to: target)
        return ImportedMediaAsset(fileURL: target, assetIdentifier: identifier,
            representation: preferOriginal ? "Photos original resource" : (chosen.type == renderedType ? "Photos rendered resource" : "Photos original (no rendered resource)"),
            resourceInventory: resources.map(inventory),
            notes: ["Resource extraction can download an iCloud asset. Original and current resources are separate evidence."])
    }

    func save(fileURL: URL, route: PhotoSaveRoute, existingAssetIdentifier: String? = nil,
              adjustmentDescription: String = "Controlled native metadata probe",
              baselineSourceURL: URL? = nil, libraryDate: Date? = nil,
              libraryLocation: CLLocation? = nil) async throws -> PhotoCommitResult {
        try requireReadWrite()
        try Task.checkCancellation()
        try validateFile(fileURL)
        let type = try contentType(fileURL)
        if route == .existingContentEdit {
            guard let identifier = existingAssetIdentifier, let baselineSourceURL else {
                throw PhotosProbeError.unsupported("Existing edits require a selected authorized Photos identifier and its staged baseline file.")
            }
            return try await edit(fileURL: fileURL, type: type, identifier: identifier,
                baselineSourceURL: baselineSourceURL, description: adjustmentDescription,
                libraryDate: libraryDate, libraryLocation: libraryLocation)
        }
        let holder = TransactionState()
        try await transaction {
            let request: PHAssetChangeRequest?
            switch route {
            case .resourceCreation:
                let creation = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileURL.lastPathComponent
                options.uniformTypeIdentifier = type.identifier
                options.shouldMoveFile = false
                creation.addResource(with: type.conforms(to: .image) ? .photo : .video, fileURL: fileURL, options: options)
                request = creation
            case .convenienceCreation:
                request = type.conforms(to: .image)
                    ? PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                    : PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            case .existingContentEdit: request = nil
            }
            guard let request, let placeholder = request.placeholderForCreatedAsset else {
                holder.failure = "The file creation factory did not provide a request/placeholder."
                return
            }
            if let libraryDate { request.creationDate = libraryDate }
            if let libraryLocation { request.location = libraryLocation }
            holder.identifier = placeholder.localIdentifier
        }
        guard let identifier = holder.identifier, holder.failure == nil else {
            throw PhotosProbeError.transactionFailed(holder.failure ?? "Missing committed identifier")
        }
        // No cancellation check after commit: the committed identifier must reach the report/UI.
        return PhotoCommitResult(assetIdentifier: identifier, route: route, supportedRenderedTypes: [],
            notes: ["Photos confirmed this transaction. The staged output was copied, not moved.",
                    "Embedded metadata, saved resource integrity, and Photos attribution still require separate verification."])
    }

    func readBack(assetIdentifier: String, to directory: URL) async throws -> PhotosReadback {
        try requireReadWrite()
        let asset = try fetch(assetIdentifier)
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw PhotosProbeError.missingResource }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved: [SavedPhotoResource] = []
        for resource in resources {
            try Task.checkCancellation()
            let target = destination(for: resource, in: directory)
            try await extract(resource, to: target)
            let info = inventory(resource)
            saved.append(SavedPhotoResource(type: info.type, typeRawValue: info.typeRawValue,
                filename: info.filename, contentType: info.contentType, url: target))
        }
        let location = asset.location.map {
            "latitude=\($0.coordinate.latitude); longitude=\($0.coordinate.longitude); altitude=\($0.altitude)"
        }
        return PhotosReadback(resources: saved, libraryDate: asset.creationDate,
            locationSummary: location, sourceType: "rawValue=\(asset.sourceType.rawValue)",
            notes: ["Every enumerated resource was extracted, including adjustment/original/current resources where present.",
                    "PHAsset.sourceType is a broad category and cannot establish importing-app attribution.",
                    "A successful file readback does not establish the camera information or source label displayed in Photos."])
    }

    private func edit(fileURL: URL, type: UTType, identifier: String, baselineSourceURL: URL,
                      description: String, libraryDate: Date?, libraryLocation: CLLocation?) async throws -> PhotoCommitResult {
        try validateFile(baselineSourceURL)
        let asset = try fetch(identifier)
        try rejectLivePhoto(asset)
        guard asset.canPerform(.content) else {
            throw PhotosProbeError.unsupported("Photos does not permit a content edit for this asset.")
        }
        let existingResources = PHAssetResource.assetResources(for: asset)
        // Refusing all existing adjustments is intentional. This probe does not reconstruct them.
        guard !existingResources.contains(where: { $0.type == .adjustmentData }) else {
            throw PhotosProbeError.priorAdjustments
        }
        let input = try await editingInput(asset)
        guard input.adjustmentData == nil else { throw PhotosProbeError.priorAdjustments }
        let inputURL: URL
        if type.conforms(to: .image) {
            guard asset.mediaType == .image, input.fullSizeImageOrientation == 1,
                  let url = input.fullSizeImageURL else {
                throw PhotosProbeError.unsupported("Existing photo edits require a file-backed upright input (EXIF orientation 1).")
            }
            try requireUprightImage(fileURL)
            inputURL = url
        } else {
            guard asset.mediaType == .video, let video = input.audiovisualAsset as? AVURLAsset else {
                throw PhotosProbeError.unsupported("Existing video edits require a file-backed AVURLAsset, not a composition.")
            }
            inputURL = video.url
            try await requireUprightVideo(inputURL)
            try await requireUprightVideo(fileURL)
        }
        guard try contentType(inputURL) == type, try contentType(baselineSourceURL) == type,
              try digest(inputURL) == digest(baselineSourceURL) else { throw PhotosProbeError.sourceMismatch }
        let output = PHContentEditingOutput(contentEditingInput: input)
        let supported = output.supportedRenderedContentTypes
        guard supported.contains(type) else {
            throw PhotosProbeError.unsupported("Photos rendered types: \(supported.map(\.identifier).joined(separator: ", ")); requested \(type.identifier). No conversion was attempted.")
        }
        let renderedURL = try output.renderedContentURL(for: type)
        // This is Photos' app-owned temporary rendered output URL, never the library original.
        if FileManager.default.fileExists(atPath: renderedURL.path) {
            try FileManager.default.removeItem(at: renderedURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: renderedURL)
        let recipe = AdjustmentRecipe(schemaVersion: 1, description: description,
            sourceSHA256: try digest(baselineSourceURL), outputSHA256: try digest(fileURL),
            contentType: type.identifier, operation: "file-backed native metadata experiment; prior adjustments refused",
            canReconstruct: false)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "\(Bundle.main.bundleIdentifier ?? "local.metadata.probe").diagnostic-adjustment",
            formatVersion: "1.0", data: try JSONEncoder().encode(recipe))
        try Task.checkCancellation()
        try await transaction {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
            if let libraryDate { request.creationDate = libraryDate }
            if let libraryLocation { request.location = libraryLocation }
        }
        return PhotoCommitResult(assetIdentifier: identifier, route: .existingContentEdit,
            supportedRenderedTypes: supported.map(\.identifier),
            notes: ["Existing controlled asset edit committed with genuine versioned diagnostic adjustment data.",
                    "This probe refuses subsequent edits rather than pretending it can reconstruct adjustments.",
                    "Photos retains its own original/current resource policy. Revert must be tested manually.",
                    "Camera re-indexing and imported-source attribution remain physical-device observations."])
    }

    private func editingInput(_ asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { _ in false }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let error = info[PHContentEditingInputErrorKey] as? Error { continuation.resume(throwing: error) }
                else if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: PhotosProbeError.missingEditingInput) }
            }
        }
    }

    private func transaction(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: PhotosProbeError.transactionFailed(error?.localizedDescription ?? "Unknown PhotoKit transaction failure")) }
            }
        }
    }

    private func extract(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func requireReadWrite() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotosProbeError.accessDenied }
    }
    private func fetch(_ identifier: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotosProbeError.assetUnavailable
        }
        return asset
    }
    private func rejectLivePhoto(_ asset: PHAsset) throws {
        guard !asset.mediaSubtypes.contains(.photoLive) else {
            throw PhotosProbeError.unsupported("Live Photos and paired resources are outside this probe.")
        }
    }
    private func inventory(_ resource: PHAssetResource) -> PhotoResourceInventory {
        PhotoResourceInventory(type: String(describing: resource.type), typeRawValue: resource.type.rawValue,
            filename: resource.originalFilename, contentType: resource.uniformTypeIdentifier)
    }
    private func destination(for resource: PHAssetResource, in directory: URL) -> URL {
        // Never reuse the resource filename as a path: it is external input and can collide.
        let ext = (resource.originalFilename as NSString).pathExtension
        let base = directory.appendingPathComponent(UUID().uuidString)
        return ext.isEmpty ? base : base.appendingPathExtension(ext)
    }
    private func validateFile(_ url: URL) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.isFileURL, info.isRegularFile == true, (info.fileSize ?? 0) > 0 else {
            throw PhotosProbeError.invalidFile
        }
    }
    private func contentType(_ url: URL) throws -> UTType {
        if let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let raw = CGImageSourceGetType(image), let type = UTType(raw as String), type == .jpeg || type == .heic {
            return type
        }
        // Native engine preflight independently inspects container bytes before this adapter.
        switch url.pathExtension.lowercased() {
        case "mp4": return .mpeg4Movie
        case "mov": return .quickTimeMovie
        default: throw PhotosProbeError.unsupported("Only controlled JPEG, HEIC, MP4 and MOV files are accepted.")
        }
    }
    private func requireUprightImage(_ url: URL) throws {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              ((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1) == 1 else {
            throw PhotosProbeError.unsupported("Existing photo edit output must have upright compressed content. Rotating tags or re-encoding is forbidden in this probe.")
        }
    }
    private func requireUprightVideo(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw PhotosProbeError.unsupported("No video track found.") }
        for track in tracks {
            let transform = try await track.load(.preferredTransform)
            guard transform.isIdentity else {
                throw PhotosProbeError.unsupported("Existing video edit requires identity track transforms; no rotation/re-encoding workaround is allowed.")
            }
        }
    }
    private func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Original/current selection is explicit and refuses ambiguous resources or missing edited renditions.
enum PhotosResourcePolicy {
    static func selectedIndex(types: [PHAssetResourceType], isVideo: Bool, preferOriginal: Bool) throws -> Int {
        let original: PHAssetResourceType = isVideo ? .video : .photo
        let current: PHAssetResourceType = isVideo ? .fullSizeVideo : .fullSizePhoto
        let wanted = preferOriginal ? original : current
        let candidates = types.indices.filter { types[$0] == wanted }
        if candidates.count == 1 { return candidates[0] }
        if !preferOriginal && candidates.isEmpty && !types.contains(.adjustmentData) {
            let fallback = types.indices.filter { types[$0] == original }
            if fallback.count == 1 { return fallback[0] }
        }
        throw PhotosProbeError.missingResource
    }
}

private struct AdjustmentRecipe: Codable {
    let schemaVersion: Int
    let description: String
    let sourceSHA256: String
    let outputSHA256: String
    let contentType: String
    let operation: String
    let canReconstruct: Bool
}

/// PhotoKit invokes change and completion blocks on framework queues.
private final class TransactionState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentifier: String?
    private var storedFailure: String?
    var identifier: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedIdentifier }
        set { lock.lock(); defer { lock.unlock() }; storedIdentifier = newValue }
    }
    var failure: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedFailure }
        set { lock.lock(); defer { lock.unlock() }; storedFailure = newValue }
    }
}
