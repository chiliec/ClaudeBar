import SwiftUI

@MainActor
@Observable
public final class AppState {
    // MARK: - Auth State
    public var sessionKey: String?
    public var orgId: String?
    public var organizations: [Organization] = [] {
        didSet { orgListStore.save(organizations) }
    }
    public var isAuthenticated: Bool { sessionKey != nil && orgId != nil }

    /// Subset of `organizations` shown in switcher UIs. Hides free/individual
    /// orgs (no paid capability marker) since their usage is not tracked here.
    /// The currently-active org is always kept visible so the user can navigate
    /// out of it even if it happens to be unpaid.
    public var visibleOrganizations: [Organization] {
        organizations.filter { $0.isPaidPlan || $0.uuid == orgId }
    }

    /// Orgs offered when connecting/switching. Prefers paid/trackable orgs, but
    /// falls back to the full list when none carry a recognized paid capability —
    /// so a user is never stranded with no selectable org (e.g. if Claude.ai
    /// renames the capability markers `isPaidPlan` keys off of).
    public var selectableOrganizations: [Organization] {
        visibleOrganizations.isEmpty ? organizations : visibleOrganizations
    }

    // MARK: - Pending Key-Update State
    /// Set while the user is updating their session key and the new key
    /// belongs to a different account (current orgId is not in the new org list).
    /// While true, polling is paused and the Settings UI shows an inline picker.
    public var pendingOrgPick: Bool = false
    public var pendingSessionKey: String?
    public var pendingOrganizations: [Organization] = []

    // MARK: - Usage State
    public var usage: UsageResponse?
    public var organizationDetails: OrganizationDetails?
    public var lastUpdated: Date?
    public var isLoading = false
    public var error: AppError?

    // Platform (platform.claude.com) prepaid API credit balance — independent of
    // the claude.ai session. `platformSessionKey` is the host-only sessionKey
    // captured from platform.claude.com (NOT the claude.ai key).
    public var platformSessionKey: String?
    public var platformCredits: PlatformCredits?
    public var platformCreditsIsStale: Bool = false
    public var cachedPlatformOrgId: String?

    /// Authoritative tier from `/organizations/{id}` when available; falls
    /// back to a heuristic on the usage payload during the first-load window.
    public var tier: SubscriptionTier {
        if let details = organizationDetails { return details.tier }
        return (usage?.isMaxTier ?? false) ? .max5x : .pro
    }

    // MARK: - UI State
    public var showingSettings = false

    // MARK: - Services
    private let keychain: KeychainService
    private let orgListStore: OrgListStore
    private var pollTimer: Timer?
    public var pollInterval: TimeInterval = 300 // 5 minutes

    public init(
        keychain: KeychainService = KeychainService(),
        orgListStore: OrgListStore = UserDefaultsOrgListStore()
    ) {
        self.keychain = keychain
        self.orgListStore = orgListStore
        self.organizations = orgListStore.load()  // triggers didSet, harmless idempotent save
        loadCredentials()
        if isAuthenticated {
            // Defer polling start to next run loop to avoid publishing changes during init
            Task { @MainActor [weak self] in
                self?.startPolling()
            }
        }
    }

    // MARK: - Computed Display Values

    public var menuBarText: String {
        guard let usage else { return "—%" }
        let pct = Int((usage.fiveHour?.utilization ?? usage.sevenDay.utilization) * 100)
        return "\(pct)%"
    }

    public var menuBarUtilization: Double {
        usage?.fiveHour?.utilization ?? usage?.sevenDay.utilization ?? 0
    }

    public var usageColor: UsageColor {
        UsageColor.forUtilization(menuBarUtilization)
    }

    // MARK: - Lifecycle

    // Store both values in a single keychain item to avoid multiple password prompts on launch
    private static let credentialsAccount = "credentials"
    private static let credentialsSeparator: Character = "\0"
    private static let platformCredentialsAccount = "platform_credentials"

