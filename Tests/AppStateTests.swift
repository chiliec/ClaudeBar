import Testing
@testable import ClaudeBarUI

@MainActor
@Suite(.serialized)
struct AppStateTests {
    private func makeState(orgStore: OrgListStore = InMemoryOrgListStore()) -> AppState {
        let state = AppState(
            keychain: KeychainService(serviceName: "com.claudebar.test"),
            orgListStore: orgStore
        )
        // Clean slate
        state.signOut()
        return state
    }

    // MARK: - Visible Organizations

    @Test func visibleOrganizationsHidesIndividualOrgs() {
        let state = makeState()
        state.organizations = [
            Organization(uuid: "paid-1", name: "Acme", capabilities: ["claude_max"]),
            Organization(uuid: "free-1", name: "Personal", capabilities: ["chat"]),
            Organization(uuid: "paid-2", name: "Beta", capabilities: ["claude_pro"]),
        ]
        let visible = state.visibleOrganizations
        #expect(visible.map(\.uuid) == ["paid-1", "paid-2"])
    }

    @Test func visibleOrganizationsKeepsCurrentEvenIfUnpaid() {
        let state = makeState()
        state.orgId = "free-1"
        state.organizations = [
            Organization(uuid: "free-1", name: "Personal", capabilities: ["chat"]),
            Organization(uuid: "paid-1", name: "Acme", capabilities: ["claude_pro"]),
        ]
        let visible = state.visibleOrganizations
        #expect(visible.contains(where: { $0.uuid == "free-1" }))
        #expect(visible.contains(where: { $0.uuid == "paid-1" }))
    }

    @Test func visibleOrganizationsHidesOrgWithNilCapabilities() {
        let state = makeState()
        state.organizations = [
            Organization(uuid: "x", name: "Unknown", capabilities: nil),
            Organization(uuid: "y", name: "Pro", capabilities: ["claude_pro"]),
        ]
        let visible = state.visibleOrganizations
        #expect(visible.map(\.uuid) == ["y"])
    }

    // MARK: - Selectable Organizations

    @Test func selectableOrganizationsPrefersPaidOrgs() {
        let state = makeState()
        state.organizations = [
            Organization(uuid: "paid-1", name: "Acme", capabilities: ["claude_max"]),
            Organization(uuid: "free-1", name: "Personal", capabilities: ["chat"]),
        ]
        #expect(state.selectableOrganizations.map(\.uuid) == ["paid-1"])
    }

    @Test func selectableOrganizationsFallsBackToAllWhenNonePaid() {
        // The gap that stranded connect: several orgs, none carrying a
        // recognized paid capability. visibleOrganizations is empty, so the
        // picker never showed and auto-connect never fired. selectable must
        // fall back to the full list so the user can still pick.
        let state = makeState()
        state.organizations = [
            Organization(uuid: "a", name: "One", capabilities: ["chat"]),
            Organization(uuid: "b", name: "Two", capabilities: nil),
        ]
        #expect(state.visibleOrganizations.isEmpty)
        #expect(state.selectableOrganizations.map(\.uuid) == ["a", "b"])
    }

    @Test func selectableOrganizationsSinglePaidAmongManyIsOne() {
        // Single-paid-org account (personal + paid workspace). selectable
        // count == 1 → validateAndFetchOrgs auto-connects instead of silence.
        let state = makeState()
        state.organizations = [
            Organization(uuid: "personal", name: "Me", capabilities: ["chat"]),
            Organization(uuid: "work", name: "Work", capabilities: ["claude_max"]),
        ]
        #expect(state.selectableOrganizations.map(\.uuid) == ["work"])
    }

    // MARK: - Authentication State

    @Test func initialStateIsNotAuthenticated() {
        let state = makeState()
        #expect(!state.isAuthenticated)
        #expect(state.sessionKey == nil)
        #expect(state.orgId == nil)
    }

    @Test func isAuthenticatedRequiresBothKeys() {
        let state = makeState()

        state.sessionKey = "sk-test"
        #expect(!state.isAuthenticated, "Should not be authenticated with only sessionKey")

        state.orgId = "org-123"
        #expect(state.isAuthenticated, "Should be authenticated with both keys")
    }

