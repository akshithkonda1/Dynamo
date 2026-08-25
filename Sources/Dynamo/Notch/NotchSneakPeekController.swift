import Combine
import Foundation

/// Presents a single sneak peek in the notch, then auto-hides.
///
/// **Delivery ownership** lives in `PeekNotificationCenter` (queue, coalesce,
/// history, haptics). This controller only owns the visual session + timing.
/// Higher-urgency / media can preempt the current peek; Meeting Mode quieting
/// is applied by the center before `showDirect`.
@MainActor
final class NotchSneakPeekController: ObservableObject {
    @Published private(set) var peek: NotchSneakPeek?

    /// Fired when a peek session fully ends (auto-hide or preemption complete).
    var onDidHide: (() -> Void)?

    private var hideWorkItem: DispatchWorkItem?
    private weak var notch: NotchWindowController?
    private var holdingOverlay = false
    /// Generation so delayed hide only clears the matching session.
    private var sessionID: UInt64 = 0

    private func displayDuration(for urgency: NotchSneakPeekUrgency, peek: NotchSneakPeek? = nil) -> TimeInterval {
        let multiplier = UserDefaults.standard.object(forKey: "peekDwellMultiplier") as? Double ?? 1.0
        var base: TimeInterval
        switch urgency {
        case .low: base = 2.4
        case .normal: base = 2.8
        case .high: base = 4.5
        case .critical: base = 6.0
        }
        // Peek-only: hold messages/calls longer so the notch is the real alert surface.
        if DynamoNotificationRouter.shared.peekOnlyDelivery, let peek {
            let d = peek.detail.lowercased()
            if d.hasPrefix("text") || d.hasPrefix("call") || peek.systemImage.contains("message")
                || peek.systemImage.contains("phone") {
                base *= 1.4
            }
        }
        return base * multiplier
    }

    func attach(registry: WidgetRegistry, notch: NotchWindowController) {
        self.notch = notch
        // Presentation is driven by PeekNotificationCenter.showDirect —
        // registry peeks are intercepted there so nothing bypasses the queue.
        _ = registry
    }

    /// Direct path for FocusController — goes through Dynamo’s notification router.
    func showForFocus(_ content: NotchSneakPeek) {
        DynamoNotificationRouter.shared.route(
            content,
            source: .focus,
            category: "focus",
            id: "focus|\(content.title)"
        )
    }

    /// Present immediately (called only by PeekNotificationCenter).
    func showDirect(_ content: NotchSneakPeek) {
        present(content)
    }

    func teardown() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if holdingOverlay {
            holdingOverlay = false
            notch?.overlayDidHide(style: .peek)
        }
        peek = nil
        onDidHide = nil
    }

    private func present(_ content: NotchSneakPeek) {
        // Preempt current session without double-firing onDidHide for queue.
        hideWorkItem?.cancel()
        sessionID &+= 1
        let thisSession = sessionID

        peek = content
        if !holdingOverlay {
            holdingOverlay = true
            notch?.presentForOverlay(style: .peek)
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sessionID == thisSession else { return }
            self.peek = nil
            if self.holdingOverlay {
                self.holdingOverlay = false
                self.notch?.overlayDidHide(style: .peek)
            }
            self.onDidHide?()
        }
        hideWorkItem = work
        let duration = content.style == .media
            ? max(displayDuration(for: content.urgency, peek: content), 2.4)
            : displayDuration(for: content.urgency, peek: content)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
