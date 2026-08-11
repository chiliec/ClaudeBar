import AppKit
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController` so the rest of the
/// app doesn't import Sparkle directly. With Info.plist's
/// `SUEnableAutomaticChecks=true` and `SUScheduledCheckInterval=86400`,
/// initialising this is enough: Sparkle runs checks on launch and daily,
/// and presents its own dialog when an update is available.
@MainActor
public final class SparkleUpdater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    public override init() {
        super.init()
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    /// Triggers a manual update check, showing Sparkle's UI even if no
    /// update is available. Wired to Settings' "Check for Updates" button.
    public func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// An accessory app (no Dock icon) can't bring windows forward unless it
    /// activates itself first — without this, Sparkle's Software Update dialog
    /// opens behind every other window and looks like the check did nothing.
    /// Covers scheduled checks too, where `checkForUpdates()` never runs.
    public nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
