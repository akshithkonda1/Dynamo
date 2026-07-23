import AppKit
import SwiftUI

@MainActor
final class CalendarPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding, NotchAmbientProviding {
    let id = "calendar"
    let displayName = "Calendar"
    let systemImage = "calendar"

    @Published private(set) var events: [CalendarEventItem] = []
    @Published private(set) var authState: CalendarAuthState = .notDetermined
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: CalendarProvider
    /// Stages already announced per event id (e.g. "t15", "t5", "now").
    private var notifiedEventStages: [String: Set<String>] = [:]
    private let leadTime: TimeInterval = 15 * 60

    init(provider: CalendarProvider? = nil) {
        // Events only — system Reminders live in the Checklist tab.
        let resolved = provider ?? EventKitCalendarProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in
            guard let self else { return }
            self.applyProviderSnapshot()
            self.checkUpcomingEvents()
        }
    }

    var ambientEvent: CalendarEventItem? {
        let now = Date()
        return events
            .filter { !$0.isAllDay && $0.end > now }
            .sorted { $0.start < $1.start }
            .first { event in
                if event.start <= now { return true }
                return event.start.timeIntervalSince(now) <= 60 * 60
            }
    }

    var isAmbientActive: Bool { ambientEvent != nil }
    var ambientPriority: Int {
        guard let event = ambientEvent else { return 0 }
        switch event.phase() {
        case .now: return 85
        case .soon: return 80
        default: return 40
        }
    }

    var isMeetingNow: Bool {
        ambientEvent.map { $0.phase() == .now } ?? false
    }

    func ambientView() -> AnyView {
        AnyView(AmbientCalendarView(event: ambientEvent))
    }

    func start() {
        MeetingMode.shared.isInActiveMeeting = { [weak self] in
            self?.isMeetingNow == true
        }
        FocusController.shared.isCalendarMeetingNow = { [weak self] in
            self?.isMeetingNow == true
        }
        FocusController.shared.calendarMeetingTitle = { [weak self] in
            self?.ambientEvent?.title
        }
        provider.start()
        applyProviderSnapshot()
        switch authState {
        case .notDetermined:
            Task { await provider.requestAccess() }
        case .authorized:
            provider.refresh()
        case .denied:
            break
        }
    }

    func refresh() {
        provider.refresh()
        applyProviderSnapshot()
    }

    private func applyProviderSnapshot() {
        let now = Date()
        events = provider.upcoming.filter { $0.end > now }
        authState = provider.authorizationState
        // Feed Focus modes.
        FocusController.shared.reevaluateMeeting()
        FocusAgendaEngine.shared.updateEvents(events)
        if FocusController.shared.effective == .dynamic {
            DynamicCompanion.shared.maybePulse(events: events, reminders: []) { [weak self] peek in
                self?.onSneakPeek?(peek)
            }
            DynamicCompanion.shared.maybeSessionNudge { [weak self] peek in
                self?.onSneakPeek?(peek)
            }
        }
        if FocusController.shared.effective == .trueFocus {
            FocusAgendaEngine.shared.trueFocusPeeks(events: events) { [weak self] peek in
                self?.onSneakPeek?(peek)
            }
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

    func openNewEvent() {
        provider.openNewEvent()
    }

    func openToday() {
        provider.openToday()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedCalendarView(plugin: self))
    }

    var expandedContentHeight: CGFloat { 255 }

    private func checkUpcomingEvents() {
        let liveIDs = Set(events.map(\.id))
        notifiedEventStages = notifiedEventStages.filter { liveIDs.contains($0.key) }

        for event in events {
            guard !event.isAllDay else { continue }
            let interval = event.start.timeIntervalSinceNow
            guard interval <= leadTime, interval > -90 else { continue }

            let stage = peekStage(for: interval)
            var seen = notifiedEventStages[event.id] ?? []
            guard !seen.contains(stage) else { continue }
            seen.insert(stage)
            notifiedEventStages[event.id] = seen

            let urgency: NotchSneakPeekUrgency = stage == "now" ? .critical : .high
            var detailParts: [String] = []
            if !event.calendarName.isEmpty { detailParts.append(event.calendarName) }
            if let loc = event.location, !loc.isEmpty { detailParts.append(loc) }
            onSneakPeek?(NotchSneakPeek(
                systemImage: stage == "now" ? "calendar.badge.clock" : "calendar",
                title: event.title,
                subtitle: eventTimeLabel(event: event, interval: interval, stage: stage),
                urgency: urgency,
                detail: detailParts.joined(separator: " · ")
            ))
        }
    }

    private func peekStage(for interval: TimeInterval) -> String {
        if interval <= 45 { return "now" }
        if interval <= 5 * 60 + 20 { return "t5" }
        return "t15"
    }

    private func eventTimeLabel(event: CalendarEventItem, interval: TimeInterval, stage: String) -> String {
        let time = event.start.formatted(date: .omitted, time: .shortened)
        if stage == "now" || interval <= 0 {
            return "Starting now · \(time)"
        }
        let minutes = max(1, Int((interval / 60).rounded()))
        if minutes == 1 { return "Starts in 1 minute · \(time)" }
        return "Starts in \(minutes) minutes · \(time)"
    }
}

