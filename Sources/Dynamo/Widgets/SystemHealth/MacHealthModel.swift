import Foundation
import Darwin

/// One line item in a weekly (or on-demand) Mac health report.
struct MacHealthFinding: Equatable, Identifiable, Codable {
    enum Severity: String, Codable, Equatable {
        case good
        case info
        case caution
        case warning
    }

    var id: String
    var title: String
    var detail: String
    var severity: Severity
    var systemImage: String
}

/// Full read-only snapshot of this Mac’s health.
struct MacHealthReport: Equatable, Codable {
    var generatedAt: Date
    /// 0…100 composite — lower means needs attention.
    var score: Int
    var grade: String
    var summary: String
    var findings: [MacHealthFinding]
    /// ISO week key used for “once a week” scheduling (e.g. "2026-W30").
    var weekKey: String

    var warningCount: Int {
        findings.filter { $0.severity == .warning || $0.severity == .caution }.count
    }

    static let empty = MacHealthReport(
        generatedAt: .distantPast,
        score: 0,
        grade: "—",
        summary: "Not checked yet.",
        findings: [],
        weekKey: ""
    )
}

/// Builds and persists weekly Mac health reports from local system metrics.
enum MacHealthModel {
    private static let storeFile = "mac-health-report.json"
    private static let lastWeekKey = "dynamo.health.lastWeekKey"
    private static let lastPeekWeekKey = "dynamo.health.lastPeekWeekKey"

    // MARK: - Schedule

