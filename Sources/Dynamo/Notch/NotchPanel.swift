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
        // SwiftUI draws island shadow; AppKit shadow would double-blur.
        hasShadow = false
        // Real macOS floating utility chrome (menu-bar adjacent).
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
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .statusBar
        ignoresMouseEvents = false
        // Match system dark HUD so vibrancy materials resolve correctly.
        appearance = NSAppearance(named: .darkAqua)
        // Sharper compositing with desktop behind the glass.
        if let contentView {
            contentView.wantsLayer = true
            contentView.layerUsesCoreImageFilters = false
        }
    }

    /// First click both focuses the panel *and* reaches the control underneath
    /// (no “click once to focus, again to press”).
    override func mouseDown(with event: NSEvent) {
        makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}
