import Foundation

/// Next-N-day strip used beside the Calendar event list.
enum CalendarMonthStrip {
    static let defaultDays = 30

    static func days(
        from start: Date = Date(),
        count: Int = defaultDays,
        calendar: Calendar = .current
    ) -> [Date] {
        let origin = calendar.startOfDay(for: start)
        return (0..<max(1, count)).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: origin)
        }
    }

    static func eventCount(
        on day: Date,
        events: [CalendarEventItem],
        calendar: Calendar = .current
    ) -> Int {
        events.filter { calendar.isDate($0.start, inSameDayAs: day) }.count
    }
}
