import Foundation
import SwiftUI

/// Owns ClaudeBar Pro entitlement: persists the license in the Keychain, decides
/// unlock (with offline grace), and exposes `isPro` for feature gating.
///
/// Unlock rules (see the offline-grace design):
///  - a successful validate that says active → Pro, refresh `lastValidated`;
///  - a validate that REACHES the server and says invalid/expired/disabled
///    (e.g. a refund) → lock immediately, no grace;
///  - a validate that fails to REACH the network → keep Pro if the last good
///    validation was within `graceWindow`, else lock with a reconnect prompt.
@MainActor
@Observable
public final class LicenseStore {
    /// Whether Pro features are currently unlocked.
    public private(set) var isPro: Bool = false
    /// True while an activate/validate/deactivate call is in flight (for the UI).
    public private(set) var isWorking: Bool = false
    /// Last user-facing error (bad key, activation limit, reconnect prompt).
    public private(set) var message: String?
    /// True when unlocked only by offline grace (server unreachable) — the UI can nudge a reconnect.
    public private(set) var isInGrace: Bool = false

    private let service: any LicenseServicing
    private let keychain: any KeychainServicing
    private let account: String
    private let graceWindow: TimeInterval

    /// 14 days of offline grace: covers travel/planes without ever hard-failing on a blip.
    public init(
        service: any LicenseServicing = LicenseService(),
        keychain: any KeychainServicing = KeychainService(),
        account: String = "pro_license",
        graceWindow: TimeInterval = 14 * 24 * 60 * 60
    ) {
        self.service = service
        self.keychain = keychain
        self.account = account
        self.graceWindow = graceWindow
        loadAndReflect()
    }

    private struct Stored: Codable {
        var key: String
        var instanceId: String
        var lastValidated: Date
    }

    // MARK: - Public actions

    /// Activate a freshly-pasted key, then persist and unlock on success.
    public func activate(key: String, instanceName: String) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { message = "Enter your license key."; return }
        isWorking = true; defer { isWorking = false }
        do {
            let result = try await service.activate(key: key, instanceName: instanceName)
            guard result.activated, let instanceId = result.instanceId else {
                message = result.error ?? "Couldn't activate this key."
                return
            }
            persist(Stored(key: key, instanceId: instanceId, lastValidated: Date()))
            isPro = true; isInGrace = false; message = nil
        } catch is LicenseNetworkError {
            message = "Couldn't reach the license server. Check your connection and try again."
        } catch {
            message = "Activation failed. Please try again."
        }
    }

    /// Re-validate the stored key (call at launch and daily). Applies grace on a network failure.
    public func refresh() async {
        guard let stored = load() else { isPro = false; return }
        isWorking = true; defer { isWorking = false }
        do {
            let result = try await service.validate(key: stored.key, instanceId: stored.instanceId)
            if result.grantsPro {
                var updated = stored
                updated.lastValidated = Date()
                persist(updated)
                isPro = true; isInGrace = false; message = nil
            } else {
                // Authoritative revocation (expired/disabled/refunded): lock now.
                clear()
                isPro = false; isInGrace = false
                message = result.error ?? "Your Pro license is no longer active."
            }
        } catch is LicenseNetworkError {
            // Couldn't reach LS — grant grace if the last good check is recent enough.
            if Date().timeIntervalSince(stored.lastValidated) < graceWindow {
                isPro = true; isInGrace = true; message = nil
            } else {
                isPro = false; isInGrace = false
                message = "Reconnect to verify your Pro license."
            }
        } catch {
            // Parse-level oddity: fall back to grace rather than punish a paying user.
            isPro = Date().timeIntervalSince(stored.lastValidated) < graceWindow
            isInGrace = isPro
        }
    }

    /// Release this machine's activation slot and lock.
    public func deactivate() async {
        guard let stored = load() else { return }
        isWorking = true; defer { isWorking = false }
        _ = try? await service.deactivate(key: stored.key, instanceId: stored.instanceId)
        clear()
        isPro = false; isInGrace = false; message = nil
    }

    // MARK: - Persistence

    private func loadAndReflect() {
        guard let stored = load() else { isPro = false; return }
        // Trust the last good validation until `refresh()` runs; keeps launch instant/offline-safe.
        isPro = Date().timeIntervalSince(stored.lastValidated) < graceWindow
        isInGrace = false
    }

    private func load() -> Stored? {
        guard let raw = try? keychain.retrieve(account: account),
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return stored
    }

    private func persist(_ stored: Stored) {
        guard let data = try? JSONEncoder().encode(stored),
              let json = String(data: data, encoding: .utf8)
        else { return }
        try? keychain.save(account: account, value: json)
    }

    private func clear() {
        try? keychain.delete(account: account)
    }
}