    @Test func saveAndLoadCredentials() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-ant-test", orgId: "org-abc")

        #expect(state.sessionKey == "sk-ant-test")
        #expect(state.orgId == "org-abc")
        #expect(state.isAuthenticated)

        // Create a new state with the same keychain to verify persistence
        let state2 = AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
        state2.loadCredentials()
        #expect(state2.sessionKey == "sk-ant-test")
        #expect(state2.orgId == "org-abc")
        #expect(state2.isAuthenticated)

        // Cleanup
        state2.signOut()
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
        #expect(AppError.sessionExpired.message == "Session expired — update your key")
        #expect(AppError.rateLimited.message == "Rate limited — will retry")
        #expect(AppError.network("Connection failed").message == "Connection failed")
        #expect(AppError.api(.httpError(500)).message == "API error: HTTP 500")
        #expect(APIError.invalidURL.displayMessage == "Invalid URL")
        #expect(APIError.invalidResponse.displayMessage == "Invalid response")
    }

    // MARK: - Organization Selection

    @Test func sessionKeyRetainedForOrgSelection() {
        let state = makeState()
        state.sessionKey = "sk-ant-multi-org"
        state.organizations = [
            Organization(uuid: "org-1", name: "Personal", capabilities: nil),
            Organization(uuid: "org-2", name: "Work", capabilities: nil),
        ]

        #expect(state.sessionKey == "sk-ant-multi-org")
        #expect(!state.isAuthenticated, "Not yet authenticated until org is selected")
    }

    @Test func switchOrganizationSavesCredentials() async throws {
        let state = makeState()
        state.sessionKey = "sk-ant-test"
        state.stopPolling()

        let org = Organization(uuid: "org-2", name: "Work", capabilities: nil)
        await state.switchOrganization(to: org)

        #expect(state.sessionKey == "sk-ant-test")
        #expect(state.orgId == "org-2")
        #expect(state.isAuthenticated)

        state.signOut()
    }

    // MARK: - Org List Persistence

    @Test func loadsOrgListFromStoreOnInit() {
        let store = InMemoryOrgListStore(initial: [
            Organization(uuid: "org-1", name: "Cached", capabilities: nil),
        ])
        let state = AppState(
            keychain: KeychainService(serviceName: "com.claudebar.test"),
            orgListStore: store
        )
        #expect(state.organizations.count == 1)
        #expect(state.organizations[0].name == "Cached")
        state.signOut()
    }

    @Test func persistsOrgListWhenSet() {
        let store = InMemoryOrgListStore()
        let state = AppState(
            keychain: KeychainService(serviceName: "com.claudebar.test"),
            orgListStore: store
        )
        state.organizations = [Organization(uuid: "org-1", name: "Saved", capabilities: nil)]
        #expect(store.load().count == 1)
        #expect(store.load()[0].name == "Saved")
        state.signOut()
    }

    // MARK: - Sign Out & Session-Expired

    @Test func signOutWipesEverything() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk", orgId: "org-1")
        state.organizations = [Organization(uuid: "org-1", name: "X", capabilities: nil)]
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.3, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )

        state.signOut()

        #expect(state.sessionKey == nil)
        #expect(state.orgId == nil)
        #expect(state.usage == nil)
        #expect(state.organizations.isEmpty)
        #expect(!state.isAuthenticated)
    }

    @Test func handleSessionExpiredPreservesOrgIdAndOrgs() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-old", orgId: "org-1")
        state.organizations = [Organization(uuid: "org-1", name: "Acme", capabilities: nil)]
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.3, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )

        state.handleSessionExpired()

        #expect(state.sessionKey == nil)
        #expect(state.orgId == "org-1")
        #expect(state.organizations.count == 1)
        #expect(state.organizations[0].name == "Acme")
        #expect(state.usage == nil)
        #expect(state.error == .sessionExpired)
        #expect(!state.isAuthenticated)
    }

    // MARK: - Switch Organization

    @Test func switchOrganizationSavesAndClearsStaleUsage() async throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk", orgId: "org-1")
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.3, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        state.organizationDetails = OrganizationDetails(
            uuid: "org-1", name: "Old", rateLimitTier: "max5x"
        )

        // Don't actually start polling in tests — just verify state mutations
        state.stopPolling()
        let newOrg = Organization(uuid: "org-2", name: "New", capabilities: nil)
        await state.switchOrganization(to: newOrg)

        #expect(state.orgId == "org-2")
        #expect(state.usage == nil)
        #expect(state.organizationDetails == nil)
        #expect(state.sessionKey == "sk")  // unchanged

        state.signOut()
    }

    @Test func switchOrganizationDoesNothingWithoutSessionKey() async {
        let state = makeState()
        // No sessionKey set; pre-populate state we can verify is left alone
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.3, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil, extraUsage: nil
        )
        state.error = .rateLimited

        let org = Organization(uuid: "org-2", name: "New", capabilities: nil)
        await state.switchOrganization(to: org)

        #expect(state.orgId == nil, "Should not save orgId without sessionKey")
        #expect(state.usage?.fiveHour?.utilization == 0.5, "Should not clear usage on early return")
        #expect(state.error == .rateLimited, "Should not clear error on early return")
    }

    // MARK: - Update Session Key

    @Test func applyKeyUpdateResultPreservesOrgIdWhenStillValid() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-old", orgId: "org-1")
        state.organizations = [Organization(uuid: "org-1", name: "Old", capabilities: nil)]
        state.stopPolling()

        let newOrgs = [
            Organization(uuid: "org-1", name: "Renamed", capabilities: nil),
            Organization(uuid: "org-2", name: "Other", capabilities: nil),
        ]
        state.applyKeyUpdateResult(newSessionKey: "sk-new", fetchedOrgs: newOrgs)

        #expect(state.sessionKey == "sk-new")
        #expect(state.orgId == "org-1")
        #expect(state.organizations.count == 2)
        #expect(!state.pendingOrgPick)

        state.signOut()
    }

    @Test func applyKeyUpdateResultClearsPriorPendingStateOnPreserve() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-old", orgId: "org-1")
        state.organizations = [Organization(uuid: "org-1", name: "Old", capabilities: nil)]
        state.stopPolling()

        // Pre-populate pending state from a prior aborted update
        state.pendingSessionKey = "sk-stale"
        state.pendingOrganizations = [Organization(uuid: "stale", name: "Stale", capabilities: nil)]
        state.pendingOrgPick = true

        let newOrgs = [Organization(uuid: "org-1", name: "Renamed", capabilities: nil)]
        state.applyKeyUpdateResult(newSessionKey: "sk-new", fetchedOrgs: newOrgs)

        #expect(state.sessionKey == "sk-new")
        #expect(!state.pendingOrgPick)
        #expect(state.pendingSessionKey == nil)
        #expect(state.pendingOrganizations.isEmpty)

        state.signOut()
    }

    @Test func applyKeyUpdateResultEntersPendingPickWhenOrgMissing() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-old", orgId: "org-1")
        state.organizations = [Organization(uuid: "org-1", name: "Old", capabilities: nil)]
        state.stopPolling()

        let newOrgs = [
            Organization(uuid: "org-2", name: "Different", capabilities: nil),
            Organization(uuid: "org-3", name: "Also", capabilities: nil),
        ]
        state.applyKeyUpdateResult(newSessionKey: "sk-new", fetchedOrgs: newOrgs)

        // Old creds intact in keychain
        #expect(state.sessionKey == "sk-old")
        #expect(state.orgId == "org-1")
        // Pending state populated
        #expect(state.pendingOrgPick)
        #expect(state.pendingSessionKey == "sk-new")
        #expect(state.pendingOrganizations.count == 2)
        // Cached orgs NOT touched yet
        #expect(state.organizations.count == 1)
        #expect(state.organizations[0].name == "Old")

        state.signOut()
    }

    @Test func confirmPendingOrgCommitsAndClearsPending() async throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-old", orgId: "org-1")
        state.stopPolling()

        // Simulate pending state
        state.pendingSessionKey = "sk-new"
        state.pendingOrganizations = [Organization(uuid: "org-7", name: "New", capabilities: nil)]
        state.pendingOrgPick = true

        await state.confirmPendingOrg(Organization(uuid: "org-7", name: "New", capabilities: nil))

        #expect(state.sessionKey == "sk-new")
        #expect(state.orgId == "org-7")
        #expect(state.organizations.count == 1)
        #expect(state.organizations[0].uuid == "org-7")
        #expect(!state.pendingOrgPick)
        #expect(state.pendingSessionKey == nil)
        #expect(state.pendingOrganizations.isEmpty)

        state.signOut()
    }

    @Test func confirmPendingOrgDoesNothingWithoutPendingKey() async throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-old", orgId: "org-1")
        // No pending state set
        let org = Organization(uuid: "org-7", name: "New", capabilities: nil)
        await state.confirmPendingOrg(org)

        // Old creds untouched, no spurious mutations
        #expect(state.sessionKey == "sk-old")
        #expect(state.orgId == "org-1")
        #expect(!state.pendingOrgPick)

        state.signOut()
    }

    @Test func cancelPendingOrgPickRevertsTransientState() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk-old", orgId: "org-1")

        state.pendingSessionKey = "sk-new"
        state.pendingOrganizations = [Organization(uuid: "org-2", name: "X", capabilities: nil)]
        state.pendingOrgPick = true

        state.cancelPendingOrgPick()

        #expect(state.sessionKey == "sk-old")
        #expect(state.orgId == "org-1")
        #expect(!state.pendingOrgPick)
        #expect(state.pendingSessionKey == nil)
        #expect(state.pendingOrganizations.isEmpty)

        state.signOut()
    }

    // MARK: - Background Org-List Refresh

    @Test func applyRefreshedOrgListReplacesCache() {
        let state = makeState()
        state.organizations = [Organization(uuid: "old", name: "Old", capabilities: nil)]
        let refreshed = [
            Organization(uuid: "old", name: "Renamed", capabilities: nil),
            Organization(uuid: "new", name: "Added", capabilities: nil),
        ]
        state.applyRefreshedOrgList(refreshed)
        #expect(state.organizations.count == 2)
        #expect(state.organizations[0].name == "Renamed")
    }

    @Test func applyRefreshedOrgListIgnoresEmptyResponse() {
        let state = makeState()
        state.organizations = [Organization(uuid: "x", name: "Keep", capabilities: nil)]
        state.applyRefreshedOrgList([])
        #expect(state.organizations.count == 1)
        #expect(state.organizations[0].name == "Keep")
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

    @Test func signOutClearsAllPlatformState() throws {
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk", orgId: "org-1")
        state.platformSessionKey = "sk-platform"
        state.platformCredits = PlatformCredits(amountCents: 189, currency: "USD")
        state.platformCreditsIsStale = true
        state.cachedPlatformOrgId = "platform-org-1"

        state.signOut()

        #expect(state.platformSessionKey == nil)
        #expect(state.platformCredits == nil)
        #expect(state.platformCreditsIsStale == false)
        #expect(state.cachedPlatformOrgId == nil)
    }

    @Test func handleSessionExpiredDoesNotTouchPlatformState() throws {
        // Critical regression guard: claude.ai expiry MUST NOT clear the platform
        // key. The two sessions are independent.
        let state = makeState()
        try state.saveCredentials(sessionKey: "sk", orgId: "org-1")
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
        let keychain = FakeKeychain(throwingAccounts: ["credentials"])
        let state = AppState(keychain: keychain, orgListStore: InMemoryOrgListStore())

        #expect(state.error == .keychainLocked)
        #expect(state.isAuthenticated == false)
    }

    @Test func loadCredentialsKeychainLockedStillLoadsPlatformKey() {
        // The platform key is a separate keychain item; a failure reading the
        // claude.ai credentials must not prevent a best-effort platform read.
        let keychain = FakeKeychain(
            throwingAccounts: ["credentials"],
            values: ["platform_credentials": "sk-platform"]
        )
        let state = AppState(keychain: keychain, orgListStore: InMemoryOrgListStore())

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
        try state.saveCredentials(sessionKey: "sk", orgId: "org-1")
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
        #expect(state.sessionKey == "sk")
        #expect(state.orgId == "org-1")
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
