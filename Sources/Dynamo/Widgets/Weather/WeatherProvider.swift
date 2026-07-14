import Foundation

/// A resolved current-weather reading for the active location. Views format the
/// `Measurement` values with the user's locale (°F in the US, °C elsewhere), so
/// the provider never has to pick a unit.
struct WeatherSnapshot: Equatable {
    var locationName: String
    var temperature: Measurement<UnitTemperature>
    var conditionDescription: String
    /// SF Symbol name straight from WeatherKit's `symbolName` — no hand-built
    /// weather-code-to-icon table needed.
    var symbolName: String
    var high: Measurement<UnitTemperature>?
    var low: Measurement<UnitTemperature>?
    var isDaylight: Bool
    var updatedAt: Date
}

/// A severe-weather alert surfaced in the expanded view.
struct WeatherAlertItem: Identifiable, Equatable {
    var id: String
    var summary: String
    var severity: WeatherAlertSeverity
    var region: String?
}

enum WeatherAlertSeverity: String, Equatable {
    case unknown
    case minor
    case moderate
    case severe
    case extreme
}

/// A fixed place used when the user opts out of automatic location.
struct WeatherPlace: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

/// Where the provider fetches weather for.
enum WeatherLocationMode: Equatable {
    case automatic
    case manual(WeatherPlace)
}

/// CoreLocation authorization mirrored for the automatic mode. `.unavailable`
/// means we're in manual mode and don't need CoreLocation at all.
enum WeatherLocationAuth: Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

/// Apple requires displaying the "Weather" attribution wherever WeatherKit data
/// appears, linking to the legal page. These URLs come from
/// `WeatherService.attribution`.
struct WeatherAttributionInfo: Equatable {
    var legalPageURL: URL
    /// Combined "Weather" mark suited to a dark background (the notch is dark).
    var markURL: URL?
}

/// Decouples the Weather UI from *how* weather is obtained — same seam shape as
/// `NowPlayingProvider` / `CalendarProvider`. Swap a mock for `WeatherKit`
/// without touching any view.
@MainActor
protocol WeatherProvider: AnyObject {
    var snapshot: WeatherSnapshot? { get }
    var alerts: [WeatherAlertItem] { get }
    var locationMode: WeatherLocationMode { get }
    var locationAuth: WeatherLocationAuth { get }
    var attribution: WeatherAttributionInfo? { get }
    var lastError: String? { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    /// Prompt for CoreLocation access (automatic mode only).
    func requestLocationAccess()
    /// Switch to a fixed place, or pass `nil` to return to automatic location.
    func setManualPlace(_ place: WeatherPlace?)
    func refresh() async
}
