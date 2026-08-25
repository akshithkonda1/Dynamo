import AppKit
import EventKit
import Foundation

/// EventKit-backed calendar source — reads **your** calendars the same way
/// Calendar.app does. Reminders live in the Checklist tab.
@MainActor
final class EventKitCalendarProvider: CalendarProvider {
    private(set) var authorizationState: CalendarAuthState = .notDetermined
    private(set) var upcoming: [CalendarEventItem] = []
    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?

    func start() {
        updateAuthState()
        if authorizationState == .authorized {
            refresh()
        } else {
            onChange?()
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
    }

    func requestAccess() async {
        do {
            let eventsGranted: Bool
            if #available(macOS 14.0, *) {
                // Always ask for **full** access so we can list upcoming events.
                // Write-only leaves the tray empty even when the calendar is full.
                eventsGranted = try await store.requestFullAccessToEvents()
            } else {
                eventsGranted = try await store.requestAccess(to: .event)
            }
            updateAuthState()
            if eventsGranted || authorizationState == .authorized {
                refresh()
            } else {
                upcoming = []
                onChange?()
            }
        } catch {
            updateAuthState()
            if authorizationState != .authorized {
                upcoming = []
            }
            onChange?()
        }
    }

    func refresh() {
        updateAuthState()
        // Write-only / denied / undetermined cannot read the schedule.
        guard authorizationState == .authorized else {
            upcoming = []
            onChange?()
            return
        }

        let start = Date()
        // Fetch far enough for CalendarPlugin’s lookahead setting (up to 30 days).
        let days = 30
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)
            ?? start.addingTimeInterval(TimeInterval(days) * 86_400)

        // Prefer every event calendar the user can see. `nil` calendars uses
        // EventKit’s default (all accessible) — more reliable after partial TCC.
        let calendars = store.calendars(for: .event)
        let windowStart = start.addingTimeInterval(-12 * 60 * 60)
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: end,
            calendars: calendars.isEmpty ? nil : calendars
        )
        let now = Date()
        var raw = store.events(matching: predicate)
        // Safety net: unrestricted calendar set if the first pass is empty.
        if raw.isEmpty, !calendars.isEmpty {
            let fallback = store.predicateForEvents(
                withStart: windowStart,
                end: end,
                calendars: nil
            )
            raw = store.events(matching: fallback)
        }

        let events = raw
            .filter { event in
                // Keep in-progress and future; all-day ending today still counts.
                if event.endDate > now { return true }
                if event.isAllDay {
                    return Calendar.current.isDateInToday(event.startDate)
                        || Calendar.current.isDateInToday(event.endDate)
                }
                return false
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(50)
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
                let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                let attendees = event.attendees?.compactMap { $0.name }.filter { !$0.isEmpty } ?? []
                let id: String
                if let ek = event.eventIdentifier, !ek.isEmpty {
                    id = "\(ek)|\(event.startDate.timeIntervalSinceReferenceDate)"
                } else {
                    id = UUID().uuidString
                }
                return CalendarEventItem(
                    id: id,
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    calendarColor: color,
                    isAllDay: event.isAllDay,
                    calendarName: event.calendar.title,
                    location: (location?.isEmpty == false) ? location : nil,
                    notes: notes,
                    attendees: attendees
                )
            }
        upcoming = Array(events)
        onChange?()
    }

    func openEvent(id: String) {
        let ekID = id.split(separator: "|", maxSplits: 1).first.map(String.init) ?? id
        let encoded = ekID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ekID
        if let url = URL(string: "ical://ekevent/\(encoded)"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let event = store.event(withIdentifier: ekID) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            let day = formatter.string(from: event.startDate)
            if let url = URL(string: "ical://\(day)") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let startPart = id.split(separator: "|").dropFirst().first,
           let abs = TimeInterval(startPart) {
            let date = Date(timeIntervalSinceReferenceDate: abs)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            let day = formatter.string(from: date)
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

    func createEvent(_ draft: CalendarEventComposer.Draft) -> CalendarEventComposer.Result {
        let result = CalendarEventComposer.create(draft, store: store)
        if case .created = result {
            refresh()
        }
        return result
    }

    func openToday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: Date())
        if let url = URL(string: "ical://\(day)"), NSWorkspace.shared.open(url) {
            return
        }
        openCalendarApp()
    }

    private func updateAuthState() {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess:
                authorizationState = .authorized
            case .writeOnly:
                // Can create, cannot list — do not pretend we can read.
                authorizationState = .writeOnly
            case .authorized:
                // Legacy alias on some SDKs.
                authorizationState = .authorized
            case .notDetermined:
                authorizationState = .notDetermined
            default:
                authorizationState = .denied
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized:
                authorizationState = .authorized
            case .notDetermined:
                authorizationState = .notDetermined
            default:
                authorizationState = .denied
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
