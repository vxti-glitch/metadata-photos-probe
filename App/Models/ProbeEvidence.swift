import Foundation
import UIKit
import ProbeCore

enum ProbeStage: String, Codable, CaseIterable, Identifiable {
    case preparedFiles = "Stage A · prepared files"
    case onDevice = "Stage B · on-device change"
    var id: String { rawValue }
}

enum ObservationPhase: String, Codable, CaseIterable, Identifiable {
    case immediate = "Immediately after save"
    case relaunched = "After Photos relaunch"
    case synchronized = "After iCloud sync settles"
    var id: String { rawValue }
}

enum AttributionObservation: String, Codable, CaseIterable, Identifiable {
    case notChecked = "Not checked"
    case absent = "No unwanted source label observed"
    case present = "Source label displayed"
    case inconclusive = "Could not determine"
    var id: String { rawValue }
}

enum CameraObservation: String, Codable, CaseIterable, Identifiable {
    case notChecked = "Not checked"
    case matches = "Displayed values match intended metadata"
    case differs = "Displayed values differ"
    case notDisplayed = "Camera details not displayed"
    var id: String { rawValue }
}

struct ManualObservation: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var phase: ObservationPhase
    var attribution: AttributionObservation
    var attributionText: String
    var camera: CameraObservation
    var cameraText: String
    var screenshotReference: String
    var notes: String

    var hasMeaningfulObservation: Bool {
        attribution != .notChecked || camera != .notChecked
    }
}

struct DeviceEvidence: Codable {
    let model: String
    let hardwareIdentifier: String
    let osVersion: String
    let osDescription: String
    let appVersion: String
    let appBuild: String
    let bundleIdentifier: String
    let simulator: Bool

    static func capture() -> DeviceEvidence {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let hardware = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        #if targetEnvironment(simulator)
        let simulated = true
        #else
        let simulated = false
        #endif
        return DeviceEvidence(
            model: UIDevice.current.model,
            hardwareIdentifier: hardware,
            osVersion: UIDevice.current.systemVersion,
            osDescription: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            simulator: simulated
        )
    }

    var matchesPrimaryTarget: Bool {
        !simulator && hardwareIdentifier == "iPhone16,2" && osVersion == "27.2"
    }
}

struct ProbeAttempt: Codable, Identifiable {
    var id = UUID()
    var startedAt = Date()
    var finishedAt: Date?
    var stage: ProbeStage
    var sourceFileURL: URL
    var outputFileURL: URL
    var sourceRepresentation: String
    var baselineOrigin: String
    var sourceInspection: MediaInspection
    var outputInspection: MediaInspection
    var requestedPatch: CameraPatch?
    var stagedIntegrity: IntegrityComparison
    var route: PhotoSaveRoute
    var stageAReviewAcknowledged: Bool
    var incompleteIntegrityAcknowledged: Bool
    var state: String
    var commit: PhotoCommitResult?
    var readback: PhotosReadback?
    var savedResourceInspections: [String: MediaInspection] = [:]
    var savedResourceIntegrity: [String: IntegrityComparison] = [:]
    var savedCameraChecks: [String: [IntegrityCheck]] = [:]
    var observations: [ManualObservation] = []
    var error: String?
}

struct ProbeEvidenceDocument: Codable {
    let schemaVersion = 1
    let exportedAt: Date
    let device: DeviceEvidence
    let userReportedBuild: String
    let declaredScope = "Single-file feasibility prototype; no automatic attribution detection or authenticity proof"
    let hardwareVerdict = "Pending supervised physical-device evaluation; manual observations are user-reported evidence"
    let attempts: [ProbeAttempt]
}

enum ProbeSafetyPolicy {
    static func canTransform(stageAReviewed: Bool, sourcePresent: Bool) -> Bool {
        stageAReviewed && sourcePresent
    }

    static func canSave(
        integrityStatus: IntegrityStatus,
        incompleteAcknowledged: Bool,
        existingRoute: Bool,
        existingAssetSelected: Bool,
        existingEditConsented: Bool
    ) -> Bool {
        guard integrityStatus != .mismatch else { return false }
        guard integrityStatus == .verified || incompleteAcknowledged else { return false }
        return !existingRoute || (existingAssetSelected && existingEditConsented)
    }
}
