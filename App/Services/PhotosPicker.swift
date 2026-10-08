import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PhotosPicker: UIViewControllerRepresentable {
    let stagingDirectory: URL
    let onAcquisitionStarted: () -> UUID?
    let onResult: (UUID?, Result<ImportedMediaAsset, Error>) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 1
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotosPicker
        init(parent: PhotosPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                picker.dismiss(animated: true)
                deliver(.failure(PhotosProbeError.canceled), acquisitionID: nil)
                return
            }
            // Establish the model's busy state and generation synchronously while its
            // selection sheet still covers the form. Never start a provider load if rejected.
            guard let acquisitionID = PhotosAcquisitionOrdering.beginBeforeDismissal(
                begin: parent.onAcquisitionStarted,
                dismiss: { picker.dismiss(animated: true) }) else { return }
            let provider = result.itemProvider
            if provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
                deliver(.failure(PhotosProbeError.unsupported("Live Photos must not be flattened.")), acquisitionID: acquisitionID)
                return
            }
            let allowed = [UTType.heic, .jpeg, .mpeg4Movie, .quickTimeMovie]
            // Require an explicitly advertised original/current type, not a conversion offered
            // only via broad type conformance. Actual file bytes are inspected by the engine.
            guard let type = allowed.first(where: { provider.registeredTypeIdentifiers.contains($0.identifier) }) else {
                deliver(.failure(PhotosProbeError.unsupported("Select a JPEG, HEIC, MP4, or MOV fixture.")), acquisitionID: acquisitionID)
                return
            }
            // NSItemProvider invokes its file-representation completion on its internal queue.
            // Copy before returning: the provider's temporary URL expires after this callback.
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error { self.deliver(.failure(error), acquisitionID: acquisitionID); return }
                guard let url else { self.deliver(.failure(PhotosProbeError.missingResource), acquisitionID: acquisitionID); return }
                var stagedURL: URL?
                do {
                    try FileManager.default.createDirectory(at: self.parent.stagingDirectory, withIntermediateDirectories: true)
                    let suffix = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "media") : url.pathExtension
                    let destination = self.parent.stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
                    stagedURL = destination
                    try FileManager.default.copyItem(at: url, to: destination)
                    self.deliver(.success(ImportedMediaAsset(fileURL: destination,
                        assetIdentifier: result.assetIdentifier, representation: "Photos picker current file representation",
                        resourceInventory: [], notes: ["Current representation was requested; picker transcoding/preservation must be verified against a controlled baseline.", "The picker identifier does not itself authorize an existing-asset edit."])), acquisitionID: acquisitionID)
                } catch {
                    if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
                    self.deliver(.failure(error), acquisitionID: acquisitionID)
                }
            }
        }
        private func deliver(_ result: Result<ImportedMediaAsset, Error>, acquisitionID: UUID?) {
            DispatchQueue.main.async { self.parent.onResult(acquisitionID, result) }
        }
    }
}

/// Kept separate so a regression cannot expose idle controls before the busy lease starts.
enum PhotosAcquisitionOrdering {
    static func beginBeforeDismissal(begin: () -> UUID?, dismiss: () -> Void) -> UUID? {
        let generation = begin()
        dismiss()
        return generation
    }
}
