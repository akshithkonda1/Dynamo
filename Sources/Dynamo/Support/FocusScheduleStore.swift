import Foundation

struct FocusScheduleEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Bitmask: Sunday = 1, Monday = 2, Tuesday = 4, ... Saturday = 64
    var weekdayMask: Int
    /// Minutes from midnight for start.
    var startMinute: Int
    /// Minutes from midnight for end.
    var endMinute: Int
    var mode: String

    var startTime: String {
        let h = startMinute / 60, m = startMinute % 60
        return String(format: "%d:%02d %@", h > 12 ? h - 12 : (h == 0 ? 12 : h), m, h >= 12 ? "PM" : "AM")
    }

    var endTime: String {
        let h = endMinute / 60, m = endMinute % 60
        return String(format: "%d:%02d %@", h > 12 ? h - 12 : (h == 0 ? 12 : h), m, h >= 12 ? "PM" : "AM")
    }

    var weekdayLabel: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var result: [String] = []
        for (i, name) in names.enumerated() {
            if weekdayMask & (1 << i) != 0 { result.append(name) }
        }
        return result.joined(separator: ", ")
    }

    func isActive(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: now) - 1
        guard weekdayMask & (1 << weekday) != 0 else { return false }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return minute >= startMinute && minute < endMinute
    }
}

@MainActor
final class FocusScheduleStore: ObservableObject {
    static let shared = FocusScheduleStore()

    private static let key = "dynamo.focus.schedule"

    @Published var entries: [FocusScheduleEntry] = []
    @Published var isEnabled: Bool = false {
        didSet { save() }
    }

    private var timer: Timer?

    private init() {
        load()
        scheduleEvaluation()
    }

    func add(_ entry: FocusScheduleEntry) {
        entries.append(entry)
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func activeMode() -> FocusBaseMode? {
        guard isEnabled else { return nil }
        let now = Date()
        for entry in entries where entry.isActive(now: now) {
            return FocusBaseMode(rawValue: entry.mode)
        }
        return nil
    }

    private func scheduleEvaluation() {
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func evaluate() {
        guard let mode = activeMode() else { return }
        if FocusController.shared.baseMode != mode {
            FocusController.shared.baseMode = mode
        }
    }

    private func save() {
        let payload: [String: Any] = [
            "enabled": isEnabled,
            "entries": (try? JSONEncoder().encode(entries)) ?? Data()
        ]
        UserDefaults.standard.set(payload, forKey: Self.key)
    }

    private func load() {
        guard let payload = UserDefaults.standard.dictionary(forKey: Self.key) else { return }
        isEnabled = payload["enabled"] as? Bool ?? false
        if let data = payload["entries"] as? Data {
            entries = (try? JSONDecoder().decode([FocusScheduleEntry].self, from: data)) ?? []
        }
    }
}
