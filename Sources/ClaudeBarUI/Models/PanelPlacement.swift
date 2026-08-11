import CoreGraphics

/// Bottom-left origin (AppKit screen coordinates) for the menu bar panel.
///
/// The panel hangs from the status item's left edge, reading left-to-right like the
/// rest of the menu bar. That only stays put if the item itself has a fixed width —
/// menu bar items grow leftward, so a label that changes width moves its own left
/// edge. `AppDelegate` pins the item's width for exactly this reason.
///
/// The result is clamped onto `visibleFrame`, which matters for a status item near
/// the right edge of the screen or on a narrow display.
public func menuBarPanelOrigin(
    statusItem: CGRect,
    panelSize: CGSize,
    visibleFrame: CGRect,
    gap: CGFloat = 4
) -> CGPoint {
    let leftLimit = visibleFrame.minX + gap
    let rightLimit = visibleFrame.maxX - panelSize.width - gap
    // max() last so a panel wider than the screen stays pinned to the left edge
    // instead of running off it.
    let x = max(leftLimit, min(statusItem.minX, rightLimit))
    return CGPoint(x: x, y: statusItem.minY - panelSize.height - gap)
}
