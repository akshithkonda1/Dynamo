import CoreLocation
import SwiftUI

/// Notch weather widget. Talks only to `WeatherProvider`, so the WeatherKit
/// implementation can be swapped for a mock without touching any view.
@MainActor
final class WeatherPlugin: ObservableObject, NotchWidgetPlugin, WidgetSettingsProviding, NotchSneakPeekProviding, NotchAmbientProviding {
    let id = "weather"
    let displayName = "Weather"
    let systemImage = "cloud.sun"

    var expandedContentHeight: CGFloat { 255 }

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var alerts: [WeatherAlertItem] = []
    @Published private(set) var locationAuth: WeatherLocationAuth = .notDetermined
    @Published private(set) var isManualLocation = false
    @Published private(set) var attribution: WeatherAttributionInfo?
    @Published private(set) var lastError: String?
    @Published private(set) var isGeocoding = false
    @Published var manualQuery: String = ""
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: WeatherProvider
    /// Held so an in-flight geocode isn't cancelled by the geocoder deallocating.
    private let geocoder = CLGeocoder()
    /// Alert IDs already peeked, so a persisting alert doesn't re-peek on every
    /// refresh — only genuinely new alerts do.
    private var notifiedAlertIDs: Set<String> = []

    init(provider: WeatherProvider? = nil) {
        let resolved = provider ?? WeatherKitWeatherProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in
            self?.syncFromProvider()
        }
    }

    private func syncFromProvider() {
        snapshot = provider.snapshot
        alerts = provider.alerts
        locationAuth = provider.locationAuth
        attribution = provider.attribution
        lastError = provider.lastError
        if case .manual = provider.locationMode {
            isManualLocation = true
        } else {
            isManualLocation = false
        }
        checkNewAlerts()
    }

    /// Peek once per genuinely new severe/extreme alert. Minor/moderate
    /// advisories still show in the expanded view but don't interrupt.
    private func checkNewAlerts() {
        notifiedAlertIDs.formIntersection(Set(alerts.map(\.id)))
        for alert in alerts where !notifiedAlertIDs.contains(alert.id) {
            notifiedAlertIDs.insert(alert.id)
            guard alert.severity == .severe || alert.severity == .extreme else { continue }
            onSneakPeek?(NotchSneakPeek(
                systemImage: "exclamationmark.triangle.fill",
                title: "Severe Weather Alert",
                subtitle: alert.summary,
                urgency: .critical
            ))
        }
    }

    func start() {
        provider.start()
        syncFromProvider()
    }

    func stop() {
        provider.stop()
    }

    func requestLocationAccess() {
        provider.requestLocationAccess()
    }

    func refresh() {
        Task { await provider.refresh() }
    }

    func useAutomaticLocation() {
        manualQuery = ""
        provider.setManualPlace(nil)
    }

    /// Geocode the typed city and switch to it as a fixed location — lets users
    /// who'd rather not grant Location still get weather.
    func applyManualQuery() {
        let query = manualQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isGeocoding = true
        lastError = nil
        geocoder.geocodeAddressString(query) { [weak self] placemarks, _ in
            // Pull out only Sendable primitives before hopping to the main actor.
            let first = placemarks?.first
            let name = first?.locality ?? first?.name
            let lat = first?.location?.coordinate.latitude
            let lon = first?.location?.coordinate.longitude
            Task { @MainActor in
                guard let self else { return }
                self.isGeocoding = false
                if let lat, let lon {
                    self.provider.setManualPlace(WeatherPlace(
                        name: name ?? query,
                        latitude: lat,
                        longitude: lon
                    ))
                } else {
                    self.lastError = "Couldn’t find “\(query)”. Try a city name."
                    self.syncFromProvider()
                }
            }
        }
    }

    func expandedView() -> AnyView { AnyView(ExpandedWeatherView(plugin: self)) }
    func settingsView() -> AnyView { AnyView(WeatherSettingsView(plugin: self)) }

    // MARK: - Ambient

    var isAmbientActive: Bool { snapshot != nil }
    /// Below calendar/media/battery so weather is the calm idle fallback (above clock).
    var ambientPriority: Int { 28 }

    func ambientView() -> AnyView {
        AnyView(AmbientWeatherView(snapshot: snapshot))
    }
}

private struct AmbientWeatherView: View {
    let snapshot: WeatherSnapshot?

