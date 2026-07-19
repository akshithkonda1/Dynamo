import AppKit
import Foundation
import SQLite3

/// Read-only mirror of Calendar.app’s local database
/// (`~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb`).
///
/// No EventKit permission prompt — Dynamo only *reads* the same store Calendar
/// already maintains. Nothing is written. Clicking an event opens Calendar.app.
///
/// Access may require Full Disk Access on some macOS configurations. If the DB
/// can’t be opened, `accessState`
/// surfaces that so Settings can point the user at FDA.
@MainActor
final class LocalCalendarDatabaseProvider: CalendarProvider {
    private(set) var authorizationState: CalendarAuthState = .notDetermined
    private(set) var upcoming: [CalendarEventItem] = []
    private(set) var dueReminders: [ReminderItem] = []
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var lastSnapshotPath: URL?

    /// Calendar.app’s shared group container DB (modern macOS).
    private static var databaseURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Group Containers/group.com.apple.calendar", isDirectory: true)
            .appendingPathComponent("Calendar.sqlitedb")
    }

    func start() {
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Register once on `.common` so tracking/scroll doesn't stall refreshes.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let lastSnapshotPath {
            try? FileManager.default.removeItem(at: lastSnapshotPath)
            self.lastSnapshotPath = nil
        }
    }

    func requestAccess() async {
        // No TCC prompt for file-based read; re-check readability / FDA.
        refresh()
    }

    func refresh() {
        // Optimistic seed from last successful FDA/calendar read.
        if PermissionsStore.shared.isGranted(.fullDiskAccess), authorizationState != .authorized {
            authorizationState = .authorized
        }

        let url = Self.databaseURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            authorizationState = .denied
            upcoming = []
            dueReminders = []
            onChange?()
            return
        }

        // Snapshot the DB so we never hold a write lock against CalendarAgent.
        // Copy main db + WAL + SHM for a consistent read when possible.
        guard let snapshot = makeSnapshot(of: url) else {
            authorizationState = .denied
            PermissionsStore.shared.recordDenied(.fullDiskAccess)
            upcoming = []
            dueReminders = []
            onChange?()
            return
        }

        do {
            let events = try queryUpcoming(from: snapshot)
            upcoming = events
            authorizationState = .authorized
            PermissionsStore.shared.recordGranted(.fullDiskAccess)
            dueReminders = [] // Reminders live in a different store; keep EventKit-free for now.
        } catch {
            NSLog("Dynamo Calendar DB read failed: %@", error.localizedDescription)
            authorizationState = .denied
            upcoming = []
        }
        onChange?()
    }

    func openEvent(id: String) {
        // Prefer Calendar deep link by UUID when we stored one.
        if id.count >= 8 {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            if let url = URL(string: "ical://ekevent/\(encoded)"), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Fallback: open Calendar to a day if id encodes a timestamp.
        if let interval = TimeInterval(id), interval > 0 {
            let date = Date(timeIntervalSinceReferenceDate: interval)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            let day = formatter.string(from: date)
            if let url = URL(string: "ical://\(day)"), NSWorkspace.shared.open(url) {
                return
            }
        }
        openCalendarApp()
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }

    // MARK: - Snapshot

    private func makeSnapshot(of dbURL: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("DynamoCalendarSnapshots", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Clean previous snapshot
        if let lastSnapshotPath {
            try? fm.removeItem(at: lastSnapshotPath)
            let base = lastSnapshotPath.path
            try? fm.removeItem(atPath: base + "-wal")
            try? fm.removeItem(atPath: base + "-shm")
        }

        let dest = dir.appendingPathComponent("Calendar-\(UUID().uuidString).sqlitedb")
        do {
            try fm.copyItem(at: dbURL, to: dest)
            // Best-effort WAL/SHM copy for freshest data
            let wal = URL(fileURLWithPath: dbURL.path + "-wal")
            let shm = URL(fileURLWithPath: dbURL.path + "-shm")
            if fm.fileExists(atPath: wal.path) {
                try? fm.copyItem(at: wal, to: URL(fileURLWithPath: dest.path + "-wal"))
            }
            if fm.fileExists(atPath: shm.path) {
                try? fm.copyItem(at: shm, to: URL(fileURLWithPath: dest.path + "-shm"))
            }
            lastSnapshotPath = dest
            return dest
        } catch {
            // Unreadable — typically Full Disk Access not granted.
            return nil
        }
    }

    // MARK: - Query

    private func queryUpcoming(from dbURL: URL) throws -> [CalendarEventItem] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw CalendarDBError.openFailed
        }
        defer { sqlite3_close(db) }

        // Apple Absolute Time window: now → +14 days (local wall-clock converted
        // via Foundation reference date, which matches Calendar’s start_date).
        let now = Date().timeIntervalSinceReferenceDate
        let end = now + 14 * 24 * 60 * 60

        // Include in-progress events (end still ahead) plus anything starting
        // within the next two weeks — not only start ≥ now.
        let sql = """
        SELECT
          ci.UUID,
          ci.summary,
          oc.occurrence_start_date,
          oc.occurrence_end_date,
          ci.all_day,
          c.title,
          c.color,
          loc.title,
          loc.address,
          ci.ROWID
        FROM OccurrenceCache oc
        JOIN CalendarItem ci ON ci.ROWID = oc.event_id
        JOIN Calendar c ON c.ROWID = oc.calendar_id
        LEFT JOIN Location loc ON loc.ROWID = ci.location_id
        WHERE oc.occurrence_end_date >= ?
          AND oc.occurrence_start_date <= ?
          AND IFNULL(ci.hidden, 0) = 0
        ORDER BY oc.occurrence_start_date ASC
        LIMIT 80;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CalendarDBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_double(stmt, 2, end)

        var seen = Set<String>()
        var results: [CalendarEventItem] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = stringColumn(stmt, 0) ?? ""
            let summary = stringColumn(stmt, 1)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let startAbs = sqlite3_column_double(stmt, 2)
            let endAbs = sqlite3_column_double(stmt, 3)
            let allDay = sqlite3_column_int(stmt, 4) != 0
            let calName = stringColumn(stmt, 5) ?? "Calendar"
            let colorHex = stringColumn(stmt, 6)
            let locTitle = stringColumn(stmt, 7)
            let locAddress = stringColumn(stmt, 8)
            let rowID = sqlite3_column_int64(stmt, 9)

            let title = (summary?.isEmpty == false) ? summary! : "Untitled"
            // Deduplicate multi-day cache rows for the same occurrence.
            let dedupeKey = "\(uuid.isEmpty ? "\(rowID)" : uuid)|\(startAbs)"
            if seen.contains(dedupeKey) { continue }
            seen.insert(dedupeKey)

            let location: String?
            if let locTitle, !locTitle.isEmpty {
                location = locTitle
            } else if let locAddress, !locAddress.isEmpty {
                location = locAddress
            } else {
                location = nil
            }

            let id = uuid.isEmpty ? "\(rowID)|\(startAbs)" : uuid

            results.append(CalendarEventItem(
                id: id,
                title: title,
                start: Date(timeIntervalSinceReferenceDate: startAbs),
                end: Date(timeIntervalSinceReferenceDate: endAbs),
                calendarColor: Self.parseColor(colorHex),
                isAllDay: allDay,
                calendarName: calName,
                location: location
            ))

            if results.count >= 40 { break }
        }

        return results
    }

    private func stringColumn(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func parseColor(_ hex: String?) -> CodableColor? {
        guard var h = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        // Support RRGGBB or RRGGBBAA
        guard h.count == 6 || h.count == 8, let value = UInt32(h, radix: 16) else { return nil }
        let hasAlpha = h.count == 8
        let r: Double
        let g: Double
        let b: Double
        let a: Double
        if hasAlpha {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        return CodableColor(red: r, green: g, blue: b, alpha: a)
    }

    private enum CalendarDBError: LocalizedError {
        case openFailed
        case prepareFailed
        var errorDescription: String? {
            switch self {
            case .openFailed: return "Could not open Calendar database (check Full Disk Access)."
            case .prepareFailed: return "Could not query Calendar database."
            }
        }
    }
}
