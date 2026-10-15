import Foundation
import CryptoKit
import Security
import CoreFoundation

enum ZlarpLicenseConfiguration {
    static let app = "metadata-editor"
    static let endpoint = URL(string: "https://zlarp.com/api/license/verify")!
    // Pinned Zlarp Ed25519 public key; this is public verification material.
    static let publicKey = Data(base64Encoded: "V/bkaVCVHW97GQW9ACZIcOh0MJTBx+qY56gpYenjkyk=")!
}

protocol ZlarpLicenseStorage {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

struct ZlarpKeychainStorage: ZlarpLicenseStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.vxtiglitch.metadataeditor.zlarp",
         kSecAttrAccount as String: "license-v1",
         kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(lookup as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw LicenseFailure.storage }
        return data
    }
    func save(_ data: Data) throws {
        let code = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LicenseFailure.storage }
        } else if code != errSecSuccess { throw LicenseFailure.storage }
    }
    func delete() throws {
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw LicenseFailure.storage }
    }
}

enum LicenseFailure: Error { case storage, invalidToken, invalidResponse }

private final class ZlarpNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// No credential or token is exposed through the Flutter status dictionary.
@MainActor
final class ZlarpLicenseService {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let shared = ZlarpLicenseService()
    private struct Record: Codable {
        var device: String
        var key: String?
        var token: String?
        var nonce: String?
        var lastSeen: Double?
    }
    private let storage: ZlarpLicenseStorage
    private let transport: Transport
    private let now: () -> Date
    private let publicKey: Data
    private var record: Record?
    private var reason = "activation_required"
    private var retryUntil: Date?
    private var refreshing = false
    private var generation = UUID()

    init(storage: ZlarpLicenseStorage = ZlarpKeychainStorage(),
         now: @escaping () -> Date = Date.init,
         publicKey: Data = ZlarpLicenseConfiguration.publicKey,
         transport: @escaping Transport = { request in
             let session = URLSession(configuration: .ephemeral, delegate: ZlarpNoRedirectDelegate(), delegateQueue: nil)
             defer { session.invalidateAndCancel() }
             let (data, response) = try await session.data(for: request)
             guard let http = response as? HTTPURLResponse else { throw LicenseFailure.invalidResponse }
             return (data, http)
         }) {
        self.storage = storage; self.now = now; self.publicKey = publicKey; self.transport = transport
        do {
            if let data = try storage.load() {
                record = try JSONDecoder().decode(Record.self, from: data)
                guard let device = record?.device, UUID(uuidString: device) != nil else { throw LicenseFailure.storage }
            } else {
                record = Record(device: UUID().uuidString, lastSeen: now().timeIntervalSince1970)
                try persist()
            }
        } catch { record = nil; reason = "secure_storage_unavailable" }
    }

    var allowsAccess: Bool { validExpiry() != nil }
    var status: [String: Any] {
        let expiry = validExpiry()
        var result: [String: Any] = ["allowed": expiry != nil,
                                    "reason": expiry != nil ? (reason == "offline" ? "offline" : "active") :
                                        (record?.token != nil ? "expired" : reason)]
        if let expiry { result["expiresAt"] = expiry }
        if let retryUntil { result["retryAfterSeconds"] = max(0, retryUntil.timeIntervalSince(now())) }
        return result
    }

    func clear() -> [String: Any] {
        generation = UUID()
        // Keep the stable per-install device identity across account changes.
        record?.key = nil; record?.token = nil; record?.nonce = nil
        reason = "activation_required"
        do { try persist() } catch { record = nil; reason = "secure_storage_unavailable" }
        return status
    }

