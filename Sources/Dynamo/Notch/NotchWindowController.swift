import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    private weak var hud: SystemHUDController?

    private let collapsedSize = NSSize(width: 360, height: 36)
    private let expandedSize = NSSize(width: 480, height: 280)

    func attach(registry: WidgetRegistry, hud: SystemHUDController) {
        self.registry = registry
        self.hud = hud
        if panel == nil {
            installPanel(registry: registry, hud: hud)
        } else if let hostingView {
            hostingView.rootView = NotchContentView(registry: registry, controller: self, hud: hud)
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

    private func installPanel(registry: WidgetRegistry, hud: SystemHUDController) {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: collapsedSize))
        let root = NotchContentView(registry: registry, controller: self, hud: hud)
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
        panel.contentView = hosting
        // Register for file URL drags on the panel itself.
        panel.registerForDraggedTypes([.fileURL])
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
        // Don't collapse while the user is interacting with a HUD pulse.
        if hud?.state != nil { return }
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
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
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            context.allowsImplicitAnimation = true
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
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
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

/// NSHostingView that accepts file URL drags and forwards them without
/// knowing which widget will handle them.
private final class DropHostingView: NSHostingView<NotchContentView> {
    var onFileDrop: (([URL]) -> Bool)?

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
