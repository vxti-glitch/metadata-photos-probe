import Foundation

enum FilesImporter {
    /// The provider URL is never edited; copy a coordinated snapshot into our sandbox.
    static func stage(url: URL, to directory: URL) async throws -> ImportedMediaAsset {
        try await Task.detached(priority: .userInitiated) {
            let hasScope = url.startAccessingSecurityScopedResource()
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = url.pathExtension.lowercased()
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                do { try FileManager.default.copyItem(at: readableURL, to: destination) }
                catch { copyError = error }
            }
            if let error = coordinationError ?? (copyError as NSError?) { throw error }
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw PhotosProbeError.invalidFile
            }
            return ImportedMediaAsset(fileURL: destination, assetIdentifier: nil,
                representation: "Files coordinated snapshot", resourceInventory: [],
                notes: ["Provider source remains unchanged. A cloud provider may have downloaded this file."])
        }.value
    }
}
