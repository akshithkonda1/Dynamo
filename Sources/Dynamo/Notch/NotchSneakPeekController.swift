import Combine
import Foundation

/// Shows a brief sneak peek in the notch when a widget has something noteworthy
/// to report, then auto-hides — reusing the transient-overlay mechanic of the
/// volume/brightness HUD.
///
/// Content is generic (`NotchSneakPeek`) via `WidgetRegistry.sneakPeekPublisher`.
/// Higher-urgency peeks preempt lower ones; Meeting Mode only quiets low/normal.
@MainActor
final class NotchSneakPeekController: ObservableObject {
    @Published private(set) var peek: NotchSneakPeek?

    private var hideWorkItem: DispatchWorkItem?
    private weak var notch: NotchWindowController?
    private var cancellable: AnyCancellable?
    private var holdingOverlay = false

    private func displayDuration(for urgency: NotchSneakPeekUrgency) -> TimeInterval {
        switch urgency {
        case .low: return 3.0
        case .normal: return 3.4
        case .high: return 5.5
        case .critical: return 7.5
        }
    }

    func attach(registry: WidgetRegistry, notch: NotchWindowController) {
        self.notch = notch
        cancellable = registry.sneakPeekPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] content in
                self?.show(content)
            }
    }

    func teardown() {
        cancellable?.cancel()
        cancellable = nil
        hideWorkItem?.cancel()
        if holdingOverlay {
            holdingOverlay = false
            notch?.overlayDidHide(style: .peek)
        }
        peek = nil
    }

    private func show(_ content: NotchSneakPeek) {
        // Meeting Mode: drop low/normal peeks while a calendar event is Now
        // (media track peeks are exempt — see MeetingMode.shouldSuppress).
        if FocusController.shared.shouldSuppress(peek: content)
            || MeetingMode.shared.shouldSuppress(peek: content) {
            return
        }

        // Media track changes always win over whatever peek is up so next/previous
        // is never silent. Critical calendar/weather still beat non-media peeks.
        if let current = peek {
            let mediaTakesOver = content.style == .media
            let blockedByHigherUrgency =
                !mediaTakesOver && content.urgency < current.urgency
            if blockedByHigherUrgency {
                return
            }
        }

        peek = content
        if !holdingOverlay {
            holdingOverlay = true
            notch?.presentForOverlay(style: .peek)
        }
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only clear if this hide belongs to the still-current peek session.
            self.peek = nil
            if self.holdingOverlay {
                self.holdingOverlay = false
                self.notch?.overlayDidHide(style: .peek)
            }
        }
        hideWorkItem = work
        // Media peeks stay up long enough to read title + art after a skip.
        let duration = content.style == .media
            ? max(displayDuration(for: content.urgency), 3.2)
            : displayDuration(for: content.urgency)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
