import Combine
import Foundation

/// Shows a brief "sneak peek" pill in the notch when a widget has something
/// noteworthy to report (e.g. a track change), then auto-hides — reusing the
/// same transient-overlay mechanic as the volume/brightness HUD
/// (`NotchWindowController.presentForOverlay()` / `overlayDidHide()`).
///
/// Content is generic (`NotchSneakPeek`) and arrives via
/// `WidgetRegistry.sneakPeekPublisher` — this controller never knows which
/// widget originated a peek.
@MainActor
final class NotchSneakPeekController: ObservableObject {
    @Published private(set) var peek: NotchSneakPeek?

    private var hideWorkItem: DispatchWorkItem?
    private weak var notch: NotchWindowController?
    private var cancellable: AnyCancellable?

    /// How long the pill stays up before auto-hiding. Critical peeks (e.g. a
    /// severe weather alert) linger longer than a routine one (a track change,
    /// a meeting reminder) since they're worth actually reading.
    private func displayDuration(for emphasis: NotchSneakPeekEmphasis) -> TimeInterval {
        switch emphasis {
        case .normal: return 2.6
        case .critical: return 5.5
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
        peek = nil
    }

    private func show(_ content: NotchSneakPeek) {
        peek = content
        notch?.presentForOverlay()
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.peek = nil
            self?.notch?.overlayDidHide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration(for: content.emphasis), execute: work)
    }
}
