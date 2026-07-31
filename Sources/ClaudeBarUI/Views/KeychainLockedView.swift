import SwiftUI

public struct KeychainLockedView: View {
    public let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        SessionKeyInputView(
            state: state,
            title: String(localized: "keychain.locked", bundle: .module),
            subtitle: String(localized: "keychain.lockedSubtitle", bundle: .module),
            buttonLabel: String(localized: "action.reconnect", bundle: .module),
            titleIcon: "lock.trianglebadge.exclamationmark",
            titleColor: .orange,
            submitAction: { [state] key in await state.updateSessionKey(key) }
        )
    }
}
