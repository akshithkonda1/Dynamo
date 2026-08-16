import AppKit
import Combine
import Foundation

/// Dynamo’s **notification hub** — the notch Peek is the primary delivery UI
/// for everything Dynamo surfaces:
/// - Widget / Focus / battery / calendar / media peeks
/// - External API (`dynamo://notify`, distributed notifications)
/// - System apps **routed into the hub** (Messages, FaceTime, Mail, …) via
///   `SystemNotificationMirror` — not a second parallel banner surface
///
/// Design:
/// - Single funnel (queue + coalesce)
/// - Urgency / media preemption
/// - Inbox history with unread + replay
/// - Dynamo never posts competing system banners for its own alerts
@MainActor
final class PeekNotificationCenter: ObservableObject {
    static let shared = PeekNotificationCenter()

    private static let primaryKey = "dynamo.peek.primaryDelivery"
    private static let hapticsKey = "dynamo.peek.haptics"
    private static let soundKey = "dynamo.peek.sound"
    private static let maxQueue = 14
    private static let maxHistory = 60

    /// When true (default), every alert goes through the Peek hub.
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
    @Published private(set) var unreadCount: Int = 0

    private weak var presenter: NotchSneakPeekController?
    private var queue: [QueuedPeek] = []
    private var isPresenting = false
    private var registryCancellable: AnyCancellable?
    /// Full peeks keyed by history id for replay from the hub.
    private var replayStore: [String: NotchSneakPeek] = [:]

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
        let detail: String
        let systemImage: String
        let urgency: NotchSneakPeekUrgency
        let deliveredAt: Date
        var isUnread: Bool
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
        // Intercept all widget sneak peeks through the hub.
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

    /// Deliver into the hub (queued, coalesced, then Peeks from the notch).
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
                return
            }
        }

        if FocusController.shared.shouldSuppress(peek: peek) {
            // Still land in the hub inbox so nothing is lost silently.
            let item = QueuedPeek(id: key, category: category, peek: peek, enqueuedAt: Date())
            recordHistory(item, presented: false)
            return
        }

        let item = QueuedPeek(id: key, category: category, peek: peek, enqueuedAt: Date())

        // Media + critical preempt so skips / “starting now” never feel delayed.
        let preempt = peek.style == .media || peek.urgency >= .critical
        if preempt, let presenter {
            isPresenting = true
            recordHistory(item, presented: true)
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

    func markAllRead() {
        for i in history.indices {
            history[i].isUnread = false
        }
        recomputeUnread()
    }

    func markRead(id: String) {
        if let idx = history.firstIndex(where: { $0.id == id }) {
            history[idx].isUnread = false
            recomputeUnread()
        }
    }

    func clearHistory() {
        history.removeAll()
        lastDelivered = nil
        replayStore.removeAll()
        recomputeUnread()
    }

    /// Re-present a hub item as a Peek (does not re-queue).
    func replay(id: String) {
        guard let peek = replayStore[id] else { return }
        markRead(id: id)
        isPresenting = true
        presenter?.showDirect(peek)
    }

    /// Snapshot of the live queue for the Hub UI.
    var queuedItems: [QueuedPeek] { queue }

    // MARK: - Pump

    private func pump() {
        guard isPrimaryDelivery else { return }
        guard !isPresenting else { return }
        guard let presenter else { return }
        guard !queue.isEmpty else { return }

        while let next = queue.first {
            if FocusController.shared.shouldSuppress(peek: next.peek) {
                // Keep in hub history as unread; drop from live queue.
                recordHistory(next, presented: false)
                queue.removeFirst()
                pendingCount = queue.count
                continue
            }
            queue.removeFirst()
            pendingCount = queue.count
            isPresenting = true
            recordHistory(next, presented: true)
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
        while queue.count > Self.maxQueue {
            if let idx = queue.enumerated().reversed().first(where: { $0.element.peek.urgency <= .normal })?.offset {
                queue.remove(at: idx)
            } else {
                queue.removeLast()
            }
        }
    }

    private func recordHistory(_ item: QueuedPeek, presented: Bool) {
        // De-dupe same id — move to top as unread.
        history.removeAll { $0.id == item.id }
        let h = PeekHistoryItem(
            id: item.id,
            category: item.category,
            title: item.peek.title,
            subtitle: item.peek.subtitle,
            detail: item.peek.detail,
            systemImage: item.peek.systemImage,
            urgency: item.peek.urgency,
            deliveredAt: Date(),
            isUnread: true
        )
        history.insert(h, at: 0)
        if history.count > Self.maxHistory {
            let dropped = history.suffix(from: Self.maxHistory)
            for d in dropped { replayStore.removeValue(forKey: d.id) }
            history = Array(history.prefix(Self.maxHistory))
        }
        replayStore[item.id] = item.peek
        // Cap replay payloads (artwork-heavy).
        if replayStore.count > Self.maxHistory + 8 {
            let keep = Set(history.map(\.id))
            replayStore = replayStore.filter { keep.contains($0.key) }
        }
        if presented {
            lastDelivered = h
        }
        recomputeUnread()
    }

    private func recomputeUnread() {
        unreadCount = history.filter(\.isUnread).count
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
