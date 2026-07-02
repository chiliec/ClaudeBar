import Testing
import ViewInspector
@testable import ClaudeBarUI

// MARK: - PopoverView Tests

@MainActor
@Suite
struct PopoverViewTests {
    private func makeState() -> AppState {
        AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
    }

    @Test func showsSetupViewWhenNotAuthenticated() throws {
        let state = makeState()
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(SetupView.self)
    }

    @Test func showsSessionExpiredView() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-123"
        state.error = .sessionExpired
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(SessionExpiredView.self)
    }

    @Test func showsUsageDetailWhenAuthenticated() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-123"
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        // Should NOT contain SetupView or SessionExpiredView
        #expect(throws: (any Error).self) { try inspected.find(SetupView.self) }
        #expect(throws: (any Error).self) { try inspected.find(SessionExpiredView.self) }
    }

    @Test func popoverRendersVStack() throws {
        let state = makeState()
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.vStack()
    }

    @Test func showsSessionExpiredViewAfterHandleSessionExpired() throws {
        // After handleSessionExpired, sessionKey is nil but orgId is preserved.
        // PopoverView must route to SessionExpiredView, not SetupView.
        let state = makeState()
        state.orgId = "org-123"
        state.error = .sessionExpired
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(SessionExpiredView.self)
        #expect(throws: (any Error).self) { try inspected.find(SetupView.self) }
    }

    @Test func routesToSettingsWhenPendingOrgPick() throws {
        let state = makeState()
        state.pendingOrgPick = true
        state.pendingSessionKey = "sk-new"
        state.pendingOrganizations = [
            Organization(uuid: "org-1", name: "Acme", capabilities: nil)
        ]
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(SettingsView.self)
    }
}

// MARK: - SetupView Tests

@MainActor
@Suite
struct SetupViewTests {
    private func makeState() -> AppState {
        AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
    }

    @Test func showsTitle() throws {
        let state = makeState()
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(text: "Setup ClaudeBar")
    }

    @Test func showsInstructions() throws {
        let state = makeState()
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(text: "Paste sessionKey here...")
    }

    @Test func showsConnectButton() throws {
        let state = makeState()
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(button: "Connect")
    }

    @Test func showsQuitButton() throws {
        let state = makeState()
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(button: "Quit ClaudeBar")
    }

    @Test func showsErrorMessage() throws {
        let state = makeState()
        state.error = .network("Connection failed")
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(text: "Connection failed")
    }

    @Test func showsLoadingIndicator() throws {
        let state = makeState()
        state.isLoading = true
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(ViewType.ProgressView.self)
    }

    @Test func showsOrgSelectionWhenMultipleOrgs() throws {
        let state = makeState()
        state.organizations = [
            Organization(uuid: "org-1", name: "Personal", capabilities: ["claude_pro"]),
            Organization(uuid: "org-2", name: "Work", capabilities: ["claude_max"]),
        ]
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(text: "Select organization:")
        _ = try inspected.find(text: "Personal")
        _ = try inspected.find(text: "Work")
    }

    @Test func hidesOrgSelectionForSingleOrg() throws {
        let state = makeState()
        state.organizations = [
            Organization(uuid: "org-1", name: "Personal", capabilities: nil),
        ]
        let view = SetupView(state: state)
        let inspected = try view.inspect()

        #expect(throws: (any Error).self) { try inspected.find(text: "Select organization:") }
    }
}

// MARK: - SessionExpiredView Tests

@MainActor
@Suite
struct SessionExpiredViewTests {
    private func makeState() -> AppState {
        AppState(
            keychain: KeychainService(serviceName: "com.claudebar.test"),
            orgListStore: InMemoryOrgListStore()
        )
    }

    @Test func showsGenericTitleWhenNoOrgCached() throws {
        let state = makeState()
        let view = SessionExpiredView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Session Expired")
    }

    @Test func showsOrgNameInTitleWhenCached() throws {
        let state = makeState()
        state.orgId = "org-123"
        state.organizations = [Organization(uuid: "org-123", name: "Acme", capabilities: nil)]
        let view = SessionExpiredView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Reconnect Acme")
    }

