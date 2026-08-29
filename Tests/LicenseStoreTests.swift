import Testing
import Foundation
@testable import ClaudeBarUI

/// Covers the ClaudeBar Pro entitlement logic: activation, authoritative
/// revocation, and the offline-grace window. The tricky, money-sensitive parts
/// are (a) a real refund/expiry must lock immediately, and (b) a mere network
/// blip must never lock a paying user inside the grace window.
@Suite(.serialized)
@MainActor
struct LicenseStoreTests {

    /// A mutable in-memory keychain that actually round-trips save→retrieve→delete.
    final class MemoryKeychain: KeychainServicing, @unchecked Sendable {
        var values: [String: String] = [:]
        func save(account: String, value: String) throws { values[account] = value }
        func retrieve(account: String) throws -> String? { values[account] }
        func delete(account: String) throws { values[account] = nil }
    }

    /// A scriptable license service. Each closure decides the response (or throws).
    struct MockService: LicenseServicing {
        var onActivate: @Sendable (String, String) async throws -> LicenseActivation
        var onValidate: @Sendable (String, String) async throws -> LicenseValidation
        var onDeactivate: @Sendable (String, String) async throws -> Bool = { _, _ in true }

        func activate(key: String, instanceName: String) async throws -> LicenseActivation {
            try await onActivate(key, instanceName)
        }
        func validate(key: String, instanceId: String) async throws -> LicenseValidation {
            try await onValidate(key, instanceId)
        }
        func deactivate(key: String, instanceId: String) async throws -> Bool {
            try await onDeactivate(key, instanceId)
        }
    }

    private func makeStore(
        service: MockService,
        keychain: MemoryKeychain = MemoryKeychain(),
        graceWindow: TimeInterval = 14 * 24 * 60 * 60
    ) -> LicenseStore {
        LicenseStore(service: service, keychain: keychain, account: "pro_license", graceWindow: graceWindow)
    }

    private var okActivation: MockService {
        MockService(
            onActivate: { _, _ in LicenseActivation(activated: true, instanceId: "inst-1", status: "active", error: nil) },
            onValidate: { _, _ in LicenseValidation(valid: true, status: "active", expiresAt: nil, error: nil) }
        )
    }

    // MARK: - Activation

    @Test func activateSuccessUnlocksPro() async {
        let store = makeStore(service: okActivation)
        await store.activate(key: "GOOD-KEY", instanceName: "Mac")
        #expect(store.isPro)
        #expect(store.message == nil)
    }

    @Test func activateRejectedKeyStaysLocked() async {
        let svc = MockService(
            onActivate: { _, _ in LicenseActivation(activated: false, instanceId: nil, status: nil, error: "This license key has reached the activation limit.") },
            onValidate: { _, _ in LicenseValidation(valid: false, status: nil, expiresAt: nil, error: nil) }
        )
        let store = makeStore(service: svc)
        await store.activate(key: "OVERUSED", instanceName: "Mac")
        #expect(store.isPro == false)
        #expect(store.message == "This license key has reached the activation limit.")
    }

    @Test func activateEmptyKeyIsRejectedWithoutNetwork() async {
        let store = makeStore(service: okActivation)
        await store.activate(key: "   ", instanceName: "Mac")
        #expect(store.isPro == false)
        #expect(store.message == "Enter your license key.")
    }

    // MARK: - Authoritative revocation (refund / expiry) must lock now

    @Test func refreshRevokedLicenseLocksImmediately() async {
        let keychain = MemoryKeychain()
        // First activate so a key is stored.
        let store = makeStore(service: okActivation, keychain: keychain)
        await store.activate(key: "GOOD-KEY", instanceName: "Mac")
        #expect(store.isPro)

        // Now the server says the key was disabled (a refund). Re-validate.
        let revoking = makeStore(
            service: MockService(
                onActivate: { _, _ in LicenseActivation(activated: false, instanceId: nil, status: nil, error: nil) },
                onValidate: { _, _ in LicenseValidation(valid: false, status: "disabled", expiresAt: nil, error: "License disabled.") }
            ),
            keychain: keychain
        )
        await revoking.refresh()
        #expect(revoking.isPro == false)
        #expect(revoking.isInGrace == false)
        #expect(keychain.values["pro_license"] == nil) // cleared on revocation
    }

