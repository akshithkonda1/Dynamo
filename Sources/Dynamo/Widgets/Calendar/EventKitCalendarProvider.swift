import EventKit
import Foundation

/// EventKit-backed calendar + reminders source. Branches on macOS 14 full-access
/// APIs and falls back to the legacy request on macOS 13.
@MainActor
final class EventKitCalendarProvider: CalendarProvider {
    private(set) var authorizationState: CalendarAuthState = .notDetermined
    private(set) var upcoming: [CalendarEventItem] = []
    private(set) var dueReminders: [ReminderItem] = []
    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var remindersAuthorized = false

    func start() {
        updateAuthState()
        if authorizationState == .authorized {
            refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func requestAccess() async {
        do {
            let eventsGranted: Bool
            if #available(macOS 14.0, *) {
                eventsGranted = try await store.requestFullAccessToEvents()
            } else {
                eventsGranted = try await store.requestAccess(to: .event)
            }
            authorizationState = eventsGranted ? .authorized : .denied

            // Reminders are a separate grant — best-effort; calendar still works without them.
            if #available(macOS 14.0, *) {
                remindersAuthorized = (try? await store.requestFullAccessToReminders()) ?? false
            } else {
                remindersAuthorized = (try? await store.requestAccess(to: .reminder)) ?? false
            }

            if eventsGranted {
                refresh()
            }
            onChange?()
        } catch {
            authorizationState = .denied
            onChange?()
        }
    }

    func refresh() {
        updateAuthState()
        updateRemindersAuth()
        guard authorizationState == .authorized else {
            upcoming = []
            dueReminders = []
            onChange?()
            return
        }

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 3, to: start) ?? start.addingTimeInterval(259_200)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { event -> CalendarEventItem in
                var color: CodableColor?
                if let cg = event.calendar.cgColor,
                   let comps = cg.components,
                   comps.count >= 3 {
                    color = CodableColor(
                        red: Double(comps[0]),
                        green: Double(comps[1]),
                        blue: Double(comps[2]),
                        alpha: comps.count > 3 ? Double(comps[3]) : 1
                    )
                }
                return CalendarEventItem(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    calendarColor: color,
                    isAllDay: event.isAllDay
                )
            }
        upcoming = Array(events)
        refreshReminders()
        onChange?()
    }

    private func refreshReminders() {
        guard remindersAuthorized else {
            dueReminders = []
            return
        }
        let end = Date().addingTimeInterval(24 * 60 * 60)
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: end,
            calendars: nil
        )
        // EventKit reminders fetch is completion-handler based.
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                let items = (reminders ?? [])
                    .compactMap { reminder -> ReminderItem? in
                        guard let components = reminder.dueDateComponents,
                              let due = Calendar.current.date(from: components)
                        else { return nil }
                        // Only surface items due within the next day or already overdue by ≤1h.
                        guard due.timeIntervalSince(now) <= 24 * 60 * 60,
                              due.timeIntervalSince(now) > -60 * 60
                        else { return nil }
                        return ReminderItem(
                            id: reminder.calendarItemIdentifier,
                            title: reminder.title ?? "Reminder",
                            due: due
                        )
                    }
                    .sorted { $0.due < $1.due }
                    .prefix(8)
                self.dueReminders = Array(items)
                self.onChange?()
            }
        }
    }

    private func updateAuthState() {
        let status: EKAuthorizationStatus
        if #available(macOS 14.0, *) {
            status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .fullAccess, .writeOnly:
                authorizationState = (status == .fullAccess) ? .authorized : .denied
            case .authorized:
                authorizationState = .authorized
            case .notDetermined:
                authorizationState = .notDetermined
            default:
                authorizationState = .denied
            }
        } else {
            status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .authorized:
                authorizationState = .authorized
            case .notDetermined:
                authorizationState = .notDetermined
            default:
                authorizationState = .denied
            }
        }
    }

    private func updateRemindersAuth() {
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            remindersAuthorized = (status == .fullAccess || status == .authorized)
        } else {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            remindersAuthorized = (status == .authorized)
        }
    }
}
