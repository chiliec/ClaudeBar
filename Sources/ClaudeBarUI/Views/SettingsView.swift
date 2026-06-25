import SwiftUI
import ServiceManagement

public struct SettingsView: View {
    @Bindable public var state: AppState
    private let updater: SparkleUpdater?

    @State private var keyDraft: String = ""
    @State private var inlineKeyError: String?
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
                connectionStatusLine

                if state.isAuthenticated && !state.pendingOrgPick {
                    sessionKeyEditor
                    if state.visibleOrganizations.count > 1 {
                        orgPicker
                    }
                    Button {
                        state.signOut()
                    } label: {
                        Text("action.signOut", bundle: .module)
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if state.pendingOrgPick {
                    pendingPickPrompt
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("settings.session", bundle: .module)
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
            if state.isAuthenticated, let orgName = currentOrgName() {
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

    @ViewBuilder
    private var sessionKeyEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.sessionKey", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("", text: $keyDraft, prompt: Text("setup.sessionKeyPlaceholder", bundle: .module))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button {
                    inlineKeyError = nil
                    Task {
                        await state.updateSessionKey(keyDraft)
                        switch state.error {
                        case .api(.sessionExpired):
                            inlineKeyError = String(localized: "update.badKey", bundle: .module)
                        case .some(let err):
                            inlineKeyError = err.message
                        case .none:
                            keyDraft = ""
                        }
                    }
                } label: {
                    Text("action.update", bundle: .module)
                }
                .modifier(BorderedButtonModifier())
                .controlSize(.small)
                .disabled(keyDraft.isEmpty || state.isLoading)
            }
            if let inlineKeyError {
                Text(inlineKeyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var orgPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.organization", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: orgSelectionBinding) {
                ForEach(state.visibleOrganizations, id: \.uuid) { org in
                    Text(org.displayName).tag(org.uuid as String?)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var pendingPickPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("update.wrongAccount", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.orange)
            ForEach(state.pendingOrganizations, id: \.uuid) { org in
                Button {
                    Task { await state.confirmPendingOrg(org) }
                } label: {
                    Text(org.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                state.cancelPendingOrgPick()
                keyDraft = ""
                inlineKeyError = nil
            } label: {
                Text("action.cancel", bundle: .module)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func currentOrgName() -> String? {
        guard let orgId = state.orgId else { return nil }
        return state.organizations.first(where: { $0.uuid == orgId })?.displayName
    }

    private var orgSelectionBinding: Binding<String?> {
        Binding(
            get: { state.orgId },
            set: { newValue in
                guard let uuid = newValue,
                      uuid != state.orgId,
                      let org = state.organizations.first(where: { $0.uuid == uuid }) else { return }
                Task { await state.switchOrganization(to: org) }
            }
        )
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
    let state = AppState(
        keychain: KeychainService(serviceName: "com.claudebar.preview"),
        orgListStore: InMemoryOrgListStore(initial: [
            Organization(uuid: "fake-org", name: "Acme Inc", capabilities: nil)
        ])
    )
    state.sessionKey = "fake-key"
    state.orgId = "fake-org"
    state.organizations = [Organization(uuid: "fake-org", name: "Acme Inc", capabilities: nil)]
    return SettingsView(state: state)
}

#Preview("Settings - Multi-Org") {
    let state = AppState(
        keychain: KeychainService(serviceName: "com.claudebar.preview"),
        orgListStore: InMemoryOrgListStore()
    )
    state.sessionKey = "fake-key"
    state.orgId = "org-1"
    state.organizations = [
        Organization(uuid: "org-1", name: "Personal", capabilities: nil),
        Organization(uuid: "org-2", name: "Work", capabilities: nil),
    ]
    return SettingsView(state: state)
}

#Preview("Settings - Disconnected") {
    SettingsView(state: AppState(
        keychain: KeychainService(serviceName: "com.claudebar.preview"),
        orgListStore: InMemoryOrgListStore()
    ))
}
