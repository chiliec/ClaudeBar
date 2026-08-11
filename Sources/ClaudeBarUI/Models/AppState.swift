import SwiftUI

@MainActor
@Observable
public final class AppState {
    // MARK: - Auth State
    public var credentials: OAuthCredentials?
    public var isAuthenticated: Bool { credentials != nil }
    public var accounts: [Account] = []
    public var activeID: String?

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
    /// True from the moment an account switch starts until its first usage lands.
    /// The popover keeps the previous account's layout (redacted) meanwhile, so the
    /// panel doesn't collapse to a spinner and spring back a second later.
    public var isSwitchingAccount = false

    // MARK: - Services
    private let keychain: any KeychainServicing
    private var pollTimer: Timer?
    public var pollInterval: TimeInterval = 300 // 5 minutes

    public init(keychain: any KeychainServicing = KeychainService()) {
        self.keychain = keychain
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

    private static let legacyCredentialsAccount = "credentials"
    private static let platformCredentialsAccount = "platform_credentials"

    public func loadCredentials() {
        // One-time migration: the pasted claude.ai sessionKey is dead weight now.
        try? keychain.delete(account: Self.legacyCredentialsAccount)
        do {
            let set = try AccountStore.load(from: keychain)
            accounts = set.accounts
            activeID = set.activeID
            credentials = activeAccount?.credentials
            platformSessionKey = try? keychain.retrieve(account: Self.platformCredentialsAccount)
        } catch {
            // A real Keychain failure (e.g. macOS denies access because the app's
            // code signing identity changed since the item was saved) is not the
            // same as no credentials existing yet — surface it instead of
            // silently looking logged out.
            platformSessionKey = try? keychain.retrieve(account: Self.platformCredentialsAccount)
            self.error = .keychainLocked
        }
    }

    private var activeAccount: Account? {
        accounts.first { $0.id == activeID }
    }

    private func persistAccounts() throws {
        try AccountStore.save(AccountSet(accounts: accounts, activeID: activeID), to: keychain)
    }

    public func saveCredentials(_ credentials: OAuthCredentials) throws {
        let id = activeID ?? AccountStore.legacyDefaultID
        let label = accounts.first { $0.id == id }?.label ?? ""
        upsert(Account(id: id, label: label, credentials: credentials))
        activeID = id
        self.credentials = credentials
        try persistAccounts()
    }

    /// Insert or replace an account by id, preserving list order on replace.
    func upsert(_ account: Account) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
    }

    // MARK: - Account switching

    public func switchTo(id: String) {
        guard id != activeID, accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
        credentials = activeAccount?.credentials
        // `usage` deliberately survives: it's the old account's, so it gets redacted
        // rather than shown, but keeping the layout stops the panel resizing twice.
        isSwitchingAccount = true
        organizationDetails = nil
        lastUpdated = nil
        error = nil
        try? persistAccounts()
        startPolling()      // fetches the newly active account immediately
    }

    public func removeAccount(id: String) {
        accounts.removeAll { $0.id == id }
        if activeID == id {
            activeID = accounts.first?.id
            credentials = activeAccount?.credentials
            usage = nil
            organizationDetails = nil
            lastUpdated = nil
            error = nil
        }
        try? persistAccounts()
        if activeID == nil { stopPolling() } else { startPolling() }
    }

    /// After the first profile fetch, replace a migrated/default account's
    /// placeholder id+label with the real `account.uuid`/`email`. Idempotent:
    /// no-op once the active account already carries its real identity.
    func reconcileActiveIdentity(_ identity: AccountIdentity) {
        guard let i = accounts.firstIndex(where: { $0.id == activeID }) else { return }
        var acct = accounts[i]
        let needsRekey = acct.id != identity.uuid
        acct.label = identity.email
        if needsRekey {
            // Drop any pre-existing entry for this real uuid (dedup), then rekey.
            accounts.removeAll { $0.id == identity.uuid }
            acct = Account(id: identity.uuid, label: identity.email, credentials: acct.credentials)
        }
        // Re-find the index (dedup removal may have shifted it) and write back.
        if let j = accounts.firstIndex(where: { $0.id == (needsRekey ? activeID : identity.uuid) }) {
            accounts[j] = acct
        } else {
            accounts.append(acct)
        }
        activeID = identity.uuid
        try? persistAccounts()
    }

