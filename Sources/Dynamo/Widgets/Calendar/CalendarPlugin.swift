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
        case .notDetermined, .writeOnly:
            // Prompt (again) for full read access — write-only leaves the list empty.
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
        let previousCount = events.count
        let previousAuth = authState
        events = provider.upcoming.filter { item in
            if item.end > now { return true }
            // Keep all-day items that still land on today.
            if item.isAllDay {
                return Calendar.current.isDateInToday(item.start)
                    || Calendar.current.isDateInToday(item.end)
            }
            return false
        }
        authState = provider.authorizationState
        // Resize island when empty ↔ list or auth flips (compact empty tray).
        if previousCount != events.count || previousAuth != authState {
            NotificationCenter.default.post(name: .dynamoFocusLayoutDidChange, object: nil)
        }
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

    @Published var showComposer = false
    @Published var eventDraft = CalendarEventComposer.Draft()
    @Published var createError: String?
    @Published var createSuccess: String?

    @discardableResult
    func createEventFromDraft() -> Bool {
        createError = nil
        createSuccess = nil
        let result = provider.createEvent(eventDraft)
        switch result {
        case .created:
            createSuccess = "Event created"
            showComposer = false
            eventDraft = CalendarEventComposer.Draft()
            refresh()
            return true
        case .failed(let msg):
            createError = msg
            return false
        case .denied:
            createError = "Calendar access required"
            requestAccess()
            return false
        }
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedCalendarView(plugin: self))
    }

    /// Compact when empty / no read access; taller only when listing events.
    var expandedContentHeight: CGFloat {
        if showComposer { return 250 }
        switch authState {
        case .authorized:
            if events.isEmpty { return 118 }
            let rows = min(events.count, 5)
            return min(280, 120 + CGFloat(rows) * 42)
        case .writeOnly, .denied, .notDetermined:
            return 148
        }
    }

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
                        withAnimation(NotchTheme.snappy) {
                            plugin.showComposer.toggle()
                            plugin.createError = nil
                            plugin.createSuccess = nil
                        }
                    } label: {
                        NotchChipLabel(
                            title: plugin.showComposer ? "Close" : "New",
                            systemImage: plugin.showComposer ? "xmark" : "plus",
                            active: plugin.showComposer
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Create event in Dynamo")

                    Button {
                        plugin.openNewEvent()
                    } label: {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    .buttonStyle(.notchIcon(diameter: 22))
                    .help("Open new event in Calendar.app")

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

            if plugin.showComposer, plugin.authState == .authorized || plugin.authState == .writeOnly {
                calendarComposer
            }

            if let ok = plugin.createSuccess {
                Text(ok)
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.positive)
            }
            if let err = plugin.createError {
                Text(err)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.negative)
                    .lineLimit(2)
            }

            switch plugin.authState {
            case .notDetermined:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendar access needed")
                        .font(NotchTheme.caption.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("Allow Full Calendar Access so upcoming events appear here.")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow Calendar Access") { plugin.requestAccess() }
                        .controlSize(.small)
                }
            case .writeOnly:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full access required to show events")
                        .font(NotchTheme.caption.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("macOS only granted write access. Dynamo can create events but cannot read your schedule until you enable Full Calendar Access.")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Request Full Access") { plugin.requestAccess() }
                            .controlSize(.small)
                        Button("Open Calendar Privacy") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendar access is off")
                        .font(NotchTheme.caption.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("Grant Full Calendar Access in System Settings.")
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
                        systemImage: "sun.max.fill",
                        title: "Wide open calendar",
                        caption: "Nothing in the next 3 weeks — tap New when you’re ready.",
                        prominent: false
                    )
                } else {
                    GeometryReader { geo in
                        let columns = geo.size.width >= 560 ? 2 : 1
                        calendarEventList(columns: columns)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { plugin.refresh() }
    }

    @ViewBuilder
    private func calendarEventList(columns: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
                ForEach(groupedDays, id: \.dayStart) { group in
                    Text(dayLabel(group.dayStart))
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .padding(.top, 2)
                    if columns == 2 {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)
                            ],
                            spacing: 6
                        ) {
                            ForEach(group.events) { event in
                                eventRow(event)
                            }
                        }
                    } else {
                        ForEach(group.events) { event in
                            eventRow(event)
                        }
                    }
                }
            }
        }
    }

    private var calendarComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(
                    "Event title",
                    text: Binding(
                        get: { plugin.eventDraft.title },
                        set: { plugin.eventDraft.title = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(NotchTheme.body.weight(.semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .onSubmit { _ = plugin.createEventFromDraft() }

                Button {
                    _ = plugin.createEventFromDraft()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            plugin.eventDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? NotchTheme.textQuaternary
                                : NotchTheme.positive
                        )
                }
                .buttonStyle(.plain)
                .disabled(plugin.eventDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Create event")
            }

            HStack(spacing: 6) {
                durationChip(15)
                durationChip(30)
                durationChip(60)
                durationChip(90)
                Button {
                    plugin.eventDraft.allDay.toggle()
                } label: {
                    NotchChipLabel(title: "All day", systemImage: "sun.max", active: plugin.eventDraft.allDay)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                startChip("In 15m") {
                    plugin.eventDraft.start = Date().addingTimeInterval(15 * 60)
                }
                startChip("In 1h") {
                    plugin.eventDraft.start = Date().addingTimeInterval(3600)
                }
                startChip("Tomorrow 9am") {
                    let cal = Calendar.current
                    let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    var comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
                    comps.hour = 9
                    comps.minute = 0
                    plugin.eventDraft.start = cal.date(from: comps) ?? tomorrow
                }
                Spacer(minLength: 0)
            }

            TextField(
                "Location (optional)",
                text: Binding(
                    get: { plugin.eventDraft.location },
                    set: { plugin.eventDraft.location = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(NotchTheme.micro)
            .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    private func durationChip(_ minutes: Int) -> some View {
        Button {
            plugin.eventDraft.durationMinutes = minutes
            plugin.eventDraft.allDay = false
        } label: {
            NotchChipLabel(
                title: minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m",
                active: !plugin.eventDraft.allDay && plugin.eventDraft.durationMinutes == minutes
            )
        }
        .buttonStyle(.plain)
    }

    private func startChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NotchChipLabel(title: title, systemImage: "clock")
        }
        .buttonStyle(.plain)
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
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                }
                if !event.attendees.isEmpty {
                    Text("\(event.attendees.count) people")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(NotchTheme.chipFill, in: Capsule())
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
