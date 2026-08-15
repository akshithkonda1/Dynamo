import AppKit
import CoreLocation
import SwiftUI

/// World Clock — major cities, current location, and IANA time zones.
/// Pure Apple: `Foundation.TimeZone` + optional `CoreLocation` (no WeatherKit).
@MainActor
final class WorldClockPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, WidgetSettingsProviding {
    let id = "world-clock"
    let displayName = "Clocks"
    let systemImage = "globe"
    var expandedContentHeight: CGFloat { 320 }

    @Published var selectedIDs: [String] {
        didSet {
            UserDefaults.standard.set(selectedIDs, forKey: Self.selectedKey)
            objectWillChange.send()
        }
    }

    /// Placename for “Current Location” when Core Location succeeds.
    @Published private(set) var locationPlaceName: String?
    @Published private(set) var locationStatusLine: String = "Using Mac time zone"
    @Published private(set) var locationAuth: CLAuthorizationStatus = .notDetermined

    private static let selectedKey = "dynamo.worldClock.selectedIDs"
    private var timer: Timer?
    private let location = WorldClockLocationResolver()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.selectedKey), !saved.isEmpty {
            selectedIDs = saved
        } else {
            selectedIDs = ["current-location", "new-york", "london", "tokyo"]
        }
        locationAuth = location.authorizationStatus
        location.onUpdate = { [weak self] place, statusLine, auth in
            guard let self else { return }
            self.locationPlaceName = place
            self.locationStatusLine = statusLine
            self.locationAuth = auth
            self.objectWillChange.send()
        }
    }

    func start() {
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        location.refreshIfAuthorized()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func requestCurrentLocation() {
        location.request()
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

    /// Resolved active clocks in selection order.
    var activeEntries: [WorldClockEntry] {
        selectedIDs.compactMap { resolveEntry(id: $0) }
    }

    func resolveEntry(id: String) -> WorldClockEntry? {
        if id == WorldClockEntry.currentLocationID {
            return WorldClockEntry.currentLocation(placeName: locationPlaceName)
        }
        if let city = WorldClockEntry.majorCities.first(where: { $0.id == id }) {
            return city
        }
        if let zone = WorldClockEntry.referenceTimeZones.first(where: { $0.id == id }) {
            return zone
        }
        // Custom tz: id "tz:America/Chicago"
        if id.hasPrefix("tz:") {
            let ident = String(id.dropFirst(3))
            guard TimeZone(identifier: ident) != nil else { return nil }
            return WorldClockEntry(
                id: id,
                name: WorldClockEntry.shortZoneName(ident),
                timeZoneIdentifier: ident,
                kind: .timeZone,
                region: "Time Zone"
            )
        }
        return nil
    }

    func toggleEntry(_ id: String) {
        if let idx = selectedIDs.firstIndex(of: id) {
            if selectedIDs.count > 1 {
                selectedIDs.remove(at: idx)
            }
        } else {
            selectedIDs.append(id)
            if selectedIDs.count > 10 {
                selectedIDs = Array(selectedIDs.suffix(10))
            }
        }
    }

    func isSelected(_ id: String) -> Bool {
        selectedIDs.contains(id)
    }

    /// Reference “here” zone for offsets / converter.
    var referenceTimeZone: TimeZone {
        if isSelected(WorldClockEntry.currentLocationID) {
            return .current
        }
        if let first = activeEntries.first {
            return first.timeZone
        }
        return .current
    }
}

// MARK: - Model

enum WorldClockKind: String {
    case currentLocation
    case majorCity
    case timeZone
}

struct WorldClockEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let timeZoneIdentifier: String
    let kind: WorldClockKind
    let region: String

    static let currentLocationID = "current-location"

    var timeZone: TimeZone {
        if kind == .currentLocation {
            return .current
        }
        return TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    static func currentLocation(placeName: String?) -> WorldClockEntry {
        let label = placeName ?? "Current Location"
        return WorldClockEntry(
            id: currentLocationID,
            name: label,
            timeZoneIdentifier: TimeZone.current.identifier,
            kind: .currentLocation,
            region: "Location"
        )
    }

    /// Short display from IANA id: `America/Los_Angeles` → `Los Angeles`
    static func shortZoneName(_ identifier: String) -> String {
        identifier
            .split(separator: "/")
            .last
            .map { String($0).replacingOccurrences(of: "_", with: " ") }
            ?? identifier
    }

    // MARK: Major cities (Apple IANA zones)

    static let majorCities: [WorldClockEntry] = {
        let rows: [(String, String, String, String)] = [
            // Americas
            ("honolulu", "Honolulu", "Pacific/Honolulu", "Americas"),
            ("anchorage", "Anchorage", "America/Anchorage", "Americas"),
            ("los-angeles", "Los Angeles", "America/Los_Angeles", "Americas"),
            ("vancouver", "Vancouver", "America/Vancouver", "Americas"),
            ("denver", "Denver", "America/Denver", "Americas"),
            ("phoenix", "Phoenix", "America/Phoenix", "Americas"),
            ("chicago", "Chicago", "America/Chicago", "Americas"),
            ("mexico-city", "Mexico City", "America/Mexico_City", "Americas"),
            ("new-york", "New York", "America/New_York", "Americas"),
            ("toronto", "Toronto", "America/Toronto", "Americas"),
            ("miami", "Miami", "America/New_York", "Americas"),
            ("sao-paulo", "São Paulo", "America/Sao_Paulo", "Americas"),
            ("buenos-aires", "Buenos Aires", "America/Argentina/Buenos_Aires", "Americas"),
            // Europe / Africa
            ("london", "London", "Europe/London", "Europe / Africa"),
            ("dublin", "Dublin", "Europe/Dublin", "Europe / Africa"),
            ("lisbon", "Lisbon", "Europe/Lisbon", "Europe / Africa"),
            ("paris", "Paris", "Europe/Paris", "Europe / Africa"),
            ("madrid", "Madrid", "Europe/Madrid", "Europe / Africa"),
            ("amsterdam", "Amsterdam", "Europe/Amsterdam", "Europe / Africa"),
            ("berlin", "Berlin", "Europe/Berlin", "Europe / Africa"),
            ("rome", "Rome", "Europe/Rome", "Europe / Africa"),
            ("zurich", "Zurich", "Europe/Zurich", "Europe / Africa"),
            ("stockholm", "Stockholm", "Europe/Stockholm", "Europe / Africa"),
            ("warsaw", "Warsaw", "Europe/Warsaw", "Europe / Africa"),
            ("athens", "Athens", "Europe/Athens", "Europe / Africa"),
            ("istanbul", "Istanbul", "Europe/Istanbul", "Europe / Africa"),
            ("moscow", "Moscow", "Europe/Moscow", "Europe / Africa"),
            ("cairo", "Cairo", "Africa/Cairo", "Europe / Africa"),
            ("johannesburg", "Johannesburg", "Africa/Johannesburg", "Europe / Africa"),
            ("lagos", "Lagos", "Africa/Lagos", "Europe / Africa"),
            ("nairobi", "Nairobi", "Africa/Nairobi", "Europe / Africa"),
            // Middle East / Asia
            ("dubai", "Dubai", "Asia/Dubai", "Middle East / Asia"),
            ("tel-aviv", "Tel Aviv", "Asia/Jerusalem", "Middle East / Asia"),
            ("riyadh", "Riyadh", "Asia/Riyadh", "Middle East / Asia"),
            ("tehran", "Tehran", "Asia/Tehran", "Middle East / Asia"),
            ("karachi", "Karachi", "Asia/Karachi", "Middle East / Asia"),
            ("mumbai", "Mumbai", "Asia/Kolkata", "Middle East / Asia"),
            ("delhi", "Delhi", "Asia/Kolkata", "Middle East / Asia"),
            ("colombo", "Colombo", "Asia/Colombo", "Middle East / Asia"),
            ("dhaka", "Dhaka", "Asia/Dhaka", "Middle East / Asia"),
            ("bangkok", "Bangkok", "Asia/Bangkok", "Middle East / Asia"),
            ("jakarta", "Jakarta", "Asia/Jakarta", "Middle East / Asia"),
            ("singapore", "Singapore", "Asia/Singapore", "Middle East / Asia"),
            ("hong-kong", "Hong Kong", "Asia/Hong_Kong", "Middle East / Asia"),
            ("shanghai", "Shanghai", "Asia/Shanghai", "Middle East / Asia"),
            ("taipei", "Taipei", "Asia/Taipei", "Middle East / Asia"),
            ("seoul", "Seoul", "Asia/Seoul", "Middle East / Asia"),
            ("tokyo", "Tokyo", "Asia/Tokyo", "Middle East / Asia"),
            // Pacific
            ("perth", "Perth", "Australia/Perth", "Pacific"),
            ("sydney", "Sydney", "Australia/Sydney", "Pacific"),
            ("melbourne", "Melbourne", "Australia/Melbourne", "Pacific"),
            ("brisbane", "Brisbane", "Australia/Brisbane", "Pacific"),
            ("auckland", "Auckland", "Pacific/Auckland", "Pacific"),
            ("fiji", "Fiji", "Pacific/Fiji", "Pacific")
        ]
        return rows.map {
            WorldClockEntry(id: $0.0, name: $0.1, timeZoneIdentifier: $0.2, kind: .majorCity, region: $0.3)
        }
    }()

    /// Curated IANA reference zones (offsets + hubs Apple ships in the TZ database).
    static let referenceTimeZones: [WorldClockEntry] = {
        let ids = [
            "UTC",
            "GMT",
            "Pacific/Honolulu",
            "America/Anchorage",
            "America/Los_Angeles",
            "America/Denver",
            "America/Chicago",
            "America/New_York",
            "America/Sao_Paulo",
            "Atlantic/Reykjavik",
            "Europe/London",
            "Europe/Paris",
            "Europe/Berlin",
            "Europe/Moscow",
            "Africa/Cairo",
            "Asia/Dubai",
            "Asia/Kolkata",
            "Asia/Bangkok",
            "Asia/Shanghai",
            "Asia/Tokyo",
            "Australia/Sydney",
            "Pacific/Auckland"
        ]
        return ids.compactMap { ident -> WorldClockEntry? in
            guard TimeZone(identifier: ident) != nil else { return nil }
            let name: String
            if ident == "UTC" || ident == "GMT" {
                name = ident
            } else {
                name = shortZoneName(ident)
            }
            return WorldClockEntry(
                id: "tz:\(ident)",
                name: name,
                timeZoneIdentifier: ident,
                kind: .timeZone,
                region: "Time Zones"
            )
        }
    }()
}

// MARK: - Location (Core Location)

@MainActor
private final class WorldClockLocationResolver: NSObject, CLLocationManagerDelegate {
    var onUpdate: ((String?, String, CLAuthorizationStatus) -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onUpdate?(nil, "Location denied — using Mac time zone (\(TimeZone.current.identifier))", manager.authorizationStatus)
        default:
            // authorized / authorizedAlways / authorizedWhenInUse (and future cases)
            if isAuthorized(manager.authorizationStatus) {
                manager.requestLocation()
            } else {
                onUpdate?(nil, "Using Mac time zone (\(TimeZone.current.identifier))", manager.authorizationStatus)
            }
        }
    }

    func refreshIfAuthorized() {
        let status = manager.authorizationStatus
        if isAuthorized(status) {
            manager.requestLocation()
        } else {
            onUpdate?(
                nil,
                "Using Mac time zone (\(TimeZone.current.identifier))",
                status
            )
        }
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if self.isAuthorized(status) {
                manager.requestLocation()
            } else if status == .denied || status == .restricted {
                self.onUpdate?(nil, "Location denied — using Mac time zone", status)
            } else if status == .notDetermined {
                self.onUpdate?(nil, "Location not requested yet", status)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.reverseGeocode(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.onUpdate?(
                nil,
                "Location unavailable — Mac TZ \(TimeZone.current.identifier)",
                manager.authorizationStatus
            )
        }
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self else { return }
                let mark = placemarks?.first
                let city = mark?.locality ?? mark?.subAdministrativeArea ?? mark?.administrativeArea
                let place = city ?? mark?.name
                let tz = TimeZone.current.identifier
                if let place {
                    self.onUpdate?(place, "\(place) · \(tz)", self.manager.authorizationStatus)
                } else {
                    self.onUpdate?(nil, "Mac time zone · \(tz)", self.manager.authorizationStatus)
                }
            }
        }
    }
}

