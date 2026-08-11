import SwiftUI

public struct SessionExpiredView: View {
    public let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        SignInView(
            state: state,
            title: titleString,
            subtitle: String(localized: "session.expiredSubtitle", bundle: .module),
            buttonLabel: String(localized: "action.signIn", bundle: .module),
            titleIcon: "exclamationmark.triangle",
            titleColor: .orange
        )
    }

    private var titleString: String {
        if let name = state.organizationDetails?.displayName {
            return String(localized: "session.reconnect \(name)", bundle: .module)
        }
        return String(localized: "session.expired", bundle: .module)
    }
}
