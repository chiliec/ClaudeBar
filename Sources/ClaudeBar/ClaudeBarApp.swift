import SwiftUI
import ClaudeBarUI

@main
struct ClaudeBarApp: App {
    @State private var appState = AppState()
    @State private var updater = SparkleUpdater()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: appState, updater: updater)
        } label: {
            if appState.isAuthenticated {
                HStack(spacing: 4) {
                    RingProgressView(
                        progress: appState.menuBarUtilization,
                        color: appState.usageColor.swiftUIColor
                    )
                    Text(appState.menuBarText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(appState.error == .sessionExpired
                            ? Color.gray
                            : appState.usageColor.swiftUIColor)
                }
            } else {
                Image(systemName: "key.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
