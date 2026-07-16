import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Owns the notch panel and two independent, stacked interaction layers:
///
/// 1. **Hidden ↔ Peek** (only when Hidden mode is on): top-edge sensor.
/// 2. **Collapsed ↔ Expanded**: hover on the notch panel.
///
/// Stability notes (why this file is careful about timers):
/// - Expanding resizes the panel under the cursor; AppKit often fires a spurious
///   `mouseExited` mid-animation. Collapsing immediately made the tray flicker.
/// - The collapsed panel is only ~notch height; a few points of miss used to
///   drop expand instantly. We debounce collapse and re-check mouse position.
@MainActor
final class NotchWindowController: ObservableObject {
    @Published private(set) var isExpanded: Bool = false
    @Published private(set) var isHiddenModeEnabled: Bool = false

    private var panel: NotchPanel?
    private var hostingView: DropHostingView?
    private var peekSensor: PeekSensorPanel?
    private weak var registry: WidgetRegistry?
    private weak var hud: SystemHUDController?
    private weak var sneakPeek: NotchSneakPeekController?

    private var isVisible = false
    private var retreatWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var activeOverlayCount = 0
    /// Ignore hover-exit events until this date (covers frame animation churn).
    private var suppressHoverExitUntil: Date?
    private var isAnimatingFrame = false

    private var collapsedSize: NSSize {
        let metrics = NotchGeometry.currentMetrics(for: preferredScreen())
        return NSSize(width: metrics.width, height: metrics.height)
    }
    private let overlaySize = NSSize(width: 300, height: 40)
    /// Tall enough for Media (art + timeline + volume + transport) and Calendar.
    private let expandedSize = NSSize(width: 620, height: 268)
    /// Grace before auto-collapse after the cursor leaves the panel.
    private let collapseDelay: TimeInterval = 0.55
    private let retreatDelay: TimeInterval = 1.0
    /// Extra padding around the panel when deciding if the mouse is "still near".
    private let nearPadding: CGFloat = 14

    private static let hiddenModeKey = "dynamo.hiddenMode"

    func attach(registry: WidgetRegistry, hud: SystemHUDController, sneakPeek: NotchSneakPeekController) {
        self.registry = registry
        self.hud = hud
        self.sneakPeek = sneakPeek
        if panel == nil {
            installPanel(registry: registry, hud: hud, sneakPeek: sneakPeek)
        } else if let hostingView {
            hostingView.rootView = NotchContentView(registry: registry, controller: self, hud: hud, sneakPeek: sneakPeek)
        }
        isHiddenModeEnabled = UserDefaults.standard.bool(forKey: Self.hiddenModeKey)
        reposition()
        applyInitialVisibility()
    }

    // MARK: - Expansion

    func revealAndExpand() {
        cancelCollapse()
        cancelRetreat()
        if !isVisible { showPanel() }
        expand()
    }

    func expand() {
        if !isVisible { showPanel() }
        cancelCollapse()
        // Frame animation under the cursor often synthesizes mouseExited — ignore
        // those for a beat so the tray doesn't slam shut.
        suppressHoverExitUntil = Date().addingTimeInterval(0.65)
        guard !isExpanded else { return }
        isExpanded = true
        animateFrame(to: expandedSize)
        // Become key so the first click on transport / scrubber fires (nonactivating panel).
        panel?.makeKey()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        suppressHoverExitUntil = Date().addingTimeInterval(0.35)
        animateFrame(to: collapsedSize)
    }

    // MARK: - Hover

    private func hoverEntered() {
        cancelCollapse()
        cancelRetreat()
        expand()
    }

    private func hoverExited() {
        if let until = suppressHoverExitUntil, Date() < until {
            return
        }
        // Debounce: give the user a chance to re-enter (and ignore resize noise).
        scheduleCollapse()
    }

    private func scheduleCollapse() {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.mouseIsNearPanel() {
                // Still over/near us — stay expanded.
                return
            }
            if self.activeOverlayCount > 0 {
                return
            }
            self.collapse()
            if self.isHiddenModeEnabled {
                self.scheduleRetreat()
            }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
    }

    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    /// True if the cursor is inside the panel frame plus a small margin.
    private func mouseIsNearPanel() -> Bool {
        guard let panel else { return false }
        let mouse = NSEvent.mouseLocation
        return panel.frame.insetBy(dx: -nearPadding, dy: -nearPadding).contains(mouse)
    }

    // MARK: - Peek layer

    private func peekSensorEntered() {
        guard isHiddenModeEnabled else { return }
        cancelRetreat()
        cancelCollapse()
        if !isVisible { showPanel() }
    }

    private func peekSensorExited() {
        guard isHiddenModeEnabled else { return }
        if mouseIsNearPanel() { return }
        scheduleRetreat()
    }

    // MARK: - Hidden mode

