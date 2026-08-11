import SwiftUI
import ServiceManagement

public struct SettingsView: View {
    @Bindable public var state: AppState
    private let updater: SparkleUpdater?

    @State private var platformPasteDraft: String = ""
    @State private var platformPasteError: String?

    public init(state: AppState, updater: SparkleUpdater? = nil) {
        self.state = state
        self.updater = updater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("settings.title", bundle: .module)
                    .font(.headline)
                Spacer()
                Button {
                    state.showingSettings = false
                } label: {
                    Text("action.done", bundle: .module)
                }
                .modifier(BorderedButtonModifier())
                .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sessionGroup
                    platformAPISection

                    // Launch at login
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            LaunchAtLoginToggle()
                            if let updater {
                                Divider()
                                HStack {
                                    Button {
                                        updater.checkForUpdates()
                                    } label: {
                                        Text("action.checkForUpdates", bundle: .module)
                                    }
                                    .modifier(BorderedButtonModifier())
                                    .controlSize(.small)
                                    Spacer()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        Text("settings.general", bundle: .module)
                    }
                }
            }
            .scrollIndicators(.automatic)

            Divider()
            QuitButton()
        }
        .padding(12)
        .frame(height: 460)
    }

    @ViewBuilder
    private var sessionGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if state.accounts.isEmpty {
                    connectionStatusLine
                } else {
                    ForEach(state.accounts) { account in
                        accountRow(account)
                    }
                }
                Button {
                    Task { await state.signIn() }
                } label: { Text("action.addAccount", bundle: .module) }
                .modifier(BorderedButtonModifier())
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("settings.accounts", bundle: .module)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account) -> some View {
        HStack {
            Circle()
                .fill(account.id == state.activeID ? .green : .secondary)
                .frame(width: 8, height: 8)
            let label = account.label.isEmpty
                ? String(localized: "settings.connected", bundle: .module)
                : account.label
            if account.id == state.activeID {
                Text(label)
                    .font(.subheadline)
            } else {
                Button {
                    state.switchTo(id: account.id)
                } label: { Text(label) }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
            Spacer()
            Button {
                state.removeAccount(id: account.id)
            } label: { Text("action.remove", bundle: .module) }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var platformAPISection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                platformStatusRow
                if state.platformSessionKey == nil {
                    platformPasteField
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("settings.platformAPI", bundle: .module)
        }
    }

    @ViewBuilder
    private var platformStatusRow: some View {
        HStack {
            Circle()
                .fill(state.platformSessionKey != nil ? .green : .secondary)
                .frame(width: 8, height: 8)
            if let credits = state.platformCredits, state.platformSessionKey != nil {
                Text("settings.platformAPI.connected", bundle: .module)
                    .font(.subheadline)
                Text(verbatim: "· \(credits.formatted())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if state.platformSessionKey != nil {
                Text("settings.platformAPI.connected", bundle: .module)
                    .font(.subheadline)
            } else {
                Text("settings.platformAPI.notConnected", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.platformSessionKey != nil {
                Button {
                    state.disconnectPlatform()
                    platformPasteDraft = ""
                    platformPasteError = nil
                } label: {
                    Text("settings.platformAPI.disconnect", bundle: .module)
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var platformPasteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.platformAPI.pasteManually", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("", text: $platformPasteDraft, prompt: Text("setup.sessionKeyPlaceholder", bundle: .module))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button {
                    let trimmed = platformPasteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    platformPasteError = nil
                    Task {
                        await state.connectPlatform(sessionKey: trimmed)
                        platformPasteDraft = ""
                    }
                } label: {
                    Text("action.update", bundle: .module)
                }
                .modifier(BorderedButtonModifier())
                .controlSize(.small)
                .disabled(platformPasteDraft.isEmpty)
            }
            if let platformPasteError {
                Text(platformPasteError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var connectionStatusLine: some View {
        HStack {
            Circle()
                .fill(state.isAuthenticated ? .green : .red)
                .frame(width: 8, height: 8)
            if state.isAuthenticated, let orgName = state.organizationDetails?.name {
                Text("settings.connectedAs \(orgName)", bundle: .module)
                    .font(.subheadline)
            } else if state.isAuthenticated {
                Text("settings.connected", bundle: .module)
                    .font(.subheadline)
            } else {
                Text("settings.notConnected", bundle: .module)
                    .font(.subheadline)
            }
        }
    }

}

struct LaunchAtLoginToggle: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle(isOn: $launchAtLogin) {
            Text("settings.launchAtLogin", bundle: .module)
        }
        .font(.subheadline)
        .onChange(of: launchAtLogin) { _, newValue in
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = !newValue
            }
        }
    }
}

#Preview("Settings - Connected") {
    let state = AppState(keychain: KeychainService(serviceName: "com.claudebar.preview"))
    state.credentials = OAuthCredentials(
        accessToken: "fake-token",
        refreshToken: "fake-refresh",
        expiresAt: Date().addingTimeInterval(3600)
    )
    state.organizationDetails = OrganizationDetails(uuid: "fake-org", name: "Acme Inc", rateLimitTier: "default_claude_max_5x")
    return SettingsView(state: state)
}

#Preview("Settings - Disconnected") {
    SettingsView(state: AppState(keychain: KeychainService(serviceName: "com.claudebar.preview")))
}
