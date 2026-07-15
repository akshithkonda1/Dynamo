import AppKit

/// Borderless floating panel for the notch. Must accept first-click and become
/// key so SwiftUI `Button`s work without a prior click to focus the window.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        // Allow the panel to become key on click so buttons receive the event.
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .statusBar
        // Ensure mouse events hit our content even when another app is active.
        ignoresMouseEvents = false
    }

    /// First click both focuses the panel *and* reaches the control underneath
    /// (no “click once to focus, again to press”).
    override func mouseDown(with event: NSEvent) {
        makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}
