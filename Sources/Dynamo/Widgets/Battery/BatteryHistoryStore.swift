import Foundation

/// One telemetry sample for local battery behaviour modelling.
struct BatterySample: Codable, Equatable, Identifiable {
    var id: UUID
    var date: Date
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isLowPowerMode: Bool
    var cycleCount: Int?
    var maxCapacity: Int?
    var designCapacity: Int?
    var hardwareHealthPercent: Int?
    var temperatureC: Double?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        percent: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        isLowPowerMode: Bool,
        cycleCount: Int? = nil,
        maxCapacity: Int? = nil,
        designCapacity: Int? = nil,
        hardwareHealthPercent: Int? = nil,
        temperatureC: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isLowPowerMode = isLowPowerMode
        self.cycleCount = cycleCount
        self.maxCapacity = maxCapacity
        self.designCapacity = designCapacity
        self.hardwareHealthPercent = hardwareHealthPercent
        self.temperatureC = temperatureC
    }
}

/// Persists battery samples under Application Support for local prediction only.
@MainActor
final class BatteryHistoryStore: ObservableObject {
    static let shared = BatteryHistoryStore()

    private static let fileName = "battery-history.json"
    private static let maxSamples = 2_500
    /// Minimum gap between stored samples (seconds).
    private static let minInterval: TimeInterval = 4 * 60

    @Published private(set) var samples: [BatterySample] = []

    private var lastStoredAt: Date?

    private init() {
        load()
    }

    /// Record a sample if enough time has passed or state changed meaningfully.
    func record(snapshot: BatterySnapshot, isLowPowerMode: Bool) {
        guard snapshot.isPresent, snapshot.percent >= 0 else { return }
        let now = Date()
        if let last = samples.last {
            let dt = now.timeIntervalSince(last.date)
            let same =
                last.percent == snapshot.percent
                && last.isCharging == snapshot.isCharging
                && last.isPluggedIn == snapshot.isPluggedIn
                && last.isLowPowerMode == isLowPowerMode
            if same, dt < Self.minInterval { return }
            // Always keep charge-state transitions.
            let transition =
                last.isCharging != snapshot.isCharging
                || last.isPluggedIn != snapshot.isPluggedIn
                || last.isLowPowerMode != isLowPowerMode
            if !transition, dt < Self.minInterval { return }
        }

        let sample = BatterySample(
            date: now,
            percent: snapshot.percent,
            isCharging: snapshot.isCharging,
            isPluggedIn: snapshot.isPluggedIn,
            isLowPowerMode: isLowPowerMode,
            cycleCount: snapshot.cycleCount,
            maxCapacity: snapshot.maxCapacity,
            designCapacity: snapshot.designCapacity,
            hardwareHealthPercent: snapshot.hardwareHealthPercent,
            temperatureC: snapshot.temperatureC
        )
        samples.append(sample)
        if samples.count > Self.maxSamples {
            samples = Array(samples.suffix(Self.maxSamples))
        }
        lastStoredAt = now
        persist()
    }

    func samples(since: Date) -> [BatterySample] {
        samples.filter { $0.date >= since }
    }

    private struct Payload: Codable {
        var samples: [BatterySample]
    }

    private func load() {
        if let payload = AppSupportStore.load(Payload.self, from: Self.fileName) {
            samples = payload.samples.sorted { $0.date < $1.date }
            lastStoredAt = samples.last?.date
        }
    }

    private func persist() {
        AppSupportStore.save(Payload(samples: samples), to: Self.fileName)
    }
}
