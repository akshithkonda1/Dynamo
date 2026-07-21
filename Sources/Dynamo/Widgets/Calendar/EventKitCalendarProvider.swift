import AppKit
import EventKit
import Foundation

/// EventKit-backed calendar + reminders source — reads **your** calendars
/// (iCloud, Exchange, Google via Calendar.app, local, etc.) the same way the
/// system Calendar app does.
@MainActor
final class EventKitCalendarProvider: CalendarProvider {
    private(set) var authorizationState: CalendarAuthState = .notDetermined
    private(set) var upcoming: [CalendarEventItem] = []
    private(set) var dueReminders: [ReminderItem] = []
    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var remindersAuthorized = false
    private var changeObserver: NSObjectProtocol?

    func start() {
        updateAuthState()
        if authorizationState == .authorized {
            refresh()
        }
        // Live updates when the user edits Calendar.app / iCloud syncs.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
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
        // Look further ahead so "your week" feels complete.
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start)
            ?? start.addingTimeInterval(14 * 86_400)

        // All calendars the user has enabled in Calendar.app (nil = all).
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendars.isEmpty ? nil : calendars
        )
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(24)
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
                let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
                return CalendarEventItem(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    calendarColor: color,
                    isAllDay: event.isAllDay,
                    calendarName: event.calendar.title,
                    location: (location?.isEmpty == false) ? location : nil
                )
            }
        upcoming = Array(events)
        refreshReminders()
        onChange?()
    }

    func openEvent(id: String) {
        // Prefer deep-link into Calendar.app for this event.
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        if let url = URL(string: "ical://ekevent/\(encoded)"),
           NSWorkspace.shared.open(url) {
            return
        }
        // Fallback: show the day in Calendar.
        if let event = store.event(withIdentifier: id) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            let day = formatter.string(from: event.startDate)
            if let url = URL(string: "ical://\(day)") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        openCalendarApp()
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }

    func openNewEvent() {
        CalendarNewEventOpener.open()
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
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                let items = (reminders ?? [])
                    .compactMap { reminder -> ReminderItem? in
                        guard let components = reminder.dueDateComponents,
                              let due = Calendar.current.date(from: components)
                        else { return nil }
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
            case .fullAccess:
                authorizationState = .authorized
            case .writeOnly:
                authorizationState = .denied
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