// MARK: - Ambient

private struct AmbientCalendarView: View {
    let event: CalendarEventItem?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
            if let event {
                Text(event.title)
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(ambientSubtitle(for: event))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ambientSubtitle(for event: CalendarEventItem) -> String {
        let now = Date()
        if event.start <= now {
            let left = max(0, Int(event.end.timeIntervalSince(now) / 60))
            return left <= 1 ? "ending" : "\(left)m left"
        }
        let mins = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded()))
        return "in \(mins)m"
    }
}

// MARK: - Expanded

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
                NotchSectionHeader("Calendar")
                Spacer(minLength: 0)
                if plugin.authState == .authorized {
                    Button {
                        plugin.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    .buttonStyle(.notchIcon(diameter: 22))
                    .help("Refresh events")

                    Button {
                        plugin.openToday()
                    } label: {
                        NotchChipLabel(title: "Today", systemImage: "calendar")
                    }
                    .buttonStyle(.plain)
                    .help("Open today in Calendar")

                    Button {
                        plugin.openNewEvent()
                    } label: {
                        NotchChipLabel(title: "New", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Create event in Calendar")

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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Calendar access needed")
                        .font(NotchTheme.caption.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("Allow Dynamo to read your calendars so upcoming events appear in the notch.")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow Calendar Access") { plugin.requestAccess() }
                        .controlSize(.small)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendar access is off")
                        .font(NotchTheme.caption.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("Grant Full Calendar Access in System Settings. Dynamo never writes to your calendar.")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Open Calendar Privacy") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        Button("Retry") { plugin.requestAccess() }
                            .controlSize(.small)
                        Button("Open Calendar") { plugin.openCalendarApp() }
                            .controlSize(.small)
                    }
                }
            case .authorized:
                if plugin.events.isEmpty {
                    NotchEmptyState(
                        systemImage: "calendar",
                        title: "No upcoming events",
                        caption: "Next two weeks are clear — tap New to schedule. Reminders live under Checklist.",
                        prominent: true
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
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
        let phase = event.phase()
        return HStack(alignment: .top, spacing: NotchTheme.spaceSM) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color(for: event))
                .frame(width: 3, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(NotchTheme.body.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    phaseChip(phase)
                }
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
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
                .padding(.top, 4)
        }
        .notchRowBackground()
        .contentShape(Rectangle())
        .onTapGesture { plugin.openEvent(event) }
        .help("Open in Calendar")
    }

    @ViewBuilder
    private func phaseChip(_ phase: CalendarEventItem.Phase) -> some View {
        switch phase {
        case .now:
            NotchStatusChip(text: "Now", kind: .now)
        case .soon:
            NotchStatusChip(text: "Soon", kind: .soon)
        case .later, .ended:
            EmptyView()
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
