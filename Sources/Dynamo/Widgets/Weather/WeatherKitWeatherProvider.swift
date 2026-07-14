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
            switch locationAuth {
            case .authorized:
                locationManager.requestLocation()
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            default:
                break
            }
        case .manual(let place):
            locationAuth = .unavailable
            lastLatitude = place.latitude
            lastLongitude = place.longitude
            Task { await refresh() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    func requestLocationAccess() {
        guard case .automatic = locationMode else { return }
        locationManager.requestWhenInUseAuthorization()
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
            switch locationAuth {
            case .authorized:
                locationManager.requestLocation()
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            default:
                break
            }
        }
        onChange?()
    }

    func refresh() async {
        guard let lat = lastLatitude, let lon = lastLongitude else {
            // Automatic mode with no fix yet — wait for CoreLocation to reply.
            return
        }
        let location = CLLocation(latitude: lat, longitude: lon)
        do {
            let weather = try await service.weather(for: location)
            let current = weather.currentWeather
            let today = weather.dailyForecast.forecast.first
            let name = await resolvePlaceName(for: location)

            snapshot = WeatherSnapshot(
                locationName: name,
                temperature: current.temperature,
                conditionDescription: current.condition.description,
                symbolName: current.symbolName,
                high: today?.highTemperature,
                low: today?.lowTemperature,
                isDaylight: current.isDaylight,
                updatedAt: Date()
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
        } catch {
            lastError = "Weather unavailable: \(error.localizedDescription)"
        }
        onChange?()
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
        let message = error.localizedDescription
        Task { @MainActor in
            // kCLErrorLocationUnknown is transient; keep any prior snapshot.
            self.lastError = "Location error: \(message)"
            self.onChange?()
        }
    }

    @MainActor
    private func handleAuthChange(_ status: CLAuthorizationStatus) {
        guard case .automatic = locationMode else { return }
        locationAuth = Self.mapAuth(status)
        if locationAuth == .authorized {
            locationManager.requestLocation()
        }
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
    }

    private func persistMode() {
        let manual: WeatherPlace?
        if case .manual(let place) = locationMode { manual = place } else { manual = nil }
        AppSupportStore.save(PersistedMode(manual: manual), to: Self.placeFile)
    }

    private func loadPersistedMode() {
        if let persisted = AppSupportStore.load(PersistedMode.self, from: Self.placeFile),
           let place = persisted.manual {
            locationMode = .manual(place)
        } else {
            locationMode = .automatic
        }
    }
}