// MARK: - Formatting & helpers

private enum WorldClockFormat {
    static func timeString(date: Date, timeZone: TimeZone, withSeconds: Bool = false) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = .current
        f.dateFormat = withSeconds ? "h:mm:ss" : "h:mm"
        return f.string(from: date)
    }

    static func periodString(date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = .current
        f.dateFormat = "a"
        return f.string(from: date)
    }

    static func abbreviation(date: Date, timeZone: TimeZone) -> String {
        timeZone.abbreviation(for: date) ?? timeZone.identifier
    }

    static func dayHint(date: Date, timeZone: TimeZone, reference: TimeZone = .current) -> String {
        var refCal = Calendar.current
        refCal.timeZone = reference
        var tzCal = Calendar.current
        tzCal.timeZone = timeZone
        let a = refCal.dateComponents([.year, .month, .day], from: date)
        let b = tzCal.dateComponents([.year, .month, .day], from: date)
        let ra = (a.year ?? 0) * 400 + (a.month ?? 0) * 32 + (a.day ?? 0)
        let rb = (b.year ?? 0) * 400 + (b.month ?? 0) * 32 + (b.day ?? 0)
        let d = rb - ra
        if d == 0 { return "Today" }
        if d == 1 { return "Tomorrow" }
        if d == -1 { return "Yesterday" }
        return d > 0 ? "+\(d)d" : "\(d)d"
    }

    static func offsetLabel(from reference: TimeZone, to target: TimeZone, date: Date = Date()) -> String {
        let seconds = target.secondsFromGMT(for: date) - reference.secondsFromGMT(for: date)
        if seconds == 0 { return "same time" }
        let hours = Double(seconds) / 3600.0
        if hours == hours.rounded() {
            return String(format: "%+.0fh", hours)
        }
        return String(format: "%+.1fh", hours)
    }

    static func gmtOffsetLabel(timeZone: TimeZone, date: Date = Date()) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let hours = Double(seconds) / 3600.0
        if hours == hours.rounded() {
            return String(format: "GMT%+.0f", hours)
        }
        return String(format: "GMT%+.1f", hours)
    }

    static func isDST(timeZone: TimeZone, date: Date = Date()) -> Bool {
        timeZone.isDaylightSavingTime(for: date)
    }

    static func nextDSTHint(timeZone: TimeZone, date: Date = Date()) -> String? {
        guard let next = timeZone.nextDaylightSavingTimeTransition(after: date) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: next).day ?? 0
        if days < 0 || days > 120 { return nil }
        let on = timeZone.isDaylightSavingTime(for: next.addingTimeInterval(3600))
        return on ? "DST in \(days)d" : "Std in \(days)d"
    }

    /// Hour 0–23 in the given zone.
    static func hour(date: Date, timeZone: TimeZone) -> Int {
        var cal = Calendar.current
        cal.timeZone = timeZone
        return cal.component(.hour, from: date)
    }

    /// Rough “good time to call” for business-ish hours 9–21 local.
    static func callWindow(date: Date, timeZone: TimeZone) -> (label: String, good: Bool) {
        let h = hour(date: date, timeZone: timeZone)
        switch h {
        case 9..<12: return ("Morning", true)
        case 12..<17: return ("Day", true)
        case 17..<21: return ("Evening", true)
        case 21..<24, 0..<7: return ("Night", false)
        default: return ("Early", false)
        }
    }

    static func convert(localHour: Int, localMinute: Int, from: TimeZone, to: TimeZone, on date: Date = Date()) -> Date {
        var fromCal = Calendar.current
        fromCal.timeZone = from
        var comps = fromCal.dateComponents([.year, .month, .day], from: date)
        comps.hour = localHour
        comps.minute = localMinute
        comps.second = 0
        let absolute = fromCal.date(from: comps) ?? date
        return absolute
    }
}

