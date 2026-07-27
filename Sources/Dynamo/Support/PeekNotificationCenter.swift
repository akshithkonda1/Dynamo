import AppKit
import Combine
import Foundation

/// Dynamo’s **primary notification surface** — the notch Peek replaces system
/// banners for everything Dynamo originates (calendar, reminders, focus,
/// battery, media, external Shortcuts).
///
/// Design goals:
/// - Single funnel (no lost alerts when peeks overlap)
/// - Queue + coalesce by stable id
/// - Urgency / media preemption rules
/// - Light haptics on deliver
/// - Recent history for Settings / debugging
/// - Never posts `UNUserNotification` banners while Peek delivery is on
@MainActor
final class PeekNotificationCenter: ObservableObject {
    static let shared = PeekNotificationCenter()

    private static let primaryKey = "dynamo.peek.primaryDelivery"
    private static let hapticsKey = "dynamo.peek.haptics"
    private static let soundKey = "dynamo.peek.sound"
    private static let maxQueue = 12
    private static let maxHistory = 40

    /// When true (default), all Dynamo alerts go through Peek only.
    @Published var isPrimaryDelivery: Bool {
        didSet { UserDefaults.standard.set(isPrimaryDelivery, forKey: Self.primaryKey) }
    }

    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Self.hapticsKey) }
    }

    /// Soft system beep on critical peeks only.
    @Published var criticalSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(criticalSoundEnabled, forKey: Self.soundKey) }
    }

    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var history: [PeekHistoryItem] = []
    @Published private(set) var lastDelivered: PeekHistoryItem?

    private weak var presenter: NotchSneakPeekController?
    private var queue: [QueuedPeek] = []
    private var isPresenting = false
    private var registryCancellable: AnyCancellable?
    private var hideCancellable: AnyCancellable?

    struct QueuedPeek: Identifiable, Equatable {
        let id: String
        let category: String
        let peek: NotchSneakPeek
        let enqueuedAt: Date
    }

    struct PeekHistoryItem: Identifiable, Equatable {
        let id: String
        let category: String
        let title: String
        let subtitle: String
        let urgency: NotchSneakPeekUrgency
        let deliveredAt: Date
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.primaryKey) == nil {
            isPrimaryDelivery = true
        } else {
            isPrimaryDelivery = UserDefaults.standard.bool(forKey: Self.primaryKey)
        }
        if UserDefaults.standard.object(forKey: Self.hapticsKey) == nil {
            hapticsEnabled = true
        } else {
            hapticsEnabled = UserDefaults.standard.bool(forKey: Self.hapticsKey)
        }
        if UserDefaults.standard.object(forKey: Self.soundKey) == nil {
            criticalSoundEnabled = false
        } else {
            criticalSoundEnabled = UserDefaults.standard.bool(forKey: Self.soundKey)
        }
    }

    // MARK: - Attach

    /// Wire registry fan-out + peek presenter. Call once at bootstrap.
    func attach(registry: WidgetRegistry, presenter: NotchSneakPeekController) {
        self.presenter = presenter
        presenter.onDidHide = { [weak self] in
            self?.handlePresenterDidHide()
        }
        // Intercept all widget sneak peeks through the delivery center.
        registryCancellable = registry.sneakPeekPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] peek in
                self?.deliver(peek, category: "widget")
            }
    }

    func teardown() {
        registryCancellable?.cancel()
        registryCancellable = nil
        queue.removeAll()
        pendingCount = 0
        isPresenting = false
        presenter?.onDidHide = nil
        presenter = nil
    }

    // MARK: - Public API

    /// Deliver a notification as a Peek (queued, coalesced).
    func deliver(
        _ peek: NotchSneakPeek,
        id: String? = nil,
        category: String = "general",
        coalesce: Bool = true
    ) {
        guard isPrimaryDelivery else {
            // Fallback: still show peek, but skip queue policy (legacy path).
            presenter?.showDirect(peek)
            return
        }

        let key = id ?? Self.makeID(peek: peek, category: category)
        if coalesce {
            // Replace existing queued item with same id (latest wins).
            if let idx = queue.firstIndex(where: { $0.id == key }) {
                queue[idx] = QueuedPeek(id: key, category: category, peek: peek, enqueuedAt: Date())
                pendingCount = queue.count
                // If this id is currently showing and urgency rose, re-present.
                return
            }
        }

        if FocusController.shared.shouldSuppress(peek: peek) {
            return
        }

        let item = QueuedPeek(id: key, category: category, peek: peek, enqueuedAt: Date())

        // Media + critical preempt the current session so skips / "starting now"
        // never feel delayed behind a routine heads-up.
        let preempt = peek.style == .media || peek.urgency >= .critical
        if preempt, let presenter {
            // Keep lower-priority items queued; present this now.
            isPresenting = true
            recordHistory(item)
            feedback(for: peek)
            presenter.showDirect(peek)
            pendingCount = queue.count
            return
        }

        queue.append(item)
        trimQueue()
        pendingCount = queue.count
        pump()
    }

    /// Convenience builders used by plugins / Focus / external bridge.
    func notify(
        title: String,
        subtitle: String = "",
        systemImage: String = "bell.fill",
        urgency: NotchSneakPeekUrgency = .normal,
        detail: String = "",
        category: String = "general",
        id: String? = nil
    ) {
        deliver(
            NotchSneakPeek(
                systemImage: systemImage,
                title: title,
                subtitle: subtitle,
                urgency: urgency,
                detail: detail
            ),
            id: id,
            category: category
        )
    }

    func clearQueue() {
        queue.removeAll()
        pendingCount = 0
    }

    // MARK: - Pump

    private func pump() {
        guard isPrimaryDelivery else { return }
        guard !isPresenting else { return }
        guard let presenter else { return }
        guard !queue.isEmpty else { return }

        // Skip suppressed items without dropping the whole queue forever.
        while let next = queue.first {
            if FocusController.shared.shouldSuppress(peek: next.peek) {
                queue.removeFirst()
                pendingCount = queue.count
                continue
            }
            queue.removeFirst()
            pendingCount = queue.count
            isPresenting = true
            recordHistory(next)
            feedback(for: next.peek)
            presenter.showDirect(next.peek)
            return
        }
    }

    private func handlePresenterDidHide() {
        isPresenting = false
        // Small gap so stacked peeks don't feel like a single flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.pump()
        }
    }

    private func trimQueue() {
        guard queue.count > Self.maxQueue else { return }
        // Drop oldest lowest-urgency from the back half.
        while queue.count > Self.maxQueue {
            if let idx = queue.enumerated().reversed().first(where: { $0.element.peek.urgency <= .normal })?.offset {
                queue.remove(at: idx)
            } else {
                queue.removeLast()
            }
        }
    }

    private func recordHistory(_ item: QueuedPeek) {
        let h = PeekHistoryItem(
            id: item.id,
            category: item.category,
            title: item.peek.title,
            subtitle: item.peek.subtitle,
            urgency: item.peek.urgency,
            deliveredAt: Date()
        )
        history.insert(h, at: 0)
        if history.count > Self.maxHistory {
            history = Array(history.prefix(Self.maxHistory))
        }
        lastDelivered = h
    }

    private func feedback(for peek: NotchSneakPeek) {
        if hapticsEnabled {
            let pattern: NSHapticFeedbackManager.FeedbackPattern
            switch peek.urgency {
            case .critical: pattern = .levelChange
            case .high: pattern = .alignment
            default: pattern = .generic
            }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        if criticalSoundEnabled, peek.urgency >= .critical {
            NSSound.beep()
        }
    }

    private static func makeID(peek: NotchSneakPeek, category: String) -> String {
        "\(category)|\(peek.systemImage)|\(peek.title)|\(peek.subtitle)"
    }
}
