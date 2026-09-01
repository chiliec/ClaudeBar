import Foundation
import Testing
@testable import ClaudeBarUI

@MainActor
@Suite(.serialized)
struct AppStateTests {
    private func makeState() -> AppState {
        let state = AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
        // Clean slate
        state.wipeAllState()
        return state
    }

    private func testCredentials(expiresIn: TimeInterval = 3600) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: "sk-at-test",
            refreshToken: "sk-rt-test",
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - Authentication State

    @Test func initialStateIsNotAuthenticated() {
        let state = makeState()
        #expect(!state.isAuthenticated)
        #expect(state.credentials == nil)
    }

    @Test func saveAndLoadCredentials() throws {
        let state = makeState()
        let creds = testCredentials()
        try state.saveCredentials(creds)
        #expect(state.isAuthenticated)

        // A fresh state over the same keychain sees them
        let reloaded = AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
        #expect(reloaded.credentials == creds)
        reloaded.wipeAllState()
    }

    @Test func refreshedTokensPersistIntoActiveAccount() throws {
        let state = makeState()
        try state.saveCredentials(testCredentials())          // creates active "default" account
        let newer = OAuthCredentials(accessToken: "sk-at-new", refreshToken: "sk-rt-new",
                                     expiresAt: Date().addingTimeInterval(7200))
        try state.saveCredentials(newer)                       // simulate refresh write-back
        let reloaded = AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
        #expect(reloaded.credentials == newer)
        #expect(reloaded.accounts.count == 1)                  // upsert, not duplicate
        reloaded.wipeAllState()
    }

    /// The app builds its state before it has drawn anything, so `init` must not
    /// touch the Keychain: a read can sit behind a macOS password prompt, and on the
    /// main thread that stops the status item from ever appearing. `start()` does the
    /// read instead, off the main thread.
    @Test func loadNowFalseDefersTheKeychainReadToStart() async throws {
        let state = makeState()
        let creds = testCredentials()
        try state.saveCredentials(creds)

        let deferred = AppState(keychain: KeychainService(serviceName: "com.claudebar.test"),
                                loadNow: false)
        #expect(deferred.credentials == nil)
        await deferred.start()
        #expect(deferred.credentials == creds)
        deferred.wipeAllState()
    }

    // MARK: - Menu Bar Display Values

    @Test func menuBarTextWithNoUsage() {
        let state = makeState()
        #expect(state.menuBarText == "—%")
    }