    @Test func showsReconnectButton() throws {
        let state = makeState()
        let view = SessionExpiredView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(button: "Reconnect")
    }

    @Test func showsKeyInputField() throws {
        let state = makeState()
        let view = SessionExpiredView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(ViewType.TextField.self)
    }
}

// MARK: - UsageDetailView Header Tests

@MainActor
@Suite
struct UsageDetailViewHeaderTests {
    private func makeAuthedState(orgs: [Organization]) -> AppState {
        let state = AppState(
            keychain: KeychainService(serviceName: "com.claudebar.test"),
            orgListStore: InMemoryOrgListStore()
        )
        state.signOut()
        state.sessionKey = "sk"
        state.orgId = orgs.first?.uuid
        state.organizations = orgs
        return state
    }

    @Test func showsCurrentOrgNameInHeader() throws {
        let state = makeAuthedState(orgs: [
            Organization(uuid: "org-1", name: "Acme", capabilities: nil),
        ])
        let view = UsageDetailView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Acme")
    }

    @Test func showsMenuWhenMultipleOrgs() throws {
        let state = makeAuthedState(orgs: [
            Organization(uuid: "org-1", name: "Personal", capabilities: ["claude_pro"]),
            Organization(uuid: "org-2", name: "Work", capabilities: ["claude_max"]),
        ])
        let view = UsageDetailView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(ViewType.Menu.self)
    }

    @Test func noMenuForSingleOrg() throws {
        let state = makeAuthedState(orgs: [
            Organization(uuid: "org-1", name: "Solo", capabilities: nil),
        ])
        let view = UsageDetailView(state: state)
        let inspected = try view.inspect()
        #expect(throws: (any Error).self) { try inspected.find(ViewType.Menu.self) }
    }

    @Test func fallsBackToTitleWhenNoOrgName() throws {
        let state = makeAuthedState(orgs: [])
        let view = UsageDetailView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Claude Usage")
    }

    // MARK: - Per-model 7-day window rows

    @Test func showsSonnetAndDesignRowsWhenReported() throws {
        let state = makeAuthedState(orgs: [
            Organization(uuid: "org-1", name: "Acme", capabilities: nil),
        ])
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.12, resetsAt: nil),
            sevenDaySonnet: WindowUsage(utilization: 0.3, resetsAt: nil),
            sevenDayOmelette: WindowUsage(utilization: 0.4, resetsAt: nil)
        )
        let inspected = try UsageDetailView(state: state).inspect()
        _ = try inspected.find(text: "Sonnet")
        _ = try inspected.find(text: "Design")
    }

    @Test func hidesSonnetAndDesignRowsWhenNull() throws {
        // API returns `null` for these windows when the plan no longer
        // provisions them — the rows must disappear, not render as 0%.
        let state = makeAuthedState(orgs: [
            Organization(uuid: "org-1", name: "Acme", capabilities: nil),
        ])
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.12, resetsAt: nil),
            sevenDaySonnet: nil,
            sevenDayOmelette: nil
        )
        let inspected = try UsageDetailView(state: state).inspect()
        // Total row still renders; per-model rows are gone.
        _ = try inspected.find(text: "Total")
        #expect(throws: (any Error).self) { try inspected.find(text: "Sonnet") }
        #expect(throws: (any Error).self) { try inspected.find(text: "Design") }
    }

    @Test func surfacesCodenamedDollarPoolRow() throws {
        let state = makeAuthedState(orgs: [
            Organization(uuid: "org-1", name: "Acme", capabilities: nil),
        ])
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.12, resetsAt: nil),
            additionalWindows: [
                AdditionalWindow(key: "amberLadder", utilization: 0, resetsAt: nil,
                                 limitDollars: 2500, usedDollars: 0, remainingDollars: 2500),
            ]
        )
        let inspected = try UsageDetailView(state: state).inspect()
        _ = try inspected.find(text: "Usage Credits")
        _ = try inspected.find(text: "$0 / $2,500 ·")
    }

    @Test func nonDollarCodenameStillHumanizes() throws {
        let state = makeAuthedState(orgs: [
            Organization(uuid: "org-1", name: "Acme", capabilities: nil),
        ])
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.5, resetsAt: nil),
            sevenDay: WindowUsage(utilization: 0.12, resetsAt: nil),
            additionalWindows: [
                AdditionalWindow(key: "cinderCove", utilization: 0.3, resetsAt: nil),
            ]
        )
        let inspected = try UsageDetailView(state: state).inspect()
        _ = try inspected.find(text: "Cinder Cove")
    }
}

