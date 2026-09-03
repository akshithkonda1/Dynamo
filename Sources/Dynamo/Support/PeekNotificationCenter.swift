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
    private static let historyCapKey = "dynamo.peek.historyRetention"
    private static let maxQueue = 14
    private static let defaultMaxHistory = 100

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

    /// How many delivered Peeks to keep in the hub inbox.
    @Published var historyRetention: Int {
        didSet {
            let clamped = min(200, max(20, historyRetention))
            if clamped != historyRetention {
                historyRetention = clamped
                return
            }
            UserDefaults.standard.set(historyRetention, forKey: Self.historyCapKey)
            trimHistoryIfNeeded()
        }
    }

    private var maxHistory: Int { historyRetention }

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

    struct PeekHistoryItem: Identifiable, Equatable, Codable {
        let id: String
        let category: String
        let title: String
        let subtitle: String
        let detail: String
        let systemImage: String
        let urgency: NotchSneakPeekUrgency
        let deliveredAt: Date
        var isUnread: Bool
        var sourceBundleID: String
        var appName: String

        enum CodingKeys: String, CodingKey {
            case id, category, title, subtitle, detail, systemImage, urgency, deliveredAt, isUnread
            case sourceBundleID, appName
        }

        init(
            id: String,
            category: String,
            title: String,
            subtitle: String,
            detail: String,
            systemImage: String,
            urgency: NotchSneakPeekUrgency,
            deliveredAt: Date,
            isUnread: Bool,
            sourceBundleID: String = "",
            appName: String = ""
        ) {
            self.id = id
            self.category = category
            self.title = title
            self.subtitle = subtitle
            self.detail = detail
            self.systemImage = systemImage
            self.urgency = urgency
            self.deliveredAt = deliveredAt
            self.isUnread = isUnread
            self.sourceBundleID = sourceBundleID
            self.appName = appName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            category = try c.decode(String.self, forKey: .category)
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
            detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
            systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage) ?? "bell.fill"
            urgency = try c.decodeIfPresent(NotchSneakPeekUrgency.self, forKey: .urgency) ?? .normal
            deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt) ?? Date()
            isUnread = try c.decodeIfPresent(Bool.self, forKey: .isUnread) ?? true
            sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID) ?? ""
            appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        }
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
        if UserDefaults.standard.object(forKey: Self.historyCapKey) == nil {
            historyRetention = Self.defaultMaxHistory
        } else {
            historyRetention = min(200, max(20, UserDefaults.standard.integer(forKey: Self.historyCapKey)))
        }
        loadPersistedHistory()
    }

    private static let historyFile = "peek-hub.json"

    private func loadPersistedHistory() {
        guard let items = AppSupportStore.load([PeekHistoryItem].self, from: Self.historyFile) else { return }
        history = items
        unreadCount = history.filter(\.isUnread).count
    }

    private func persistHistory() {
        AppSupportStore.save(history, to: Self.historyFile)
    }

    private func trimHistoryIfNeeded() {
        guard history.count > maxHistory else { return }
        let dropped = history.suffix(from: maxHistory)
        for item in dropped {
            replayStore.removeValue(forKey: item.id)
        }
        history = Array(history.prefix(maxHistory))
        unreadCount = history.filter(\.isUnread).count
        persistHistory()
    }

    // MARK: - Attach

    /// Wire peek presenter. Widget / system / API traffic is owned by
    /// `DynamoNotificationRouter` — the hub only presents + stores inbox.
    func attach(registry: WidgetRegistry, presenter: NotchSneakPeekController) {
        self.presenter = presenter
        presenter.onDidHide = { [weak self] in
            self?.handlePresenterDidHide()
        }
        // Registry is no longer attached here — DynamoNotificationRouter owns
        // widget fan-in so every source shares one routing policy.
        _ = registry
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
        coalesce: Bool = true,
        present: Bool = true
    ) {
        guard isPrimaryDelivery else {
            if present { presenter?.showDirect(peek) }
            return
        }

        let key = id ?? Self.makeID(peek: peek, category: category)
        if coalesce {
            // Replace existing queued item with same id (latest wins).
            if let idx = queue.firstIndex(where: { $0.id == key }) {
                if present {
                    queue[idx] = QueuedPeek(id: key, category: category, peek: peek, enqueuedAt: Date())
                    pendingCount = queue.count
                }
                return
            }
        }

        let item = QueuedPeek(id: key, category: category, peek: peek, enqueuedAt: Date())

        if !present {
            recordHistory(item, presented: false)
            return
        }

        if FocusController.shared.shouldSuppress(peek: peek) {
            recordHistory(item, presented: false)
            return
        }

        // Media + critical preempt so skips / “starting now” never feel delayed.
        let preempt = peek.style == .media || peek.urgency >= .critical
        if preempt, let presenter {
            isPresenting = true
            recordHistory(item, presented: true)
            feedback(for: peek, category: category, id: key)
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
        persistHistory()
    }

    func markRead(id: String) {
        if let idx = history.firstIndex(where: { $0.id == id }) {
            history[idx].isUnread = false
            recomputeUnread()
            persistHistory()
        }
    }

    func clearHistory() {
        history.removeAll()
        lastDelivered = nil
        replayStore.removeAll()
        recomputeUnread()
        persistHistory()
    }

    func remove(id: String) {
        history.removeAll { $0.id == id }
        replayStore.removeValue(forKey: id)
        if lastDelivered?.id == id {
            lastDelivered = history.first
        }
        recomputeUnread()
        persistHistory()
    }

    /// Re-present a hub item as a Peek (does not re-queue).
    func replay(id: String) {
        let peek = replayStore[id] ?? history.first(where: { $0.id == id }).map {
            NotchSneakPeek(
                systemImage: $0.systemImage,
                title: $0.title,
                subtitle: $0.subtitle,
                urgency: $0.urgency,
                detail: $0.detail,
                category: $0.category,
                sourceBundleID: $0.sourceBundleID,
                appName: $0.appName
            )
        }
        guard let peek else { return }
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
            feedback(for: next.peek, category: next.category, id: next.id)
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
            isUnread: true,
            sourceBundleID: item.peek.sourceBundleID,
            appName: item.peek.appName
        )
        history.insert(h, at: 0)
        if history.count > maxHistory {
            let dropped = history.suffix(from: maxHistory)
            for d in dropped { replayStore.removeValue(forKey: d.id) }
            history = Array(history.prefix(maxHistory))
        }
        replayStore[item.id] = item.peek
        // Cap replay payloads (artwork-heavy).
        if replayStore.count > maxHistory + 8 {
            let keep = Set(history.map(\.id))
            replayStore = replayStore.filter { keep.contains($0.key) }
        }
        if presented {
            lastDelivered = h
        }
        recomputeUnread()
        persistHistory()
    }

    private func recomputeUnread() {
        unreadCount = history.filter(\.isUnread).count
    }

    private func feedback(for peek: NotchSneakPeek, category: String = "", id: String = "") {
        if hapticsEnabled {
            let pattern: NSHapticFeedbackManager.FeedbackPattern
            switch peek.urgency {
            case .critical: pattern = .levelChange
            case .high: pattern = .alignment
            default: pattern = .generic
            }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
        // Always play a notification sound for battery 10% / full-charge Peeks.
        // Other critical Peeks respect the Preferences toggle.
        let batteryAlertSound = Self.isBatteryAlertSound(category: category, id: id, title: peek.title)
        if batteryAlertSound || (criticalSoundEnabled && peek.urgency >= .critical) {
            Self.playNotificationSound(battery: batteryAlertSound)
        }
    }

    /// 10% / critically low / fully charged — always audible, even if critical sound is off.
    private static func isBatteryAlertSound(category: String, id: String, title: String) -> Bool {
        guard category == "battery" else { return false }
        let idLower = id.lowercased()
        if idLower.contains("|p10") || idLower.contains("|p5") || idLower.contains("|full") {
            return true
        }
        let t = title.lowercased()
        return t.contains("10%") || t.contains("critically low") || t.contains("fully charged")
    }

    private static func playNotificationSound(battery: Bool) {
        // Prefer distinct system sounds; fall back to beep.
        let names = battery
            ? ["Glass", "Hero", "Ping", "Submarine"]
            : ["Tink", "Pop", "Glass"]
        for name in names {
            if let sound = NSSound(named: NSSound.Name(name)) {
                sound.play()
                return
            }
        }
        NSSound.beep()
    }

    private static func makeID(peek: NotchSneakPeek, category: String) -> String {
        "\(category)|\(peek.systemImage)|\(peek.title)|\(peek.subtitle)"
    }
}