    public func loadCredentials() {
        guard let stored = try? keychain.retrieve(account: Self.credentialsAccount) else {
            // Even with no claude.ai credentials, a platform key may exist independently.
            platformSessionKey = try? keychain.retrieve(account: Self.platformCredentialsAccount)
            return
        }
        let parts = stored.split(separator: Self.credentialsSeparator, maxSplits: 1)
        guard parts.count == 2 else { return }
        sessionKey = String(parts[0])
        orgId = String(parts[1])
        platformSessionKey = try? keychain.retrieve(account: Self.platformCredentialsAccount)
    }

    public func saveCredentials(sessionKey: String, orgId: String) throws {
        let combined = "\(sessionKey)\(Self.credentialsSeparator)\(orgId)"
        try keychain.save(account: Self.credentialsAccount, value: combined)
        self.sessionKey = sessionKey
        self.orgId = orgId
    }

    public func signOut() {
        try? keychain.delete(account: Self.credentialsAccount)
        try? keychain.delete(account: Self.platformCredentialsAccount)
        sessionKey = nil
        orgId = nil
        usage = nil
        organizationDetails = nil
        organizations = []
        pendingSessionKey = nil
        pendingOrganizations = []
        pendingOrgPick = false
        platformSessionKey = nil
        platformCredits = nil
        platformCreditsIsStale = false
        cachedPlatformOrgId = nil
    }

    /// Non-destructive recovery: wipes sessionKey + usage but preserves
    /// orgId and cached organizations so the reconnect screen can name the org.
    func handleSessionExpired() {
        try? keychain.delete(account: Self.credentialsAccount)
        sessionKey = nil
        usage = nil
        organizationDetails = nil
        error = .sessionExpired
        // orgId and organizations: preserved
    }

    // MARK: - API Calls

    public func validateAndFetchOrgs(sessionKey: String) async {
        isLoading = true
        error = nil
        self.sessionKey = sessionKey
        do {
            organizations = try await ClaudeAPIClient.fetchOrganizations(sessionKey: sessionKey)
            NSLog("ClaudeBar: fetchOrganizations returned %d org(s), %d selectable",
                  organizations.count, selectableOrganizations.count)
            if organizations.isEmpty {
                // Valid session but the account exposes no organizations — surface
                // it instead of silently sitting on the input screen.
                error = .noOrganizations
                self.sessionKey = nil
            } else if selectableOrganizations.count == 1 {
                // Exactly one connectable org (either the only org, or the single
                // paid one among several) — connect it without a picker.
                try saveCredentials(sessionKey: sessionKey, orgId: selectableOrganizations[0].uuid)
                startPolling()
            }
            // Otherwise multiple selectable orgs — SessionKeyInputView shows the picker.
        } catch let apiError as APIError {
            error = .api(apiError)
            self.sessionKey = nil
        } catch {
            self.error = .network(error.localizedDescription)
            self.sessionKey = nil
        }
        isLoading = false
    }

