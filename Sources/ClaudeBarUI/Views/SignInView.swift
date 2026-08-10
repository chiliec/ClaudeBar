import SwiftUI

/// The shared sign-in panel. Setup, session-expired, and Keychain-locked all
/// funnel into the same browser OAuth flow, so they share one view.
struct SignInView: View {
    let state: AppState
    let title: String
    let subtitle: String
    let buttonLabel: String
    let titleIcon: String?
    let titleColor: Color?
    let showQuitButton: Bool

    init(
        state: AppState,
        title: String,
        subtitle: String,
        buttonLabel: String,
        titleIcon: String? = nil,
        titleColor: Color? = nil,
        showQuitButton: Bool = false
    ) {
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.buttonLabel = buttonLabel
        self.titleIcon = titleIcon
        self.titleColor = titleColor
        self.showQuitButton = showQuitButton
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

            if state.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }

            if let error = state.error, error != .sessionExpired {
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button {
                    guard !state.isLoading else { return }
                    Task { await state.signIn() }
                } label: {
                    Text(buttonLabel)
                }
                .modifier(ProminentButtonModifier())
                .keyboardShortcut(.defaultAction)
                .disabled(state.isLoading)
            }

            if showQuitButton {
                Divider()
                QuitButton(foregroundStyle: .secondary)
            }
        }
        .padding(16)
    }
}
