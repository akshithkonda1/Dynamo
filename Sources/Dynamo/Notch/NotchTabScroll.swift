import AppKit
import SwiftUI

/// Horizontal strip with a thin native scroller, edge chevrons, and a
/// **plain mouse wheel** that maps onto the sideways axis.
///
/// Used for tab cheeks and for widget cards whose extra content lives
/// left/right inside the compact ~200pt panel (no vertical card scroll).
struct NotchHScroll<Content: View>: View {
    var leftHelp: String = "Show earlier"
    var rightHelp: String = "Show later"
    @StateObject private var bridge = TabScrollBridge()
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            tabChevron(systemImage: "chevron.left", help: leftHelp) {
                bridge.scroll?.page(direction: -1)
            }
            NotchTabScrollViewRepresentable(content: content(), bridge: bridge)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabChevron(systemImage: "chevron.right", help: rightHelp) {
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

/// Tab-row cheek — same scroller, tray-specific help text.
struct NotchTabCheek<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        NotchHScroll(leftHelp: "Show earlier tabs", rightHelp: "Show later tabs") {
            content()
        }
    }
}

final class TabScrollBridge: ObservableObject {
    weak var scroll: NotchTabScrollView?
}

/// Pure mapping used by `NotchTabScrollView` and XCTest (no windowing).
enum NotchTabScroll {
    /// Convert a wheel event into a **horizontal** delta.
    ///
    /// A plain mouse wheel on macOS only sends vertical line deltas
    /// (`hasPreciseScrollingDeltas == false`, `deltaX ≈ 0`). Those become
    /// horizontal so the strip moves without holding Shift.
    ///
    /// Trackpad / Magic Mouse already report precise `deltaX` / `deltaY`.
    /// Sideways swipes keep `deltaX`. Vertical swipes are **not** hijacked
    /// (`0`) so a two-finger vertical gesture does not steal the strip.
    static func horizontalDelta(
        deltaY: CGFloat,
        deltaX: CGFloat,
        hasPreciseScrollingDeltas: Bool
    ) -> CGFloat {
        if !hasPreciseScrollingDeltas, abs(deltaX) < 0.01 {
            return deltaY
        }
        return deltaX
    }
}

final class NotchTabScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        horizontalScroller?.controlSize = .mini
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        let mapped = NotchTabScroll.horizontalDelta(
            deltaY: event.scrollingDeltaY,
            deltaX: event.scrollingDeltaX,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        )
        guard mapped != 0 else { return }
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
        scroll.horizontalScroller?.controlSize = .mini
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
