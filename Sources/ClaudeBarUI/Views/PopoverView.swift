import SwiftUI

public struct PopoverView: View {
    @Bindable public var state: AppState
    private let license: LicenseStore
    private let updater: SparkleUpdater?

    @MainActor
    public init(state: AppState, license: LicenseStore? = nil, updater: SparkleUpdater? = nil) {
        self.state = state
        self.license = license ?? LicenseStore()
        self.updater = updater
    }

    public var body: some View {
        VStack(spacing: 0) {
            if state.showingSettings {
                SettingsView(state: state, license: license, updater: updater)
            } else if state.error == .sessionExpired {
                // Session-expired routing must precede !isAuthenticated:
                // handleSessionExpired nils the credentials, so isAuthenticated is
                // false, but the cached profile lets us name the account.
                SessionExpiredView(state: state)
            } else if state.error == .keychainLocked {
                // Same ordering reason as sessionExpired above: a Keychain
                // failure during loadCredentials also leaves isAuthenticated
                // false, so this must be checked before the SetupView fallback.
                KeychainLockedView(state: state)
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
        state.credentials = OAuthCredentials(
            accessToken: "fake-token",
            refreshToken: "fake-refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
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
        return state
    }
}

#Preview("Usage Detail") {
    PopoverView(state: .previewWithUsage, license: LicenseStore())
}

#Preview("Setup") {
    PopoverView(state: .previewNotAuthenticated, license: LicenseStore())
}

#Preview("Session Expired") {
    PopoverView(state: .previewSessionExpired, license: LicenseStore())
}
