import AppKit

/// A thin, invisible, click-through sensor pinned to the very top edge of the
/// screen.
///
/// It uses an `NSTrackingArea` (mouseEntered / mouseExited) rather than a global
/// mouse-moved handler, so it only fires on actual entry/exit of the watched
/// strip — the cheap way to detect "the cursor reached the top edge" without a
/// listener that runs on every system-wide mouse move.
final class PeekSensorPanel: NSPanel {
    var onEntered: (() -> Void)? {
        get { sensorView.onEntered }
        set { sensorView.onEntered = newValue }
    }
    var onExited: (() -> Void)? {
        get { sensorView.onExited }
        set { sensorView.onExited = newValue }
    }

    private let sensorView = PeekSensorView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: PeekSensorPanel.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        contentView = sensorView
    }

    static let height: CGFloat = 4

    /// Pin the sensor across the full width of the very top edge of `screen`.
    func place(on screen: NSScreen) {
        let frame = screen.frame
        setFrame(
            NSRect(x: frame.minX, y: frame.maxY - Self.height, width: frame.width, height: Self.height),
            display: true
        )
    }
}

private final class PeekSensorView: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?
    private var installedTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let installedTrackingArea { removeTrackingArea(installedTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        installedTrackingArea = area
    }

    // Click-through: clicks in the top strip pass to the menu bar / windows
    // below, while enter/exit tracking still fires. This keeps the sensor from
    // stealing menu-bar clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { onEntered?() }
    override func mouseExited(with event: NSEvent) { onExited?() }
}