// MARK: - RingProgressView Tests

@MainActor
@Suite
struct RingProgressViewTests {
    @Test func clampsProgressToZero() throws {
        let view = RingProgressView(progress: -0.5, color: .green)
        let inspected = try view.inspect()

        let zstack = try inspected.zStack()
        #expect(try zstack.fixedFrame().width == 16)
    }

    @Test func clampsProgressToOne() throws {
        let view = RingProgressView(progress: 1.5, color: .red)
        let inspected = try view.inspect()
        _ = try inspected.zStack()
    }

    @Test func customSize() throws {
        let view = RingProgressView(progress: 0.5, color: .blue, size: 32)
        let inspected = try view.inspect()
        let frame = try inspected.zStack().fixedFrame()
        #expect(frame.width == 32)
        #expect(frame.height == 32)
    }

    @Test func defaultSize() throws {
        let view = RingProgressView(progress: 0.5, color: .green)
        let inspected = try view.inspect()
        let frame = try inspected.zStack().fixedFrame()
        #expect(frame.width == 16)
        #expect(frame.height == 16)
    }

    @Test func containsTwoCircles() throws {
        let view = RingProgressView(progress: 0.5, color: .green)
        let inspected = try view.inspect()
        let zstack = try inspected.zStack()

        #expect(zstack.count == 2)
    }
}

// MARK: - SettingsView Tests

@MainActor
@Suite
struct SettingsViewTests {
    private func makeState() -> AppState {
        AppState(
            keychain: KeychainService(serviceName: "com.claudebar.test"),
            orgListStore: InMemoryOrgListStore()
        )
    }

    @Test func showsTitle() throws {
        let state = makeState()
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Settings")
    }

    @Test func showsDisconnectedWhenNotAuthenticated() throws {
        let state = makeState()
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Not connected")
    }

    @Test func showsConnectedAsOrgNameWhenAuthenticated() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-123"
        state.organizations = [Organization(uuid: "org-123", name: "Acme", capabilities: nil)]
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Connected as Acme")
    }

    @Test func showsSessionKeyFieldWhenAuthenticated() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-123"
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(ViewType.SecureField.self)
    }

    @Test func showsUpdateButtonWhenAuthenticated() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-123"
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(button: "Update")
    }

    @Test func showsSignOutButtonWhenAuthenticated() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-123"
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(button: "Sign out")
    }

    @Test func showsOrgPickerLabelWhenMultipleOrgs() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-1"
        state.organizations = [
            Organization(uuid: "org-1", name: "Personal", capabilities: ["claude_pro"]),
            Organization(uuid: "org-2", name: "Work", capabilities: ["claude_max"]),
        ]
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Organization:")
    }

    @Test func hidesOrgPickerForSingleOrg() throws {
        let state = makeState()
        state.sessionKey = "sk-test"
        state.orgId = "org-1"
        state.organizations = [Organization(uuid: "org-1", name: "Solo", capabilities: nil)]
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        #expect(throws: (any Error).self) { try inspected.find(text: "Organization:") }
    }

    @Test func showsPendingOrgPickerInWrongAccountState() throws {
        let state = makeState()
        state.sessionKey = "sk-old"
        state.orgId = "org-1"
        state.pendingSessionKey = "sk-new"
        state.pendingOrganizations = [
            Organization(uuid: "org-9", name: "DifferentAccount", capabilities: nil),
        ]
        state.pendingOrgPick = true
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "This key belongs to a different account. Pick org:")
        _ = try inspected.find(text: "DifferentAccount")
    }

    @Test func showsQuitButton() throws {
        let state = makeState()
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(button: "Quit ClaudeBar")
    }

    @Test func showsDoneButton() throws {
        let state = makeState()
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(button: "Done")
    }
}