    func refresh(key: String? = nil) async -> [String: Any] {
        guard !refreshing else {
            if key != nil {
                _ = clear()
                reason = "verification_in_progress"
            }
            return status
        }
        guard record != nil else { reason = "secure_storage_unavailable"; return status }
        if let key {
            let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.utf8.count <= 256 else { _ = clear(); reason = "invalid_key"; return status }
            if clean != record?.key {
                // Invalidate the previous account before submitting another key.
                // Server backoff applies to this client even when the key changes.
                generation = UUID()
                record?.key = clean; record?.token = nil; record?.nonce = nil
                do { try persist() } catch { record = nil; reason = "secure_storage_unavailable"; return status }
            }
        }
        guard let key = record?.key, let device = record?.device else { reason = "activation_required"; return status }
        if let retryUntil, retryUntil > now() { return status }
        refreshing = true
        defer { refreshing = false }
        let current = generation
        let nonce = UUID().uuidString
        var request = URLRequest(url: ZlarpLicenseConfiguration.endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key, "app": ZlarpLicenseConfiguration.app, "device": device, "nonce": nonce])
        do {
            let (data, response) = try await transport(request)
            guard current == generation else { return status }
            if response.statusCode == 429 || response.statusCode == 503 {
                let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                retryUntil = now().addingTimeInterval(min(max(delay, 1), 3600))
                reason = allowsAccess ? "offline" : "temporarily_unavailable"
                return status
            }
            guard response.statusCode == 200 else {
                let body = data.count <= 65536 ? (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) : nil
                let reported = body?["reason"] as? String
                let refusalReasons = ["invalid_key", "not_entitled", "device_limit", "unavailable"]
                try invalidate(reason: response.statusCode == 403 && refusalReasons.contains(reported ?? "") ? reported! : "verification_failed")
                return status
            }
            guard data.count <= 65536,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = json["ok"] as? Bool, ok,
                  let token = json["token"] as? String else { throw LicenseFailure.invalidResponse }
            _ = try verify(token: token, device: device, nonce: nonce)
            record?.token = token; record?.nonce = nonce
            let lastSeen = max(record?.lastSeen ?? 0, now().timeIntervalSince1970)
            record?.lastSeen = lastSeen
            try persist()
            reason = "active"; retryUntil = nil
        } catch let error as URLError {
            guard current == generation else { return status }
            // Only connectivity errors permit a still-authentic, unexpired lease.
            let connectivity: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                                .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                                .internationalRoamingOff, .dataNotAllowed]
            if connectivity.contains(error.code) {
                retryUntil = now().addingTimeInterval(30)
                reason = allowsAccess ? "offline" : "connection_required"
            } else { try? invalidate(reason: "verification_failed") }
        } catch {
            guard current == generation else { return status }
            do { try invalidate(reason: "verification_failed") }
            catch { record = nil; reason = "secure_storage_unavailable" }
        }
        return status
    }

    private func persist() throws {
        guard let record else { throw LicenseFailure.storage }
        try storage.save(JSONEncoder().encode(record))
    }
    private func invalidate(reason: String) throws {
        record?.token = nil; record?.nonce = nil; self.reason = reason
        do { try persist() } catch { record = nil; self.reason = "secure_storage_unavailable"; throw error }
    }
    private func validExpiry() -> Double? {
        guard let saved = record, saved.key != nil, let token = saved.token, let nonce = saved.nonce else { return nil }
        let instant = now().timeIntervalSince1970
        guard instant >= (saved.lastSeen ?? instant) - 5,
              let expiry = try? verify(token: token, device: saved.device, nonce: nonce) else { return nil }
        if instant - (saved.lastSeen ?? 0) >= 60 {
            record?.lastSeen = instant
            do { try persist() } catch { record = nil; reason = "secure_storage_unavailable"; return nil }
        }
        return expiry
    }
    private func verify(token: String, device: String, nonce: String) throws -> Double {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count <= 32768,
              let headerData = Self.decode(String(parts[0])), let claimsData = Self.decode(String(parts[1])),
              let signature = Self.decode(String(parts[2])), signature.count == 64,
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "EdDSA", header["crit"] == nil,
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              claims["iss"] as? String == "zlarp", claims["aud"] as? String == ZlarpLicenseConfiguration.app,
              claims["dev"] as? String == device, claims["nonce"] as? String == nonce,
              claims["ent"] as? String == "active",
              let exp = claims["exp"] as? NSNumber, CFGetTypeID(exp) != CFBooleanGetTypeID(),
              exp.doubleValue.isFinite, exp.doubleValue > now().timeIntervalSince1970 else { throw LicenseFailure.invalidToken }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)) else { throw LicenseFailure.invalidToken }
        if let raw = claims["nbf"] {
            guard let nbf = raw as? NSNumber, CFGetTypeID(nbf) != CFBooleanGetTypeID(),
                  nbf.doubleValue.isFinite, nbf.doubleValue <= now().timeIntervalSince1970 else { throw LicenseFailure.invalidToken }
        }
        return exp.doubleValue
    }
    private static func decode(_ value: String) -> Data? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}
