import AppKit
import SwiftUI

/// Scroll container for notch expanded content.
/// Uses a real AppKit scroller so the bar stays visible (macOS overlay
/// scrollers otherwise hide until you trackpad-swipe).
struct NotchScrollView<Content: View>: View {
    var axes: Axis.Set = .vertical
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(axes, showsIndicators: true) {
            content()
                .frame(
                    maxWidth: axes.contains(.horizontal) ? nil : .infinity,
                    alignment: .topLeading
                )
        }
        .background(ScrollerStyleFixer(
            wantsVertical: axes.contains(.vertical),
            wantsHorizontal: axes.contains(.horizontal)
        ))
    }
}

/// Walks the AppKit view tree under this slot and forces legacy, always-on
/// scrollers so users can grab the bar with the mouse.
private struct ScrollerStyleFixer: NSViewRepresentable {
    var wantsVertical: Bool
    var wantsHorizontal: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onMove = { [wantsVertical, wantsHorizontal] probe in
            Self.apply(from: probe, vertical: wantsVertical, horizontal: wantsHorizontal)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.apply(from: nsView, vertical: wantsVertical, horizontal: wantsHorizontal)
    }

    private static func apply(from probe: NSView, vertical: Bool, horizontal: Bool) {
        // Defer until SwiftUI has attached the ScrollView hierarchy.
        DispatchQueue.main.async {
            guard let root = probe.enclosingScrollView ?? probe.superview?.enclosingScrollView
                    ?? findScrollView(from: probe) else { return }
            root.scrollerStyle = .legacy
            root.autohidesScrollers = false
            root.hasVerticalScroller = vertical
            root.hasHorizontalScroller = horizontal
            root.verticalScroller?.controlSize = .mini
            root.horizontalScroller?.controlSize = .mini
            root.drawsBackground = false
            root.backgroundColor = .clear
        }
    }

    private static func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let c = current {
            if let scroll = c as? NSScrollView { return scroll }
            // Climb up, then scan siblings/ancestors' subtrees.
            if let scroll = c.subviews.compactMap({ findScrollView(inSubtree: $0) }).first {
                return scroll
            }
            current = c.superview
        }
        return nil
    }

    private static func findScrollView(inSubtree view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = findScrollView(inSubtree: child) { return found }
        }
        return nil
    }
}

private final class ProbeView: NSView {
    var onMove: ((NSView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMove?(self)
    }

    override func layout() {
        super.layout()
        onMove?(self)
    }
}
