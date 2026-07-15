import AppKit
import SwiftUI

@MainActor
final class CalendarPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding {
    let id = "calendar"
    let displayName = "Calendar"
    let systemImage = "calendar"

    @Published private(set) var events: [CalendarEventItem] = []
    @Published private(set) var dueReminders: [ReminderItem] = []
    @Published private(set) var authState: CalendarAuthState = .notDetermined
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: CalendarProvider
    private var notifiedEventIDs: Set<String> = []
    private var notifiedReminderIDs: Set<String> = []
    private let leadTime: TimeInterval = 5 * 60

    init(provider: CalendarProvider? = nil) {
        // Default: read-only snapshot of Calendar.app’s local SQLite store —
        // no EventKit API, no write access. Click opens Calendar.app.
        let resolved = provider ?? LocalCalendarDatabaseProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in
            guard let self else { return }
            self.events = self.provider.upcoming
            self.dueReminders = self.provider.dueReminders
            self.authState = self.provider.authorizationState
            self.checkUpcomingEvents()
            self.checkDueReminders()
        }
    }

    func start() {
        provider.start()
        events = provider.upcoming
        dueReminders = provider.dueReminders
        authState = provider.authorizationState
        // Local DB path: requestAccess just re-checks file readability (no TCC).
        if authState != .authorized {
            Task { await provider.requestAccess() }
        } else {
            provider.refresh()
        }
    }

    func stop() {
        provider.stop()
    }

    func requestAccess() {
        Task { await provider.requestAccess() }
    }

    func openEvent(_ event: CalendarEventItem) {
        provider.openEvent(id: event.id)
    }

    func openCalendarApp() {
        provider.openCalendarApp()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedCalendarView(plugin: self))
    }

    private func checkUpcomingEvents() {
        notifiedEventIDs.formIntersection(Set(events.map(\.id)))
        for event in events {
            guard !event.isAllDay, !notifiedEventIDs.contains(event.id) else { continue }
            let interval = event.start.timeIntervalSinceNow
            guard interval <= leadTime, interval > -60 else { continue }
            notifiedEventIDs.insert(event.id)
            onSneakPeek?(NotchSneakPeek(
                systemImage: "calendar",
                title: event.title,
                subtitle: startingSoonLabel(interval)
            ))
        }
    }

    private func startingSoonLabel(_ interval: TimeInterval) -> String {
        if interval <= 0 { return "Starting now" }
        let minutes = max(1, Int((interval / 60).rounded()))
        return minutes == 1 ? "Starts in 1 minute" : "Starts in \(minutes) minutes"
    }

    private func checkDueReminders() {
        notifiedReminderIDs.formIntersection(Set(dueReminders.map(\.id)))
        for reminder in dueReminders {
            guard !notifiedReminderIDs.contains(reminder.id) else { continue }
            let interval = reminder.due.timeIntervalSinceNow
            guard interval <= leadTime, interval > -60 else { continue }
            notifiedReminderIDs.insert(reminder.id)
            let subtitle: String
            if interval <= 0 {
                subtitle = "Due now"
            } else {
                let minutes = max(1, Int((interval / 60).rounded()))
                subtitle = minutes == 1 ? "Due in 1 minute" : "Due in \(minutes) minutes"
            }
            onSneakPeek?(NotchSneakPeek(
                systemImage: "checklist",
                title: reminder.title,
                subtitle: subtitle
            ))
        }
    }
}

// MARK: - Views

private struct ExpandedCalendarView: View {
    @ObservedObject var plugin: CalendarPlugin

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your Calendar")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                if plugin.authState == .authorized {
                    Button {
                        plugin.openCalendarApp()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    .buttonStyle(.notchIcon(diameter: 22))
                    .help("Open Calendar app")
                }
            }

            switch plugin.authState {
            case .notDetermined:
                Text("Looking for Calendar data…")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
                Button("Retry") { plugin.requestAccess() }
                    .controlSize(.small)
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Can’t read Calendar’s local database.")
                        .font(NotchTheme.caption)
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("Dynamo reads Calendar.app’s files in read-only mode (no EventKit write). If blocked, grant Full Disk Access to Dynamo, then Retry.")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Open Full Disk Access") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        Button("Retry") { plugin.requestAccess() }
                            .controlSize(.small)
                    }
                }
            case .authorized:
                if plugin.events.isEmpty && plugin.dueReminders.isEmpty {
                    Text("No upcoming events in the next two weeks.")
                        .font(NotchTheme.body)
                        .foregroundStyle(NotchTheme.textTertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
                            if !plugin.dueReminders.isEmpty {
                                Text("Reminders")
                                    .font(NotchTheme.micro.weight(.semibold))
                                    .foregroundStyle(NotchTheme.textQuaternary)
                                ForEach(plugin.dueReminders) { reminder in
                                    reminderRow(reminder)
                                }
                            }
                            ForEach(groupedDays, id: \.dayStart) { group in
                                Text(dayLabel(group.dayStart))
                                    .font(NotchTheme.micro.weight(.semibold))
                                    .foregroundStyle(NotchTheme.textQuaternary)
                                    .padding(.top, 2)
                                ForEach(group.events) { event in
                                    eventRow(event)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct DayGroup {
        let dayStart: Date
        let events: [CalendarEventItem]
    }

    private var groupedDays: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: plugin.events) { event -> Date in
            cal.startOfDay(for: event.start)
        }
        return grouped.keys.sorted().map { day in
            DayGroup(dayStart: day, events: (grouped[day] ?? []).sorted { $0.start < $1.start })
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return Self.dayHeaderFormatter.string(from: day)
    }

    private func eventRow(_ event: CalendarEventItem) -> some View {
        Button {
            plugin.openEvent(event)
        } label: {
            HStack(alignment: .top, spacing: NotchTheme.spaceSM) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(for: event))
                    .frame(width: 3, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(NotchTheme.body)
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(for: event))
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                    if let location = event.location {
                        Text(location)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Calendar")
    }

    private func reminderRow(_ reminder: ReminderItem) -> some View {
        HStack(alignment: .top, spacing: NotchTheme.spaceSM) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.caution)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(NotchTheme.body)
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(Self.timeFormatter.string(from: reminder.due))
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func subtitle(for event: CalendarEventItem) -> String {
        let time: String
        if event.isAllDay {
            time = "All day"
        } else {
            let start = Self.timeFormatter.string(from: event.start)
            let end = Self.timeFormatter.string(from: event.end)
            time = "\(start)–\(end)"
        }
        return "\(time) · \(event.calendarName)"
    }

    private func color(for event: CalendarEventItem) -> Color {
        if let c = event.calendarColor {
            return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }
        return Color.accentColor
    }
}
