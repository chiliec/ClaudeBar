import CoreGraphics
import Testing
@testable import ClaudeBarUI

@Suite
struct PanelPlacementTests {
    // A 1440x900 display with a 24pt menu bar: visibleFrame stops below it.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 876)
    private let panel = CGSize(width: 320, height: 400)

    private func statusItem(maxX: CGFloat, width: CGFloat = 80) -> CGRect {
        CGRect(x: maxX - width, y: 876, width: width, height: 24)
    }

    @Test func pinsRightEdgeToStatusItemRightEdge() {
        let item = statusItem(maxX: 1200)
        let origin = menuBarPanelOrigin(statusItem: item, panelSize: panel, visibleFrame: screen)

        #expect(origin.x + panel.width == item.maxX)
    }

    @Test func widerLabelDoesNotMovePanel() {
        // Same right edge, different widths — this is the drift the pinning prevents.
        let narrow = menuBarPanelOrigin(statusItem: statusItem(maxX: 1200, width: 50),
                                        panelSize: panel, visibleFrame: screen)
        let wide = menuBarPanelOrigin(statusItem: statusItem(maxX: 1200, width: 140),
                                      panelSize: panel, visibleFrame: screen)

        #expect(narrow == wide)
    }

    @Test func hangsBelowTheStatusItem() {
        let item = statusItem(maxX: 1200)
        let origin = menuBarPanelOrigin(statusItem: item, panelSize: panel, visibleFrame: screen)

        #expect(origin.y == item.minY - panel.height - 4)
    }

    @Test func clampsToScreenWhenStatusItemIsNearTheRightEdge() {
        let origin = menuBarPanelOrigin(statusItem: statusItem(maxX: 1439),
                                        panelSize: panel, visibleFrame: screen)

        #expect(origin.x + panel.width <= screen.maxX)
    }

    @Test func clampsToScreenWhenStatusItemIsNearTheLeftEdge() {
        let origin = menuBarPanelOrigin(statusItem: statusItem(maxX: 100),
                                        panelSize: panel, visibleFrame: screen)

        #expect(origin.x >= screen.minX)
    }

    @Test func staysOnScreenWhenPanelIsWiderThanTheDisplay() {
        let narrowScreen = CGRect(x: 0, y: 0, width: 200, height: 400)
        let origin = menuBarPanelOrigin(statusItem: statusItem(maxX: 180),
                                        panelSize: panel, visibleFrame: narrowScreen)

        #expect(origin.x >= narrowScreen.minX)
    }

    @Test func respectsANonZeroScreenOrigin() {
        // Second display to the right of the primary one.
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1056)
        let origin = menuBarPanelOrigin(statusItem: CGRect(x: 1500, y: 1056, width: 80, height: 24),
                                        panelSize: panel, visibleFrame: secondary)

        #expect(origin.x >= secondary.minX)
    }
}
