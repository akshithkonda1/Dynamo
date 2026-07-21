import AppKit
import EventKit
import Foundation

/// Read/write bridge to Apple Reminders via EventKit (full access).
@MainActor
final class RemindersProvider: ObservableObject {
    enum AuthState: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    @Published private(set) var authState: AuthState = .notDetermined
    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var lastError: String?

    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var fetchToken: Any?
    private var undatedFetchToken: Any?
    /// Bumps on every refresh so late dual-fetch callbacks are ignored.
    private var refreshGeneration: UInt64 = 0
    private let fetchLock = NSLock()

    private let horizonDays = 30
    private let overdueLookbackDays = 30

    func start() {
        updateAuth()
        if authState == .authorized {
            refresh()
        }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        cancelFetches()
    }

    /// Requests **full** Reminders access (read + write).
    func requestAccess() async {
        lastError = nil
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToReminders()
            } else {
                granted = try await store.requestAccess(to: .reminder)
            }
            authState = granted ? .authorized : .denied
        } catch {
            authState = .denied
            lastError = error.localizedDescription
        }
        if authState == .authorized {
            refresh()
        } else {
            items = []
            onChange?()
        }
    }

    func refresh() {
        updateAuth()
        guard authState == .authorized else {
            items = []
            onChange?()
            return
        }
        cancelFetches()

        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -overdueLookbackDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(-overdueLookbackDays) * 86_400)
        let end = cal.date(byAdding: .day, value: horizonDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(horizonDays) * 86_400)

        // 1) Incomplete with due dates in window (incl. overdue).
        let datedPred = store.predicateForIncompleteReminders(
            withDueDateStarting: start,
            ending: end,
            calendars: nil
        )
        // 2) Incomplete with no due date (inbox-style).
        let undatedPred = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )

        refreshGeneration &+= 1
        let generation = refreshGeneration

        var dated: [EKReminder] = []
        var undated: [EKReminder] = []
        let group = DispatchGroup()
        let lock = fetchLock

        group.enter()
        fetchToken = store.fetchReminders(matching: datedPred) { list in
            lock.lock()
            dated = list ?? []
            lock.unlock()
            group.leave()
        }
        group.enter()
        undatedFetchToken = store.fetchReminders(matching: undatedPred) { list in
            lock.lock()
            undated = list ?? []
            lock.unlock()
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            lock.lock()
            let datedCopy = dated
            let undatedCopy = undated
            lock.unlock()
            Task { @MainActor in
                guard self.refreshGeneration == generation else { return }
                self.fetchToken = nil
                self.undatedFetchToken = nil
                self.applyFetched(
                    dated: datedCopy,
                    undated: undatedCopy,
                    windowStart: start,
                    windowEnd: end
                )
            }
        }
    }

    // MARK: - Write

    /// Create a new incomplete reminder in the default list.
    @discardableResult
    func create(
        title: String,
        due: Date? = Date(),
        allDay: Bool = false,
        notes: String? = nil,
        priority: Int = 0
    ) async -> Bool {
        guard authState == .authorized else {
            lastError = "Reminders access required"
            return false
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let list = store.defaultCalendarForNewReminders()
                ?? store.calendars(for: .reminder).first
        else {
            lastError = "No Reminders list available"
            return false
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = list
        reminder.priority = priority
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reminder.notes = notes
        }
        if let due {
            reminder.dueDateComponents = Self.dueComponents(from: due, allDay: allDay)
            // Alarm at due so Reminders still fires notifications.
            if !allDay {
                let alarm = EKAlarm(absoluteDate: due)
                reminder.addAlarm(alarm)
            }
        }

        do {
            try store.save(reminder, commit: true)
            lastError = nil
            // Optimistic insert so UI updates before async refresh.
            if let mapped = mapReminder(reminder) {
                items.insert(mapped, at: 0)
                sortItems()
                onChange?()
            }
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func complete(id: String) async -> Bool {
        guard authState == .authorized else { return false }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            lastError = "Reminder not found"
            return false
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        do {
            try store.save(reminder, commit: true)
            items.removeAll { $0.id == id }
            lastError = nil
            onChange?()
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func uncomplete(id: String) async -> Bool {
        guard authState == .authorized else { return false }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return false
        }
        reminder.isCompleted = false
        reminder.completionDate = nil
        do {
            try store.save(reminder, commit: true)
            lastError = nil
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateTitle(id: String, title: String) async -> Bool {
        guard authState == .authorized else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return false
        }
        reminder.title = trimmed
        do {
            try store.save(reminder, commit: true)
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx] = items[idx].with(title: trimmed)
                onChange?()
            }
            lastError = nil
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setDue(id: String, due: Date?, allDay: Bool = false) async -> Bool {
        guard authState == .authorized else { return false }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return false
        }
        if let due {
            reminder.dueDateComponents = Self.dueComponents(from: due, allDay: allDay)
        } else {
            reminder.dueDateComponents = nil
        }
        do {
            try store.save(reminder, commit: true)
            lastError = nil
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func delete(id: String) async -> Bool {
        guard authState == .authorized else { return false }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return false
        }
        do {
            try store.remove(reminder, commit: true)
            items.removeAll { $0.id == id }
            lastError = nil
            onChange?()
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func open(id: String) {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        if let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(encoded)"),
           NSWorkspace.shared.open(url) {
            return
        }
        openApp()
    }

    func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
        }
    }

    // MARK: - Mapping

    private func applyFetched(
        dated: [EKReminder],
        undated: [EKReminder],
        windowStart: Date,
        windowEnd: Date
    ) {
        var byID: [String: EKReminder] = [:]
        for r in dated {
            byID[r.calendarItemIdentifier] = r
        }
        // Undated incomplete (no due components) — keep a reasonable cap.
        for r in undated {
            if r.dueDateComponents == nil {
                byID[r.calendarItemIdentifier] = r
            }
        }

        let mapped = byID.values.compactMap { mapReminder($0, windowStart: windowStart, windowEnd: windowEnd) }
        items = mapped
        sortItems()
        onChange?()
    }

    private func mapReminder(
        _ reminder: EKReminder,
        windowStart: Date? = nil,
        windowEnd: Date? = nil
    ) -> ReminderItem? {
        if reminder.isCompleted { return nil }
        let components = reminder.dueDateComponents
        let due: Date?
        let isAllDay: Bool
        if let components {
            due = Calendar.current.date(from: components)
            isAllDay = components.hour == nil && components.minute == nil
            if let due, let windowStart, let windowEnd {
                // Dated items outside window dropped (undated always kept).
                if due < windowStart || due > windowEnd { return nil }
            }
        } else {
            due = nil
            isAllDay = true
        }

        var color: CodableColor?
        if let cg = reminder.calendar.cgColor,
           let comps = cg.components,
           comps.count >= 3 {
            color = CodableColor(
                red: Double(comps[0]),
                green: Double(comps[1]),
                blue: Double(comps[2]),
                alpha: comps.count > 3 ? Double(comps[3]) : 1
            )
        }
        let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "Reminder",
            due: due,
            isAllDay: isAllDay,
            listName: reminder.calendar.title,
            priority: Int(reminder.priority),
            notes: (notes?.isEmpty == false) ? notes : nil,
            listColor: color
        )
    }

    private func sortItems() {
        items.sort { lhs, rhs in
            // Overdue first, then dated ascending, undated last.
            switch (lhs.due, rhs.due) {
            case (nil, nil):
                return lhs.priority < rhs.priority
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (l?, r?):
                if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue && !rhs.isOverdue }
                if l != r { return l < r }
                return lhs.priority < rhs.priority
            }
        }
        if items.count > 50 {
            items = Array(items.prefix(50))
        }
    }

    private func cancelFetches() {
        if let fetchToken {
            store.cancelFetchRequest(fetchToken)
            self.fetchToken = nil
        }
        if let undatedFetchToken {
            store.cancelFetchRequest(undatedFetchToken)
            self.undatedFetchToken = nil
        }
    }

    private static func dueComponents(from date: Date, allDay: Bool) -> DateComponents {
        var comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        if allDay {
            comps.hour = nil
            comps.minute = nil
            comps.second = nil
        }
        return comps
    }

    private func updateAuth() {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess, .authorized: authState = .authorized
            case .writeOnly:
                // Write-only is rare; still treat as usable for create/complete.
                authState = .authorized
            case .notDetermined: authState = .notDetermined
            default: authState = .denied
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .authorized: authState = .authorized
            case .notDetermined: authState = .notDetermined
            default: authState = .denied
            }
        }
    }
}

// MARK: - Model

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// Nil = no due date (inbox).
    let due: Date?
    let isAllDay: Bool
    let listName: String
    /// EventKit: 0 none, 1 high … 9 low.
    let priority: Int
    let notes: String?
    let listColor: CodableColor?

    var isOverdue: Bool {
        guard let due else { return false }
        return due < Date()
    }

    var isHighPriority: Bool { priority > 0 && priority <= 4 }

    enum Phase: Equatable {
        case overdue
        case dueNow
        case soon
        case later
        case undated
    }

    func phase(reference now: Date = Date()) -> Phase {
        guard let due else { return .undated }
        let until = due.timeIntervalSince(now)
        if until < -60 { return .overdue }
        if until <= 45 { return .dueNow }
        if until <= 30 * 60 { return .soon }
        return .later
    }

    func with(title: String) -> ReminderItem {
        ReminderItem(
            id: id,
            title: title,
            due: due,
            isAllDay: isAllDay,
            listName: listName,
            priority: priority,
            notes: notes,
            listColor: listColor
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
