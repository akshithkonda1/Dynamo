import Foundation

struct FocusAgendaItem: Identifiable, Equatable {
    enum Kind { case event, reminder, localTask }
    let id: String
    let title: String
    let when: Date?
    let kind: Kind
    let detail: String
    let isOverdue: Bool
    let isNow: Bool
}

struct FocusAgendaSnapshot: Equatable {
    var now: FocusAgendaItem?
    var upNext: [FocusAgendaItem]
    var needsAttention: [FocusAgendaItem]
}

/// Builds today timeline for True Focus (no AI).
@MainActor
final class FocusAgendaEngine: ObservableObject {
    static let shared = FocusAgendaEngine()

    @Published private(set) var snapshot = FocusAgendaSnapshot(now: nil, upNext: [], needsAttention: [])

    private var prepNotified = Set<String>()
    private var endNotified = Set<String>()
    private var lastEvents: [CalendarEventItem] = []
    private var lastReminders: [ReminderItem] = []
    private var lastLocal: [(id: UUID, text: String)] = []

    func updateEvents(_ events: [CalendarEventItem]) {
        lastEvents = events
        rebuild()
    }

    func updateReminders(_ reminders: [ReminderItem], localOpen: [(id: UUID, text: String)]) {
        lastReminders = reminders
        lastLocal = localOpen
        rebuild()
    }

    func rebuild(
        events: [CalendarEventItem]? = nil,
        reminders: [ReminderItem]? = nil,
        localOpen: [(id: UUID, text: String)]? = nil
    ) {
        if let events { lastEvents = events }
        if let reminders { lastReminders = reminders }
        if let localOpen { lastLocal = localOpen }

        let events = lastEvents
        let reminders = lastReminders
        let localOpen = lastLocal

        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? now.addingTimeInterval(86_400)

        var items: [FocusAgendaItem] = []

        for e in events {
            guard e.end > now else { continue }
            let isToday = e.start < endOfDay && e.end > startOfDay
            guard isToday || e.start.timeIntervalSince(now) < 36 * 3600 else { continue }
            let phase = e.phase(reference: now)
            items.append(FocusAgendaItem(
                id: "e:\(e.id)",
                title: e.title,
                when: e.start,
                kind: .event,
                detail: e.calendarName,
                isOverdue: false,
                isNow: phase == .now
            ))
        }

        for r in reminders {
            let overdue = r.isOverdue
            if let due = r.due {
                let today = due < endOfDay && due >= startOfDay.addingTimeInterval(-7 * 86_400)
                guard today || overdue else { continue }
                items.append(FocusAgendaItem(
                    id: "r:\(r.id)",
                    title: r.title,
                    when: due,
                    kind: .reminder,
                    detail: r.listName,
                    isOverdue: overdue,
                    isNow: !overdue && abs(due.timeIntervalSince(now)) < 45
                ))
            } else {
                items.append(FocusAgendaItem(
                    id: "r:\(r.id)",
                    title: r.title,
                    when: nil,
                    kind: .reminder,
                    detail: r.listName,
                    isOverdue: false,
                    isNow: false
                ))
            }
        }

        for t in localOpen.prefix(8) {
            items.append(FocusAgendaItem(
                id: "l:\(t.id.uuidString)",
                title: t.text,
                when: nil,
                kind: .localTask,
                detail: "Local",
                isOverdue: false,
                isNow: false
            ))
        }

        let nowItem = items.first(where: \.isNow)
        let attention = items.filter(\.isOverdue)
        let upcoming = items
            .filter { !$0.isNow && !$0.isOverdue }
            .sorted { ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture) }

        snapshot = FocusAgendaSnapshot(
            now: nowItem,
            upNext: Array(upcoming.prefix(5)),
            needsAttention: Array(attention.prefix(5))
        )
    }

    /// Prep / end-of-block peeks for True Focus.
    func trueFocusPeeks(events: [CalendarEventItem], emit: (NotchSneakPeek) -> Void) {
        let now = Date()
        for e in events where !e.isAllDay {
            let untilStart = e.start.timeIntervalSince(now)
            // Prep at ~30 minutes.
            if untilStart > 25 * 60, untilStart <= 35 * 60 {
                let key = "prep:\(e.id)"
                if !prepNotified.contains(key) {
                    prepNotified.insert(key)
                    var detail = e.calendarName
                    if let loc = e.location, !loc.isEmpty { detail += " · \(loc)" }
                    emit(NotchSneakPeek(
                        systemImage: "target",
                        title: "Prep · \(e.title)",
                        subtitle: "Starts in \(Int((untilStart / 60).rounded())) min",
                        urgency: .high,
                        detail: detail
                    ))
                }
            }
            // Just ended.
            let sinceEnd = now.timeIntervalSince(e.end)
            if sinceEnd > 0, sinceEnd < 120 {
                let key = "end:\(e.id)"
                if !endNotified.contains(key) {
                    endNotified.insert(key)
                    let next = events
                        .filter { $0.start > e.end && !$0.isAllDay }
                        .sorted { $0.start < $1.start }
                        .first
                    let sub: String
                    if let next {
                        sub = "Next: \(next.title)"
                    } else {
                        sub = "Block complete"
                    }
                    emit(NotchSneakPeek(
                        systemImage: "checkmark.circle",
                        title: "Done · \(e.title)",
                        subtitle: sub,
                        urgency: .normal,
                        detail: "True Focus"
                    ))
                }
            }
        }
        // Cap memory
        if prepNotified.count > 40 { prepNotified = Set(prepNotified.suffix(20)) }
        if endNotified.count > 40 { endNotified = Set(endNotified.suffix(20)) }
    }
}
