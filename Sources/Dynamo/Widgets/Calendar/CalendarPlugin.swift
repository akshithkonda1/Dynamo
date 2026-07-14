import SwiftUI

@MainActor
final class CalendarPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding {
    let id = "calendar"
    let displayName = "Calendar"
    let systemImage = "calendar"

    @Published private(set) var events: [CalendarEventItem] = []
    @Published private(set) var authState: CalendarAuthState = .notDetermined
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: CalendarProvider
    /// Event IDs already peeked, so the ~60s refresh doesn't re-fire while an
    /// event is still inside the "starting soon" window.
    private var notifiedEventIDs: Set<String> = []
    /// How far ahead of an event's start to peek.
    private let leadTime: TimeInterval = 5 * 60

    init(provider: CalendarProvider? = nil) {
        let resolved = provider ?? EventKitCalendarProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in
            guard let self else { return }
            self.events = self.provider.upcoming
            self.authState = self.provider.authorizationState
            self.checkUpcomingEvents()
        }
    }

    func start() {
        provider.start()
        events = provider.upcoming
        authState = provider.authorizationState
        if authState == .notDetermined {
            Task { await provider.requestAccess() }
        }
    }

    func stop() {
        provider.stop()
    }

    func requestAccess() {
        Task { await provider.requestAccess() }
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedCalendarView(plugin: self))
    }

    /// Peek once for any event that's about to start (or started within the
    /// last minute, to cover the refresh interval), skipping all-day events.
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

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upcoming")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)

            switch plugin.authState {
            case .notDetermined:
                Button("Allow Calendar Access") { plugin.requestAccess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .denied:
                Text("Calendar access denied. Enable it in System Settings → Privacy & Security → Calendars.")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .authorized:
                if plugin.events.isEmpty {
                    Text("No events in the next few days.")
                        .font(NotchTheme.body)
                        .foregroundStyle(NotchTheme.textTertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
                            ForEach(plugin.events) { event in
                                eventRow(event)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func eventRow(_ event: CalendarEventItem) -> some View {
        HStack(alignment: .top, spacing: NotchTheme.spaceSM) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color(for: event))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(NotchTheme.body)
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle(for: event))
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func subtitle(for event: CalendarEventItem) -> String {
        let day = Self.dayFormatter.string(from: event.start)
        if event.isAllDay {
            return "\(day) · All day"
        }
        let start = Self.timeFormatter.string(from: event.start)
        let end = Self.timeFormatter.string(from: event.end)
        return "\(day) · \(start)–\(end)"
    }

    private func color(for event: CalendarEventItem) -> Color {
        if let c = event.calendarColor {
            return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }
        return Color.accentColor
    }
}
