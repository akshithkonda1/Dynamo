import EventKit
import Foundation

/// In-process EventKit create path for calendar events (not just open Calendar.app).
@MainActor
enum CalendarEventComposer {
    struct Draft: Equatable {
        var title: String = ""
        var start: Date = Date().addingTimeInterval(15 * 60)
        var durationMinutes: Int = 30
        var allDay: Bool = false
        var location: String = ""
        var notes: String = ""

        var end: Date {
            if allDay {
                return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: start))
                    ?? start.addingTimeInterval(86_400)
            }
            return start.addingTimeInterval(TimeInterval(max(15, durationMinutes)) * 60)
        }
    }

    enum Result {
        case created(id: String)
        case failed(String)
        case denied
    }

    /// Create and commit an event into the default calendar.
    static func create(_ draft: Draft, store: EKEventStore = EKEventStore()) -> Result {
        let auth = authorization()
        // Write-only still allows create; full access required only for listing.
        guard auth == .authorized || auth == .writeOnly else {
            return .denied
        }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .failed("Title required")
        }

        guard let calendar = store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications })
        else {
            return .failed("No writable calendar")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = calendar
        event.isAllDay = draft.allDay
        if draft.allDay {
            let day = Calendar.current.startOfDay(for: draft.start)
            event.startDate = day
            event.endDate = draft.end
        } else {
            event.startDate = draft.start
            event.endDate = draft.end
        }
        let loc = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loc.isEmpty { event.location = loc }
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { event.notes = notes }

        // Gentle 10-minute alarm for timed events.
        if !draft.allDay {
            event.addAlarm(EKAlarm(relativeOffset: -10 * 60))
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
            let id = event.eventIdentifier ?? UUID().uuidString
            return .created(id: id)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func authorization() -> CalendarAuthState {
        if #available(macOS 14.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .authorized
            case .writeOnly: return .writeOnly
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }
}
