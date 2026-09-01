import SwiftUI
import AppKit
import ClaudeBarUI

@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The UI lives in the status item + panel owned by AppDelegate. SwiftUI still
        // requires a Scene, and an accessory app never shows this one.
        Settings { EmptyView() }
    }
}

/// Hosts the menu bar item and its panel by hand instead of using `MenuBarExtra`:
/// `MenuBarExtra` gives no control over where the panel lands, so it drifts sideways
/// whenever anything about the item changes. Here the panel hangs from the item's
/// left edge, and the item is given a fixed width so that edge never moves.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    /// Sparkle needs a real .app bundle -- Info.plist for SUFeedURL, and the
    /// framework's Updater.app to hand off to. `scripts/run.sh` runs the bare
    /// binary in `.build/debug`, where a check fails with "verify you have the
    /// latest version of debug". Nil there hides the button entirely.
    private let updater: SparkleUpdater? =
        Bundle.main.bundleURL.pathExtension == "app" ? SparkleUpdater() : nil

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var lastHiddenAt = Date.distantPast
    /// Applies the hosting controller's preferred size to the panel. AppKit does
    /// this itself for a contentViewController, but the panel's content view is
    /// the material backdrop instead — see makePanel().
    private var contentSizeObservation: NSKeyValueObservation?
    /// Held explicitly: the panel's content view is the backdrop, so nothing but the
    /// responder chain would keep the hosting controller alive.
    private var panelContent: NSViewController!

    private static let panelWidth: CGFloat = 320

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeStatusItem()
        makePanel()
        if let report = ProcessInfo.processInfo.environment["CLAUDEBAR_SMOKE"] {
            reportPanelGeometry(to: report)
        }
    }

    /// Release smoke test hook (`scripts/release.sh`). Launching the app only proves
    /// the bundle loads; three releases in a row were broken in the panel, which
    /// nothing opens until the user clicks. Open it and write out what it measures,
    /// so the release can fail on a panel that crashed, came up empty, or came up a
    /// different height than its content.
    private func reportPanelGeometry(to path: String) {
        showPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            let line = "panel=\(panel.frame.height)"
                + " content=\(panelContent.view.fittingSize.height)"
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Status item

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        button.font = font
        // Fixed width, not variableLength: menu bar items grow leftward, so an item
        // that resizes between "9%" and "100%" moves its own left edge — and the panel
        // hanging off it. Measured from the widest label rather than guessed, so the
        // item is exactly as wide as it needs to be.
        // "100%" is the widest possible label (utilization is capped), so its width
        // IS the slot; shorter labels center in the slack.
        // Measure the *button*, not the string: the cell insets its title, so a slot
        // sized to the bare string width leaves "100%" ~4pt short and the cell wraps
        // it onto two lines. intrinsicContentSize includes those insets.
        button.title = "100%"
        statusItem.length = button.intrinsicContentSize.width
        button.alignment = .center
        button.target = self
        button.action = #selector(togglePanel)
        observeLabel()
    }

    /// Redraw the label on every observable change AppState makes to it. Re-arming the
    /// tracking is required — `withObservationTracking` fires `onChange` only once.
    private func observeLabel() {
        withObservationTracking {
            updateLabel()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLabel() }
        }
    }

    private func updateLabel() {
        guard let button = statusItem.button else { return }
        if appState.isAuthenticated {
            button.title = appState.menuBarText
            button.image = nil
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Sign in")
        }
    }

    // MARK: - Panel

    private func makePanel() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.delegate = self

        let controller = NSHostingController(
            rootView: PopoverView(state: appState, updater: updater)
                // A status popover should snap, not animate: implicit animations here
                // turn every refresh and account switch into a visible wobble, and the
                // window resizes along with the content.
                .transaction { $0.animation = nil }
        )
        // Keeps preferredContentSize tracking the content, which the observation
        // below applies to the panel. The popover swaps between usage, settings and
        // error views, which are all different heights.
        controller.sizingOptions = [.preferredContentSize]

        // The controller is deliberately NOT the panel's contentViewController.
        // AppKit resizes the window for one from NSHostingView.windowDidLayout ->
        // updateAnimatedWindowSize, i.e. from inside the layout pass, and the
        // resize re-enters layout: NSView.setFrameOrigin: ->
        // _updateSimpleAutoresizingConstraintsInPlace -> NSISEngine
        // _flushPendingRemovals, which runs the main thread out of stack. Verified
        // by A/B: contentViewController crashes within seconds of the panel
        // opening, this arrangement does not. Applying the size from a KVO callback
        // instead keeps the resize outside the layout pass.
        let backdrop = NSVisualEffectView()
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 11
        backdrop.layer?.masksToBounds = true

        // Assign the backdrop first: a freshly constructed NSVisualEffectView has a
        // zero frame, and becoming the content view is what gives it the panel's
        // size. Sizing the hosting view from bounds before that leaves it at zero,
        // and an autoresizing mask scales a zero frame to nothing -- the panel then
        // shows a clipped slice of its content.
        panel.contentView = backdrop
        controller.view.frame = backdrop.bounds
        controller.view.autoresizingMask = [.width, .height]
        backdrop.addSubview(controller.view)
        panelContent = controller

        contentSizeObservation = controller.observe(
            \.preferredContentSize, options: [.initial, .new]
        ) { [weak self] controller, _ in
            MainActor.assumeIsolated {
                let size = controller.preferredContentSize
                guard let self, size.width > 0, size.height > 0 else { return }
                self.panel.setContentSize(size)
            }
        }
    }

    @objc private func togglePanel() {
        // Clicking the item while the panel is open resigns key first, which already
        // hid it — without this the same click would immediately reopen it.
        if panel.isVisible || Date().timeIntervalSince(lastHiddenAt) < 0.2 {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        panel.setFrameOrigin(menuBarPanelOrigin(
            statusItem: buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)),
            panelSize: panel.frame.size,
            visibleFrame: (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        ))
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHiddenAt = Date()
        // The panel's hosting view stays alive across opens, so PopoverView's
        // onDisappear never fires — reset here or the next open lands on Settings.
        appState.showingSettings = false
    }
}

/// A borderless NSPanel refuses key status by default, so it never resigns key and
/// never gets the signal to close on an outside click.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    /// Resizing keeps the bottom-left origin, which would grow the panel up into the
    /// menu bar — re-pin it to the status item instead.
    ///
    /// Only move the panel here, never resize it: the content's preferred size owns
    /// the window's size (see makePanel), and setting a size it disagrees with
    /// recurses until the stack overflows. Content that shouldn't change height is
    /// handled in the views.
    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible else { return }
        positionPanel()
    }
}

