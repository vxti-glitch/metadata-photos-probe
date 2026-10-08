import Foundation

enum PhotoSaveRoute: String, CaseIterable, Codable, Identifiable {
    case resourceCreation, convenienceCreation, existingContentEdit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .resourceCreation: return "New asset: file resource"
        case .convenienceCreation: return "New asset: file factory"
        case .existingContentEdit: return "Edit selected existing asset"
        }
    }
}

struct PhotoResourceInventory: Codable {
    let type: String
    let typeRawValue: Int
    let filename: String
    let contentType: String
}

struct ImportedMediaAsset: Codable {
    let fileURL: URL
    let assetIdentifier: String?
    let representation: String
    let resourceInventory: [PhotoResourceInventory]
    let notes: [String]
}

struct PhotoCommitResult: Codable {
    let assetIdentifier: String
    let route: PhotoSaveRoute
    let supportedRenderedTypes: [String]
    let notes: [String]
}

struct SavedPhotoResource: Codable {
    let type: String
    let typeRawValue: Int
    let filename: String
    let contentType: String
    let url: URL
}

struct PhotosReadback: Codable {
    let resources: [SavedPhotoResource]
    let libraryDate: Date?
    let locationSummary: String?
    let sourceType: String
    let notes: [String]
}

enum PhotosProbeError: LocalizedError {
    case accessDenied, assetUnavailable, unsupported(String), missingResource, missingEditingInput
    case sourceMismatch, priorAdjustments, invalidFile, transactionFailed(String), canceled
    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Photos read/write permission is required for resource verification. Allow access in Settings, including the selected asset for limited access."
        case .assetUnavailable: return "The Photos asset is unavailable or outside the permitted limited selection."
        case .unsupported(let detail): return "Unsupported controlled experiment: \(detail)"
        case .missingResource: return "Photos did not supply the requested original/current media resource."
        case .missingEditingInput: return "Photos did not return a content editing input."
        case .sourceMismatch: return "The selected Photos editing input differs from the staged baseline. Import this unedited controlled asset again before editing."
        case .priorAdjustments: return "This asset already has adjustments. This first probe refuses to overwrite or reconstruct previous edits. Use an unedited controlled fixture."
        case .invalidFile: return "The staged source or output is missing, empty, or not a regular file."
        case .transactionFailed(let detail): return "Photos did not confirm the change: \(detail). Do not retry automatically; check the library for a possible completed asset."
        case .canceled: return "The selection was canceled."
        }
    }
}