    public func signOut() {
        AccountStore.clear(from: keychain)
        OAuthService.clear(from: keychain)
        try? keychain.delete(account: Self.legacyCredentialsAccount)
        try? keychain.delete(account: Self.platformCredentialsAccount)
        stopPolling()
        accounts = []
        activeID = nil
        credentials = nil
        usage = nil
        organizationDetails = nil
        error = nil
        platformSessionKey = nil
        platformCredits = nil
        platformCreditsIsStale = false
        cachedPlatformOrgId = nil
    }

    /// Non-destructive recovery: drops the token set but preserves
    /// `organizationDetails` so the re-login screen can name the account.
    func handleSessionExpired() {
        // Drop only the expired account from the persisted set — its refresh
        // token is dead and re-login will create a fresh entry. Other accounts
        // (once multi-account is wired up) are untouched.
        accounts.removeAll { $0.id == activeID }
        activeID = nil
        try? persistAccounts()
        credentials = nil
        usage = nil
        error = .sessionExpired
        // organizationDetails: preserved
    }

    // MARK: - API Calls

    /// Opens the browser for consent, identifies the account via its profile,
    /// and adds it to the set as the new active account.
    public func signIn() async {
        isLoading = true
        error = nil
        do {
            let tokens = try await OAuthService.signIn()
            let profile = try await ClaudeAPIClient.fetchOAuthProfile(accessToken: tokens.accessToken)
            let account = Account(id: profile.account.uuid,
                                  label: profile.account.email,
                                  credentials: tokens)
            upsert(account)
            activeID = account.id
            credentials = tokens
            organizationDetails = profile.organization
            usage = nil
            lastUpdated = nil
            try persistAccounts()
            startPolling()
        } catch let oauthError as OAuthError {
            error = .oauth(oauthError)
        } catch {
            self.error = .network(error.localizedDescription)
        }
        isLoading = false
    }

    public func refreshUsage() async {
        guard var creds = credentials else { return }
        isLoading = true
        error = nil
        do {
            if OAuthService.needsRefresh(creds) {
                creds = try await refreshAndSave(creds)
            }
            do {
                usage = try await ClaudeAPIClient.fetchOAuthUsage(accessToken: creds.accessToken)
            } catch APIError.sessionExpired {
                // The token died early (revoked, or clock skew). Refresh once,
                // retry once; a second failure falls through to the re-login state.
                creds = try await refreshAndSave(creds)
                usage = try await ClaudeAPIClient.fetchOAuthUsage(accessToken: creds.accessToken)
            }
            lastUpdated = Date()
            // Fetch the profile once per session — org name and tier are stable.
            if organizationDetails == nil {
                if let profile = try? await ClaudeAPIClient.fetchOAuthProfile(accessToken: creds.accessToken) {
                    organizationDetails = profile.organization
                    reconcileActiveIdentity(profile.account)
                }
            }
            // Platform credits — no-ops when no platform key is connected.
            Task { @MainActor [weak self] in
                await self?.refreshPlatformCredits()
            }
        } catch APIError.sessionExpired {
            handleSessionExpired()
        } catch is OAuthError {
            // Refresh itself failed — the refresh token is revoked or expired.
            handleSessionExpired()
        } catch APIError.rateLimited {
            error = .rateLimited
        } catch {
            self.error = .network(error.localizedDescription)
        }
        isLoading = false
        isSwitchingAccount = false
    }

    private func refreshAndSave(_ creds: OAuthCredentials) async throws -> OAuthCredentials {
        let refreshed = try await OAuthService.refresh(creds)
        try saveCredentials(refreshed)
        return refreshed
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
    /// claude.ai OAuth credentials, usage display, and global error state are
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
    case oauth(OAuthError)
    case sessionExpired
    case rateLimited
    case network(String)
    case keychainLocked

    public var message: String {
        switch self {
        case .sessionExpired: return String(localized: "error.sessionExpired", bundle: .module)
        case .rateLimited: return String(localized: "error.rateLimited", bundle: .module)
        case .api(let e): return String(localized: "error.api \(e.displayMessage)", bundle: .module)
        case .oauth(let e): return e.displayMessage
        case .network(let msg): return msg
        case .keychainLocked: return String(localized: "error.keychainLocked", bundle: .module)
        }
    }
}
