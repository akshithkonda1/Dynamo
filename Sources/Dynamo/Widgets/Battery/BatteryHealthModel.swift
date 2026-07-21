import Foundation

/// On-device battery behaviour summary — not medical/diagnostic grade.
///
/// Combines:
/// - Hardware health (Design vs Max capacity) when IOKit reports it
/// - Observed drain rate (%/hour) from local history
/// - Predicted remaining minutes from recent discharge
/// - Simple wear score from cycle count + health trend
struct BatteryInsight: Equatable {
    /// 0…100 composite health (hardware weighted when available).
    var healthScore: Int
    /// Label for the score.
    var healthLabel: String
    /// Recent average discharge rate in percent per hour (nil if unknown).
    var drainPercentPerHour: Double?
    /// Predicted minutes remaining from our model (overrides OS when more stable).
    var predictedRemainingMinutes: Int?
    /// Predicted minutes to full when charging.
    var predictedToFullMinutes: Int?
    /// Sample count used in the last window.
    var samplesUsed: Int
    /// Short human summary.
    var summary: String
    /// Wear tip based on behaviour.
    var tip: String
}

/// Builds `BatteryInsight` from live snapshot + local history.
enum BatteryHealthModel {
    /// Use last N hours of samples for rate estimation.
    private static let windowHours: Double = 18
    private static let minDrainSamples = 4

    static func insight(
        snapshot: BatterySnapshot,
        samples: [BatterySample],
        now: Date = Date()
    ) -> BatteryInsight {
        guard snapshot.isPresent else {
            return BatteryInsight(
                healthScore: 0,
                healthLabel: "Unavailable",
                drainPercentPerHour: nil,
                predictedRemainingMinutes: nil,
                predictedToFullMinutes: nil,
                samplesUsed: 0,
                summary: "No internal battery detected.",
                tip: "Desktop Macs don’t expose portable battery health."
            )
        }

        let since = now.addingTimeInterval(-windowHours * 3600)
        let window = samples.filter { $0.date >= since }
        let drain = dischargeRatePercentPerHour(in: window)
        let charge = chargeRatePercentPerHour(in: window)

        let hardware = snapshot.hardwareHealthPercent
        let cycles = snapshot.cycleCount
        let healthScore = compositeHealth(
            hardware: hardware,
            cycles: cycles,
            samples: samples
        )
        let label = healthLabel(for: healthScore)

        var predictedEmpty: Int?
        var predictedFull: Int?
        if !snapshot.isCharging, !snapshot.isPluggedIn, let drain, drain > 0.15 {
            let hours = Double(snapshot.percent) / drain
            predictedEmpty = max(1, Int((hours * 60).rounded()))
        }
        if snapshot.isCharging, let charge, charge > 0.15 {
            let need = Double(100 - snapshot.percent)
            let hours = need / charge
            predictedFull = max(1, Int((hours * 60).rounded()))
        }

        // Prefer model when OS estimate is missing or wildly different.
        let osRemain = snapshot.timeRemainingMinutes
        if predictedEmpty == nil { predictedEmpty = osRemain }
        if predictedFull == nil, snapshot.isCharging { predictedFull = osRemain }

        let summary: String
        if snapshot.isCharging {
            if let os = osRemain {
                summary = "Charging · ~\(formatDuration(os)) to full"
            } else if let m = predictedFull {
                summary = "Charging · ~\(formatDuration(m)) to full (estimated)"
            } else {
                summary = "Charging"
            }
        } else if snapshot.isPluggedIn {
            summary = "Plugged in · not discharging"
        } else if let drain {
            if let hw = hardware {
                summary = String(format: "Using ~%.1f%%/h · capacity %d%%", drain, hw)
            } else {
                summary = String(format: "Using ~%.1f%%/h", drain)
            }
        } else if let os = osRemain {
            summary = "~\(formatDuration(os)) remaining"
        } else {
            summary = "Reading system battery…"
        }

        let tip = makeTip(
            health: healthScore,
            cycles: cycles,
            drain: drain,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            percent: snapshot.percent,
            isCharging: snapshot.isCharging
        )

        return BatteryInsight(
            healthScore: healthScore,
            healthLabel: label,
            drainPercentPerHour: drain,
            predictedRemainingMinutes: snapshot.isCharging ? nil : predictedEmpty,
            predictedToFullMinutes: snapshot.isCharging ? predictedFull : nil,
            samplesUsed: window.count,
            summary: summary,
            tip: tip
        )
    }

