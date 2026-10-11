import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case jpeg, heic, png, mp4, mov
    public var isImage: Bool { self == .jpeg || self == .heic || self == .png }
}

public struct CameraPatch: Codable, Sendable {
    public var make: String
    public var model: String
    public var lens: String?
    public init(make: String = "Feasibility Test", model: String = "Controlled Camera", lens: String? = nil) {
        self.make = make; self.model = model; self.lens = lens
    }
    public func validate() throws {
        for value in [make, model] + (lens.map { [$0] } ?? []) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 256,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ProbeError.invalidPatch
            }
        }
    }
}

public struct MediaInspection: Codable, Sendable {
    public let kind: MediaKind
    public let byteCount: Int64
    public let metadata: [String: String]
    public let notes: [String]
    public let structure: [String: String]
    public let location: EmbeddedLocationEvidence?
    public init(kind: MediaKind, byteCount: Int64, metadata: [String: String], notes: [String], structure: [String: String], location: EmbeddedLocationEvidence? = nil) {
        self.kind = kind; self.byteCount = byteCount; self.metadata = metadata; self.notes = notes; self.structure = structure
        self.location = location
    }
}

public enum IntegrityStatus: String, Codable, Sendable { case verified, mismatch, incomplete }
public enum CheckStatus: String, Codable, Sendable { case passed, failed, notChecked }
public struct IntegrityCheck: Codable, Sendable {
    public let name: String
    public let status: CheckStatus
    public let detail: String
    public init(name: String, status: CheckStatus, detail: String) { self.name = name; self.status = status; self.detail = detail }
}
public struct IntegrityComparison: Codable, Sendable {
    public let status: IntegrityStatus
    public let checks: [IntegrityCheck]
    public let limitations: [String]
    public init(status: IntegrityStatus, checks: [IntegrityCheck], limitations: [String]) {
        self.status = status; self.checks = checks; self.limitations = limitations
    }
}
public struct ProcessingResult: Codable, Sendable {
    public let outputURL: URL
    public let sourceInspection: MediaInspection
    public let outputInspection: MediaInspection
    public let integrity: IntegrityComparison
    public init(outputURL: URL, sourceInspection: MediaInspection, outputInspection: MediaInspection, integrity: IntegrityComparison) {
        self.outputURL = outputURL; self.sourceInspection = sourceInspection
        self.outputInspection = outputInspection; self.integrity = integrity
    }
}

public enum ProbeError: LocalizedError {
    case unsupported(String), malformed(String), invalidPatch, outputExists, sameFile, writeFailed(String), readbackFailed(String), integrityMismatch(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): return "Unsupported media: \(detail)"
        case .malformed(let detail): return "Invalid media: \(detail)"
        case .invalidPatch: return "One or more metadata fields has an invalid value, unknown key, or conflicting edit and removal."
        case .outputExists: return "The output already exists. Choose a new output path."
        case .sameFile: return "Source and output must be different files."
        case .writeFailed(let detail): return "Metadata write failed: \(detail)"
        case .readbackFailed(let detail): return "Independent metadata readback failed: \(detail)"
        case .integrityMismatch(let detail): return "Media integrity verification failed: \(detail)"
        }
    }
}
