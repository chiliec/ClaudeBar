import SwiftUI

struct SessionKeyInputView: View {
    let state: AppState
    let title: String
    let subtitle: String
    let buttonLabel: String
    let titleIcon: String?
    let titleColor: Color?
    let showQuitButton: Bool
    /// Optional submit handler. When set, replaces the default `validateAndFetchOrgs`
    /// behavior — used by SessionExpiredView to route through `updateSessionKey`,
    /// which preserves the cached `orgId` when the new key is for the same account.
    let submitAction: ((String) async -> Void)?

    @State private var keyInput = ""
    @State private var selectedOrgId: String?

    init(
        state: AppState,
        title: String,
        subtitle: String,
        buttonLabel: String,
        titleIcon: String? = nil,
        titleColor: Color? = nil,
        showQuitButton: Bool = false,
        submitAction: ((String) async -> Void)? = nil
    ) {
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.buttonLabel = buttonLabel
        self.titleIcon = titleIcon
        self.titleColor = titleColor
        self.showQuitButton = showQuitButton
        self.submitAction = submitAction
    }

    private func submit() {
        guard !keyInput.isEmpty, !state.isLoading else { return }
        Task {
            if let submitAction {
                await submitAction(keyInput)
            } else {
                await state.validateAndFetchOrgs(sessionKey: keyInput)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let icon = titleIcon {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(titleColor ?? .primary)
            } else {
                Text(title)
                    .font(.headline)
            }

            Text(.init(subtitle))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("", text: $keyInput, prompt: Text("setup.sessionKeyPlaceholder", bundle: .module))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit { submit() }

            if state.selectableOrganizations.count > 1 {
                Text("setup.selectOrganization", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedOrgId) {
                    Text("setup.chooseOrganization", bundle: .module)
                        .tag(nil as String?)
                    ForEach(state.selectableOrganizations, id: \.uuid) { org in
                        Text(org.displayName).tag(org.uuid as String?)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedOrgId) { _, newValue in
                    guard let orgId = newValue,
                          let org = state.organizations.first(where: { $0.uuid == orgId }) else { return }
                    Task { await state.switchOrganization(to: org) }
                }
            }

            if state.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }

            if let error = state.error {
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button {
                    submit()
                } label: {
                    Text(buttonLabel)
                }
                .modifier(ProminentButtonModifier())
                .keyboardShortcut(.defaultAction)
                .disabled(keyInput.isEmpty || state.isLoading)
            }

            if showQuitButton {
                Divider()
                QuitButton(foregroundStyle: .secondary)
            }
        }
        .padding(16)
    }
}