    func setHiddenMode(_ enabled: Bool) {
        guard enabled != isHiddenModeEnabled else { return }
        isHiddenModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.hiddenModeKey)
        if enabled {
            installPeekSensor()
            hidePanel()
        } else {
            removePeekSensor()
            cancelRetreat()
            cancelCollapse()
            showPanel()
        }
    }

    // MARK: - Transient overlays

    func presentForOverlay() {
        activeOverlayCount += 1
        cancelRetreat()
        cancelCollapse()
        if !isVisible { showPanel() }
        if !isExpanded {
            suppressHoverExitUntil = Date().addingTimeInterval(0.5)
            animateFrame(to: overlaySize)
        }
    }

    func overlayDidHide() {
        activeOverlayCount = max(0, activeOverlayCount - 1)
        guard activeOverlayCount == 0 else { return }
        if mouseIsNearPanel() {
            // Cursor still on the notch — keep or expand rather than snap shut.
            if !isExpanded { expand() }
            return
        }
        if !isExpanded {
            animateFrame(to: collapsedSize)
        }
        if isHiddenModeEnabled {
            scheduleRetreat()
        }
    }

    // MARK: - Visibility

    private func applyInitialVisibility() {
        if isHiddenModeEnabled {
            installPeekSensor()
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        isVisible = true
    }

    private func hidePanel() {
        guard activeOverlayCount == 0 else { return }
        cancelCollapse()
        if isExpanded {
            isExpanded = false
        }
        panel?.orderOut(nil)
        isVisible = false
    }

    private func scheduleRetreat() {
        cancelRetreat()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isHiddenModeEnabled, self.activeOverlayCount == 0 else { return }
            if self.mouseIsNearPanel() { return }
            self.hidePanel()
        }
        retreatWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retreatDelay, execute: work)
    }

    private func cancelRetreat() {
        retreatWorkItem?.cancel()
        retreatWorkItem = nil
    }

    // MARK: - Sensor

    private func installPeekSensor() {
        guard peekSensor == nil, let screen = preferredScreen() else { return }
        let sensor = PeekSensorPanel()
        sensor.onEntered = { [weak self] in
            Task { @MainActor in self?.peekSensorEntered() }
        }
        sensor.onExited = { [weak self] in
            Task { @MainActor in self?.peekSensorExited() }
        }
        sensor.place(on: screen)
        sensor.orderFrontRegardless()
        peekSensor = sensor
    }

    private func removePeekSensor() {
        peekSensor?.orderOut(nil)
        peekSensor = nil
    }

    // MARK: - Teardown

    func teardown() {
        cancelRetreat()
        cancelCollapse()
        removePeekSensor()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Setup

    private func installPanel(registry: WidgetRegistry, hud: SystemHUDController, sneakPeek: NotchSneakPeekController) {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: collapsedSize))
        let root = NotchContentView(registry: registry, controller: self, hud: hud, sneakPeek: sneakPeek)
        let hosting = DropHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: collapsedSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.onFileDrop = { [weak self] urls in
            guard let self, let registry = self.registry else { return false }
            let handled = registry.dispatchFileDrop(urls: urls)
            if handled {
                self.expand()
            }
            return handled
        }
        hosting.onMouseEntered = { [weak self] in self?.hoverEntered() }
        hosting.onMouseExited = { [weak self] in self?.hoverExited() }
        panel.contentView = hosting
        panel.registerForDraggedTypes([.fileURL])
        self.panel = panel
        self.hostingView = hosting
        reposition()
    }

    func reposition() {
        guard let panel, let screen = preferredScreen() else { return }
        let size = targetSize
        let origin = topCenterOrigin(size: size, on: screen)
        // Avoid fighting an in-flight hover animation with a hard setFrame.
        if isAnimatingFrame {
            return
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        peekSensor?.place(on: screen)
    }

    private var targetSize: NSSize {
        if isExpanded { return expandedSize }
        if activeOverlayCount > 0 { return overlaySize }
        return collapsedSize
    }

    private func animateFrame(to size: NSSize) {
        guard let panel, let screen = panel.screen ?? preferredScreen() else { return }
        let origin = topCenterOrigin(size: size, on: screen)
        let target = NSRect(origin: origin, size: size)
        isAnimatingFrame = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isAnimatingFrame = false
                // If the cursor stayed over us, keep expanded; if it left mid-animation,
                // the debounced collapse will handle it.
                if let self, self.isExpanded, !self.mouseIsNearPanel(), self.activeOverlayCount == 0 {
                    self.scheduleCollapse()
                }
            }
        })
    }

    func preferredScreen() -> NSScreen? {
        DisplayPreference.resolveScreen()
    }

    func applyPreferredDisplay() {
        if isHiddenModeEnabled {
            removePeekSensor()
            installPeekSensor()
        }
        isAnimatingFrame = false
        reposition()
    }

    private func topCenterOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let notchInset = max(screen.safeAreaInsets.top, menuBarHeight)
        let x = frame.midX - size.width / 2
        // Hang from the top of the screen into the notch band.
        let y = frame.maxY - size.height
        // When taller than the notch, still pin top edge to the screen top so
        // the expanded tray drops downward (not upward into empty space).
        _ = notchInset
        return NSPoint(x: x, y: y)
    }
}

// MARK: - Drop-capable hosting view

private final class DropHostingView: NSHostingView<NotchContentView> {
    var onFileDrop: (([URL]) -> Bool)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    /// Critical for accessory / nonactivating panels: the first click must
    /// reach SwiftUI buttons, not only focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // `.mouseMoved` is intentionally omitted (battery). Enter/exit is enough
        // when paired with debounced collapse on the controller.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        return onFileDrop?(urls) ?? false
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])
    }
}
