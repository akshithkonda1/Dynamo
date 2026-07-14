import SwiftUI

@MainActor
final class CalendarPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "calendar"
    let displayName = "Calendar"
    let systemImage = "calendar"

    @Published private(set) var events: [CalendarEventItem] = []
    @Published private(set) var authState: CalendarAuthState = .notDetermined

    private let provider: CalendarProvider

    init(provider: CalendarProvider? = nil) {
        let resolved = provider ?? EventKitCalendarProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in
            guard let self else { return }
            self.events = self.provider.upcoming
            self.authState = self.provider.authorizationState
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
