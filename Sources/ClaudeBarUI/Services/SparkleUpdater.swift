import Sparkle
import SwiftUI

/// Thin wrapper around `SPUStandardUpdaterController` so the rest of the
/// app doesn't import Sparkle directly. With Info.plist's
/// `SUEnableAutomaticChecks=true` and `SUScheduledCheckInterval=86400`,
/// initialising this is enough: Sparkle runs checks on launch and daily,
/// and presents its own dialog when an update is available.
@MainActor
@Observable
public final class SparkleUpdater {
    private let controller: SPUStandardUpdaterController

    public init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Triggers a manual update check, showing Sparkle's UI even if no
    /// update is available. Wired to a menu item only if/when one is added;
    /// currently unused but kept for future extension.
    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
