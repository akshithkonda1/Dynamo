import AppKit
import SwiftUI

/// Free multi-city world clock — production-safe Weather replacement (no APIs, no WeatherKit).
@MainActor
final class WorldClockPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, WidgetSettingsProviding {
    let id = "world-clock"
    let displayName = "Clocks"
    let systemImage = "globe"
    var expandedContentHeight: CGFloat { 268 }

    @Published private(set) var cities: [WorldClockCity] = WorldClockCity.defaults
    @Published var selectedIDs: [String] {
        didSet {
            UserDefaults.standard.set(selectedIDs, forKey: Self.selectedKey)
            objectWillChange.send()
        }
    }

    private static let selectedKey = "dynamo.worldClock.selectedIDs"
    private var timer: Timer?

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.selectedKey), !saved.isEmpty {
            selectedIDs = saved
        } else {
            selectedIDs = ["local", "new-york", "london", "tokyo"]
        }
    }

    func start() {
        // 15s is enough for minute-accurate clocks without waste.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedWorldClockView(plugin: self))
    }

    var isAmbientActive: Bool { true }
    var ambientPriority: Int { 15 }

    func ambientView() -> AnyView {
        AnyView(AmbientWorldClockView(plugin: self))
    }

    func settingsView() -> AnyView {
        AnyView(WorldClockSettingsView(plugin: self))
    }

    var activeCities: [WorldClockCity] {
        let map = Dictionary(uniqueKeysWithValues: WorldClockCity.catalog.map { ($0.id, $0) })
        return selectedIDs.compactMap { map[$0] }
    }

    func toggleCity(_ id: String) {
        if let idx = selectedIDs.firstIndex(of: id) {
            // Keep at least one city.
            if selectedIDs.count > 1 {
                selectedIDs.remove(at: idx)
            }
        } else {
            selectedIDs.append(id)
            if selectedIDs.count > 8 {
                selectedIDs = Array(selectedIDs.suffix(8))
            }
        }
    }
}

// MARK: - Model

struct WorldClockCity: Identifiable, Equatable {
    let id: String
    let name: String
    let timeZoneIdentifier: String

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    static var local: WorldClockCity {
        WorldClockCity(
            id: "local",
            name: "Local",
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }

    static let catalog: [WorldClockCity] = {
        var list: [WorldClockCity] = [.local]
        let cities: [(String, String, String)] = [
            ("new-york", "New York", "America/New_York"),
            ("los-angeles", "Los Angeles", "America/Los_Angeles"),
            ("chicago", "Chicago", "America/Chicago"),
            ("london", "London", "Europe/London"),
            ("paris", "Paris", "Europe/Paris"),
            ("berlin", "Berlin", "Europe/Berlin"),
            ("dubai", "Dubai", "Asia/Dubai"),
            ("mumbai", "Mumbai", "Asia/Kolkata"),
            ("singapore", "Singapore", "Asia/Singapore"),
            ("tokyo", "Tokyo", "Asia/Tokyo"),
            ("sydney", "Sydney", "Australia/Sydney"),
            ("auckland", "Auckland", "Pacific/Auckland")
        ]
        list.append(contentsOf: cities.map {
            WorldClockCity(id: $0.0, name: $0.1, timeZoneIdentifier: $0.2)
        })
        return list
    }()

    static var defaults: [WorldClockCity] { Array(catalog.prefix(4)) }
}

// MARK: - Formatting

private enum WorldClockFormat {
    static func timeString(date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }

    static func periodString(date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "a"
        return f.string(from: date)
    }

    static func dayHint(date: Date, timeZone: TimeZone) -> String {
        let cal = Calendar.current
        let localDay = cal.startOfDay(for: date)
        var tzCal = Calendar.current
        tzCal.timeZone = timeZone
        let cityDay = tzCal.startOfDay(for: date)
        let diff = tzCal.dateComponents([.day], from: localDay, to: cityDay).day ?? 0
        if diff == 0 { return "Today" }
        if diff == 1 { return "Tomorrow" }
        if diff == -1 { return "Yesterday" }
        return diff > 0 ? "+\(diff)d" : "\(diff)d"
    }

    static func offsetLabel(timeZone: TimeZone, date: Date = Date()) -> String {
        let seconds = timeZone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        if seconds == 0 { return "±0h" }
        let hours = Double(seconds) / 3600.0
        if hours == hours.rounded() {
            return String(format: "%+.0fh", hours)
        }
        return String(format: "%+.1fh", hours)
    }
}

// MARK: - Ambient

private struct AmbientWorldClockView: View {
    @ObservedObject var plugin: WorldClockPlugin

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let cities = Array(plugin.activeCities.prefix(3))
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.calmGlow)
                ForEach(cities) { city in
                    HStack(spacing: 3) {
                        Text(city.id == "local" ? "Here" : String(city.name.prefix(3)))
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                        Text(WorldClockFormat.timeString(date: context.date, timeZone: city.timeZone))
                            .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textPrimary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NotchTheme.ambientInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Expanded

private struct ExpandedWorldClockView: View {
    @ObservedObject var plugin: WorldClockPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            NotchSectionHeader("World Clock")

            TimelineView(.periodic(from: .now, by: 15)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plugin.activeCities) { city in
                            cityRow(city, at: context.date)
                        }
                    }
                }
            }

            Text("Free · no network · Time Zone database on this Mac")
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textQuaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cityRow(_ city: WorldClockCity, at date: Date) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(city.name)
                    .font(NotchTheme.body.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                Text("\(WorldClockFormat.dayHint(date: date, timeZone: city.timeZone)) · \(WorldClockFormat.offsetLabel(timeZone: city.timeZone, date: date))")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(WorldClockFormat.timeString(date: date, timeZone: city.timeZone))
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(WorldClockFormat.periodString(date: date, timeZone: city.timeZone))
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NotchTheme.cardFill)
        )
    }
}

// MARK: - Settings

private struct WorldClockSettingsView: View {
    @ObservedObject var plugin: WorldClockPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cities (up to 8)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(WorldClockCity.catalog) { city in
                Toggle(isOn: Binding(
                    get: { plugin.selectedIDs.contains(city.id) },
                    set: { _ in plugin.toggleCity(city.id) }
                )) {
                    Text(city.name)
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}
