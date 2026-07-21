import Foundation

/// One available Apple software update (from `softwareupdate -l`).
struct SoftwareUpdateItem: Equatable, Identifiable, Codable {
    var id: String { label }
    var label: String
    var title: String
    var version: String?
    var recommended: Bool
    var requiresRestart: Bool
}

/// Snapshot of pending Apple software updates — read-only.
struct SoftwareUpdateSnapshot: Equatable, Codable {
    var checkedAt: Date
    var items: [SoftwareUpdateItem]
    /// True when the tool ran successfully (even if zero updates).
    var succeeded: Bool
    var errorMessage: String?

    var hasUpdates: Bool { !items.isEmpty }
    var count: Int { items.count }
    var recommendedCount: Int { items.filter(\.recommended).count }

    static let empty = SoftwareUpdateSnapshot(
        checkedAt: .distantPast,
        items: [],
        succeeded: false,
        errorMessage: nil
    )
}

/// Polls Apple’s Software Update catalog via `/usr/sbin/softwareupdate -l`.
/// Read-only — never installs updates.
@MainActor
final class SoftwareUpdateProvider: ObservableObject {
    static let shared = SoftwareUpdateProvider()

    @Published private(set) var snapshot: SoftwareUpdateSnapshot = .empty
    @Published private(set) var isChecking = false

    /// How often to re-check when the app is running (12h is enough).
    private static let pollInterval: TimeInterval = 12 * 3600
    /// Don’t re-run the (slow) catalog query more often than this.
    private static let minInterval: TimeInterval = 30 * 60

    private var timer: Timer?
    private var isStarted = false
    private var lastAttempt: Date?

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Delay first check slightly so launch stays snappy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkIfNeeded(force: false)
        }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfNeeded(force: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    func refresh(force: Bool = true) {
        checkIfNeeded(force: force)
    }

    private func checkIfNeeded(force: Bool) {
        if isChecking { return }
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < Self.minInterval {
            return
        }
        lastAttempt = Date()
        isChecking = true

        Task.detached(priority: .utility) {
            let result = Self.runSoftwareUpdateList()
            await MainActor.run {
                self.snapshot = result
                self.isChecking = false
            }
        }
    }

    // MARK: - Process (background)

    nonisolated private static func runSoftwareUpdateList() -> SoftwareUpdateSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["-l"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return SoftwareUpdateSnapshot(
                checkedAt: Date(),
                items: [],
                succeeded: false,
                errorMessage: error.localizedDescription
            )
        }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let combined = String(data: outData, encoding: .utf8).map { $0 } ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""
        // softwareupdate often prints progress on stderr.
        let text = (combined + "\n" + errText)

        if process.terminationStatus != 0,
           !text.localizedCaseInsensitiveContains("No new software available"),
           !text.localizedCaseInsensitiveContains("Software Update found") {
            return SoftwareUpdateSnapshot(
                checkedAt: Date(),
                items: [],
                succeeded: false,
                errorMessage: "Couldn’t query Software Update."
            )
        }

        let items = parse(text: text)
        return SoftwareUpdateSnapshot(
            checkedAt: Date(),
            items: items,
            succeeded: true,
            errorMessage: nil
        )
    }

    /// Parses `softwareupdate -l` human-readable output.
    nonisolated static func parse(text: String) -> [SoftwareUpdateItem] {
        if text.localizedCaseInsensitiveContains("No new software available") {
            return []
        }

        var items: [SoftwareUpdateItem] = []
        var currentLabel: String?
        var currentTitle: String?
        var currentVersion: String?
        var recommended = false
        var restart = false

        func flush() {
            guard let label = currentLabel else { return }
            let title = currentTitle ?? label
            items.append(SoftwareUpdateItem(
                label: label,
                title: title,
                version: currentVersion,
                recommended: recommended,
                requiresRestart: restart
            ))
            currentLabel = nil
            currentTitle = nil
            currentVersion = nil
            recommended = false
            restart = false
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") || line.hasPrefix("*Label:") {
                flush()
                let label = line
                    .replacingOccurrences(of: "* Label:", with: "")
                    .replacingOccurrences(of: "*Label:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                currentLabel = label
                continue
            }
            // Title: Foo, Version: 1.2, Size: …, Recommended: YES, Action: restart
            if line.hasPrefix("Title:") || line.contains("Title:") {
                // May appear as "Title: …" on its own line (sometimes indented under label).
                let body: String
                if let range = line.range(of: "Title:") {
                    body = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    body = line
                }
                // Title may include comma-separated fields.
                let parts = body.components(separatedBy: ", ")
                if let first = parts.first {
                    currentTitle = first.trimmingCharacters(in: .whitespaces)
                }
                for part in parts.dropFirst() {
                    let p = part.trimmingCharacters(in: .whitespaces)
                    if p.hasPrefix("Version:") {
                        currentVersion = p.replacingOccurrences(of: "Version:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    } else if p.localizedCaseInsensitiveContains("Recommended: YES") {
                        recommended = true
                    } else if p.localizedCaseInsensitiveContains("Action: restart")
                                || p.localizedCaseInsensitiveContains("restart") {
                        restart = true
                    }
                }
                if body.localizedCaseInsensitiveContains("Recommended: YES") {
                    recommended = true
                }
                if body.localizedCaseInsensitiveContains("restart") {
                    restart = true
                }
            }
        }
        flush()

        // De-dupe by label
        var seen = Set<String>()
        return items.filter { seen.insert($0.label).inserted }
    }
}