    /// Calendar week key for “once a week” (ISO year-week).
    static func weekKey(for date: Date = Date()) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        return String(format: "%d-W%02d", year, week)
    }

    static var needsWeeklyReport: Bool {
        let key = weekKey()
        let last = UserDefaults.standard.string(forKey: lastWeekKey)
        return last != key
    }

    static func markWeekCompleted(_ key: String = weekKey()) {
        UserDefaults.standard.set(key, forKey: lastWeekKey)
    }

    static var shouldPeekWeeklyReport: Bool {
        let key = weekKey()
        let last = UserDefaults.standard.string(forKey: lastPeekWeekKey)
        return last != key
    }

    static func markWeeklyPeekShown(_ key: String = weekKey()) {
        UserDefaults.standard.set(key, forKey: lastPeekWeekKey)
    }

    // MARK: - Persist

    static func loadCached() -> MacHealthReport? {
        AppSupportStore.load(MacHealthReport.self, from: storeFile)
    }

    static func save(_ report: MacHealthReport) {
        AppSupportStore.save(report, to: storeFile)
        markWeekCompleted(report.weekKey)
    }

    // MARK: - Generate

    /// Read-only system metrics → health report.
    static func generate(
        updates: SoftwareUpdateSnapshot,
        now: Date = Date()
    ) -> MacHealthReport {
        var findings: [MacHealthFinding] = []

        // macOS version
        let ver = ProcessInfo.processInfo.operatingSystemVersion
        let verString = "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
        findings.append(MacHealthFinding(
            id: "os",
            title: "macOS \(verString)",
            detail: "Build \(ProcessInfo.processInfo.operatingSystemVersionString)",
            severity: .info,
            systemImage: "apple.logo"
        ))

        // Disk free
        let disk = diskSpace()
        if let disk {
            let freeGB = Double(disk.free) / 1_073_741_824
            let totalGB = Double(disk.total) / 1_073_741_824
            let freePct = totalGB > 0 ? (freeGB / totalGB) * 100 : 100
            let severity: MacHealthFinding.Severity
            if freePct < 8 || freeGB < 10 {
                severity = .warning
            } else if freePct < 15 || freeGB < 25 {
                severity = .caution
            } else {
                severity = .good
            }
            findings.append(MacHealthFinding(
                id: "disk",
                title: String(format: "%.0f GB free", freeGB),
                detail: String(format: "%.0f%% of %.0f GB available", freePct, totalGB),
                severity: severity,
                systemImage: "internaldrive"
            ))
        }

        // Uptime
        if let uptime = systemUptime() {
            let days = uptime / 86_400
            let severity: MacHealthFinding.Severity
            if days >= 21 {
                severity = .caution
            } else if days >= 14 {
                severity = .info
            } else {
                severity = .good
            }
            let detail: String
            if days >= 1 {
                detail = String(format: "%.0f days since last restart", days)
            } else {
                let hours = uptime / 3600
                detail = String(format: "%.0f hours since last restart", hours)
            }
            let uptimeDetail: String
            if updates.hasUpdates, updates.items.contains(where: \.requiresRestart) {
                uptimeDetail = "Update needs restart · tap to open"
            } else if days >= 14 {
                uptimeDetail = detail + " · tap to restart"
            } else {
                uptimeDetail = detail
            }
            findings.append(MacHealthFinding(
                id: "uptime",
                title: days >= 1 ? String(format: "%.0fd uptime", days) : "Recently restarted",
                detail: uptimeDetail,
                severity: severity,
                systemImage: "clock.arrow.circlepath"
            ))
        }

        // Thermal
        let thermal = ProcessInfo.processInfo.thermalState
        let thermalFinding: MacHealthFinding
        switch thermal {
        case .nominal:
            thermalFinding = MacHealthFinding(
                id: "thermal",
                title: "Cool",
                detail: "Thermal state is nominal.",
                severity: .good,
                systemImage: "thermometer.medium"
            )
        case .fair:
            thermalFinding = MacHealthFinding(
                id: "thermal",
                title: "Warm",
                detail: "Thermal state is fair — light load is fine.",
                severity: .info,
                systemImage: "thermometer.medium"
            )
        case .serious:
            thermalFinding = MacHealthFinding(
                id: "thermal",
                title: "Hot",
                detail: "Serious thermal pressure — ease heavy workloads.",
                severity: .caution,
                systemImage: "thermometer.high"
            )
        case .critical:
            thermalFinding = MacHealthFinding(
                id: "thermal",
                title: "Critical heat",
                detail: "Critical thermal pressure — cool the Mac down.",
                severity: .warning,
                systemImage: "thermometer.high"
            )
        @unknown default:
            thermalFinding = MacHealthFinding(
                id: "thermal",
                title: "Thermal",
                detail: "Unknown thermal state.",
                severity: .info,
                systemImage: "thermometer.medium"
            )
        }
        findings.append(thermalFinding)

        // Memory pressure (approx from host_statistics)
        if let mem = memoryPressure() {
            findings.append(mem)
        }

        // Low Power Mode
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            findings.append(MacHealthFinding(
                id: "lpm",
                title: "Low Power Mode",
                detail: "System power saving is on.",
                severity: .info,
                systemImage: "leaf.fill"
            ))
        }

        // Software updates
        if updates.succeeded {
            if updates.hasUpdates {
                let titles = updates.items.prefix(2).map(\.title).joined(separator: " · ")
                let more = updates.count > 2 ? " +\(updates.count - 2) more" : ""
                findings.append(MacHealthFinding(
                    id: "updates",
                    title: updates.count == 1
                        ? "1 software update"
                        : "\(updates.count) software updates",
                    detail: titles + more,
                    severity: updates.recommendedCount > 0 ? .caution : .info,
                    systemImage: "arrow.down.circle"
                ))
            } else {
                findings.append(MacHealthFinding(
                    id: "updates",
                    title: "Up to date",
                    detail: "No Apple software updates waiting.",
                    severity: .good,
                    systemImage: "checkmark.seal"
                ))
            }
        } else if let err = updates.errorMessage {
            findings.append(MacHealthFinding(
                id: "updates",
                title: "Updates unknown",
                detail: err,
                severity: .info,
                systemImage: "questionmark.circle"
            ))
        }

        let score = compositeScore(findings)
        let grade = gradeLabel(score)
        let summary = makeSummary(score: score, findings: findings, updates: updates)

        return MacHealthReport(
            generatedAt: now,
            score: score,
            grade: grade,
            summary: summary,
            findings: findings,
            weekKey: weekKey(for: now)
        )
    }

    // MARK: - Metrics

    private static func diskSpace() -> (free: Int64, total: Int64)? {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber
        else { return nil }
        return (free.int64Value, total.int64Value)
    }

    private static func systemUptime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        let result = sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        guard result == 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        return Date().timeIntervalSince(bootDate)
    }

    private static func memoryPressure() -> MacHealthFinding? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let totalUsed = active + inactive + wired + compressed
        let total = totalUsed + free + speculative
        guard total > 0 else { return nil }

        let freePct = Double(free + speculative) / Double(total) * 100
        let usedGB = Double(totalUsed) / 1_073_741_824
        let freeGB = Double(free + speculative) / 1_073_741_824

        let severity: MacHealthFinding.Severity
        if freePct < 5 {
            severity = .warning
        } else if freePct < 12 {
            severity = .caution
        } else {
            severity = .good
        }

        return MacHealthFinding(
            id: "memory",
            title: String(format: "%.1f GB free RAM", freeGB),
            detail: String(format: "%.1f GB in use · ~%.0f%% free pages", usedGB, freePct),
            severity: severity,
            systemImage: "memorychip"
        )
    }

    private static func compositeScore(_ findings: [MacHealthFinding]) -> Int {
        var score = 100
        for f in findings {
            switch f.severity {
            case .good, .info: break
            case .caution: score -= 12
            case .warning: score -= 25
            }
        }
        return min(100, max(0, score))
    }

    private static func gradeLabel(_ score: Int) -> String {
        switch score {
        case 90...100: return "Excellent"
        case 75..<90: return "Good"
        case 60..<75: return "Fair"
        case 40..<60: return "Needs care"
        default: return "Attention"
        }
    }

    private static func makeSummary(
        score: Int,
        findings: [MacHealthFinding],
        updates: SoftwareUpdateSnapshot
    ) -> String {
        let warnings = findings.filter { $0.severity == .warning || $0.severity == .caution }
        if updates.hasUpdates {
            return "\(updates.count) update\(updates.count == 1 ? "" : "s") waiting · health \(score)%"
        }
        if let first = warnings.first {
            return "\(first.title) · overall \(score)%"
        }
        return "Mac looks healthy · \(score)%"
    }
}
