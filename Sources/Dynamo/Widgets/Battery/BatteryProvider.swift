import Foundation
import IOKit
import IOKit.ps

struct BatterySnapshot: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var timeRemainingMinutes: Int?
    var isPresent: Bool
    /// Apple Smart Battery cycle count when available.
    var cycleCount: Int?
    /// Design capacity (mAh or relative units).
    var designCapacity: Int?
    /// Current max charge capacity.
    var maxCapacity: Int?
    /// Firmware-reported health 0…100 when Design/Max known.
    var hardwareHealthPercent: Int?
    /// Temperature in °C when available.
    var temperatureC: Double?

    static let unknown = BatterySnapshot(
        percent: -1,
        isCharging: false,
        isPluggedIn: false,
        timeRemainingMinutes: nil,
        isPresent: false,
        cycleCount: nil,
        designCapacity: nil,
        maxCapacity: nil,
        hardwareHealthPercent: nil,
        temperatureC: nil
    )
}

@MainActor
protocol BatteryProvider: AnyObject {
    var current: BatterySnapshot { get }
    var onChange: ((BatterySnapshot) -> Void)? { get set }
    func start()
    func stop()
}

/// IOKit power-source + AppleSmartBattery (no special entitlement).
@MainActor
final class IOKitBatteryProvider: BatteryProvider {
    private(set) var current: BatterySnapshot = .unknown
    var onChange: ((BatterySnapshot) -> Void)?

    private var timer: Timer?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refresh()
        // 60s is enough for UI; history store may sample more carefully.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    /// Force a re-read (after Low Power Mode toggle, etc.).
    func refreshNow() {
        refresh()
    }

    private func refresh() {
        let snapshot = Self.read()
        guard snapshot != current else { return }
        current = snapshot
        onChange?(snapshot)
    }

    private static func read() -> BatterySnapshot {
        var base = readPowerSource()
        let smart = readSmartBattery()
        if base.isPresent {
            base.cycleCount = smart.cycleCount ?? base.cycleCount
            base.designCapacity = smart.designCapacity ?? base.designCapacity
            base.maxCapacity = smart.maxCapacity ?? base.maxCapacity
            base.temperatureC = smart.temperatureC ?? base.temperatureC
            if let design = base.designCapacity, let maxC = base.maxCapacity, design > 0 {
                base.hardwareHealthPercent = min(100, max(0, Int((Double(maxC) / Double(design) * 100).rounded())))
            } else {
                base.hardwareHealthPercent = smart.hardwareHealthPercent
            }
        }
        return base
    }

    private static func readPowerSource() -> BatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return .unknown
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }

            let type = desc[kIOPSTypeKey] as? String
            if type == kIOPSInternalBatteryType || type == nil {
                let current = desc[kIOPSCurrentCapacityKey] as? Int
                    ?? Int(desc[kIOPSCurrentCapacityKey] as? Double ?? -1)
                let maxCap = desc[kIOPSMaxCapacityKey] as? Int
                    ?? Int(desc[kIOPSMaxCapacityKey] as? Double ?? 100)
                let percent: Int
                if current >= 0, maxCap > 0 {
                    if maxCap == 100 {
                        percent = min(100, max(0, current))
                    } else {
                        percent = min(100, max(0, Int((Double(current) / Double(maxCap) * 100).rounded())))
                    }
                } else {
                    percent = -1
                }
                let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                let powerState = desc[kIOPSPowerSourceStateKey] as? String
                let isPluggedIn = powerState == kIOPSACPowerValue || isCharging
                let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int
                let timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int
                let remaining: Int?
                if isCharging, let t = timeToFull, t > 0, t < 6000 {
                    remaining = t
                } else if !isCharging, let t = timeToEmpty, t > 0, t < 6000 {
                    remaining = t
                } else {
                    remaining = nil
                }
                if percent >= 0 {
                    return BatterySnapshot(
                        percent: percent,
                        isCharging: isCharging,
                        isPluggedIn: isPluggedIn,
                        timeRemainingMinutes: remaining,
                        isPresent: true,
                        cycleCount: desc["Cycle Count"] as? Int,
                        designCapacity: nil,
                        maxCapacity: maxCap == 100 ? nil : maxCap,
                        hardwareHealthPercent: nil,
                        temperatureC: nil
                    )
                }
            }
        }
        return .unknown
    }

    /// Richer metrics from AppleSmartBattery (cycles, design capacity, temp).
    private static func readSmartBattery() -> (
        cycleCount: Int?,
        designCapacity: Int?,
        maxCapacity: Int?,
        hardwareHealthPercent: Int?,
        temperatureC: Double?
    ) {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return (nil, nil, nil, nil, nil)
        }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else {
            return (nil, nil, nil, nil, nil)
        }

        let cycles: Int? = {
            if let i = dict["CycleCount"] as? Int { return i }
            if let i = dict["CycleCount"] as? Int64 { return Int(i) }
            if let n = dict["CycleCount"] as? NSNumber { return n.intValue }
            return nil
        }()
        let design = intValue(dict["DesignCapacity"])
        let maxC = intValue(dict["AppleRawMaxCapacity"])
            ?? intValue(dict["MaxCapacity"])
            ?? intValue(dict["NormalizedMaxCapacity"])
        // Temperature is often in decidegrees C (e.g. 301 = 30.1°C).
        let tempRaw = intValue(dict["Temperature"])
        let tempC: Double? = tempRaw.map { Double($0) / 100.0 }
        var health: Int?
        if let design, let maxC, design > 0 {
            health = min(100, max(0, Int((Double(maxC) / Double(design) * 100).rounded())))
        }
        return (cycles, design, maxC, health, tempC)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let i = any as? Int64 { return Int(i) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
