import SwiftUI

/// The sign-in panel shown in place of the usage rows when the active
/// account's session is dead. The header above it already names the account.
public struct SessionExpiredView: View {
    public let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        SignInView(
            state: state,
            title: String(localized: "session.expired", bundle: .module),
            subtitle: String(localized: "session.expiredSubtitle", bundle: .module),
            buttonLabel: String(localized: "action.signIn", bundle: .module),
            titleIcon: "exclamationmark.triangle",
            titleColor: .orange
        )
    }
}
