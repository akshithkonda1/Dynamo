import AppKit
import CoreLocation
import SwiftUI

/// How selected clocks are ordered in ambient + expanded lists.
enum WorldClockSortMode: String, CaseIterable, Identifiable {
    case selection
    case nearest
    case farthest
    case random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: return "As picked"
        case .nearest: return "Nearest first"
        case .farthest: return "Farthest first"
        case .random: return "Random"
        }
    }

    var systemImage: String {
        switch self {
        case .selection: return "list.number"
        case .nearest: return "location.north.line"
        case .farthest: return "location.north.line.fill"
        case .random: return "shuffle"
        }
    }
}

/// World Clock — major cities, current location, and IANA time zones.
/// Pure Apple: `Foundation.TimeZone` + optional `CoreLocation` (no WeatherKit).
@MainActor
final class WorldClockPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, WidgetSettingsProviding {
    let id = "world-clock"
    let displayName = "Clocks"
    let systemImage = "globe"
    var expandedContentHeight: CGFloat { 280 }

    @Published var selectedIDs: [String] {
        didSet {
            UserDefaults.standard.set(selectedIDs, forKey: Self.selectedKey)
            objectWillChange.send()
        }
    }

    @Published var sortMode: WorldClockSortMode {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: Self.sortKey)
            if sortMode == .random, randomSeed == 0 {
                reshuffle()
            }
            objectWillChange.send()
        }
    }

    /// Seed for stable random order until reshuffled.
    @Published private(set) var randomSeed: UInt64 {
        didSet { UserDefaults.standard.set(String(randomSeed), forKey: Self.randomSeedKey) }
    }

    /// Test / deterministic shuffle support — not exposed in the UI.
    func setRandomSeedForTesting(_ seed: UInt64) {
        randomSeed = seed == 0 ? 1 : seed
    }

    /// Placename for “Current Location” when Core Location succeeds.
    @Published private(set) var locationPlaceName: String?
    @Published private(set) var locationStatusLine: String = "Using Mac time zone"
    @Published private(set) var locationAuth: CLAuthorizationStatus = .notDetermined
    /// GPS / last fix used as origin for distance sort.
    @Published private(set) var referenceCoordinate: CLLocationCoordinate2D?

    private static let selectedKey = "dynamo.worldClock.selectedIDs"
    private static let sortKey = "dynamo.worldClock.sortMode"
    private static let randomSeedKey = "dynamo.worldClock.randomSeed"
    private var timer: Timer?
    private let location = WorldClockLocationResolver()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.selectedKey), !saved.isEmpty {
            selectedIDs = saved
        } else {
            selectedIDs = ["current-location", "new-york", "london", "tokyo"]
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sortKey),
           let mode = WorldClockSortMode(rawValue: raw) {
            sortMode = mode
        } else {
            sortMode = .nearest
        }
        if let seedStr = UserDefaults.standard.string(forKey: Self.randomSeedKey),
           let seed = UInt64(seedStr) {
            randomSeed = seed
        } else {
            randomSeed = UInt64.random(in: 1...UInt64.max)
        }
        locationAuth = location.authorizationStatus
        location.onUpdate = { [weak self] place, statusLine, auth, coordinate in
            guard let self else { return }
            self.locationPlaceName = place
            self.locationStatusLine = statusLine
            self.locationAuth = auth
            if let coordinate {
                self.referenceCoordinate = coordinate
            }
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

    func reshuffle() {
        randomSeed = UInt64.random(in: 1...UInt64.max)
        sortMode = .random
        objectWillChange.send()
    }

    func cycleSortMode() {
        let all = WorldClockSortMode.allCases
        guard let idx = all.firstIndex(of: sortMode) else {
            sortMode = .nearest
            return
        }
        sortMode = all[(idx + 1) % all.count]
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

    /// Resolved active clocks: **current location (“Here”) always first**, then the
    /// rest in the designated order (distance / reverse / random / pick order).
    var activeEntries: [WorldClockEntry] {
        let base = selectedIDs.compactMap { resolveEntry(id: $0) }
        return sortedEntries(base)
    }

    func sortedEntries(_ entries: [WorldClockEntry]) -> [WorldClockEntry] {
        // Pin “Here” to the top whenever present; sort everyone else by mode.
        let here = entries.filter { $0.kind == .currentLocation }
        let rest = entries.filter { $0.kind != .currentLocation }
        let orderedRest: [WorldClockEntry]
        switch sortMode {
        case .selection:
            // Preserve selection-list order for non-Here clocks.
            orderedRest = rest
        case .nearest:
            orderedRest = rest.sorted { distanceKm(for: $0) < distanceKm(for: $1) }
        case .farthest:
            orderedRest = rest.sorted { distanceKm(for: $0) > distanceKm(for: $1) }
        case .random:
            // Stable shuffle keyed by seed + id.
            orderedRest = rest.sorted { a, b in
                shuffleKey(a.id) < shuffleKey(b.id)
            }
        }
        return here + orderedRest
    }

    /// Kilometers from reference location (0 for “Here”).
    func distanceKm(for entry: WorldClockEntry) -> Double {
        if entry.kind == .currentLocation { return 0 }
        guard let origin = distanceOrigin,
              let lat = entry.latitude, let lon = entry.longitude
        else {
            // Unknown coords — pin to end of nearest list.
            return 50_000
        }
        let from = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let to = CLLocation(latitude: lat, longitude: lon)
        return from.distance(from: to) / 1000.0
    }

    func distanceLabel(for entry: WorldClockEntry) -> String? {
        guard sortMode == .nearest || sortMode == .farthest else { return nil }
        if entry.kind == .currentLocation {
            return MeasurementUnitsStore.shared.system == .metric ? "0 km" : "0 mi"
        }
        let km = distanceKm(for: entry)
        if km >= 49_000 { return nil }
        return MeasurementUnitsStore.shared.formatDistance(kilometers: km)
    }

    /// Origin for distance: live GPS if available, else first selected city with coords.
    private var distanceOrigin: CLLocationCoordinate2D? {
        if let referenceCoordinate { return referenceCoordinate }
        // Prefer a non-here city with coords as origin fallback when GPS off.
        for id in selectedIDs {
            if id == WorldClockEntry.currentLocationID { continue }
            if let e = resolveEntry(id: id), let lat = e.latitude, let lon = e.longitude {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return nil
    }

    private func shuffleKey(_ id: String) -> UInt64 {
        // FNV-1a style mix of seed + id bytes for stable random order.
        var hash: UInt64 = randomSeed ^ 0xcbf29ce484222325
        for b in id.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    func resolveEntry(id: String) -> WorldClockEntry? {
        if id == WorldClockEntry.currentLocationID {
            return WorldClockEntry.currentLocation(
                placeName: locationPlaceName,
                coordinate: referenceCoordinate
            )
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
            let coord = WorldClockEntry.coordinate(forTimeZone: ident)
            return WorldClockEntry(
                id: id,
                name: WorldClockEntry.shortZoneName(ident),
                timeZoneIdentifier: ident,
                kind: .timeZone,
                region: "Time Zone",
                latitude: coord?.lat,
                longitude: coord?.lon
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
    /// Approximate WGS84 for distance sort (nil = unknown).
    let latitude: Double?
    let longitude: Double?

    static let currentLocationID = "current-location"

    var timeZone: TimeZone {
        if kind == .currentLocation {
            return .current
        }
        return TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    static func currentLocation(placeName: String?, coordinate: CLLocationCoordinate2D?) -> WorldClockEntry {
        let label = placeName ?? "Current Location"
        return WorldClockEntry(
            id: currentLocationID,
            name: label,
            timeZoneIdentifier: TimeZone.current.identifier,
            kind: .currentLocation,
            region: "Location",
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
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

    static func coordinate(forTimeZone ident: String) -> (lat: Double, lon: Double)? {
        timeZoneCoordinates[ident]
    }

    // MARK: Major cities (Apple IANA zones + lat/lon for distance)

    static let majorCities: [WorldClockEntry] = {
        // id, name, tz, region, lat, lon
        let rows: [(String, String, String, String, Double, Double)] = [
            ("honolulu", "Honolulu", "Pacific/Honolulu", "Americas", 21.3069, -157.8583),
            ("anchorage", "Anchorage", "America/Anchorage", "Americas", 61.2181, -149.9003),
            ("los-angeles", "Los Angeles", "America/Los_Angeles", "Americas", 34.0522, -118.2437),
            ("vancouver", "Vancouver", "America/Vancouver", "Americas", 49.2827, -123.1207),
            ("denver", "Denver", "America/Denver", "Americas", 39.7392, -104.9903),
            ("phoenix", "Phoenix", "America/Phoenix", "Americas", 33.4484, -112.0740),
            ("chicago", "Chicago", "America/Chicago", "Americas", 41.8781, -87.6298),
            ("mexico-city", "Mexico City", "America/Mexico_City", "Americas", 19.4326, -99.1332),
            ("new-york", "New York", "America/New_York", "Americas", 40.7128, -74.0060),
            ("toronto", "Toronto", "America/Toronto", "Americas", 43.6532, -79.3832),
            ("miami", "Miami", "America/New_York", "Americas", 25.7617, -80.1918),
            ("sao-paulo", "São Paulo", "America/Sao_Paulo", "Americas", -23.5505, -46.6333),
            ("buenos-aires", "Buenos Aires", "America/Argentina/Buenos_Aires", "Americas", -34.6037, -58.3816),
            ("london", "London", "Europe/London", "Europe / Africa", 51.5074, -0.1278),
            ("dublin", "Dublin", "Europe/Dublin", "Europe / Africa", 53.3498, -6.2603),
            ("lisbon", "Lisbon", "Europe/Lisbon", "Europe / Africa", 38.7223, -9.1393),
            ("paris", "Paris", "Europe/Paris", "Europe / Africa", 48.8566, 2.3522),
            ("madrid", "Madrid", "Europe/Madrid", "Europe / Africa", 40.4168, -3.7038),
            ("amsterdam", "Amsterdam", "Europe/Amsterdam", "Europe / Africa", 52.3676, 4.9041),
            ("berlin", "Berlin", "Europe/Berlin", "Europe / Africa", 52.5200, 13.4050),
            ("rome", "Rome", "Europe/Rome", "Europe / Africa", 41.9028, 12.4964),
            ("zurich", "Zurich", "Europe/Zurich", "Europe / Africa", 47.3769, 8.5417),
            ("stockholm", "Stockholm", "Europe/Stockholm", "Europe / Africa", 59.3293, 18.0686),
            ("warsaw", "Warsaw", "Europe/Warsaw", "Europe / Africa", 52.2297, 21.0122),
            ("athens", "Athens", "Europe/Athens", "Europe / Africa", 37.9838, 23.7275),
            ("istanbul", "Istanbul", "Europe/Istanbul", "Europe / Africa", 41.0082, 28.9784),
            ("moscow", "Moscow", "Europe/Moscow", "Europe / Africa", 55.7558, 37.6173),
            ("cairo", "Cairo", "Africa/Cairo", "Europe / Africa", 30.0444, 31.2357),
            ("johannesburg", "Johannesburg", "Africa/Johannesburg", "Europe / Africa", -26.2041, 28.0473),
            ("lagos", "Lagos", "Africa/Lagos", "Europe / Africa", 6.5244, 3.3792),
            ("nairobi", "Nairobi", "Africa/Nairobi", "Europe / Africa", -1.2921, 36.8219),
            ("dubai", "Dubai", "Asia/Dubai", "Middle East / Asia", 25.2048, 55.2708),
            ("tel-aviv", "Tel Aviv", "Asia/Jerusalem", "Middle East / Asia", 32.0853, 34.7818),
            ("riyadh", "Riyadh", "Asia/Riyadh", "Middle East / Asia", 24.7136, 46.6753),
            ("tehran", "Tehran", "Asia/Tehran", "Middle East / Asia", 35.6892, 51.3890),
            ("karachi", "Karachi", "Asia/Karachi", "Middle East / Asia", 24.8607, 67.0011),
            ("mumbai", "Mumbai", "Asia/Kolkata", "Middle East / Asia", 19.0760, 72.8777),
            ("delhi", "Delhi", "Asia/Kolkata", "Middle East / Asia", 28.6139, 77.2090),
            ("colombo", "Colombo", "Asia/Colombo", "Middle East / Asia", 6.9271, 79.8612),
            ("dhaka", "Dhaka", "Asia/Dhaka", "Middle East / Asia", 23.8103, 90.4125),
            ("bangkok", "Bangkok", "Asia/Bangkok", "Middle East / Asia", 13.7563, 100.5018),
            ("jakarta", "Jakarta", "Asia/Jakarta", "Middle East / Asia", -6.2088, 106.8456),
            ("singapore", "Singapore", "Asia/Singapore", "Middle East / Asia", 1.3521, 103.8198),
            ("hong-kong", "Hong Kong", "Asia/Hong_Kong", "Middle East / Asia", 22.3193, 114.1694),
            ("shanghai", "Shanghai", "Asia/Shanghai", "Middle East / Asia", 31.2304, 121.4737),
            ("taipei", "Taipei", "Asia/Taipei", "Middle East / Asia", 25.0330, 121.5654),
            ("seoul", "Seoul", "Asia/Seoul", "Middle East / Asia", 37.5665, 126.9780),
            ("tokyo", "Tokyo", "Asia/Tokyo", "Middle East / Asia", 35.6762, 139.6503),
            ("perth", "Perth", "Australia/Perth", "Pacific", -31.9505, 115.8605),
            ("sydney", "Sydney", "Australia/Sydney", "Pacific", -33.8688, 151.2093),
            ("melbourne", "Melbourne", "Australia/Melbourne", "Pacific", -37.8136, 144.9631),
            ("brisbane", "Brisbane", "Australia/Brisbane", "Pacific", -27.4698, 153.0251),
            ("auckland", "Auckland", "Pacific/Auckland", "Pacific", -36.8485, 174.7633),
            ("fiji", "Fiji", "Pacific/Fiji", "Pacific", -18.1416, 178.4419)
        ]
        return rows.map {
            WorldClockEntry(
                id: $0.0, name: $0.1, timeZoneIdentifier: $0.2, kind: .majorCity, region: $0.3,
                latitude: $0.4, longitude: $0.5
            )
        }
    }()

    /// Representative coordinates for IANA zones (hub city).
    private static let timeZoneCoordinates: [String: (lat: Double, lon: Double)] = [
        "UTC": (0, 0),
        "GMT": (51.5074, -0.1278),
        "Pacific/Honolulu": (21.3069, -157.8583),
        "America/Anchorage": (61.2181, -149.9003),
        "America/Los_Angeles": (34.0522, -118.2437),
        "America/Denver": (39.7392, -104.9903),
        "America/Chicago": (41.8781, -87.6298),
        "America/New_York": (40.7128, -74.0060),
        "America/Sao_Paulo": (-23.5505, -46.6333),
        "Atlantic/Reykjavik": (64.1466, -21.9426),
        "Europe/London": (51.5074, -0.1278),
        "Europe/Paris": (48.8566, 2.3522),
        "Europe/Berlin": (52.5200, 13.4050),
        "Europe/Moscow": (55.7558, 37.6173),
        "Africa/Cairo": (30.0444, 31.2357),
        "Asia/Dubai": (25.2048, 55.2708),
        "Asia/Kolkata": (28.6139, 77.2090),
        "Asia/Bangkok": (13.7563, 100.5018),
        "Asia/Shanghai": (31.2304, 121.4737),
        "Asia/Tokyo": (35.6762, 139.6503),
        "Australia/Sydney": (-33.8688, 151.2093),
        "Pacific/Auckland": (-36.8485, 174.7633)
    ]

    /// Curated IANA reference zones (offsets + hubs Apple ships in the TZ database).
    static let referenceTimeZones: [WorldClockEntry] = {
        let ids = Array(timeZoneCoordinates.keys).sorted()
        return ids.compactMap { ident -> WorldClockEntry? in
            guard TimeZone(identifier: ident) != nil else { return nil }
            let name = (ident == "UTC" || ident == "GMT") ? ident : shortZoneName(ident)
            let c = timeZoneCoordinates[ident]
            return WorldClockEntry(
                id: "tz:\(ident)",
                name: name,
                timeZoneIdentifier: ident,
                kind: .timeZone,
                region: "Time Zones",
                latitude: c?.lat,
                longitude: c?.lon
            )
        }
    }()
}

// MARK: - Location (Core Location)

@MainActor
private final class WorldClockLocationResolver: NSObject, CLLocationManagerDelegate {
    /// place name, status line, auth, optional WGS84 coordinate for distance sort
    var onUpdate: ((String?, String, CLAuthorizationStatus, CLLocationCoordinate2D?) -> Void)?

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
            onUpdate?(nil, "Location denied — using Mac time zone (\(TimeZone.current.identifier))", manager.authorizationStatus, nil)
        default:
            if isAuthorized(manager.authorizationStatus) {
                manager.requestLocation()
            } else {
                onUpdate?(nil, "Using Mac time zone (\(TimeZone.current.identifier))", manager.authorizationStatus, nil)
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
                status,
                nil
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
                self.onUpdate?(nil, "Location denied — using Mac time zone", status, nil)
            } else if status == .notDetermined {
                self.onUpdate?(nil, "Location not requested yet", status, nil)
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
                manager.authorizationStatus,
                nil
            )
        }
    }

    private func reverseGeocode(_ location: CLLocation) {
        let coord = location.coordinate
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self else { return }
                let mark = placemarks?.first
                let city = mark?.locality ?? mark?.subAdministrativeArea ?? mark?.administrativeArea
                let place = city ?? mark?.name
                let tz = TimeZone.current.identifier
                if let place {
                    self.onUpdate?(place, "\(place) · \(tz)", self.manager.authorizationStatus, coord)
                } else {
                    self.onUpdate?(nil, "Mac time zone · \(tz)", self.manager.authorizationStatus, coord)
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

    /// Local day phase for tinting clock cards (sun / dusk / night).
    static func dayPhase(date: Date, timeZone: TimeZone) -> (label: String, symbol: String, tint: Color) {
        let h = hour(date: date, timeZone: timeZone)
        switch h {
        case 5..<8:
            return ("Dawn", "sunrise.fill", Color(red: 1.0, green: 0.72, blue: 0.42))
        case 8..<17:
            return ("Day", "sun.max.fill", Color(red: 1.0, green: 0.86, blue: 0.35))
        case 17..<20:
            return ("Dusk", "sunset.fill", Color(red: 1.0, green: 0.55, blue: 0.38))
        case 20..<24, 0..<5:
            return ("Night", "moon.stars.fill", Color(red: 0.55, green: 0.72, blue: 1.0))
        default:
            return ("Day", "sun.max.fill", NotchTheme.calmGlow)
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let entries = Array(plugin.activeEntries.prefix(3))
            HStack(spacing: 6) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.calmGlow)
                    .symbolRenderingMode(.hierarchical)
                ForEach(entries) { entry in
                    let phase = WorldClockFormat.dayPhase(date: context.date, timeZone: entry.timeZone)
                    HStack(spacing: 3) {
                        Circle()
                            .fill(phase.tint.opacity(0.9))
                            .frame(width: 4, height: 4)
                        Text(ambientLabel(entry))
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                        Text(WorldClockFormat.timeString(date: context.date, timeZone: entry.timeZone))
                            .font(NotchTheme.micro.weight(.bold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textPrimary)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(phase.tint.opacity(0.12))
                    )
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
            return String(entry.name.prefix(3)).uppercased()
        case .majorCity:
            return String(entry.name.prefix(3)).uppercased()
        }
    }
}

// MARK: - Expanded

private struct ExpandedWorldClockView: View {
    @ObservedObject var plugin: WorldClockPlugin
    @ObservedObject private var units = MeasurementUnitsStore.shared
    @State private var showMeasureConvert = false
    @State private var convertHour: Int = {
        Calendar.current.component(.hour, from: Date())
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("World Clock")
                        .font(NotchTheme.section)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(footerLine)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(NotchTheme.snappy) { showMeasureConvert.toggle() }
                } label: {
                    NotchChipLabel(
                        title: units.system == .metric ? "Metric" : "Imperial",
                        systemImage: "ruler",
                        active: showMeasureConvert || units.showConversionTable
                    )
                }
                .buttonStyle(.plain)
                .help("Measurement units & conversion")
                sortControls
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(plugin.activeEntries.enumerated()), id: \.element.id) { index, entry in
                            cityCard(entry, at: context.date, isHero: index == 0)
                                .notchAppear(delay: Double(min(index, 5)) * 0.035)
                        }
                        converterCard(at: context.date)
                            .notchAppear(delay: 0.12)
                        if showMeasureConvert || units.showConversionTable {
                            measureConvertCard
                                .notchAppear(delay: 0.14)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchAppear()
    }

    private var measureConvertCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "ruler")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.calmGlow)
                Text("Convert measurements")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textSecondary)
                Spacer(minLength: 0)
                Picker("", selection: $units.system) {
                    ForEach(MeasurementUnitsStore.System.allCases) { sys in
                        Text(sys.title).tag(sys)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            MeasurementConvertPanel()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NotchTheme.cardFill.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NotchTheme.calmGlow.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    private var footerLine: String {
        switch plugin.sortMode {
        case .nearest: return "Here first · nearest next · offline"
        case .farthest: return "Here first · farthest next · offline"
        case .random: return "Here first · shuffled · offline"
        case .selection: return "Here first · pick order · offline"
        }
    }

    private var sortControls: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(WorldClockSortMode.allCases) { mode in
                    Button {
                        plugin.sortMode = mode
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
                Divider()
                Button {
                    plugin.reshuffle()
                } label: {
                    Label("Shuffle now", systemImage: "shuffle")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: plugin.sortMode.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                    Text(plugin.sortMode.title)
                        .font(NotchTheme.micro.weight(.semibold))
                }
                .foregroundStyle(NotchTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(NotchTheme.chipFill)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(NotchTheme.hairline.opacity(0.5), lineWidth: 0.5)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .help("Sort clocks by distance, reverse, random, or pick order")

            if plugin.sortMode == .random {
                Button {
                    plugin.reshuffle()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchTheme.textTertiary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(NotchTheme.chipFill))
                }
                .buttonStyle(.plain)
                .help("Reshuffle")
            }
        }
    }

    private func cityCard(_ entry: WorldClockEntry, at date: Date, isHero: Bool) -> some View {
        let tz = entry.timeZone
        let ref = plugin.referenceTimeZone
        let window = WorldClockFormat.callWindow(date: date, timeZone: tz)
        let dst = WorldClockFormat.isDST(timeZone: tz, date: date)
        let phase = WorldClockFormat.dayPhase(date: date, timeZone: tz)
        let timeSize: CGFloat = isHero ? 28 : 20

        return HStack(alignment: .center, spacing: 12) {
            // Day/night orb
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [phase.tint.opacity(0.55), phase.tint.opacity(0.08)],
                            center: .center,
                            startRadius: 1,
                            endRadius: 18
                        )
                    )
                    .frame(width: isHero ? 40 : 34, height: isHero ? 40 : 34)
                Image(systemName: phase.symbol)
                    .font(.system(size: isHero ? 15 : 12, weight: .semibold))
                    .foregroundStyle(phase.tint)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(isHero ? NotchTheme.body.weight(.bold) : NotchTheme.body.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    if entry.kind == .currentLocation {
                        Text("HERE")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(NotchTheme.calmGlow)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NotchTheme.calmGlow.opacity(0.18)))
                    }
                    if dst {
                        Text("DST")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange.opacity(0.95))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }

                HStack(spacing: 5) {
                    metaChip(WorldClockFormat.abbreviation(date: date, timeZone: tz))
                    metaChip(WorldClockFormat.gmtOffsetLabel(timeZone: tz, date: date))
                    metaChip(WorldClockFormat.dayHint(date: date, timeZone: tz, reference: ref))
                    if entry.kind != .currentLocation {
                        metaChip(WorldClockFormat.offsetLabel(from: ref, to: tz, date: date))
                    }
                    if let dist = plugin.distanceLabel(for: entry) {
                        metaChip(dist, tint: NotchTheme.calmGlow)
                    }
                }

                HStack(spacing: 6) {
                    callPill(window)
                    if let dstHint = WorldClockFormat.nextDSTHint(timeZone: tz, date: date) {
                        Text(dstHint)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(WorldClockFormat.timeString(date: date, timeZone: tz))
                        .font(.system(size: timeSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(NotchTheme.textPrimary)
                    Text(WorldClockFormat.periodString(date: date, timeZone: tz))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(phase.tint.opacity(0.95))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(phase.tint.opacity(0.14)))
                }
                Button {
                    copyTime(entry, at: date)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Copy")
                            .font(NotchTheme.micro.weight(.semibold))
                    }
                    .foregroundStyle(NotchTheme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(NotchTheme.chipFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isHero ? 12 : 10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(NotchTheme.cardFill)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                phase.tint.opacity(isHero ? 0.16 : 0.10),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.14),
                                phase.tint.opacity(0.18),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            }
        }
        .contextMenu {
            Button("Copy time") { copyTime(entry, at: date) }
            if entry.kind == .currentLocation {
                Button("Refresh location") { plugin.requestCurrentLocation() }
            }
        }
    }

    private func metaChip(_ text: String, tint: Color = NotchTheme.textTertiary) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    private func callPill(_ window: (label: String, good: Bool)) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(window.good ? Color.green.opacity(0.9) : Color.white.opacity(0.28))
                .frame(width: 5, height: 5)
            Text(window.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(window.good ? Color.green.opacity(0.95) : NotchTheme.textTertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(window.good ? Color.green.opacity(0.12) : Color.white.opacity(0.05))
        )
    }

    private func converterCard(at date: Date) -> some View {
        let from = plugin.referenceTimeZone
        let targets = plugin.activeEntries.filter {
            $0.timeZone.identifier != from.identifier || $0.kind == .currentLocation
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.calmGlow)
                Text("When it’s this hour here…")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textSecondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Picker("Hour", selection: $convertHour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(hourLabel(h)).tag(h)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                Text("local")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
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
                let phase = WorldClockFormat.dayPhase(date: instant, timeZone: entry.timeZone)
                HStack(spacing: 8) {
                    Circle()
                        .fill(phase.tint.opacity(0.85))
                        .frame(width: 6, height: 6)
                    Text(entry.name)
                        .font(NotchTheme.micro.weight(.medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(WorldClockFormat.timeString(date: instant, timeZone: entry.timeZone))
                        .font(NotchTheme.micro.weight(.bold).monospacedDigit())
                        .foregroundStyle(NotchTheme.textPrimary)
                    Text(WorldClockFormat.periodString(date: instant, timeZone: entry.timeZone))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(phase.tint)
                    Text(WorldClockFormat.abbreviation(date: instant, timeZone: entry.timeZone))
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NotchTheme.cardFill.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NotchTheme.calmGlow.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    private func hourLabel(_ h: Int) -> String {
        let period = h < 12 ? "AM" : "PM"
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(period)"
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
    @ObservedObject private var units = MeasurementUnitsStore.shared
    @State private var cityFilter = ""
    @State private var zoneFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick up to 10 clocks. Sort by distance from your location, reverse, random, or keep pick order.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Measurements")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Units", selection: $units.system) {
                    ForEach(MeasurementUnitsStore.System.allCases) { sys in
                        Text(sys.title).tag(sys)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Distance labels on clocks use \(units.system.title.lowercased()) units. Same preference as Preferences → General.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show measurement conversion table", isOn: $units.showConversionTable)
                MeasurementConvertPanel()
                    .padding(.top, 4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Sort order")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $plugin.sortMode) {
                    ForEach(WorldClockSortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                if plugin.sortMode == .nearest || plugin.sortMode == .farthest {
                    Text("Uses Current Location (GPS) when available; otherwise the first city with known coordinates.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if plugin.sortMode == .random {
                    Button("Shuffle now") { plugin.reshuffle() }
                        .controlSize(.small)
                }
            }

            Divider()

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
