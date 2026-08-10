import Foundation
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

    private func authenticated(_ state: AppState) -> AppState {
        state.credentials = OAuthCredentials(
            accessToken: "sk-at-test",
            refreshToken: "sk-rt-test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        return state
    }

    @Test func showsSetupViewWhenNotAuthenticated() throws {
        let state = makeState()
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(SetupView.self)
    }

    @Test func showsSessionExpiredView() throws {
        let state = authenticated(makeState())
        state.error = .sessionExpired
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(SessionExpiredView.self)
    }

    @Test func showsUsageDetailWhenAuthenticated() throws {
        let state = authenticated(makeState())
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
        // handleSessionExpired nils credentials; routing must key off `.sessionExpired`
        // rather than isAuthenticated.
        let state = makeState()
        state.error = .sessionExpired
        let view = PopoverView(state: state)
        let inspected = try view.inspect()

        _ = try inspected.find(SessionExpiredView.self)
        #expect(throws: (any Error).self) { try inspected.find(SetupView.self) }
    }

    @Test func showsSessionExpiredViewWithoutCredentials() throws {
        // handleSessionExpired nils credentials but keeps the profile.
        let state = makeState()
        state.organizationDetails = OrganizationDetails(uuid: "org-1", name: "Acme", rateLimitTier: nil)
        state.error = .sessionExpired
        let inspected = try PopoverView(state: state).inspect()

        _ = try inspected.find(SessionExpiredView.self)
        #expect(throws: (any Error).self) { try inspected.find(SetupView.self) }
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

        _ = try inspected.find(text: "Sign in with your Claude account. Your browser will open to claude.ai — approve access and come back here.")
    }

    @Test func showsSignInButton() throws {
        let view = SetupView(state: makeState())
        let button = try view.inspect().find(button: "Sign in with Claude")
        #expect(try button.labelView().text().string() == "Sign in with Claude")
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
}

// MARK: - SessionExpiredView Tests

@MainActor
@Suite
struct SessionExpiredViewTests {
    private func makeState() -> AppState {
        AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
    }

    @Test func showsGenericTitleWhenNoOrgCached() throws {
        let state = makeState()
        let view = SessionExpiredView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Session Expired")
    }

    @Test func showsOrgNameInTitleWhenCached() throws {
        let state = makeState()
        state.organizationDetails = OrganizationDetails(uuid: "org-123", name: "Acme", rateLimitTier: nil)
        let view = SessionExpiredView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Reconnect Acme")
    }

    @Test func showsSignInButton() throws {
        let state = makeState()
        let view = SessionExpiredView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(button: "Sign in with Claude")
    }
}

// MARK: - UsageDetailView Header Tests

@MainActor
@Suite
struct UsageDetailViewHeaderTests {
    private func makeState() -> AppState {
        AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
    }

    @Test func showsOrgNameFromProfileInHeader() throws {
        let state = makeState()
        state.organizationDetails = OrganizationDetails(uuid: "org-1", name: "Acme", rateLimitTier: nil)
        let inspected = try UsageDetailView(state: state).inspect()
        _ = try inspected.find(text: "Acme")
    }

    @Test func fallsBackToTitleWithoutProfile() throws {
        let state = makeState()
        let inspected = try UsageDetailView(state: state).inspect()
        _ = try inspected.find(text: "Claude Usage")
    }

    // MARK: - Per-model 7-day window rows

    @Test func showsSonnetAndDesignRowsWhenReported() throws {
        let state = makeState()
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
        let state = makeState()
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
        let state = makeState()
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
        let state = makeState()
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
        AppState(keychain: KeychainService(serviceName: "com.claudebar.test"))
    }

    private func authenticated(_ state: AppState) -> AppState {
        state.credentials = OAuthCredentials(
            accessToken: "sk-at-test",
            refreshToken: "sk-rt-test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        return state
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
        let state = authenticated(makeState())
        state.organizationDetails = OrganizationDetails(uuid: "org-123", name: "Acme", rateLimitTier: nil)
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(text: "Connected as Acme")
    }

    @Test func showsSignOutButtonWhenAuthenticated() throws {
        let state = authenticated(makeState())
        let view = SettingsView(state: state)
        let inspected = try view.inspect()
        _ = try inspected.find(button: "Sign out")
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
