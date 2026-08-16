import AppKit
import Foundation
import SQLite3

/// Mirrors **macOS Notification Center** deliveries into Dynamo Peeks.
///
/// Apple does not publish an API to intercept other apps’ banners. This reads
/// the local `usernoted` SQLite store (same data Notification Center uses) when
/// the Mac grants access (often Full Disk Access / TCC for Group Containers).
///
/// - Only **new** deliveries after Dynamo starts (no history dump)
/// - Skips Dynamo’s own bundle
/// - Routes everything through `PeekNotificationCenter`
/// - Never raises system volume; never suppresses other apps’ banners itself
///   (user can quiet banners via Focus / System Settings while using Peek)
@MainActor
final class SystemNotificationMirror: ObservableObject {
    static let shared = SystemNotificationMirror()

    private static let enabledKey = "dynamo.peek.mirrorSystemNotifications"
    private static let lastRecKey = "dynamo.peek.mirror.lastRecID"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    @Published private(set) var lastStatus: String = "Idle"
    @Published private(set) var mirroredCount: Int = 0
    @Published private(set) var databaseFound: Bool = false
    @Published private(set) var accessDenied: Bool = false

    private var timer: Timer?
    private var highWaterRecID: Int64 = 0
    private var seenUUIDs = Set<String>()
    private let maxSeen = 400
    /// Sparse enough for battery; still catches alerts within a couple seconds.
    private let pollInterval: TimeInterval = 2.5

    private static let selfBundleID = "com.akshithkonda.Dynamo"

