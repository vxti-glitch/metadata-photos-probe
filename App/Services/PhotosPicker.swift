import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PhotosPicker: UIViewControllerRepresentable {
    let stagingDirectory: URL
    let onResult: (Result<ImportedMediaAsset, Error>) -> Void

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
            picker.dismiss(animated: true)
            guard let result = results.first else { deliver(.failure(PhotosProbeError.canceled)); return }
            let provider = result.itemProvider
            if provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
                deliver(.failure(PhotosProbeError.unsupported("Live Photos must not be flattened.")))
                return
            }
            let allowed = [UTType.heic, .jpeg, .mpeg4Movie, .quickTimeMovie]
            // Require an explicitly advertised original/current type, not a conversion offered
            // only via broad type conformance. Actual file bytes are inspected by the engine.
            guard let type = allowed.first(where: { provider.registeredTypeIdentifiers.contains($0.identifier) }) else {
                deliver(.failure(PhotosProbeError.unsupported("Select a JPEG, HEIC, MP4, or MOV fixture.")))
                return
            }
            // NSItemProvider invokes its file-representation completion on its internal queue.
            // Copy before returning: the provider's temporary URL expires after this callback.
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error { self.deliver(.failure(error)); return }
                guard let url else { self.deliver(.failure(PhotosProbeError.missingResource)); return }
                do {
                    try FileManager.default.createDirectory(at: self.parent.stagingDirectory, withIntermediateDirectories: true)
                    let suffix = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "media") : url.pathExtension
                    let destination = self.parent.stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
                    try FileManager.default.copyItem(at: url, to: destination)
                    self.deliver(.success(ImportedMediaAsset(fileURL: destination,
                        assetIdentifier: result.assetIdentifier, representation: "Photos picker current file representation",
                        resourceInventory: [], notes: ["Current representation was requested; picker transcoding/preservation must be verified against a controlled baseline.", "The picker identifier does not itself authorize an existing-asset edit."])))
                } catch { self.deliver(.failure(error)) }
            }
        }
        private func deliver(_ result: Result<ImportedMediaAsset, Error>) {
            DispatchQueue.main.async { self.parent.onResult(result) }
        }
    }
}
