import AppKit
import SwiftUI

/// Horizontal tab cheek that a **plain mouse wheel** can scroll.
///
/// AppKit’s `NSScrollView` ignores vertical-wheel deltas on a horizontal-only
/// scroller. We remap those deltas and expose edge chevrons so Webcam / World
/// Clock stay reachable without a trackpad.
struct NotchTabCheek<Content: View>: View {
    @StateObject private var bridge = TabScrollBridge()
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            tabChevron(systemImage: "chevron.left", help: "Show earlier tabs") {
                bridge.scroll?.page(direction: -1)
            }
            NotchTabScrollViewRepresentable(content: content(), bridge: bridge)
                .frame(maxWidth: .infinity)
            tabChevron(systemImage: "chevron.right", help: "Show later tabs") {
                bridge.scroll?.page(direction: 1)
            }
        }
    }

    private func tabChevron(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(width: 12, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

final class TabScrollBridge: ObservableObject {
    weak var scroll: NotchTabScrollView?
}

/// Pure mapping used by `NotchTabScrollView` and XCTest (no windowing).
enum NotchTabScroll {
    /// Prefer the axis with the larger |delta|. Vertical wheel → horizontal.
    static func horizontalDelta(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
        abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
    }
}

final class NotchTabScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        autohidesScrollers = true
        borderType = .noBorder
        scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        let mapped = NotchTabScroll.horizontalDelta(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        )
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        var origin = contentView.bounds.origin
        origin.x -= mapped * scale
        contentView.scroll(to: clamped(origin))
        reflectScrolledClipView(contentView)
    }

    func page(direction: CGFloat) {
        var origin = contentView.bounds.origin
        origin.x += contentView.bounds.width * 0.75 * direction
        contentView.scroll(to: clamped(origin))
        reflectScrolledClipView(contentView)
    }

    func layoutDocument() {
        guard let doc = documentView else { return }
        doc.layoutSubtreeIfNeeded()
        let fitting = doc.fittingSize
        let height = max(contentView.bounds.height, 1)
        let width = max(fitting.width, contentView.bounds.width)
        doc.setFrameSize(NSSize(width: width, height: height))
    }

    private func clamped(_ origin: NSPoint) -> NSPoint {
        let docWidth = documentView?.frame.width ?? 0
        let maxX = max(0, docWidth - contentView.bounds.width)
        return NSPoint(x: min(max(0, origin.x), maxX), y: 0)
    }
}

private struct NotchTabScrollViewRepresentable<Content: View>: NSViewRepresentable {
    var content: Content
    var bridge: TabScrollBridge

    func makeNSView(context: Context) -> NotchTabScrollView {
        let scroll = NotchTabScrollView()
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        ])
        context.coordinator.hosting = host
        bridge.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NotchTabScrollView, context: Context) {
        context.coordinator.hosting?.rootView = content
        scroll.layoutDocument()
        bridge.scroll = scroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var hosting: NSHostingView<Content>?
    }
}