    var body: some View {
        HStack(spacing: 6) {
            if let snapshot {
                Image(systemName: snapshot.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 11, weight: .semibold))
                Text(TemperatureFormat.short(snapshot.temperature))
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(snapshot.conditionDescription)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Temperature formatting

/// Formats WeatherKit temperatures in the viewer's locale unit (°F in the US),
/// showing just the degree number for the compact notch.
enum TemperatureFormat {
    private static let formatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .temperatureWithoutUnit
        f.numberFormatter.maximumFractionDigits = 0
        return f
    }()

    static func short(_ temperature: Measurement<UnitTemperature>) -> String {
        formatter.string(from: temperature)
    }
}

// MARK: - Views

private struct ExpandedWeatherView: View {
    @ObservedObject var plugin: WeatherPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            header
            content
            Spacer(minLength: 0)
            attributionFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("Weather")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
            Spacer()
            if let name = plugin.snapshot?.locationName {
                Text(name)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            }
            Button { plugin.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help("Refresh weather")
        }
    }

    @ViewBuilder
    private var content: some View {
        if plugin.snapshot == nil, plugin.locationAuth == .notDetermined, !plugin.isManualLocation {
            Button("Allow Location Access") { plugin.requestLocationAccess() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Text("Or set a location in Settings → Weather.")
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textTertiary)
        } else if plugin.snapshot == nil, plugin.locationAuth == .denied {
            NotchEmptyState(
                systemImage: "location.slash",
                title: "Location access denied",
                caption: "Enable Location Services, or set a city in Settings → Weather.",
                prominent: true
            )
        } else if let snapshot = plugin.snapshot {
            currentConditions(snapshot)
            if !snapshot.hourly.isEmpty {
                hourlyStrip(snapshot.hourly)
            }
            if !plugin.alerts.isEmpty {
                alertList
            }
            if let error = plugin.lastError {
                Text(error)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(plugin.lastError ?? "Fetching weather…")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
        }
    }

    private func currentConditions(_ snapshot: WeatherSnapshot) -> some View {
        NotchCard {
            HStack(alignment: .center, spacing: NotchTheme.spaceMD) {
                Image(systemName: snapshot.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 36))
                VStack(alignment: .leading, spacing: 2) {
                    Text(TemperatureFormat.short(snapshot.temperature))
                        .font(NotchTheme.heroDigit)
                        .foregroundStyle(NotchTheme.textPrimary)
                    Text(snapshot.conditionDescription)
                        .font(NotchTheme.caption)
                        .foregroundStyle(NotchTheme.textSecondary)
                    if let high = snapshot.high, let low = snapshot.low {
                        Text("H \(TemperatureFormat.short(high))   L \(TemperatureFormat.short(low))")
                            .font(NotchTheme.micro.monospacedDigit())
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func hourlyStrip(_ hours: [WeatherHourItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(hours) { hour in
                    VStack(spacing: 3) {
                        Text(hourLabel(hour.hour))
                            .font(NotchTheme.micro.monospacedDigit())
                            .foregroundStyle(NotchTheme.textTertiary)
                        Image(systemName: hour.symbolName)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 12))
                        Text(TemperatureFormat.short(hour.temperature))
                            .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textSecondary)
                    }
                    .frame(minWidth: 36)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func hourLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f.string(from: date)
    }

    private var alertList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plugin.alerts) { alert in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NotchTheme.caution)
                    Text(alert.summary)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Apple's WeatherKit terms require showing the "Weather" attribution and a
    /// link to the legal page wherever the data appears.
    @ViewBuilder
    private var attributionFooter: some View {
        if let attribution = plugin.attribution {
            HStack(spacing: 4) {
                if let markURL = attribution.markURL {
                    AsyncImage(url: markURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text("Weather")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    .frame(height: 12)
                } else {
                    Text("Weather")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                Spacer(minLength: 0)
                Link("Data & Legal", destination: attribution.legalPageURL)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }
}

/// Settings panel for Weather — shown generically via `WidgetSettingsProviding`.
private struct WeatherSettingsView: View {
    @ObservedObject var plugin: WeatherPlugin

    private var locationSummary: String {
        guard plugin.isManualLocation else {
            return "Using your current location (automatic)."
        }
        if let name = plugin.snapshot?.locationName {
            return "Using a manual location: \(name)"
        }
        return "Using a manual location."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(locationSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("City (e.g. San Francisco)", text: Binding(
                    get: { plugin.manualQuery },
                    set: { plugin.manualQuery = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { plugin.applyManualQuery() }

                Button("Set") { plugin.applyManualQuery() }
                    .disabled(plugin.manualQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plugin.isGeocoding)
            }

            if plugin.isManualLocation {
                Button("Use my location instead") { plugin.useAutomaticLocation() }
                    .controlSize(.small)
            }

            if plugin.isGeocoding {
                Text("Looking up location…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = plugin.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