    @Test func menuBarTextWithFiveHourUsage() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.73, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.3, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.menuBarText == "73%")
    }

    @Test func menuBarTextFallsBackToSevenDay() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: nil,
            sevenDay: WindowUsage(utilization: 0.42, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.menuBarText == "42%")
    }

    @Test func menuBarTextAtZero() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.0, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.0, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.menuBarText == "0%")
    }

    @Test func menuBarTextAtFull() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 1.0, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.menuBarText == "100%")
    }

    // MARK: - Utilization & Color

    @Test func menuBarUtilizationWithNoUsage() {
        let state = makeState()
        #expect(state.menuBarUtilization == 0)
    }

    @Test func menuBarUtilizationPrefersFiveHour() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.8, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.2, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.menuBarUtilization == 0.8)
    }

    @Test func usageColorGreen() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.3, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.1, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.usageColor == .green)
    }

    @Test func usageColorYellow() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.6, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.1, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.usageColor == .yellow)
    }

    @Test func usageColorOrange() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.85, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.1, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.usageColor == .orange)
    }

    @Test func usageColorRed() {
        let state = makeState()
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.95, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.1, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        #expect(state.usageColor == .red)
    }

    // MARK: - Error Messages

    @Test func appErrorMessages() {
        #expect(AppError.sessionExpired.message == "Session expired — sign in again")
        #expect(AppError.rateLimited.message == "Rate limited — will retry")
        #expect(AppError.network("Connection failed").message == "Connection failed")
        #expect(AppError.api(.httpError(500)).message == "API error: HTTP 500")
        #expect(APIError.invalidURL.displayMessage == "Invalid URL")
        #expect(APIError.invalidResponse.displayMessage == "Invalid response")
    }

    // MARK: - Sign Out & Session-Expired

    @Test func wipeAllStateClearsEverything() throws {
        let state = makeState()
        try state.saveCredentials(testCredentials())
        state.usage = UsageResponse(fiveHour: nil, sevenDay: WindowUsage(utilization: 0.5, resetsAt: nil))
        state.organizationDetails = OrganizationDetails(uuid: "org-1", name: "Acme", rateLimitTier: nil)

        state.wipeAllState()

        #expect(state.credentials == nil)
        #expect(!state.isAuthenticated)
        #expect(state.usage == nil)
        #expect(state.organizationDetails == nil)
        let fresh = AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
        #expect(fresh.credentials == nil)
    }

    @Test func handleSessionExpiredClearsCredentialsButKeepsOrgName() throws {
        let state = makeState()
        try state.saveCredentials(testCredentials())
        state.organizationDetails = OrganizationDetails(uuid: "org-1", name: "Acme", rateLimitTier: nil)
        state.usage = UsageResponse(fiveHour: nil, sevenDay: WindowUsage(utilization: 0.5, resetsAt: nil))

        state.handleSessionExpired()

        #expect(state.credentials == nil)
        #expect(state.usage == nil)
        #expect(state.error == .sessionExpired)
        // Preserved so the re-login screen can name the account
        #expect(state.organizationDetails?.name == "Acme")
    }

    @Test func handleSessionExpiredSurvivesRelaunch() throws {
        // Regression guard: pre-fix, handleSessionExpired() only cleared the
        // legacy single-credential Keychain key, leaving the AccountStore blob
        // intact — so a fresh AppState over the same keychain would resurrect
        // the "expired" account on next load.
        let state = makeState()
        try state.saveCredentials(testCredentials())

        state.handleSessionExpired()

        let reloaded = AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
        #expect(!reloaded.isAuthenticated)
        #expect(reloaded.accounts.isEmpty)
        reloaded.wipeAllState()
    }

    @Test func loadCredentialsDropsLegacyCookieItem() throws {
        let keychain = KeychainService(serviceName: "com.claudebar.test")
        try keychain.save(account: "credentials", value: "sk-old\u{0}org-old")

        let state = AppState(keychain: keychain)

        #expect(try keychain.retrieve(account: "credentials") == nil)
        #expect(!state.isAuthenticated)
        state.wipeAllState()
    }

    // MARK: - Initial UI State

    @Test func initialLoadingState() {
        let state = makeState()
        #expect(!state.isLoading)
        #expect(state.error == nil)
        #expect(state.lastUpdated == nil)
        #expect(!state.showingSettings)
    }

    // MARK: - Platform State

    @Test func wipeAllStateClearsAllPlatformState() throws {
        let state = makeState()
        try state.saveCredentials(testCredentials())
        state.platformSessionKey = "sk-platform"
        state.platformCredits = PlatformCredits(amountCents: 189, currency: "USD")
        state.platformCreditsIsStale = true
        state.cachedPlatformOrgId = "platform-org-1"

        state.wipeAllState()

        #expect(state.platformSessionKey == nil)
        #expect(state.platformCredits == nil)
        #expect(state.platformCreditsIsStale == false)
        #expect(state.cachedPlatformOrgId == nil)
    }

    @Test func handleSessionExpiredDoesNotTouchPlatformState() throws {
        // Critical regression guard: claude.ai expiry MUST NOT clear the platform
        // key. The two sessions are independent.
        let state = makeState()
        try state.saveCredentials(testCredentials())
        state.platformSessionKey = "sk-platform"
        state.platformCredits = PlatformCredits(amountCents: 189, currency: "USD")
        state.cachedPlatformOrgId = "platform-org-1"

        state.handleSessionExpired()

        #expect(state.platformSessionKey == "sk-platform")
        #expect(state.platformCredits?.amountCents == 189)
        #expect(state.cachedPlatformOrgId == "platform-org-1")
    }

    @Test func loadCredentialsRestoresPlatformKeyFromKeychain() throws {
        let state = makeState()
        // Pre-seed keychain via a fresh service instance using the same test name
        let kc = KeychainService(serviceName: "com.claudebar.test")
        try kc.save(account: "platform_credentials", value: "sk-platform-restored")

        state.loadCredentials()

        #expect(state.platformSessionKey == "sk-platform-restored")
    }

    // MARK: - Multi-Account Switching

    private func account(_ id: String, _ label: String) -> Account {
        Account(id: id, label: label, credentials: testCredentials())
    }

    @Test func switchToChangesActiveAndMarksTheSwitch() throws {
        let state = makeState()
        state.accounts = [account("u1", "a@x.com"), account("u2", "b@x.com")]
        state.activeID = "u1"
        state.usage = UsageResponse(fiveHour: nil,
                                    sevenDay: WindowUsage(utilization: 0.5, resetsAt: nil))
        state.switchTo(id: "u2")
        #expect(state.activeID == "u2")
        #expect(state.credentials == state.accounts.first { $0.id == "u2" }?.credentials)
        // Usage survives on purpose — redacted by the view until the new one lands,
        // which keeps the panel from collapsing and re-expanding mid-switch.
        #expect(state.usage != nil)
        #expect(state.isSwitchingAccount)
        #expect(state.organizationDetails == nil)   // header falls back to the new label
        state.wipeAllState()
    }

    @Test func removeActiveReactivatesAnother() throws {
        let state = makeState()
        state.accounts = [account("u1", "a@x.com"), account("u2", "b@x.com")]
        state.activeID = "u1"
        state.error = .sessionExpired
        state.removeAccount(id: "u1")
        #expect(state.accounts.map(\.id) == ["u2"])
        #expect(state.activeID == "u2")
        #expect(state.credentials != nil)
        #expect(state.error == nil)
        state.wipeAllState()
    }

    @Test func removeLastAccountLeavesUnauthenticated() throws {
        let state = makeState()
        state.accounts = [account("u1", "a@x.com")]
        state.activeID = "u1"
        state.removeAccount(id: "u1")
        #expect(state.accounts.isEmpty)
        #expect(state.activeID == nil)
        #expect(!state.isAuthenticated)
        state.wipeAllState()
    }

    @Test func reconcileIdentityRekeysMigratedAccount() throws {
        let state = makeState()
        state.accounts = [Account(id: AccountStore.legacyDefaultID, label: "",
                                  credentials: testCredentials())]
        state.activeID = AccountStore.legacyDefaultID
        state.reconcileActiveIdentity(
            AccountIdentity(uuid: "real-uuid", email: "real@x.com"))
        #expect(state.activeID == "real-uuid")
        #expect(state.accounts.first?.id == "real-uuid")
        #expect(state.accounts.first?.label == "real@x.com")
        state.wipeAllState()
    }

    private struct FakeKeychain: KeychainServicing {
        var throwingAccounts: Set<String> = []
        var values: [String: String] = [:]
        func save(account: String, value: String) throws {}
        func retrieve(account: String) throws -> String? {
            if throwingAccounts.contains(account) {
                throw KeychainError.retrieveFailed(-1)
            }
            return values[account]
        }
        func delete(account: String) throws {}
    }

    @Test func loadCredentialsSetsKeychainLockedOnRetrieveFailure() {
        // A real Keychain failure (e.g. the app's signing identity changed since
        // the item was saved) must not look identical to "no credentials yet" —
        // that regression would silently show the setup screen instead of
        // explaining why the saved session is inaccessible.
        let keychain = FakeKeychain(throwingAccounts: [OAuthService.keychainAccount])
        let state = AppState(keychain: keychain)

        #expect(state.error == .keychainLocked)
        #expect(state.isAuthenticated == false)
    }

    @Test func loadCredentialsKeychainLockedStillLoadsPlatformKey() {
        // The platform key is a separate keychain item; a failure reading the
        // claude.ai credentials must not prevent a best-effort platform read.
        let keychain = FakeKeychain(
            throwingAccounts: [OAuthService.keychainAccount],
            values: ["platform_credentials": "sk-platform"]
        )
        let state = AppState(keychain: keychain)

        #expect(state.error == .keychainLocked)
        #expect(state.platformSessionKey == "sk-platform")
    }

    @Test func applyPlatformCreditsSuccessSetsValueAndClearsStale() {
        let state = makeState()
        state.platformCreditsIsStale = true

        state.applyPlatformCreditsSuccess(PlatformCredits(amountCents: 250, currency: "USD"))

        #expect(state.platformCredits?.amountCents == 250)
        #expect(state.platformCreditsIsStale == false)
    }

    @Test func markPlatformCreditsFetchFailedSetsStaleWhenValueExists() {
        let state = makeState()
        state.platformCredits = PlatformCredits(amountCents: 189, currency: "USD")

        state.markPlatformCreditsFetchFailed()

        #expect(state.platformCredits?.amountCents == 189)
        #expect(state.platformCreditsIsStale == true)
    }

    @Test func markPlatformCreditsFetchFailedNoOpWhenNoValue() {
        let state = makeState()

        state.markPlatformCreditsFetchFailed()

        #expect(state.platformCredits == nil)
        #expect(state.platformCreditsIsStale == false)
    }

    @Test func applyPlatformSessionExpiredClearsPlatformKeyAndCacheButPreservesUsage() throws {
        let state = makeState()
        let creds = testCredentials()
        try state.saveCredentials(creds)
        state.platformSessionKey = "sk-platform"
        state.platformCredits = PlatformCredits(amountCents: 189, currency: "USD")
        state.cachedPlatformOrgId = "platform-org-1"

        state.applyPlatformSessionExpired()

        // Platform side cleared
        #expect(state.platformSessionKey == nil)
        #expect(state.platformCredits == nil)
        #expect(state.platformCreditsIsStale == false)
        #expect(state.cachedPlatformOrgId == nil)
        // claude.ai side preserved
        #expect(state.credentials == creds)
        #expect(state.error == nil)
    }

    @Test func disconnectPlatformDeletesKeychainEntryAndClearsState() throws {
        let state = makeState()
        let kc = KeychainService(serviceName: "com.claudebar.test")
        try kc.save(account: "platform_credentials", value: "sk-platform")
        state.platformSessionKey = "sk-platform"
        state.platformCredits = PlatformCredits(amountCents: 189, currency: "USD")
        state.cachedPlatformOrgId = "platform-org-1"

        state.disconnectPlatform()

        #expect(state.platformSessionKey == nil)
        #expect(state.platformCredits == nil)
        #expect(state.cachedPlatformOrgId == nil)
        #expect((try? kc.retrieve(account: "platform_credentials")) == nil)
    }
}