    /// Switch to a different organization while keeping the current sessionKey.
    /// Clears stale usage/tier data (tier may differ between orgs) and triggers
    /// a fresh fetch via startPolling().
    public func switchOrganization(to org: Organization) async {
        guard let sessionKey else { return }
        do {
            try saveCredentials(sessionKey: sessionKey, orgId: org.uuid)
            usage = nil
            organizationDetails = nil
            error = nil
            startPolling()
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }

    /// Validate a new session key by fetching the org list, then either
    /// preserve the current orgId (if still in the list) or enter a pending
    /// pick state that holds the new key transiently until the user confirms.
    public func updateSessionKey(_ newKey: String) async {
        isLoading = true
        error = nil
        do {
            let fetched = try await ClaudeAPIClient.fetchOrganizations(sessionKey: newKey)
            applyKeyUpdateResult(newSessionKey: newKey, fetchedOrgs: fetched)
        } catch let apiError as APIError {
            error = .api(apiError)
        } catch {
            self.error = .network(error.localizedDescription)
        }
        isLoading = false
    }

    /// Pure state-machine step extracted from updateSessionKey for testability.
    /// Decides between "preserve current org" and "enter pending pick".
    func applyKeyUpdateResult(newSessionKey: String, fetchedOrgs: [Organization]) {
        if let currentOrgId = orgId, fetchedOrgs.contains(where: { $0.uuid == currentOrgId }) {
            // Common case: cookie rotated, account/org unchanged
            do {
                try saveCredentials(sessionKey: newSessionKey, orgId: currentOrgId)
                organizations = fetchedOrgs
                pendingOrgPick = false
                pendingSessionKey = nil
                pendingOrganizations = []
                startPolling()
            } catch {
                self.error = .network(error.localizedDescription)
            }
        } else {
            // Different account: hold new key transiently, wait for user pick
            stopPolling()
            pendingSessionKey = newSessionKey
            pendingOrganizations = fetchedOrgs
            pendingOrgPick = true
        }
    }

    /// Commit the held sessionKey + the picked org atomically, then resume polling.
    public func confirmPendingOrg(_ org: Organization) async {
        guard let pending = pendingSessionKey else { return }
        do {
            try saveCredentials(sessionKey: pending, orgId: org.uuid)
            organizations = pendingOrganizations
            usage = nil
            organizationDetails = nil
            pendingSessionKey = nil
            pendingOrganizations = []
            pendingOrgPick = false
            startPolling()
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }

    /// Discard pending key/org state. Old credentials are untouched.
    public func cancelPendingOrgPick() {
        pendingSessionKey = nil
        pendingOrganizations = []
        pendingOrgPick = false
        if isAuthenticated {
            startPolling()
        }
    }

    public func refreshUsage() async {
        guard let sessionKey, let orgId else { return }
        isLoading = true
        error = nil
        let client = ClaudeAPIClient(sessionKey: sessionKey, orgId: orgId)
        do {
            usage = try await client.fetchUsage()
            lastUpdated = Date()
            // Fetch org details once per session — tier is stable across polls.
            if organizationDetails == nil {
                organizationDetails = try? await client.fetchOrganizationDetails()
            }
            // Best-effort background refresh of the org list. Capture the
            // sessionKey at spawn; on completion, only apply if the user is
            // still signed in with that same key — avoids leaking the prior
            // account's orgs after sign-out or account switch.
            Task { [weak self, sessionKey] in
                if let fetched = try? await ClaudeAPIClient.fetchOrganizations(sessionKey: sessionKey) {
                    await MainActor.run {
                        guard let self, self.sessionKey == sessionKey else { return }
                        self.applyRefreshedOrgList(fetched)
                    }
                }
            }
            // Platform credits — no-ops when no platform key is connected.
            Task { @MainActor [weak self] in
                await self?.refreshPlatformCredits()
            }
        } catch APIError.sessionExpired {
            handleSessionExpired()
        } catch APIError.rateLimited {
            error = .rateLimited
        } catch {
            self.error = .network(error.localizedDescription)
        }
        isLoading = false
    }

    /// Replace the cached org list with a fresh server response.
    /// Empty responses are ignored to avoid wiping the cache on a transient blip.
    public func applyRefreshedOrgList(_ fetched: [Organization]) {
        guard !fetched.isEmpty else { return }
        organizations = fetched
    }

    // MARK: - Platform Credits

    /// Apply a successful platform credits fetch — value is updated, stale flag clears.
    func applyPlatformCreditsSuccess(_ credits: PlatformCredits) {
        platformCredits = credits
        platformCreditsIsStale = false
    }

    /// Mark the most recent platform credits fetch as failed. Preserves the last
    /// known value and sets the stale flag if (and only if) we have a value to
    /// display — there is no "stale nothing" state.
    func markPlatformCreditsFetchFailed() {
        if platformCredits != nil {
            platformCreditsIsStale = true
        }
    }

    /// 401/403 from a platform endpoint — clear ONLY the platform side. The
    /// claude.ai sessionKey, orgId, usage display, and global error state are
    /// untouched. Settings shows "Disconnected · session expired" via the absence
    /// of `platformSessionKey`.
    func applyPlatformSessionExpired() {
        try? keychain.delete(account: Self.platformCredentialsAccount)
        platformSessionKey = nil
        platformCredits = nil
        platformCreditsIsStale = false
        cachedPlatformOrgId = nil
    }

    /// Save a platform-scoped sessionKey to Keychain and trigger an immediate
    /// balance refresh. Called by both the WKWebView capture path and the manual
    /// paste path — they share the same downstream pipeline.
    public func connectPlatform(sessionKey: String) async {
        do {
            try keychain.save(account: Self.platformCredentialsAccount, value: sessionKey)
        } catch {
            self.error = .network(error.localizedDescription)
            return
        }
        platformSessionKey = sessionKey
        cachedPlatformOrgId = nil       // force re-discovery for the new account
        await refreshPlatformCredits()
    }

    /// User-initiated disconnect: drop the Keychain entry, clear all platform state.
    public func disconnectPlatform() {
        try? keychain.delete(account: Self.platformCredentialsAccount)
        platformSessionKey = nil
        platformCredits = nil
        platformCreditsIsStale = false
        cachedPlatformOrgId = nil
    }

    /// Discover the API org (cached for the session) and fetch its prepaid credit
    /// balance. No-op when `platformSessionKey == nil` — the caller does not need
    /// to gate. Network failures are silent: keep the last known value, mark stale.
    /// 401/403 specifically clears the platform key (decision #8 in the v2 spec).
    func refreshPlatformCredits() async {
        guard let key = platformSessionKey else { return }

        if cachedPlatformOrgId == nil {
            do {
                let orgs = try await ClaudeAPIClient.fetchPlatformOrganizations(platformSessionKey: key)
                let apiOrgs = orgs.filter { $0.capabilities?.contains("api") == true }
                cachedPlatformOrgId = apiOrgs.first?.uuid
                if apiOrgs.count > 1 {
                    NSLog("ClaudeBar: multiple platform API orgs found, using first (%@)", apiOrgs.first?.uuid ?? "?")
                }
            } catch is PlatformAuthError {
                applyPlatformSessionExpired()
                return
            } catch {
                markPlatformCreditsFetchFailed()
                return
            }
        }
        guard let orgId = cachedPlatformOrgId else { return }   // No API org for this account

        do {
            if let credits = try await ClaudeAPIClient.fetchPlatformCredits(
                platformSessionKey: key, platformOrgId: orgId
            ) {
                applyPlatformCreditsSuccess(credits)
            } else {
                // permission_error 200 — cached UUID stale or org lost `api`.
                cachedPlatformOrgId = nil
                markPlatformCreditsFetchFailed()
            }
        } catch is PlatformAuthError {
            applyPlatformSessionExpired()
        } catch {
            markPlatformCreditsFetchFailed()
        }
    }

    // MARK: - Polling

    public func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshUsage() }
        }
        // Also fetch immediately
        Task { await refreshUsage() }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

}

public enum AppError: Equatable {
    case api(APIError)
    case sessionExpired
    case rateLimited
    case noOrganizations
    case network(String)

    public var message: String {
        switch self {
        case .sessionExpired: return String(localized: "error.sessionExpired", bundle: .module)
        case .rateLimited: return String(localized: "error.rateLimited", bundle: .module)
        case .noOrganizations: return String(localized: "error.noOrganizations", bundle: .module)
        case .api(let e): return String(localized: "error.api \(e.displayMessage)", bundle: .module)
        case .network(let msg): return msg
        }
    }
}
