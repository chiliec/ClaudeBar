import SwiftUI

public struct PopoverView: View {
    @Bindable public var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            if state.showingSettings || state.pendingOrgPick {
                // Pending-pick state lives in SettingsView; auto-route there
                // so the user can resolve it from any source view.
                SettingsView(state: state)
            } else if state.error == .sessionExpired, state.orgId != nil {
                // Session-expired routing must precede !isAuthenticated:
                // handleSessionExpired nils sessionKey, so isAuthenticated is false,
                // but the cached orgId lets us show the personalized reconnect view.
                SessionExpiredView(state: state)
            } else if !state.isAuthenticated {
                SetupView(state: state)
            } else {
                UsageDetailView(state: state)
            }
        }
        .frame(width: 320)
        .onDisappear {
            state.showingSettings = false
        }
    }
}

// MARK: - Previews

private extension AppState {
    static var previewWithUsage: AppState {
        let state = AppState(keychain: KeychainService(serviceName: "com.claudebar.preview"))
        state.sessionKey = "fake-key"
        state.orgId = "fake-org"
        state.usage = UsageResponse(
            fiveHour: WindowUsage(utilization: 0.42, resetsAt: Date().addingTimeInterval(3600 * 2)),
            sevenDay: WindowUsage(utilization: 0.65, resetsAt: Date().addingTimeInterval(86400 * 3)),
            sevenDaySonnet: WindowUsage(utilization: 0.30, resetsAt: Date().addingTimeInterval(86400 * 3)),
            sevenDayOpus: WindowUsage(utilization: 0.78, resetsAt: Date().addingTimeInterval(86400 * 3)),
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 200, usedCredits: 45, utilization: 0.225)
        )
        state.lastUpdated = Date()
        return state
    }

    static var previewNotAuthenticated: AppState {
        AppState(keychain: KeychainService(serviceName: "com.claudebar.preview"))
    }

    static var previewSessionExpired: AppState {
        let state = AppState(keychain: KeychainService(serviceName: "com.claudebar.preview"))
        state.error = .sessionExpired
        state.sessionKey = "fake-key"
        state.orgId = "fake-org"
        return state
    }
}

#Preview("Usage Detail") {
    PopoverView(state: .previewWithUsage)
}

#Preview("Setup") {
    PopoverView(state: .previewNotAuthenticated)
}

#Preview("Session Expired") {
    PopoverView(state: .previewSessionExpired)
}

#Preview("Session Key Input") {
    SessionKeyInputView(
        state: .previewNotAuthenticated,
        title: "Custom Title",
        subtitle: "Custom subtitle with **markdown** support",
        buttonLabel: "Submit",
        titleIcon: "key.fill",
        titleColor: .blue,
        showQuitButton: true
    )
    .frame(width: 320)
}
