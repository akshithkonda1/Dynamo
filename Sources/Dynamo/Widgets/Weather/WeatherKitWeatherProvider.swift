import AppKit
import CoreLocation
import Foundation
import WeatherKit

/// WeatherKit-backed weather source using the native Swift API
/// (`WeatherService.shared.weather(for:)`) — no REST/JWT complexity, which is
/// only relevant for non-Apple-platform access. Location comes from CoreLocation
/// in automatic mode, or a saved `WeatherPlace` in manual mode.
@MainActor
final class WeatherKitWeatherProvider: NSObject, WeatherProvider, CLLocationManagerDelegate {
    /// WeatherKit's per-membership call limits are generous; a 15-minute refresh
    /// of a single location is comfortable.
    private static let refreshInterval: TimeInterval = 900
    private static let placeFile = "weather_location.json"

    private(set) var snapshot: WeatherSnapshot?
    private(set) var alerts: [WeatherAlertItem] = []
    private(set) var locationMode: WeatherLocationMode = .automatic
    private(set) var locationAuth: WeatherLocationAuth = .notDetermined
    private(set) var attribution: WeatherAttributionInfo?
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    private let service = WeatherService.shared
    private let locationManager = CLLocationManager()
    private var timer: Timer?
    private var isStarted = false
    /// Last coordinate we resolved (from CoreLocation or a manual place).
    private var lastLatitude: Double?
    private var lastLongitude: Double?
    /// Last successful automatic GPS fix — used so weather still loads after a
    /// permission reset while Core Location is catching up.
    private var lastAutomaticPlace: WeatherPlace?

    override init() {
        super.init()
        locationManager.delegate = self
        // City-level accuracy is plenty for weather and prompts a lighter grant.
        locationManager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadPersistedMode()
        Task { await loadAttribution() }

        switch locationMode {
        case .automatic:
            locationAuth = Self.mapAuth(locationManager.authorizationStatus)
            if let last = lastAutomaticPlace {
                lastLatitude = last.latitude
                lastLongitude = last.longitude
                Task { await refresh() }
            } else if let guessed = Self.place(forTimeZone: TimeZone.current.identifier) {
                lastLatitude = guessed.latitude
                lastLongitude = guessed.longitude
                Task { await refresh() }
            }
            requestLocationIfNeeded()
        case .manual(let place):
            locationAuth = .unavailable
            lastLatitude = place.latitude
            lastLongitude = place.longitude
            Task { await refresh() }
        }

        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    func requestLocationAccess() {
        guard case .automatic = locationMode else { return }
        NSApp.activate(ignoringOtherApps: true)
        locationManager.requestWhenInUseAuthorization()
    }

    private func requestLocationIfNeeded() {
        switch locationAuth {
        case .authorized:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied:
            if snapshot == nil {
                lastError = "Allow Location in System Settings, or set a city in Settings → Weather."
            }
        case .unavailable:
            break
        }
    }

    func setManualPlace(_ place: WeatherPlace?) {
        if let place {
            locationMode = .manual(place)
            locationAuth = .unavailable
            lastLatitude = place.latitude
            lastLongitude = place.longitude
            persistMode()
            Task { await refresh() }
        } else {
            locationMode = .automatic
            persistMode()
            locationAuth = Self.mapAuth(locationManager.authorizationStatus)
            requestLocationIfNeeded()
        }
        onChange?()
    }

    func refresh() async {
        guard let lat = lastLatitude, let lon = lastLongitude else {
            requestLocationIfNeeded()
            onChange?()
            return
        }
        let location = CLLocation(latitude: lat, longitude: lon)
        do {
            let weather = try await service.weather(for: location)
            let current = weather.currentWeather
            let today = weather.dailyForecast.forecast.first
            let name = await resolvePlaceName(for: location)

            let now = Date()
            let hourly = weather.hourlyForecast.forecast
                .filter { $0.date > now }
                .prefix(5)
                .map { WeatherHourItem(hour: $0.date, symbolName: $0.symbolName, temperature: $0.temperature) }
            let daily = weather.dailyForecast.forecast.prefix(10).map {
                WeatherDayItem(
                    day: $0.date,
                    symbolName: $0.symbolName,
                    high: $0.highTemperature,
                    low: $0.lowTemperature
                )
            }
            snapshot = WeatherSnapshot(
                locationName: name,
                temperature: current.temperature,
                conditionDescription: current.condition.description,
                symbolName: current.symbolName,
                high: today?.highTemperature,
                low: today?.lowTemperature,
                isDaylight: current.isDaylight,
                updatedAt: now,
                hourly: Array(hourly),
                daily: Array(daily),
                feelsLike: current.apparentTemperature,
                windSpeedKph: current.wind.speed.converted(to: .kilometersPerHour).value,
                humidityPercent: Int(current.humidity * 100)
            )
            alerts = (weather.weatherAlerts ?? []).map { alert in
                WeatherAlertItem(
                    // Region + summary is a stable-enough identity without
                    // depending on the exact type of `detailsURL` across SDKs.
                    id: "\(alert.region ?? "")|\(alert.summary)",
                    summary: alert.summary,
                    severity: Self.mapSeverity(alert.severity),
                    region: alert.region
                )
            }
            lastError = nil
            if case .automatic = locationMode {
                lastAutomaticPlace = WeatherPlace(name: name, latitude: lat, longitude: lon)
                persistMode()
            }
        } catch {
            lastError = Self.friendlyMessage(for: error)
        }
        onChange?()
    }

    /// City-level fallback so Weather still loads when Location is off.
    nonisolated static func place(forTimeZone identifier: String) -> WeatherPlace? {
        switch identifier {
        case "America/Chicago": return WeatherPlace(name: "Chicago", latitude: 41.8781, longitude: -87.6298)
        case "America/New_York": return WeatherPlace(name: "New York", latitude: 40.7128, longitude: -74.0060)
        case "America/Los_Angeles": return WeatherPlace(name: "Los Angeles", latitude: 34.0522, longitude: -118.2437)
        case "America/Denver": return WeatherPlace(name: "Denver", latitude: 39.7392, longitude: -104.9903)
        case "America/Phoenix": return WeatherPlace(name: "Phoenix", latitude: 33.4484, longitude: -112.0740)
        case "America/Vancouver": return WeatherPlace(name: "Vancouver", latitude: 49.2827, longitude: -123.1207)
        case "America/Toronto": return WeatherPlace(name: "Toronto", latitude: 43.6532, longitude: -79.3832)
        case "America/Mexico_City": return WeatherPlace(name: "Mexico City", latitude: 19.4326, longitude: -99.1332)
        case "America/Sao_Paulo": return WeatherPlace(name: "São Paulo", latitude: -23.5505, longitude: -46.6333)
        case "America/Buenos_Aires", "America/Argentina/Buenos_Aires":
            return WeatherPlace(name: "Buenos Aires", latitude: -34.6037, longitude: -58.3816)
        case "Europe/London": return WeatherPlace(name: "London", latitude: 51.5074, longitude: -0.1278)
        case "Europe/Paris": return WeatherPlace(name: "Paris", latitude: 48.8566, longitude: 2.3522)
        case "Asia/Kolkata": return WeatherPlace(name: "Delhi", latitude: 28.6139, longitude: 77.2090)
        case "Asia/Tokyo": return WeatherPlace(name: "Tokyo", latitude: 35.6762, longitude: 139.6503)
        case "Australia/Sydney": return WeatherPlace(name: "Sydney", latitude: -33.8688, longitude: 151.2093)
        case "Australia/Melbourne": return WeatherPlace(name: "Melbourne", latitude: -37.8136, longitude: 144.9631)
        case "Pacific/Honolulu": return WeatherPlace(name: "Honolulu", latitude: 21.3069, longitude: -157.8583)
        default: return nil
        }
    }

    nonisolated static func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        let folded = raw.lowercased()
        if folded.contains("not entitled")
            || folded.contains("entitlement")
            || folded.contains("missing entitlement") {
            return "This build isn’t signed for WeatherKit. Set a city in Settings → Weather, or relaunch the developer-signed app."
        }
        if folded.contains("not authorized") || folded.contains("unauthorized") {
            return "WeatherKit wasn’t authorized. Set a city in Settings → Weather if Location is off."
        }
        if folded.contains("network") || folded.contains("offline") || folded.contains("internet") {
            return "Can’t reach Weather. Check the network and try again."
        }
        return "Weather unavailable: \(raw)"
    }

