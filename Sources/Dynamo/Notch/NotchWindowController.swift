import AppKit
import Combine
import SwiftUI

/// Owns the single two-state hover model (`isExpanded`) and the notch panel.
/// Keep expansion as one boolean so the animation stays coherent.
@MainActor
final class NotchWindowController: ObservableObject {
    @Published private(set) var isExpanded: Bool = false

    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchContentView>?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private weak var registry: WidgetRegistry?

    private let collapsedSize = NSSize(width: 220, height: 34)
    private let expandedSize = NSSize(width: 420, height: 220)

    func attach(registry: WidgetRegistry) {
        self.registry = registry
        if panel == nil {
            installPanel(registry: registry)
        }
        installMouseTracking()
        reposition()
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        animateFrame(to: expandedSize)
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        animateFrame(to: collapsedSize)
    }

    func teardown() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: - Setup

    private func installPanel(registry: WidgetRegistry) {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: collapsedSize))
        let root = NotchContentView(registry: registry, controller: self)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: collapsedSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        self.hostingView = hosting
        reposition()
        panel.orderFrontRegardless()
    }

    private func installMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateMouse()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.evaluateMouse()
            }
            return event
        }
    }

    private func evaluateMouse() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        // Slightly inflated hit area so the tray is easy to re-enter while expanded.
        let hit = frame.insetBy(dx: -8, dy: -12)
        if hit.contains(mouse) {
            if !isExpanded {
                expand()
            }
        } else if isExpanded {
            collapse()
        }
    }

    private func animateFrame(to size: NSSize) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let origin = topCenterOrigin(size: size, on: screen)
        let target = NSRect(origin: origin, size: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    func reposition() {
        guard let panel, let screen = preferredScreen() else { return }
        let size = isExpanded ? expandedSize : collapsedSize
        let origin = topCenterOrigin(size: size, on: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func preferredScreen() -> NSScreen? {
        // Prefer the screen that has a notch (safeAreaInsets.top > 0 on macOS 12+).
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
    }

    private func topCenterOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        // Anchor just under the menu bar / into the notch region.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let notchInset = max(screen.safeAreaInsets.top, menuBarHeight)
        let x = frame.midX - size.width / 2
        // Hang from the top of the screen so the panel occupies the notch area.
        let y = frame.maxY - size.height - max(0, (notchInset - collapsedSize.height) / 2)
        return NSPoint(x: x, y: y)
    }
}