    @Test func refreshExpiredLicenseLocks() async {
        let keychain = MemoryKeychain()
        let store = makeStore(service: okActivation, keychain: keychain)
        await store.activate(key: "GOOD-KEY", instanceName: "Mac")

        let expiring = makeStore(
            service: MockService(
                onActivate: { _, _ in LicenseActivation(activated: false, instanceId: nil, status: nil, error: nil) },
                onValidate: { _, _ in LicenseValidation(valid: true, status: "expired", expiresAt: Date(timeIntervalSinceNow: -60), error: nil) }
            ),
            keychain: keychain
        )
        await expiring.refresh()
        #expect(expiring.isPro == false)
    }

    // MARK: - Offline grace: a network blip must not lock a paying user

    @Test func refreshNetworkFailureWithinGraceStaysPro() async {
        let keychain = MemoryKeychain()
        let store = makeStore(service: okActivation, keychain: keychain)
        await store.activate(key: "GOOD-KEY", instanceName: "Mac") // lastValidated = now
        #expect(store.isPro)

        // Server unreachable now; last good validation was seconds ago → grace.
        let offline = makeStore(
            service: MockService(
                onActivate: { _, _ in LicenseActivation(activated: false, instanceId: nil, status: nil, error: nil) },
                onValidate: { _, _ in throw LicenseNetworkError(URLError(.notConnectedToInternet)) }
            ),
            keychain: keychain
        )
        await offline.refresh()
        #expect(offline.isPro)          // still unlocked
        #expect(offline.isInGrace)      // but flagged as grace
    }

    @Test func refreshNetworkFailurePastGraceLocks() async {
        let keychain = MemoryKeychain()
        // Seed a stored license whose last validation is 30 days ago, with a 14-day grace.
        let stale = ["key": "GOOD-KEY", "instanceId": "inst-1"]
        _ = stale
        let seed = LicenseStoreTestSeed(lastValidated: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60))
        keychain.values["pro_license"] = seed.json

        let offline = makeStore(
            service: MockService(
                onActivate: { _, _ in LicenseActivation(activated: false, instanceId: nil, status: nil, error: nil) },
                onValidate: { _, _ in throw LicenseNetworkError(URLError(.timedOut)) }
            ),
            keychain: keychain
        )
        await offline.refresh()
        #expect(offline.isPro == false)
        #expect(offline.message == "Reconnect to verify your Pro license.")
    }

    // MARK: - Deactivate frees the slot and locks

    @Test func deactivateLocksAndClearsStorage() async {
        let keychain = MemoryKeychain()
        let store = makeStore(service: okActivation, keychain: keychain)
        await store.activate(key: "GOOD-KEY", instanceName: "Mac")
        #expect(store.isPro)

        await store.deactivate()
        #expect(store.isPro == false)
        #expect(keychain.values["pro_license"] == nil)
    }

    // MARK: - grantsPro helper

    @Test func grantsProLogic() {
        #expect(LicenseValidation(valid: true, status: "active", expiresAt: nil, error: nil).grantsPro)
        #expect(LicenseValidation(valid: true, status: "active", expiresAt: Date(timeIntervalSinceNow: 3600), error: nil).grantsPro)
        #expect(!LicenseValidation(valid: true, status: "active", expiresAt: Date(timeIntervalSinceNow: -3600), error: nil).grantsPro)
        #expect(!LicenseValidation(valid: false, status: "active", expiresAt: nil, error: nil).grantsPro)
        #expect(!LicenseValidation(valid: true, status: "expired", expiresAt: nil, error: nil).grantsPro)
    }
}

/// Encodes a stored-license blob matching LicenseStore's private `Stored` shape,
/// so a test can seed a specific `lastValidated` without activating over the network.
private struct LicenseStoreTestSeed {
    let lastValidated: Date
    var json: String {
        let obj: [String: Any] = ["key": "GOOD-KEY", "instanceId": "inst-1",
                                   "lastValidated": lastValidated.timeIntervalSinceReferenceDate]
        // Match JSONEncoder's default Date strategy (secondsSinceReferenceDate as a Double).
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }
}
