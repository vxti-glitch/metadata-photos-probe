import Foundation
import ProbeCore

struct PhotosLibrarySnapshot: Codable {
    let creationDate: Date?
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let sourceType: String
    var locationSummary: String {
        guard let latitude, let longitude else { return "No location supplied by Photos" }
        return "\(latitude), \(longitude) (Photos library)"
    }
}

/// File processing/export evidence exists independently of any PhotoKit write.
struct FileWorkflowTrial: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    let device: DeviceEvidence
    let reportedBuild: String
    let stage: ProbeStage
    let source: ImportedMediaAsset
    let sourceInspection: MediaInspection
    let outputURL: URL
    let outputInspection: MediaInspection
    let patch: CameraPatch?
    let integrity: IntegrityComparison
    var exportState = "Not exported"
    var exportCompletedAt: Date?
    var externalRoute = "Safari/iCloud.com Photos (user operated; not automatically verified)"
    var returnedAsset: ImportedMediaAsset?
    var returnedInspection: MediaInspection?
    var returnedIntegrity: IntegrityComparison?
    var returnedError: String?
    var observations: [ManualObservation] = []
}