    // MARK: - Attribution (required by WeatherKit terms)

    private func loadAttribution() async {
        do {
            let attr = try await service.attribution
            attribution = WeatherAttributionInfo(
                legalPageURL: attr.legalPageURL,
                markURL: attr.combinedMarkDarkURL
            )
            onChange?()
        } catch {
            // Non-fatal: the mark just won't render; the legal Link falls back to text.
        }
    }

    private func resolvePlaceName(for location: CLLocation) async -> String {
        if case .manual(let place) = locationMode { return place.name }
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
           let mark = placemarks.first {
            return mark.locality ?? mark.administrativeArea ?? mark.name ?? "Current Location"
        }
        return "Current Location"
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.handleAuthChange(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        Task { @MainActor in
            self.lastLatitude = lat
            self.lastLongitude = lon
            await self.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let ns = error as NSError
        Task { @MainActor in
            if ns.domain == kCLErrorDomain, ns.code == CLError.locationUnknown.rawValue {
                if self.snapshot == nil, self.lastLatitude == nil {
                    self.lastError = "Waiting for a location fix…"
                    self.onChange?()
                }
                return
            }
            self.lastError = "Location error: \(error.localizedDescription)"
            self.onChange?()
        }
    }

    @MainActor
    private func handleAuthChange(_ status: CLAuthorizationStatus) {
        guard case .automatic = locationMode else { return }
        locationAuth = Self.mapAuth(status)
        requestLocationIfNeeded()
        onChange?()
    }

    // MARK: - Mapping helpers

    private static func mapAuth(_ status: CLAuthorizationStatus) -> WeatherLocationAuth {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        default:
            // authorizedAlways / authorizedWhenInUse / authorized — platform-dependent names.
            return .authorized
        }
    }

    private static func mapSeverity(_ severity: WeatherSeverity) -> WeatherAlertSeverity {
        switch severity {
        case .minor: return .minor
        case .moderate: return .moderate
        case .severe: return .severe
        case .extreme: return .extreme
        default: return .unknown
        }
    }

    // MARK: - Mode persistence

    private struct PersistedMode: Codable {
        /// `nil` means automatic location.
        var manual: WeatherPlace?
        var lastAutomatic: WeatherPlace?
    }

    private func persistMode() {
        let manual: WeatherPlace?
        if case .manual(let place) = locationMode { manual = place } else { manual = nil }
        AppSupportStore.save(
            PersistedMode(manual: manual, lastAutomatic: lastAutomaticPlace),
            to: Self.placeFile
        )
    }

    private func loadPersistedMode() {
        if let persisted = AppSupportStore.load(PersistedMode.self, from: Self.placeFile) {
            lastAutomaticPlace = persisted.lastAutomatic
            if let place = persisted.manual {
                locationMode = .manual(place)
                return
            }
        }
        locationMode = .automatic
    }
}
