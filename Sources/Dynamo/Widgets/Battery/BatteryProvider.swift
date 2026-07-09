import Foundation
import IOKit.ps

struct BatterySnapshot: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var timeRemainingMinutes: Int?
    var isPresent: Bool

    static let unknown = BatterySnapshot(
        percent: -1,
        isCharging: false,
        isPluggedIn: false,
        timeRemainingMinutes: nil,
        isPresent: false
    )
}

@MainActor
protocol BatteryProvider: AnyObject {
    var current: BatterySnapshot { get }
    var onChange: ((BatterySnapshot) -> Void)? { get set }
    func start()
    func stop()
}

/// IOKit power-source backed battery status (no special entitlement).
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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let snapshot = Self.read()
        guard snapshot != current else { return }
        current = snapshot
        onChange?(snapshot)
    }

    private static func read() -> BatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return .unknown
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }

            let type = desc[kIOPSTypeKey] as? String
            // Prefer internal battery; skip UPS if battery also present.
            if type == kIOPSInternalBatteryType || type == nil {
                let percent = desc[kIOPSCurrentCapacityKey] as? Int
                    ?? Int(desc[kIOPSCurrentCapacityKey] as? Double ?? -1)
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
                        percent: min(100, max(0, percent)),
                        isCharging: isCharging,
                        isPluggedIn: isPluggedIn,
                        timeRemainingMinutes: remaining,
                        isPresent: true
                    )
                }
            }
        }
        return .unknown
    }
}
