import AppKit
import Foundation

/// Deterministic Dynamic Mode helpers — peeks as tools, no AI.
@MainActor
final class DynamicCompanion {
    static let shared = DynamicCompanion()

    private var lastPulseAt: Date = .distantPast
    private let pulseInterval: TimeInterval = 45 * 60
    private var sessionNudgedChecklist = false

    /// Optional hourly-style pulse: next calendar or overdue reminder.
    func maybePulse(
        events: [CalendarEventItem],
        reminders: [ReminderItem],
        emit: (NotchSneakPeek) -> Void
    ) {
        guard FocusController.shared.effective == .dynamic else { return }
        guard !FocusController.shared.isMeetingActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPulseAt) >= pulseInterval else { return }

        // Prefer soon event within 2h.
        if let next = events
            .filter({ !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) < 2 * 3600 })
            .sorted(by: { $0.start < $1.start })
            .first {
            lastPulseAt = now
            let mins = max(1, Int(next.start.timeIntervalSince(now) / 60))
            let title = next.title
            emit(NotchSneakPeek(
                systemImage: "bolt.horizontal.circle",
                title: title,
                subtitle: mins < 60 ? "Up next in \(mins)m" : "Up next today",
                urgency: .normal,
                detail: next.calendarName
            ))
            FocusController.shared.noteDynamicPeek(title)
            return
        }

        if let overdue = reminders.first(where: \.isOverdue) {
            lastPulseAt = now
            emit(NotchSneakPeek(
                systemImage: "checklist",
                title: overdue.title,
                subtitle: "Overdue reminder",
                urgency: .high,
                detail: overdue.listName
            ))
            FocusController.shared.noteDynamicPeek(overdue.title)
        }
    }

    /// Soft one-shot nudge when coding tools frontmost.
    func maybeSessionNudge(emit: (NotchSneakPeek) -> Void) {
        guard FocusController.shared.effective == .dynamic else { return }
        guard !sessionNudgedChecklist else { return }
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        let coding: Set<String> = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.github.atom" // legacy
        ]
        guard coding.contains(bid) else { return }
        sessionNudgedChecklist = true
        emit(NotchSneakPeek(
            systemImage: "checklist",
            title: "Checklist ready",
            subtitle: "Capture a task while you code",
            urgency: .low,
            detail: "Dynamic"
        ))
        FocusController.shared.noteDynamicPeek("Checklist ready")
    }
}
