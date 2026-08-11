import CoreGraphics

/// Bottom-left origin (AppKit screen coordinates) for the menu bar panel.
///
/// The panel's right edge is pinned to the status item's right edge: menu bar items
/// grow leftward, so the right edge is the only one that stays put as the label's
/// width changes. The result is clamped onto `visibleFrame`, which matters for a
/// status item near the right edge of the screen or on a narrow display.
public func menuBarPanelOrigin(
    statusItem: CGRect,
    panelSize: CGSize,
    visibleFrame: CGRect,
    gap: CGFloat = 4
) -> CGPoint {
    let rightAligned = statusItem.maxX - panelSize.width
    let leftLimit = visibleFrame.minX + gap
    let rightLimit = visibleFrame.maxX - panelSize.width - gap
    // max() last so a panel wider than the screen stays pinned to the left edge
    // instead of running off it.
    let x = max(leftLimit, min(rightAligned, rightLimit))
    return CGPoint(x: x, y: statusItem.minY - panelSize.height - gap)
}
