import Foundation

/// Strict remains the canonical probe default. The editor may opt into showing
/// additional, unselected metadata changes as warnings. Media preservation,
/// requested edits, independent location and image-property checks stay blocking.
public enum IntegrityPolicy: Sendable {
    case strict
    case allowAdditionalMetadataChanges

    public func applying(to comparison: IntegrityComparison) -> IntegrityComparison {
        guard self == .allowAdditionalMetadataChanges else { return comparison }
        let checks = comparison.checks.map { check -> IntegrityCheck in
            if check.status == .warning && !Self.isAdditionalMetadataCheck(check.name) {
                return IntegrityCheck(name: check.name, status: .failed, detail: check.detail)
            }
            guard check.status == .failed, Self.isAdditionalMetadataCheck(check.name) else { return check }
            return IntegrityCheck(name: check.name, status: .warning, detail: check.detail)
        }
        let status: IntegrityStatus
        if checks.contains(where: { $0.status == .failed }) ||
            (comparison.status == .mismatch && !comparison.checks.contains(where: { $0.status == .failed })) {
            status = .mismatch
        } else if comparison.status == .incomplete || !comparison.limitations.isEmpty || checks.contains(where: { $0.status == .notChecked }) {
            status = .incomplete
        } else if checks.contains(where: { $0.status == .warning }) {
            status = .warning
        } else {
            status = .verified
        }
        return IntegrityComparison(status: status, checks: checks, limitations: comparison.limitations)
    }

    /// Shared closed allowlist for editor receipt validation. Arbitrary future
    /// check names must not grant a warning exception to an output.
    public static func isAdditionalMetadataCheck(_ name: String) -> Bool {
        if ["retained embedded metadata", "retained metadata unnamed key",
            "retained metadata numeric key", "retained metadata unrecognized key",
            "retained metadata location tuple"].contains(name) { return true }
        // Match a closed set rather than a prefix: future or spoofed failure names
        // never inherit this exception. Independent location comparison and
        // requested GPS readback use separate, blocking check names.
        return MetadataPatch.allKeys.contains { "retained metadata field " + $0 == name }
    }
}