// MARK: - Ambient

private struct AmbientWorldClockView: View {
    @ObservedObject var plugin: WorldClockPlugin

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let entries = Array(plugin.activeEntries.prefix(3))
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.calmGlow)
                ForEach(entries) { entry in
                    HStack(spacing: 3) {
                        Text(ambientLabel(entry))
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                        Text(WorldClockFormat.timeString(date: context.date, timeZone: entry.timeZone))
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

    private func ambientLabel(_ entry: WorldClockEntry) -> String {
        switch entry.kind {
        case .currentLocation: return "Here"
        case .timeZone:
            if entry.timeZoneIdentifier == "UTC" || entry.timeZoneIdentifier == "GMT" {
                return entry.timeZoneIdentifier
            }
            return String(entry.name.prefix(3))
        case .majorCity:
            return String(entry.name.prefix(3))
        }
    }
}

// MARK: - Expanded

private struct ExpandedWorldClockView: View {
    @ObservedObject var plugin: WorldClockPlugin
    @State private var convertHour: Int = {
        Calendar.current.component(.hour, from: Date())
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            NotchSectionHeader("World Clock")

            TimelineView(.periodic(from: .now, by: 15)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plugin.activeEntries) { entry in
                            cityRow(entry, at: context.date)
                        }

                        converterCard(at: context.date)
                    }
                }
            }

            Text("Major cities · current location · Apple time zones · offline")
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textQuaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cityRow(_ entry: WorldClockEntry, at date: Date) -> some View {
        let tz = entry.timeZone
        let ref = plugin.referenceTimeZone
        let window = WorldClockFormat.callWindow(date: date, timeZone: tz)
        let dst = WorldClockFormat.isDST(timeZone: tz, date: date)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon(for: entry))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.calmGlow)
                    Text(entry.name)
                        .font(NotchTheme.body.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    if entry.kind == .currentLocation {
                        Text("HERE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(NotchTheme.calmGlow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(NotchTheme.calmGlow.opacity(0.15)))
                    }
                }
                HStack(spacing: 6) {
                    Text(WorldClockFormat.abbreviation(date: date, timeZone: tz))
                        .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text("·")
                        .foregroundStyle(NotchTheme.textQuaternary)
                    Text(WorldClockFormat.gmtOffsetLabel(timeZone: tz, date: date))
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("·")
                        .foregroundStyle(NotchTheme.textQuaternary)
                    Text(WorldClockFormat.dayHint(date: date, timeZone: tz, reference: ref))
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                    if entry.kind != .currentLocation {
                        Text("·")
                            .foregroundStyle(NotchTheme.textQuaternary)
                        Text(WorldClockFormat.offsetLabel(from: ref, to: tz, date: date))
                            .font(NotchTheme.micro.monospacedDigit())
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    if dst {
                        Text("DST")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.orange.opacity(0.9))
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(window.good ? Color.green.opacity(0.85) : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(window.label)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                    if let dstHint = WorldClockFormat.nextDSTHint(timeZone: tz, date: date) {
                        Text("· \(dstHint)")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(WorldClockFormat.timeString(date: date, timeZone: tz))
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(NotchTheme.textPrimary)
                    Text(WorldClockFormat.periodString(date: date, timeZone: tz))
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                Button {
                    copyTime(entry, at: date)
                } label: {
                    Text("Copy")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NotchTheme.cardFill)
        )
        .contextMenu {
            Button("Copy time") { copyTime(entry, at: date) }
            if entry.kind == .currentLocation {
                Button("Refresh location") { plugin.requestCurrentLocation() }
            }
        }
    }

    private func converterCard(at date: Date) -> some View {
        let from = plugin.referenceTimeZone
        let targets = plugin.activeEntries.filter { $0.timeZone.identifier != from.identifier || $0.kind == .currentLocation }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Convert from here")
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textSecondary)

            HStack(spacing: 8) {
                Text("When it’s")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                Picker("Hour", selection: $convertHour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(hourLabel(h)).tag(h)
                    }
                }
                .labelsHidden()
                .frame(width: 88)
                Text("here")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                Spacer(minLength: 0)
            }

            ForEach(targets.prefix(6)) { entry in
                let instant = WorldClockFormat.convert(
                    localHour: convertHour,
                    localMinute: 0,
                    from: from,
                    to: entry.timeZone,
                    on: date
                )
                HStack {
                    Text(entry.name)
                        .font(NotchTheme.micro.weight(.medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(WorldClockFormat.timeString(date: instant, timeZone: entry.timeZone))
                        .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NotchTheme.textPrimary)
                    Text(WorldClockFormat.periodString(date: instant, timeZone: entry.timeZone))
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text(WorldClockFormat.abbreviation(date: instant, timeZone: entry.timeZone))
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NotchTheme.cardFill.opacity(0.85))
        )
    }

    private func hourLabel(_ h: Int) -> String {
        let period = h < 12 ? "AM" : "PM"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(period)"
    }

    private func icon(for entry: WorldClockEntry) -> String {
        switch entry.kind {
        case .currentLocation: return "location.fill"
        case .majorCity: return "building.2.fill"
        case .timeZone: return "clock.fill"
        }
    }

    private func copyTime(_ entry: WorldClockEntry, at date: Date) {
        let tz = entry.timeZone
        let text = "\(entry.name) \(WorldClockFormat.timeString(date: date, timeZone: tz)) \(WorldClockFormat.periodString(date: date, timeZone: tz)) (\(WorldClockFormat.abbreviation(date: date, timeZone: tz)), \(WorldClockFormat.gmtOffsetLabel(timeZone: tz, date: date)))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Settings

private struct WorldClockSettingsView: View {
    @ObservedObject var plugin: WorldClockPlugin
    @State private var cityFilter = ""
    @State private var zoneFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick up to 10 clocks. References: current location, major cities, and Apple time zones.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Current location
            VStack(alignment: .leading, spacing: 6) {
                Text("Current Location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Toggle(isOn: Binding(
                    get: { plugin.isSelected(WorldClockEntry.currentLocationID) },
                    set: { _ in plugin.toggleEntry(WorldClockEntry.currentLocationID) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Here · Mac time zone")
                        Text(plugin.locationStatusLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("Use Current Location") {
                        plugin.requestCurrentLocation()
                        if !plugin.isSelected(WorldClockEntry.currentLocationID) {
                            plugin.toggleEntry(WorldClockEntry.currentLocationID)
                        }
                    }
                    .controlSize(.small)
                    Text(authLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Major cities
            VStack(alignment: .leading, spacing: 6) {
                Text("Major Cities")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Filter cities", text: $cityFilter)
                    .textFieldStyle(.roundedBorder)
                ForEach(filteredCities) { city in
                    Toggle(isOn: Binding(
                        get: { plugin.isSelected(city.id) },
                        set: { _ in plugin.toggleEntry(city.id) }
                    )) {
                        HStack {
                            Text(city.name)
                            Spacer(minLength: 4)
                            Text(city.timeZoneIdentifier)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Divider()

            // Time zones
            VStack(alignment: .leading, spacing: 6) {
                Text("Time Zones (Apple IANA)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Filter zones (e.g. Tokyo, UTC, America)", text: $zoneFilter)
                    .textFieldStyle(.roundedBorder)
                ForEach(filteredZones) { zone in
                    Toggle(isOn: Binding(
                        get: { plugin.isSelected(zone.id) },
                        set: { _ in plugin.toggleEntry(zone.id) }
                    )) {
                        HStack {
                            Text(zone.name)
                            Spacer(minLength: 4)
                            Text(zone.timeZoneIdentifier)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if !zoneFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Live search of full system TZ database
                    ForEach(searchSystemZones.prefix(20), id: \.self) { ident in
                        let entryID = "tz:\(ident)"
                        Toggle(isOn: Binding(
                            get: { plugin.isSelected(entryID) },
                            set: { _ in plugin.toggleEntry(entryID) }
                        )) {
                            HStack {
                                Text(WorldClockEntry.shortZoneName(ident))
                                Spacer(minLength: 4)
                                Text(ident)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Text("\(plugin.selectedIDs.count)/10 selected")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var filteredCities: [WorldClockEntry] {
        let q = cityFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return WorldClockEntry.majorCities }
        return WorldClockEntry.majorCities.filter {
            $0.name.lowercased().contains(q) || $0.timeZoneIdentifier.lowercased().contains(q) || $0.region.lowercased().contains(q)
        }
    }

    private var filteredZones: [WorldClockEntry] {
        let q = zoneFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return WorldClockEntry.referenceTimeZones }
        return WorldClockEntry.referenceTimeZones.filter {
            $0.name.lowercased().contains(q) || $0.timeZoneIdentifier.lowercased().contains(q)
        }
    }

    private var searchSystemZones: [String] {
        let q = zoneFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let curated = Set(WorldClockEntry.referenceTimeZones.map(\.timeZoneIdentifier))
        return TimeZone.knownTimeZoneIdentifiers
            .filter { !$0.isEmpty && ($0.lowercased().contains(q) || WorldClockEntry.shortZoneName($0).lowercased().contains(q)) }
            .filter { !curated.contains($0) }
            .sorted()
    }

    private var authLabel: String {
        switch plugin.locationAuth {
        case .denied, .restricted: return "Denied in System Settings"
        case .notDetermined: return "Not asked yet"
        case .authorized, .authorizedAlways, .authorizedWhenInUse: return "Authorized"
        @unknown default: return "Authorized"
        }
    }
}
