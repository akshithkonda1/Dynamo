import AppKit
import Foundation

struct CalendarEventItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarColor: CodableColor?
    let isAllDay: Bool
    /// Name of the EKCalendar this event belongs to (e.g. "Work", "Home").
    let calendarName: String
    let location: String?
    let notes: String?
    let attendees: [String]
}

/// Hex-friendly color stored without importing AppKit into the protocol surface.
struct CodableColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

enum CalendarAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
}

@MainActor
protocol CalendarProvider: AnyObject {
    var authorizationState: CalendarAuthState { get }
    var upcoming: [CalendarEventItem] { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    func requestAccess() async
    func refresh()
    /// Open the event in the system Calendar app when possible.
    func openEvent(id: String)
    /// Open Calendar focused on today.
    func openCalendarApp()
    /// Open Calendar’s new-event UI when possible.
    func openNewEvent()
    /// Open Calendar focused on today.
    func openToday()
}

extension CalendarProvider {
    func openEvent(id: String) {}
    func openCalendarApp() {}
    func openNewEvent() { openCalendarApp() }
    func openToday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: Date())
        if let url = URL(string: "ical://\(day)") {
            NSWorkspace.shared.open(url)
            return
        }
        openCalendarApp()
    }
}

extension CalendarEventItem {
    enum Phase: Equatable {
        case ended
        case now
        case soon
        case later
    }

    func phase(reference now: Date = Date()) -> Phase {
        if end <= now { return .ended }
        // All-day events span the whole day — don't stamp "Now"/"Soon" chips.
        if isAllDay { return .later }
        if start <= now { return .now }
        let until = start.timeIntervalSince(now)
        if until <= 30 * 60 { return .soon }
        return .later
    }
}
