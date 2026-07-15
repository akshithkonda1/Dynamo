import Foundation

struct CalendarEventItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarColor: CodableColor?
    let isAllDay: Bool
}

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date
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
    /// Incomplete reminders due within the near window (for peeks + list).
    var dueReminders: [ReminderItem] { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    func requestAccess() async
    func refresh()
}

extension CalendarProvider {
    var dueReminders: [ReminderItem] { [] }
}
