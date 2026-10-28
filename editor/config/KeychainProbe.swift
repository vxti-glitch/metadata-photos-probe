import Foundation
import UIKit

/// CI-only synthetic storage exercise. Never contacts a license endpoint or reads production records.
@MainActor
final class KeychainProbeDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let storage = ZlarpKeychainStorage(service: "com.aurel.ci.keychain-probe.\(UUID().uuidString)")
        var report: [String: Any] = ["passed": false, "contains_real_credentials": false]
        defer { try? storage.delete() }
        do {
            guard try storage.load() == nil else { throw LicenseFailure.storage }
            let first = Data("synthetic-first".utf8), second = Data("synthetic-second".utf8)
            try storage.save(first)
            guard try storage.load() == first else { throw LicenseFailure.storage }
            try storage.save(second)
            let reopened = ZlarpKeychainStorage(service: storage.service)
            guard try reopened.load() == second else { throw LicenseFailure.storage }
            try reopened.delete()
            guard try storage.load() == nil else { throw LicenseFailure.storage }
            let service = ZlarpLicenseService(storage: storage, configuration: .zlarp)
            guard service.status["reason"] as? String == "activation_required" else {
                throw LicenseFailure.storage
            }
            let restored = ZlarpLicenseService(storage: reopened, configuration: .zlarp)
            guard restored.status["reason"] as? String == "activation_required" else {
                throw LicenseFailure.storage
            }
            report["passed"] = true
            report["operations"] = ["missing-load", "add", "load", "update", "reopen-load", "delete", "service-initialize", "service-reopen"]
        } catch let failure as LicenseStorageFailure {
            report["operation"] = failure.operation.rawValue
            report["osstatus"] = failure.status
            report["support_code"] = failure.supportCode
        } catch {
            report["failure"] = "synthetic_roundtrip_or_record_validation_failed"
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let output = directory.appendingPathComponent("keychain-probe.json")
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output, options: .atomic)
        }
        return true
    }
}

@main
enum KeychainProbe {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(KeychainProbeDelegate.self))
    }
}