    /// Candidate paths for the usernoted store (varies slightly by OS).
    private static var dbCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/db2/db"
            ),
            home.appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/Library/Application Support/db2/db"
            )
        ]
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    func start() {
        guard isEnabled else { return }
        guard timer == nil else { return }
        bootstrapHighWater()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // First poll slightly delayed so launch isn’t blocked on SQLite.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.poll()
        }
        lastStatus = "Watching Notification Center"
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastStatus = "Off"
    }

    // MARK: - Bootstrap

    private func bootstrapHighWater() {
        // Prefer live max rec_id so we only mirror *new* notifications.
        if let maxID = Self.queryMaxRecID() {
            highWaterRecID = maxID
            databaseFound = true
            accessDenied = false
            UserDefaults.standard.set(maxID, forKey: Self.lastRecKey)
            lastStatus = "Synced · waiting for new alerts"
            return
        }
        // Fallback to persisted watermark if DB temporarily unreadable.
        let stored = UserDefaults.standard.object(forKey: Self.lastRecKey) as? Int64 ?? 0
        highWaterRecID = stored
        databaseFound = Self.resolveDBPath() != nil
        accessDenied = !databaseFound
        lastStatus = databaseFound
            ? "Waiting for Notification Center"
            : "Need Full Disk Access to mirror alerts"
    }

    // MARK: - Poll

    private func poll() {
        guard isEnabled else { return }
        guard let path = Self.resolveDBPath() else {
            databaseFound = false
            accessDenied = true
            lastStatus = "Notification DB not readable · grant Full Disk Access"
            return
        }
        databaseFound = true
        accessDenied = false

        let rows = Self.fetchRecords(path: path, afterRecID: highWaterRecID, limit: 40)
        guard !rows.isEmpty else {
            lastStatus = "Watching · last #\(highWaterRecID)"
            return
        }

        for row in rows {
            highWaterRecID = max(highWaterRecID, row.recID)
            guard let note = Self.parse(row) else { continue }
            if note.appIdentifier == Self.selfBundleID { continue }
            if note.appIdentifier.hasPrefix("com.akshithkonda.Dynamo") { continue }

            let uuidKey = note.uuid.isEmpty ? "\(row.recID)" : note.uuid
            if seenUUIDs.contains(uuidKey) { continue }
            seenUUIDs.insert(uuidKey)
            if seenUUIDs.count > maxSeen {
                seenUUIDs = Set(seenUUIDs.suffix(maxSeen / 2))
            }

            let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !body.isEmpty else { continue }

            let appName = Self.displayName(for: note.appIdentifier)
            let peekTitle = title.isEmpty ? appName : title
            let peekSubtitle = body.isEmpty
                ? appName
                : (title.isEmpty ? body : body)
            let detail = title.isEmpty ? "Notification" : appName

            DynamoNotificationAPI.post(
                title: peekTitle,
                subtitle: peekSubtitle,
                detail: detail,
                systemImage: Self.symbol(for: note.appIdentifier),
                urgency: Self.urgency(for: note.appIdentifier),
                category: "system",
                id: "system|\(uuidKey)"
            )
            mirroredCount &+= 1
        }

        UserDefaults.standard.set(highWaterRecID, forKey: Self.lastRecKey)
        lastStatus = "Mirrored · last #\(highWaterRecID)"
    }

    // MARK: - SQLite

    private struct RawRow {
        var recID: Int64
        var data: Data
        var deliveredDate: Double
        var appIdentifier: String
    }

    private struct ParsedNote {
        var appIdentifier: String
        var title: String
        var body: String
        var uuid: String
    }

    private static func resolveDBPath() -> String? {
        let fm = FileManager.default
        for url in dbCandidates {
            if fm.isReadableFile(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }

    private static func queryMaxRecID() -> Int64? {
        guard let path = resolveDBPath() else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT IFNULL(MAX(rec_id), 0) FROM record;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func fetchRecords(path: String, afterRecID: Int64, limit: Int) -> [RawRow] {
        var db: OpaquePointer?
        // OPEN_READONLY — do not disturb usernoted.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        // Short busy timeout; skip if locked rather than stall the main actor.
        sqlite3_busy_timeout(db, 80)

        let sql = """
        SELECT r.rec_id, r.data, IFNULL(r.delivered_date, 0), IFNULL(a.identifier, '')
        FROM record r
        LEFT JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ?
        ORDER BY r.rec_id ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, afterRecID)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [RawRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let nbytes = Int(sqlite3_column_bytes(stmt, 1))
            guard nbytes > 0 else { continue }
            let data = Data(bytes: blob, count: nbytes)
            let delivered = sqlite3_column_double(stmt, 2)
            let ident = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            rows.append(RawRow(recID: recID, data: data, deliveredDate: delivered, appIdentifier: ident))
        }
        return rows
    }

    private static func parse(_ row: RawRow) -> ParsedNote? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: row.data,
            options: [],
            format: nil
        ) as? [String: Any] else { return nil }

        let app = (root["app"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? row.appIdentifier
        let uuidData = root["uuid"] as? Data
        let uuid = uuidData?.map { String(format: "%02x", $0) }.joined() ?? "\(row.recID)"

        let req = root["req"] as? [String: Any] ?? [:]
        let title = stringValue(req["titl"] ?? req["title"])
        let body = stringValue(req["body"] ?? req["subt"] ?? req["subtitle"])

        return ParsedNote(
            appIdentifier: app.isEmpty ? row.appIdentifier : app,
            title: title,
            body: body,
            uuid: uuid
        )
    }

    private static func stringValue(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func displayName(for bundleID: String) -> String {
        if bundleID.isEmpty { return "Notification" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        // Fallback: last path component of reverse-DNS.
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    private static func symbol(for bundleID: String) -> String {
        let id = bundleID.lowercased()
        if id.contains("mail") { return "envelope.fill" }
        if id.contains("message") || id.contains("mobilesms") || id.contains("ichat") {
            return "message.fill"
        }
        if id.contains("calendar") || id.contains("ical") { return "calendar" }
        if id.contains("reminders") { return "checklist" }
        if id.contains("facetime") || id.contains("phone") { return "video.fill" }
        if id.contains("slack") || id.contains("discord") || id.contains("teams") {
            return "bubble.left.and.bubble.right.fill"
        }
        if id.contains("music") || id.contains("spotify") { return "music.note" }
        if id.contains("news") { return "newspaper.fill" }
        if id.contains("safari") || id.contains("chrome") { return "globe" }
        if id.contains("xcode") { return "hammer.fill" }
        return "bell.badge.fill"
    }

    private static func urgency(for bundleID: String) -> NotchSneakPeekUrgency {
        let id = bundleID.lowercased()
        if id.contains("message") || id.contains("mobilesms")
            || id.contains("facetime") || id.contains("phone")
            || id.contains("mail") {
            return .high
        }
        if id.contains("calendar") || id.contains("reminders") {
            return .high
        }
        if id.contains("news") { return .low }
        return .normal
    }
}
