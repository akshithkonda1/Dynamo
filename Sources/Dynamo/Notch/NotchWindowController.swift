import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Owns the notch panel and two independent, stacked interaction layers:
///
/// 1. **Hidden ↔ Peek** (only when Hidden mode is on): a top-of-screen
///    `NSTrackingArea` sensor reveals the collapsed notch when the cursor nears
///    the top edge, and retreats it after a short delay when the cursor leaves.
/// 2. **Collapsed ↔ Expanded**: the existing hover mechanic, now driven by an
///    `NSTrackingArea` on the notch itself instead of a global mouse-moved
///    monitor (which was flagged as a battery-drain source).
///
/// Expansion stays a single boolean (`isExpanded`) so the animation is coherent.
@MainActor
final class NotchWindowController: ObservableObject {
    @Published private(set) var isExpanded: Bool = false
    /// User preference: when on, the notch stays hidden until the cursor peeks
    /// it out from the top edge. Default off — never forced on.
    @Published private(set) var isHiddenModeEnabled: Bool = false

    private var panel: NotchPanel?
    private var hostingView: DropHostingView?
    private var peekSensor: PeekSensorPanel?
    private weak var registry: WidgetRegistry?
    private weak var hud: SystemHUDController?
    private weak var sneakPeek: NotchSneakPeekController?

    /// Whether the notch panel is currently on screen. In non-hidden mode this
    /// is always true; in hidden mode it's true only while peeking / expanded /
    /// showing a HUD.
    private var isVisible = false
    private var retreatWorkItem: DispatchWorkItem?
    /// Number of transient overlays (volume/brightness HUD, now-playing sneak
    /// peek, ...) currently keeping the notch visible/widened, even in Hidden
    /// mode. A counter rather than a bool so two independent overlays can't
    /// clobber each other if they happen to overlap.
    private var activeOverlayCount = 0

    /// The collapsed panel hugs the physical notch so it disappears into the
    /// real cutout at rest. Sized from `NotchGeometry` (height from the screen's
    /// `safeAreaInsets`, width an on-device-tuned approximation).
    private var collapsedSize: NSSize {
        let metrics = NotchGeometry.currentMetrics(for: preferredScreen())
        return NSSize(width: metrics.width, height: metrics.height)
    }
    /// A transient overlay (volume/brightness HUD, sneak peek) needs more room
    /// than the bare notch, so the panel briefly widens (Dynamic-Island style)
    /// while one is showing.
    private let overlaySize = NSSize(width: 320, height: 40)
    /// Wider (Boring Notch uses ~640) with a little extra height for a roomier,
    /// more welcoming feel than a tight media strip.
    private let expandedSize = NSSize(width: 640, height: 215)
    /// Don't retreat the instant the cursor leaves — a short grace avoids a
    /// flickery, twitchy feel.
    private let retreatDelay: TimeInterval = 1.0

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

    // MARK: - Expansion (Collapsed ↔ Expanded)

    /// Menu-bar / debug entry: ensure the panel is visible and expanded so the
    /// tray is obvious even when collapsed into the physical notch.
    func revealAndExpand() {
        cancelRetreat()
        if !isVisible { showPanel() }
        expand()
    }

    func expand() {
        if !isVisible { showPanel() }
        guard !isExpanded else { return }
        isExpanded = true
        animateFrame(to: expandedSize)
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        animateFrame(to: collapsedSize)
    }

    // MARK: - Hover layer (driven by the notch's tracking area)

    private func hoverEntered() {
        cancelRetreat()
        expand()
    }

    private func hoverExited() {
        collapse()
        if isHiddenModeEnabled {
            scheduleRetreat()
        }
    }

    // MARK: - Peek layer (driven by the top-edge sensor)

    private func peekSensorEntered() {
        guard isHiddenModeEnabled else { return }
        cancelRetreat()
        if !isVisible { showPanel() }
    }

    private func peekSensorExited() {
        guard isHiddenModeEnabled else { return }
        // If the cursor moved onto the notch, hoverEntered cancels this.
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
            showPanel()
        }
    }

    // MARK: - Transient overlay visibility (HUD, sneak peek — keeps the notch
    // visible even in Hidden mode so the overlay isn't swallowed)

    func presentForOverlay() {
        activeOverlayCount += 1
        cancelRetreat()
        if !isVisible { showPanel() }
        // Widen from the bare notch so the overlay fits; leave an expanded panel
        // alone (it already has room and the overlay draws on top).
        if !isExpanded { animateFrame(to: overlaySize) }
    }

    func overlayDidHide() {
        activeOverlayCount = max(0, activeOverlayCount - 1)
        guard activeOverlayCount == 0 else { return }
        if !isExpanded { animateFrame(to: collapsedSize) }
        if isHiddenModeEnabled {
            scheduleRetreat()
        }
    }

    // MARK: - Visibility helpers

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
        collapse()
        panel?.orderOut(nil)
        isVisible = false
    }

    private func scheduleRetreat() {
        cancelRetreat()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isHiddenModeEnabled, self.activeOverlayCount == 0 else { return }
            self.hidePanel()
        }
        retreatWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retreatDelay, execute: work)
    }

    private func cancelRetreat() {
        retreatWorkItem?.cancel()
        retreatWorkItem = nil
    }

    // MARK: - Sensor lifecycle

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
        // Collapsed ↔ Expanded hover, via a tracking area instead of a global
        // mouse-moved monitor.
        hosting.onMouseEntered = { [weak self] in self?.hoverEntered() }
        hosting.onMouseExited = { [weak self] in self?.hoverExited() }
        panel.contentView = hosting
        // Register for file URL drags on the panel itself.
        panel.registerForDraggedTypes([.fileURL])
        self.panel = panel
        self.hostingView = hosting
        reposition()
    }

    func reposition() {
        guard let panel, let screen = preferredScreen() else { return }
        let size = isExpanded ? expandedSize : collapsedSize
        let origin = topCenterOrigin(size: size, on: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        peekSensor?.place(on: screen)
    }

    private func animateFrame(to size: NSSize) {
        guard let panel, let screen = panel.screen ?? preferredScreen() else { return }
        let origin = topCenterOrigin(size: size, on: screen)
        let target = NSRect(origin: origin, size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }

    func preferredScreen() -> NSScreen? {
        DisplayPreference.resolveScreen()
    }

    /// Public entry for Settings when the user picks another display.
    func applyPreferredDisplay() {
        if isHiddenModeEnabled {
            removePeekSensor()
            installPeekSensor()
        }
        reposition()
    }

    private func topCenterOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let notchInset = max(screen.safeAreaInsets.top, menuBarHeight)
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - max(0, (notchInset - collapsedSize.height) / 2)
        return NSPoint(x: x, y: y)
    }
}

// MARK: - Drop-capable hosting view

/// NSHostingView that accepts file URL drags and reports hover enter/exit via a
/// tracking area. It forwards drops without knowing which widget will handle
/// them, and forwards hover so the controller can expand/collapse.
private final class DropHostingView: NSHostingView<NotchContentView> {
    var onFileDrop: (([URL]) -> Bool)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
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