    // MARK: - Rates

    /// Linear fit of percent vs time on discharging segments only.
    private static func dischargeRatePercentPerHour(in samples: [BatterySample]) -> Double? {
        ratePercentPerHour(in: samples) { !$0.isCharging && !$0.isPluggedIn }
    }

    private static func chargeRatePercentPerHour(in samples: [BatterySample]) -> Double? {
        ratePercentPerHour(in: samples) { $0.isCharging }
    }

    private static func ratePercentPerHour(
        in samples: [BatterySample],
        where predicate: (BatterySample) -> Bool
    ) -> Double? {
        let pts = samples.filter(predicate)
        guard pts.count >= minDrainSamples else { return nil }

        // Use consecutive pairs to average |Δ%| / Δt on same regime.
        var rates: [Double] = []
        for i in 1..<pts.count {
            let a = pts[i - 1]
            let b = pts[i]
            let dtHours = b.date.timeIntervalSince(a.date) / 3600
            guard dtHours > 0.02, dtHours < 8 else { continue }
            let dPercent = Double(b.percent - a.percent)
            // Discharge → negative Δ%; charge → positive.
            let speed = abs(dPercent) / dtHours
            if speed > 0.05, speed < 80 {
                rates.append(speed)
            }
        }
        guard rates.count >= 2 else { return nil }
        // Robust-ish: median
        let sorted = rates.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Health score

    /// Prefer IOKit max/design capacity. Never invent a fake “90%” prior.
    private static func compositeHealth(
        hardware: Int?,
        cycles: Int?,
        samples: [BatterySample]
    ) -> Int {
        // Primary: firmware max/design capacity from AppleSmartBattery.
        if let hardware {
            return min(100, max(0, hardware))
        }
        // Last stored hardware reading from local history.
        let healthSeries = samples.compactMap(\.hardwareHealthPercent)
        if let last = healthSeries.last {
            return min(100, max(0, last))
        }
        // Coarse cycle-based estimate only when hardware health is unavailable.
        if let cycles {
            let wear = min(1.0, Double(cycles) / 1000.0)
            let fromCycles = Int((100.0 - wear * 25.0).rounded())
            return min(100, max(50, fromCycles))
        }
        return 0
    }

    static func healthLabel(for score: Int) -> String {
        switch score {
        case 0: return "Unknown"
        case 90...100: return "Excellent"
        case 80..<90: return "Good"
        case 70..<80: return "Fair"
        case 60..<70: return "Service soon"
        default: return "Replace soon"
        }
    }

    private static func makeTip(
        health: Int,
        cycles: Int?,
        drain: Double?,
        isLowPower: Bool,
        percent: Int,
        isCharging: Bool
    ) -> String {
        if isCharging {
            return "Avoid heat while charging; remove heavy cases if the Mac feels warm."
        }
        if percent <= 20, !isLowPower {
            return "Enable Low Power Mode to stretch remaining charge."
        }
        if let drain, drain > 18 {
            return "High drain right now — bright display and heavy apps shorten runtime."
        }
        if health < 80 {
            return "Capacity is reduced; keep charge between ~20–80% when you can."
        }
        if let cycles, cycles > 700 {
            return "High cycle count (\(cycles)) — health naturally declines over time."
        }
        if isLowPower {
            return "Low Power Mode is on — background activity is reduced."
        }
        return "Dynamo learns your drain pattern locally — no data leaves this Mac."
    }

    private static func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
