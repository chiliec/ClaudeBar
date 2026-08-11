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
    private let updater = SparkleUpdater()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var lastHiddenAt = Date.distantPast

    private static let panelWidth: CGFloat = 320

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeStatusItem()
        makePanel()
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
        // IS the slot — no extra padding; shorter labels center in the slack.
        statusItem.length = ("100%" as NSString).size(withAttributes: [.font: font]).width
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
                .background(PanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                // A status popover should snap, not animate: implicit animations here
                // turn every refresh and account switch into a visible wobble, and the
                // window resizes along with the content.
                .transaction { $0.animation = nil }
        )
        // Let the window follow the content's height: the popover swaps between usage,
        // settings and error views, which are all different sizes.
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
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
    /// Only move the panel here, never resize it: the hosting controller owns the
    /// window's size, and setting a size it disagrees with recurses until the stack
    /// overflows. Content that shouldn't change height is handled in the views.
    func windowDidResize(_ notification: Notification) {
        guard panel.isVisible else { return }
        positionPanel()
    }
}

/// The material AppKit uses for menu bar panels — what MenuBarExtra drew for free.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
