import CoreGraphics
import Testing
@testable import ClaudeBarUI

@Suite
struct PanelPlacementTests {
    // A 1440x900 display with a 24pt menu bar: visibleFrame stops below it.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 876)
    private let panel = CGSize(width: 320, height: 400)

    private func statusItem(minX: CGFloat, width: CGFloat = 50) -> CGRect {
        CGRect(x: minX, y: 876, width: width, height: 24)
    }

    @Test func hangsFromTheStatusItemLeftEdge() {
        let item = statusItem(minX: 1100)
        let origin = menuBarPanelOrigin(statusItem: item, panelSize: panel, visibleFrame: screen)

        #expect(origin.x == item.minX)
    }

    @Test func hangsBelowTheStatusItem() {
        let item = statusItem(minX: 1100)
        let origin = menuBarPanelOrigin(statusItem: item, panelSize: panel, visibleFrame: screen)

        #expect(origin.y == item.minY - panel.height - 4)
    }

    /// The item's width is pinned in AppDelegate precisely so this holds: a wider
    /// label must not drag the panel sideways.
    @Test func labelWidthDoesNotMovePanel() {
        let narrow = menuBarPanelOrigin(statusItem: statusItem(minX: 1100, width: 50),
                                        panelSize: panel, visibleFrame: screen)
        let wide = menuBarPanelOrigin(statusItem: statusItem(minX: 1100, width: 140),
                                      panelSize: panel, visibleFrame: screen)

        #expect(narrow == wide)
    }

    @Test func clampsToScreenWhenStatusItemIsNearTheRightEdge() {
        let origin = menuBarPanelOrigin(statusItem: statusItem(minX: 1400),
                                        panelSize: panel, visibleFrame: screen)

        #expect(origin.x + panel.width <= screen.maxX)
    }

    @Test func clampsToScreenWhenStatusItemIsAtTheLeftEdge() {
        let origin = menuBarPanelOrigin(statusItem: statusItem(minX: 0),
                                        panelSize: panel, visibleFrame: screen)

        #expect(origin.x >= screen.minX)
    }

    @Test func staysOnScreenWhenPanelIsWiderThanTheDisplay() {
        let narrowScreen = CGRect(x: 0, y: 0, width: 200, height: 400)
        let origin = menuBarPanelOrigin(statusItem: statusItem(minX: 130),
                                        panelSize: panel, visibleFrame: narrowScreen)

        #expect(origin.x >= narrowScreen.minX)
    }

    @Test func respectsANonZeroScreenOrigin() {
        // Second display to the right of the primary one.
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1056)
        let origin = menuBarPanelOrigin(statusItem: CGRect(x: 3300, y: 1056, width: 50, height: 24),
                                        panelSize: panel, visibleFrame: secondary)

        #expect(origin.x + panel.width <= secondary.maxX)
    }
}
