import EventKit
import Foundation

/// EventKit-backed calendar source. Branches on macOS 14's full-access API
/// and falls back to the legacy request on macOS 13.
@MainActor
final class EventKitCalendarProvider: CalendarProvider {
    private(set) var authorizationState: CalendarAuthState = .notDetermined
    private(set) var upcoming: [CalendarEventItem] = []
    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?

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
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            authorizationState = granted ? .authorized : .denied
            if granted {
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
        guard authorizationState == .authorized else {
            upcoming = []
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
        onChange?()
    }

    private func updateAuthState() {
        let status: EKAuthorizationStatus
        if #available(macOS 14.0, *) {
            status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .fullAccess, .writeOnly:
                // writeOnly is unexpected for our use, but treat fullAccess as authorized.
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
}
