import AppKit
import Foundation
import SQLite3

/// Read-only mirror of Calendar.app’s local database
/// (`~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb`).
/// Events only — system Reminders live in the Checklist tab.
///
/// Access may require Full Disk Access on some macOS configurations.
@MainActor
final class LocalCalendarDatabaseProvider: CalendarProvider {
    private(set) var authorizationState: CalendarAuthState = .notDetermined
    private(set) var upcoming: [CalendarEventItem] = []
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var lastSnapshotPath: URL?
    /// mtime+size fingerprint of the source db (+ its `-wal` sidecar) as of the
    /// last snapshot. Skips re-copying the whole database on every 30s tick
    /// when Calendar hasn't actually written anything since.
    private var lastSourceFingerprint: String?

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
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let lastSnapshotPath {
            let fm = FileManager.default
            try? fm.removeItem(at: lastSnapshotPath)
            try? fm.removeItem(atPath: lastSnapshotPath.path + "-wal")
            try? fm.removeItem(atPath: lastSnapshotPath.path + "-shm")
            self.lastSnapshotPath = nil
        }
        lastSourceFingerprint = nil
    }

    func requestAccess() async {
        // No TCC for file-based read; re-check readability / FDA.
        refresh()
    }

    func refresh() {
        refreshEvents()
    }

    private func refreshEvents() {
        // Optimistic seed from last successful FDA/calendar read.
        if PermissionsStore.shared.isGranted(.fullDiskAccess), authorizationState != .authorized {
            authorizationState = .authorized
        }

        let url = Self.databaseURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            authorizationState = .denied
            upcoming = []
            onChange?()
            return
        }

        // A stat()-based fingerprint alone isn't proof FDA is still granted —
        // unlike content reads, stat() can keep succeeding after FDA is
        // revoked in System Settings. Verify real read access with a cheap
        // open/close every cycle so revocation is still caught within one
        // tick, same as before this snapshot cache existed; only the
        // expensive full-file copy below is what the cache actually skips.
        guard Self.isEffectivelyReadable(url) else {
            authorizationState = .denied
            PermissionsStore.shared.recordDenied(.fullDiskAccess)
            upcoming = []
            onChange?()
            return
        }

        // Snapshot the DB so we never hold a write lock against CalendarAgent —
        // but only re-copy when the source has actually changed since the last
        // snapshot; otherwise reuse it and just re-run the (cheap, indexed)
        // time-window query below.
        let snapshot: URL
        let fingerprint = Self.sourceFingerprint(of: url)
        if let lastSnapshotPath, fingerprint != nil, fingerprint == lastSourceFingerprint,
           FileManager.default.fileExists(atPath: lastSnapshotPath.path) {
            snapshot = lastSnapshotPath
        } else if let fresh = makeSnapshot(of: url) {
            snapshot = fresh
            lastSourceFingerprint = fingerprint
        } else {
            authorizationState = .denied
            PermissionsStore.shared.recordDenied(.fullDiskAccess)
            upcoming = []
            onChange?()
            return
        }

        do {
            let events = try queryUpcoming(from: snapshot)
            upcoming = events
            authorizationState = .authorized
            PermissionsStore.shared.recordGranted(.fullDiskAccess)
        } catch {
            NSLog("Dynamo Calendar DB read failed: %@", error.localizedDescription)
            authorizationState = .denied
            upcoming = []
        }
        onChange?()
    }

    func openEvent(id: String) {
        // IDs are often "uuid|startAbs" (occurrence-stable). Prefer the UUID part.
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        let primary = parts.first ?? id
        if primary.count >= 8 {
            let encoded = primary.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? primary
            if let url = URL(string: "ical://ekevent/\(encoded)"), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Fallback: open Calendar on the occurrence day when we stored startAbs.
        if let startPart = parts.dropFirst().first, let abs = TimeInterval(startPart), abs > 0 {
            let date = Date(timeIntervalSinceReferenceDate: abs)
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

    func openNewEvent() {
        CalendarNewEventOpener.open()
    }

    func openToday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: Date())
        if let url = URL(string: "ical://\(day)"), NSWorkspace.shared.open(url) {
            return
        }
        openCalendarApp()
    }

    // MARK: - Snapshot

    /// True if the db can actually be opened for reading right now — a real
    /// content-read check, not just a stat(), so a revoked Full Disk Access
    /// grant is caught even though file metadata may still be stat-able.
    private static func isEffectivelyReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    /// Cheap "has the source changed" check — mtime + size of the main db and
    /// its `-wal` sidecar (WAL mode means real writes land there, not in the
    /// main file, until a checkpoint). Returns nil if the main db can't be
    /// stat'd, which safely forces a fresh snapshot attempt.
    private static func sourceFingerprint(of dbURL: URL) -> String? {
        let fm = FileManager.default
        guard let mainAttrs = try? fm.attributesOfItem(atPath: dbURL.path) else { return nil }
        let mainMTime = (mainAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mainSize = (mainAttrs[.size] as? Int) ?? 0

        let walPath = dbURL.path + "-wal"
        let walAttrs = try? fm.attributesOfItem(atPath: walPath)
        let walMTime = (walAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let walSize = (walAttrs?[.size] as? Int) ?? -1

        return "\(mainMTime)|\(mainSize)|\(walMTime)|\(walSize)"
    }

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

        var seen = Set<String>()
        var results: [CalendarEventItem] = []

        // 1) OccurrenceCache (expanded recurrences when CalendarAgent is fresh).
        try appendRows(
            db: db,
            sql: """
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
            """,
            now: now,
            end: end,
            seen: &seen,
            results: &results
        )

        // 2) CalendarItem fallback — OccurrenceCache often lags behind live
        //    writes (max end can trail “today”). Pull master rows still in range.
        try appendRows(
            db: db,
            sql: """
            SELECT
              ci.UUID,
              ci.summary,
              ci.start_date,
              ci.end_date,
              ci.all_day,
              c.title,
              c.color,
              loc.title,
              loc.address,
              ci.ROWID
            FROM CalendarItem ci
            JOIN Calendar c ON c.ROWID = ci.calendar_id
            LEFT JOIN Location loc ON loc.ROWID = ci.location_id
            WHERE ci.end_date >= ?
              AND ci.start_date <= ?
              AND IFNULL(ci.hidden, 0) = 0
              AND ci.start_date IS NOT NULL
              AND ci.end_date IS NOT NULL
            ORDER BY ci.start_date ASC
            LIMIT 80;
            """,
            now: now,
            end: end,
            seen: &seen,
            results: &results
        )

        results.sort { $0.start < $1.start }
        if results.count > 40 {
            results = Array(results.prefix(40))
        }
        return results
    }

    private func appendRows(
        db: OpaquePointer,
        sql: String,
        now: Double,
        end: Double,
        seen: inout Set<String>,
        results: inout [CalendarEventItem]
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CalendarDBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_double(stmt, 2, end)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = stringColumn(stmt, 0) ?? ""
            let summary = stringColumn(stmt, 1)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let startAbs = sqlite3_column_double(stmt, 2)
            let endAbs = sqlite3_column_double(stmt, 3)
            // Skip malformed rows (null dates bind as 0).
            guard startAbs > 0, endAbs > 0, endAbs >= startAbs else { continue }
            let allDay = sqlite3_column_int(stmt, 4) != 0
            let calName = stringColumn(stmt, 5) ?? "Calendar"
            let colorHex = stringColumn(stmt, 6)
            let locTitle = stringColumn(stmt, 7)
            let locAddress = stringColumn(stmt, 8)
            let rowID = sqlite3_column_int64(stmt, 9)

            let title = (summary?.isEmpty == false) ? summary! : "Untitled"
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

            let id = uuid.isEmpty ? "\(rowID)|\(startAbs)" : "\(uuid)|\(startAbs)"

            results.append(CalendarEventItem(
                id: id,
                title: title,
                start: Date(timeIntervalSinceReferenceDate: startAbs),
                end: Date(timeIntervalSinceReferenceDate: endAbs),
                calendarColor: Self.parseColor(colorHex),
                isAllDay: allDay,
                calendarName: calName,
                location: location,
                notes: nil,
                attendees: []
            ))
        }
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
