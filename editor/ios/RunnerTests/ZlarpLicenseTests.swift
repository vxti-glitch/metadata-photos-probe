import Foundation
import XCTest
import CryptoKit
@testable import Runner

private final class MemoryLicenseStorage: ZlarpLicenseStorage {
    var data: Data?
    var fails = false
    func load() throws -> Data? { if fails { throw LicenseFailure.storage }; return data }
    func save(_ data: Data) throws { if fails { throw LicenseFailure.storage }; self.data = data }
    func delete() throws { data = nil }
}

@MainActor
final class ZlarpLicenseTests: XCTestCase {
    func testRealKeychainRoundTripAndServiceRecordReopen() throws {
        // Exercise the real Security API in a synthetic namespace. A missing
        // simulator entitlement must fail here instead of hiding behind a mock.
        let storage = ZlarpKeychainStorage(service: "com.aurel.ci.storage-test.\(UUID().uuidString)")
        defer { try? storage.delete() }
        XCTAssertNil(try storage.load())
        let first = Data("synthetic-first".utf8), second = Data("synthetic-second".utf8)
        try storage.save(first)
        XCTAssertEqual(try storage.load(), first)
        try storage.save(second)
        let reopened = ZlarpKeychainStorage(service: storage.service)
        XCTAssertEqual(try reopened.load(), second)
        try reopened.delete()
        XCTAssertNil(try storage.load())
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp)
        XCTAssertEqual(service.status["reason"] as? String, "activation_required")
        let record = try XCTUnwrap(storage.load())
        let restored = ZlarpLicenseService(storage: reopened, configuration: .zlarp)
        XCTAssertEqual(restored.status["reason"] as? String, "activation_required")
        XCTAssertEqual(try reopened.load(), record)
        XCTAssertFalse(service.allowsAccess)
        XCTAssertFalse(restored.allowsAccess)
        try reopened.delete()
        XCTAssertNil(try reopened.load())
    }

    func testStorageSupportCodeContainsOnlyOperationAndOSStatus() throws {
        final class FailingStorage: ZlarpLicenseStorage {
            func load() throws -> Data? { throw LicenseStorageFailure(operation: .load, status: -34018) }
            func save(_ data: Data) throws { XCTFail("Must not write after failed load") }
            func delete() throws { XCTFail("Must not delete after failed load") }
        }
        let service = ZlarpLicenseService(storage: FailingStorage(), configuration: .zlarp)
        let state = service.status
        XCTAssertFalse(service.allowsAccess)
        XCTAssertEqual(state["reason"] as? String, "secure_storage_unavailable")
        XCTAssertEqual(state["storageSupportCode"] as? String, "KC-load:-34018")
        XCTAssertNil(state["key"]); XCTAssertNil(state["token"]); XCTAssertNil(state["device"])
        XCTAssertEqual(Set(state.keys), Set(["allowed", "providerName", "reason", "storageSupportCode"]))
    }

    private let clock = Date(timeIntervalSince1970: 2_000_000_000)
    private func response(_ status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: ZlarpLicenseConfiguration.endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
    private func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func lease(_ request: URLRequest, signing: Curve25519.Signing.PrivateKey,
                       change: ([String: Any]) -> [String: Any] = { $0 }, algorithm: String = "EdDSA") throws -> Data {
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let header = encode(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "typ": "JWT"]))
        let claims = change(["iss": "zlarp", "aud": "metadata-editor", "ent": "active",
                             "dev": sent["device"]!, "nonce": sent["nonce"]!,
                             "exp": clock.timeIntervalSince1970 + 3600])
        let payload = encode(try JSONSerialization.data(withJSONObject: claims))
        let body = "\(header).\(payload)"
        let token = "\(body).\(encode(try signing.signature(for: Data(body.utf8))))"
        return try JSONSerialization.data(withJSONObject: ["ok": true, "token": token, "expires_at": clock.timeIntervalSince1970 + 3600])
    }

    func testValidSignatureActivatesAndRequestContainsOnlyLicenseBindingFields() async throws {
        let signing = Curve25519.Signing.PrivateKey()
        let storage = MemoryLicenseStorage()
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            XCTAssertEqual(request.url, ZlarpLicenseConfiguration.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(sent.keys), Set(["key", "app", "device", "nonce"]))
            XCTAssertEqual(sent["key"] as? String, "test-key")
            XCTAssertEqual(sent["app"] as? String, "metadata-editor")
            return (try self.lease(request, signing: signing), self.response())
        }
        let state = await service.refresh(key: "test-key")
        XCTAssertEqual(state["allowed"] as? Bool, true)
        XCTAssertEqual(state["reason"] as? String, "active")
        XCTAssertTrue(service.allowsAccess)
        XCTAssertNil(state["key"]); XCTAssertNil(state["token"]); XCTAssertNil(state["device"])
    }

    func testWrongSignatureCannotActivate() async throws {
        let pinned = Curve25519.Signing.PrivateKey(), impostor = Curve25519.Signing.PrivateKey()
        let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: .zlarp, now: { self.clock }, publicKey: pinned.publicKey.rawRepresentation) {
            (try self.lease($0, signing: impostor), self.response())
        }
        _ = await service.refresh(key: "test-key")
        XCTAssertFalse(service.allowsAccess)
        XCTAssertEqual(service.status["reason"] as? String, "verification_failed")
    }

    func testEveryRequiredClaimIsValidatedIncludingBooleanExpiry() async throws {
        let signing = Curve25519.Signing.PrivateKey()
        let changes: [(String, Any)] = [("iss", "other"), ("aud", "other"), ("ent", "inactive"),
                                        ("dev", UUID().uuidString), ("nonce", "replay"),
                                        ("exp", clock.timeIntervalSince1970), ("exp", true),
                                        ("nbf", true), ("nbf", "tomorrow"), ("nbf", clock.timeIntervalSince1970 + 10)]
        for (field, value) in changes {
            let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
                (try self.lease(request, signing: signing, change: { original in
                    var changed = original; changed[field] = value; return changed
                }), self.response())
            }
            _ = await service.refresh(key: "test-key")
            XCTAssertFalse(service.allowsAccess, "Accepted invalid claim \(field)")
        }
    }

    func testWrongAlgorithmAndMalformedResponseFailClosed() async throws {
        let signing = Curve25519.Signing.PrivateKey()
        for malformed in [false, true] {
            let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
                let data = malformed ? Data("not-json".utf8) : (try self.lease(request, signing: signing, algorithm: "none"))
                return (data, self.response())
            }
            _ = await service.refresh(key: "test-key")
            XCTAssertFalse(service.allowsAccess)
        }
    }

    func testAuthenticCachePermitsOfflineUseOnlyUntilExpiry() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) {
            (try self.lease($0, signing: signing), self.response())
        }
        _ = await service.refresh(key: "test-key")
        var time = clock
        let offline = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { time }, publicKey: signing.publicKey.rawRepresentation) { _ in
            throw URLError(.notConnectedToInternet)
        }
        _ = await offline.refresh()
        XCTAssertTrue(offline.allowsAccess)
        XCTAssertEqual(offline.status["reason"] as? String, "offline")
        time = clock.addingTimeInterval(3600)
        XCTAssertFalse(offline.allowsAccess)
        XCTAssertEqual(offline.status["reason"] as? String, "expired")
    }

    func testRefusalRevokesCacheAndPersistsAcrossLaunches() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        var refuse = false
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            if refuse { return (Data("{\"reason\":\"device_limit\"}".utf8), self.response(403)) }
            return (try self.lease(request, signing: signing), self.response())
        }
        _ = await service.refresh(key: "test-key")
        refuse = true
        _ = await service.refresh()
        XCTAssertFalse(service.allowsAccess)
        XCTAssertEqual(service.status["reason"] as? String, "device_limit")
        let recovered = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation)
        XCTAssertFalse(recovered.allowsAccess)
    }

    func testNewAccountCannotReuseOldAccountsCachedLeaseOnConnectionFailure() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        var offline = false
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            if offline { throw URLError(.notConnectedToInternet) }
            return (try self.lease(request, signing: signing), self.response())
        }
        _ = await service.refresh(key: "first-key")
        offline = true
        _ = await service.refresh(key: "different-key")
        XCTAssertFalse(service.allowsAccess)
    }

    func testRateLimitUsesValidCacheAndBackoffWithoutCallingTransportAgain() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        var calls = 0
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            calls += 1
            if calls == 1 { return (try self.lease(request, signing: signing), self.response()) }
            return (Data(), self.response(429, headers: ["Retry-After": "120"]))
        }
        _ = await service.refresh(key: "test-key")
        _ = await service.refresh()
        XCTAssertTrue(service.allowsAccess)
        XCTAssertEqual(service.status["retryAfterSeconds"] as? Double, 120)
        _ = await service.refresh()
        XCTAssertEqual(calls, 2)
        _ = await service.refresh(key: "test-key")
        XCTAssertEqual(calls, 2, "Typing the same key must not bypass Retry-After")
        _ = await service.refresh(key: "another-key")
        XCTAssertEqual(calls, 2, "Changing accounts must not bypass Retry-After")
        XCTAssertFalse(service.allowsAccess)
        _ = service.clear()
        _ = await service.refresh(key: "third-key")
        XCTAssertEqual(calls, 2, "Clearing the key must not bypass Retry-After")
    }

    func testMalformedOnlineResponseInvalidatesPreviouslyGoodCache() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        var malformed = false
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            let data = malformed ? Data("{}".utf8) : (try self.lease(request, signing: signing))
            return (data, self.response())
        }
        _ = await service.refresh(key: "test-key")
        malformed = true
        _ = await service.refresh()
        XCTAssertFalse(service.allowsAccess)
    }

    func testKeychainFailuresFailClosedAndClearRetainsStableDeviceIdentity() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        var devices: [String] = []
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            devices.append(try XCTUnwrap(body["device"] as? String))
            return (try self.lease(request, signing: signing), self.response())
        }
        _ = await service.refresh(key: "test-key")
        XCTAssertFalse((service.clear()["allowed"] as? Bool) ?? true)
        _ = await service.refresh(key: "next-key")
        XCTAssertEqual(devices.count, 2); XCTAssertEqual(devices.first, devices.last)
        storage.fails = true
        _ = service.clear()
        XCTAssertFalse(service.allowsAccess)
        XCTAssertEqual(service.status["reason"] as? String, "secure_storage_unavailable")
        let locked = ZlarpLicenseService(storage: storage, configuration: .zlarp)
        XCTAssertFalse(locked.allowsAccess)
    }

    func testClockRollbackDoesNotExtendAnOfflineLease() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        var time = clock
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { time }, publicKey: signing.publicKey.rawRepresentation) {
            (try self.lease($0, signing: signing), self.response())
        }
        _ = await service.refresh(key: "test-key")
        time = clock.addingTimeInterval(1200)
        XCTAssertTrue(service.allowsAccess)
        time = clock
        XCTAssertFalse(service.allowsAccess)
        let recovered = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { time }, publicKey: signing.publicKey.rawRepresentation)
        XCTAssertFalse(recovered.allowsAccess)
    }

    func testClearDuringInFlightVerificationCannotReactivateTheAccount() async throws {
        let signing = Curve25519.Signing.PrivateKey()
        var pending: CheckedContinuation<Void, Never>?
        let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            await withCheckedContinuation { pending = $0 }
            return (try self.lease(request, signing: signing), self.response())
        }
        let request = Task { await service.refresh(key: "old-key") }
        while pending == nil { await Task.yield() }
        _ = service.clear()
        pending?.resume()
        _ = await request.value
        XCTAssertFalse(service.allowsAccess)
    }

    func testConcurrentNewKeyDoesNotExposeTheOldAccount() async throws {
        let signing = Curve25519.Signing.PrivateKey()
        var pending: CheckedContinuation<Void, Never>?
        var wait = false
        let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            if wait { await withCheckedContinuation { pending = $0 } }
            return (try self.lease(request, signing: signing), self.response())
        }
        _ = await service.refresh(key: "old-key")
        wait = true
        let request = Task { await service.refresh() }
        while pending == nil { await Task.yield() }
        let newState = await service.refresh(key: "new-key")
        XCTAssertEqual(newState["allowed"] as? Bool, false)
        pending?.resume()
        _ = await request.value
        XCTAssertFalse(service.allowsAccess)
    }

    func testServiceUnavailableCannotGrantAccessWithoutAnAuthenticCache() async throws {
        let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: .zlarp, now: { self.clock }) { _ in
            (Data(), self.response(503))
        }
        let state = await service.refresh(key: "test-key")
        XCTAssertEqual(state["allowed"] as? Bool, false)
        XCTAssertEqual(state["reason"] as? String, "temporarily_unavailable")
    }

    func testMalformedKeychainRecordNeverAllowsAccess() {
        let storage = MemoryLicenseStorage()
        storage.data = Data("{\"device\":\"not-a-uuid\",\"key\":\"test-key\",\"token\":\"forged\"}".utf8)
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp)
        XCTAssertFalse(service.allowsAccess)
        XCTAssertEqual(service.status["reason"] as? String, "secure_storage_unavailable")
    }

    func testTLSFailureIsNotTreatedAsOfflineGrace() async throws {
        let signing = Curve25519.Signing.PrivateKey(), storage = MemoryLicenseStorage()
        var fail = false
        let service = ZlarpLicenseService(storage: storage, configuration: .zlarp, now: { self.clock }, publicKey: signing.publicKey.rawRepresentation) { request in
            if fail { throw URLError(.serverCertificateUntrusted) }
            return (try self.lease(request, signing: signing), self.response())
        }
        _ = await service.refresh(key: "test-key")
        fail = true
        _ = await service.refresh()
        XCTAssertFalse(service.allowsAccess)
    }
    private func aurel(_ publicKey: Data, issuer: String = "aurel-archive-test") throws -> LicenseProviderConfiguration {
        try LicenseProviderConfiguration.resolve([
            "AurelLicenseEndpoint": "https://puxccjoofzlgxkssmfva.supabase.co/functions/v1/aurel-licenses/verify",
            "AurelLicenseIssuer": issuer, "AurelLicensePublicKey": publicKey.base64EncodedString()])
    }
    func testProviderSelectionAndInvalidConfiguration() throws {
        XCTAssertEqual(try LicenseProviderConfiguration.resolve([:]).issuer, "zlarp")
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let configured = try aurel(key)
        XCTAssertEqual(configured.providerName, "Aurel Archive")
        XCTAssertNotEqual(configured.keychainService, LicenseProviderConfiguration.zlarp.keychainService)
        XCTAssertThrowsError(try aurel(key, issuer: "aurel-archive"))
        let invalid: [[String: Any]] = [
            ["AurelLicenseIssuer": "aurel-archive-test"], ["AurelLicenseEndpoint": ""],
            ["AurelLicenseEndpoint": "https://evil.invalid/verify", "AurelLicenseIssuer": "aurel-archive-test", "AurelLicensePublicKey": key.base64EncodedString()],
            ["AurelLicenseEndpoint": configured.endpoint.absoluteString, "AurelLicenseIssuer": "zlarp", "AurelLicensePublicKey": key.base64EncodedString()],
            ["AurelLicenseEndpoint": configured.endpoint.absoluteString, "AurelLicenseIssuer": "aurel-archive-test", "AurelLicensePublicKey": Data([1, 2]).base64EncodedString()]]
        for info in invalid { XCTAssertThrowsError(try LicenseProviderConfiguration.resolve(info)) }
    }
    func testInvalidProviderNeverCallsTransportOrLoadsExistingCache() async {
        let storage = MemoryLicenseStorage(); storage.data = Data("existing".utf8)
        var calls = 0
        let service = ZlarpLicenseService(storage: storage, configuration: nil) { _ in
            calls += 1; return (Data(), self.response())
        }
        let state = await service.refresh(key: "key")
        XCTAssertEqual(state["reason"] as? String, "configuration_invalid")
        XCTAssertFalse(service.allowsAccess); XCTAssertEqual(calls, 0)
        XCTAssertEqual(storage.data, Data("existing".utf8))
    }
    func testAurelRequiresItsIssuerEnvironmentDeviceNonceAndPin() async throws {
        let signing = Curve25519.Signing.PrivateKey()
        let configuration = try aurel(signing.publicKey.rawRepresentation)
        let invalid: [(String, Any)] = [("iss", "zlarp"), ("iss", "aurel-archive"), ("env", "live"),
            ("dev", UUID().uuidString), ("nonce", "replayed"), ("aud", "other")]
        let changes: [(String, Any)?] = [nil] + invalid.map { Optional($0) }
        for change in changes {
            let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: configuration, now: { self.clock }) { request in
                XCTAssertEqual(request.url, configuration.endpoint)
                return (try self.lease(request, signing: signing, change: { original in
                    var claims = original; claims["iss"] = "aurel-archive-test"; claims["env"] = "test"
                    if let change { claims[change.0] = change.1 }; return claims
                }), self.response())
            }
            _ = await service.refresh(key: "AUREL-TEST-key")
            XCTAssertEqual(service.allowsAccess, change.map { _ in false } ?? true)
            XCTAssertEqual(service.status["providerName"] as? String, "Aurel Archive")
        }
        let wrong = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: configuration, now: { self.clock }) { request in
            (try self.lease(request, signing: Curve25519.Signing.PrivateKey(), change: { original in
                var claims = original; claims["iss"] = "aurel-archive-test"; claims["env"] = "test"; return claims
            }), self.response())
        }
        _ = await wrong.refresh(key: "AUREL-TEST-key"); XCTAssertFalse(wrong.allowsAccess)
    }

    private func aurelLive(_ publicKey: Data) throws -> LicenseProviderConfiguration {
        try LicenseProviderConfiguration.resolve([
            "AurelLicenseEndpoint": "https://puxccjoofzlgxkssmfva.supabase.co/functions/v1/aurel-licenses-live/verify",
            "AurelLicenseIssuer": "aurel-archive-live", "AurelLicenseEnvironment": "live",
            "AurelLicensePublicKey": publicKey.base64EncodedString()])
    }

    func testLiveConfigurationIsExplicitAndSeparatesKeychainFromTestAndZlarp() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let live = try aurelLive(key), test = try aurel(key)
        XCTAssertEqual(live.environment, "live")
        XCTAssertEqual(live.issuer, "aurel-archive-live")
        XCTAssertEqual(live.keychainService, "com.vxtiglitch.metadataeditor.aurel.live")
        XCTAssertNotEqual(live.keychainService, test.keychainService)
        XCTAssertNotEqual(live.keychainService, LicenseProviderConfiguration.zlarp.keychainService)
        let base: [String: Any] = ["AurelLicenseEndpoint": live.endpoint.absoluteString,
            "AurelLicenseIssuer": live.issuer, "AurelLicenseEnvironment": "live",
            "AurelLicensePublicKey": key.base64EncodedString()]
        let invalidChanges: [(String, Any?)] = [
            ("AurelLicenseEnvironment", nil), ("AurelLicenseEnvironment", "test"),
            ("AurelLicenseIssuer", "aurel-archive-test"),
            ("AurelLicenseEndpoint", test.endpoint.absoluteString),
            ("AurelLicensePublicKey", ""),
            ("AurelLicensePublicKey", Data(repeating: 0, count: 32).base64EncodedString()),
            ("AurelLicensePublicKey", "r3CMZr6wV0FOjcIZ35lSABdfsZ7k2TOZr9ubg8Qqvg8=")]
        for (name, value) in invalidChanges {
            var info = base; info[name] = value
            XCTAssertThrowsError(try LicenseProviderConfiguration.resolve(info), "Accepted mixed live field \(name)")
        }
        XCTAssertThrowsError(try LicenseProviderConfiguration.resolve(["AurelLicenseEnvironment": "live"]))
        XCTAssertThrowsError(try LicenseProviderConfiguration.resolve([
            "AurelLicenseEndpoint": test.endpoint.absoluteString, "AurelLicenseIssuer": test.issuer,
            "AurelLicensePublicKey": key.base64EncodedString(), "AurelLicenseEnvironment": "live"]))
    }

    func testLiveRejectsNonLiveKeysBeforeTransportAndKeepsTestKeyBehavior() async throws {
        let signing = Curve25519.Signing.PrivateKey(), configuration = try aurelLive(signing.publicKey.rawRepresentation)
        for key in ["test-key", "AAT1." + UUID().uuidString + "." + String(repeating: "a", count: 64),
                    "AAL1.invalid." + String(repeating: "a", count: 64), "AAL1." + UUID().uuidString + ".short"] {
            var calls = 0
            let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: configuration, now: { self.clock }) { _ in
                calls += 1; return (Data(), self.response())
            }
            let state = await service.refresh(key: key)
            XCTAssertEqual(state["reason"] as? String, "invalid_key")
            XCTAssertFalse(service.allowsAccess); XCTAssertEqual(calls, 0)
        }
    }

    func testLiveLeaseRequiresLiveIssuerEnvironmentAndSignature() async throws {
        let signing = Curve25519.Signing.PrivateKey(), configuration = try aurelLive(signing.publicKey.rawRepresentation)
        let liveKey = "AAL1." + UUID().uuidString + "." + String(repeating: "a", count: 64)
        let invalid: [(String, Any)?] = [nil, ("iss", "aurel-archive-test"), ("env", "test"),
            ("iss", "zlarp"), ("aud", "other"), ("nonce", "replayed"), ("dev", UUID().uuidString)]
        for change in invalid {
            let service = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: configuration, now: { self.clock }) { request in
                XCTAssertEqual(request.url, configuration.endpoint)
                return (try self.lease(request, signing: signing, change: { original in
                    var claims = original; claims["iss"] = "aurel-archive-live"; claims["env"] = "live"
                    if let change { claims[change.0] = change.1 }; return claims
                }), self.response())
            }
            _ = await service.refresh(key: liveKey)
            XCTAssertEqual(service.allowsAccess, change.map { _ in false } ?? true)
        }
        let wrongPin = ZlarpLicenseService(storage: MemoryLicenseStorage(), configuration: configuration, now: { self.clock }) { request in
            (try self.lease(request, signing: Curve25519.Signing.PrivateKey(), change: { original in
                var claims = original; claims["iss"] = "aurel-archive-live"; claims["env"] = "live"; return claims
            }), self.response())
        }
        _ = await wrongPin.refresh(key: liveKey)
        XCTAssertFalse(wrongPin.allowsAccess)
    }

}
