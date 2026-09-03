import AppKit
import Foundation
import SQLite3

/// **Routes** macOS Notification Center deliveries into Dynamo’s **Peek hub** —
/// the same inbox as reminders, calendar, battery, and media Peeks.
///
/// This is not a second “mirror” surface: alerts are **ingested into the hub**
/// and presented as notch Peeks. Apple does not publish an API to suppress
/// system banners; set each app’s Alert style to **None** (keep Allow Notifications on)
/// so Peek is the banner and Hub is the inbox.
///
/// Implementation reads the local `usernoted` SQLite store when TCC allows
/// (Full Disk Access / Group Containers).
///
/// - Only **new** deliveries after Dynamo starts (no history dump)
/// - Skips Dynamo’s own bundle
/// - Prioritizes **calls, texts/iMessage, mail** as high/critical
/// - Everything goes through `PeekNotificationCenter` / `DynamoNotificationAPI`
@MainActor
final class SystemNotificationMirror: ObservableObject {
    static let shared = SystemNotificationMirror()

    private static let enabledKey = "dynamo.peek.mirrorSystemNotifications"
    private static let lastRecKey = "dynamo.peek.mirror.lastRecID"
    private static let preferCallsKey = "dynamo.peek.mirror.prioritizeCallsTexts"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    /// When true (default), phone / FaceTime / Messages get critical urgency.
    @Published var prioritizeCallsAndTexts: Bool {
        didSet {
            UserDefaults.standard.set(prioritizeCallsAndTexts, forKey: Self.preferCallsKey)
        }
    }

    @Published private(set) var lastStatus: String = "Idle"
    @Published private(set) var mirroredCount: Int = 0
    @Published private(set) var databaseFound: Bool = false
    @Published private(set) var accessDenied: Bool = false
    @Published private(set) var lastMirroredApp: String = ""

    private var timer: Timer?
    private var highWaterRecID: Int64 = 0
    private var seenUUIDs = Set<String>()
    private let maxSeen = 500
    /// Snappy enough for texts/calls; light on SQLite.
    private let pollInterval: TimeInterval = 1.0

    private static let selfBundleID = "com.akshithkonda.Dynamo"

    /// Candidate paths for the usernoted store (varies by OS generation).
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
            isEnabled = false
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.preferCallsKey) == nil {
            prioritizeCallsAndTexts = true
        } else {
            prioritizeCallsAndTexts = UserDefaults.standard.bool(forKey: Self.preferCallsKey)
        }
    }

    func start() {
        guard isEnabled else { return }
        guard timer == nil else { return }
        bootstrapHighWater()
        seedRecentNotifications()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // First poll quickly so first text/call after launch isn’t delayed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.poll()
        }
        lastStatus = databaseFound
            ? "Routing system apps into Peek hub"
            : "Waiting for Notification Center access"
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastStatus = "Off"
    }

    // MARK: - Bootstrap

    private func bootstrapHighWater() {
        if let maxID = Self.queryMaxRecID() {
            highWaterRecID = maxID
            databaseFound = true
            accessDenied = false
            UserDefaults.standard.set(maxID, forKey: Self.lastRecKey)
            lastStatus = "Hub ready · routing new system alerts"
            return
        }
        let stored = UserDefaults.standard.object(forKey: Self.lastRecKey) as? Int64 ?? 0
        highWaterRecID = stored
        databaseFound = Self.resolveDBPath() != nil
        accessDenied = !databaseFound
        lastStatus = databaseFound
            ? "Waiting for Notification Center"
            : "Need Full Disk Access to route calls & texts into the hub"
    }

    /// Pull the latest Mac notifications into Hub (inbox only) so Dynamo
    /// behaves like Notification Center, not a firehose of old Peeks.
    private func seedRecentNotifications() {
        guard isEnabled, let path = Self.resolveDBPath() else { return }
        let rows = Self.fetchRecentRecords(path: path, limit: 40)
        guard !rows.isEmpty else { return }
        databaseFound = true
        accessDenied = false
        for row in rows {
            highWaterRecID = max(highWaterRecID, row.recID)
            ingest(row, presentPeek: false)
        }
        UserDefaults.standard.set(highWaterRecID, forKey: Self.lastRecKey)
        lastStatus = "Hub seeded · \(rows.count) from this Mac"
    }

    private func ingest(_ row: RawRow, presentPeek: Bool) {
        guard let note = Self.parse(row) else { return }
        if note.appIdentifier == Self.selfBundleID { return }
        if note.appIdentifier.hasPrefix("com.akshithkonda.Dynamo") { return }

        let uuidKey = note.uuid.isEmpty ? "\(row.recID)" : note.uuid
        if seenUUIDs.contains(uuidKey) { return }
        seenUUIDs.insert(uuidKey)
        if seenUUIDs.count > maxSeen {
            seenUUIDs = Set(seenUUIDs.suffix(maxSeen / 2))
        }

        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else { return }

        let kind = NotificationKind.classify(bundleID: note.appIdentifier, title: title, body: body)
        let appName = Self.displayName(for: note.appIdentifier)
        let peekTitle: String
        let peekSubtitle: String
        let detail: String

        switch kind {
        case .call:
            peekTitle = title.isEmpty ? "Incoming call" : title
            peekSubtitle = body.isEmpty ? appName : body
            detail = "Call · \(appName)"
        case .text:
            peekTitle = title.isEmpty ? "Message" : title
            peekSubtitle = body.isEmpty ? appName : body
            detail = "Text · \(appName)"
        case .mail:
            peekTitle = title.isEmpty ? "Mail" : title
            peekSubtitle = body.isEmpty ? appName : body
            detail = "Mail · \(appName)"
        case .general:
            peekTitle = title.isEmpty ? appName : title
            peekSubtitle = body.isEmpty ? appName : (title.isEmpty ? body : body)
            detail = appName
        }

        let urgency = urgency(for: kind)
        let artwork = resolveArtwork(
            kind: kind,
            title: peekTitle,
            subtitle: peekSubtitle,
            note: note
        )
        DynamoNotificationRouter.shared.route(
            title: peekTitle,
            subtitle: peekSubtitle,
            detail: detail,
            systemImage: kind.systemImage,
            urgency: urgency,
            source: kind == .call ? .call : .system,
            category: kind.category,
            id: "system|\(kind.category)|\(uuidKey)",
            artworkData: artwork,
            present: presentPeek,
            sourceBundleID: note.appIdentifier,
            appName: appName
        )
        mirroredCount &+= 1
        lastMirroredApp = appName
    }

    // MARK: - Poll

    private func poll() {
        guard isEnabled else { return }
        guard let path = Self.resolveDBPath() else {
            databaseFound = false
            accessDenied = true
            lastStatus = "Notification DB locked · grant Full Disk Access"
            return
        }
        databaseFound = true
        accessDenied = false

        let rows = Self.fetchRecords(path: path, afterRecID: highWaterRecID, limit: 60)
        guard !rows.isEmpty else {
            lastStatus = "Hub idle · last #\(highWaterRecID)"
            return
        }

        for row in rows {
            highWaterRecID = max(highWaterRecID, row.recID)
            ingest(row, presentPeek: true)
        }

        UserDefaults.standard.set(highWaterRecID, forKey: Self.lastRecKey)
        lastStatus = "Routed \(mirroredCount) into hub · last #\(highWaterRecID)"
    }

    private func urgency(for kind: NotificationKind) -> NotchSneakPeekUrgency {
        switch kind {
        case .call:
            return prioritizeCallsAndTexts ? .critical : .high
        case .text:
            return prioritizeCallsAndTexts ? .critical : .high
        case .mail:
            return .high
        case .general:
            return .normal
        }
    }

    /// Artwork for Peek chrome. **Message peeks** always try contact photo tinting.
    private func resolveArtwork(
        kind: NotificationKind,
        title: String,
        subtitle: String,
        note: ParsedNote
    ) -> Data? {
        // 1) Image embedded in the notification payload (when present).
        if let embedded = note.imageData, !embedded.isEmpty, NSImage(data: embedded) != nil {
            return embedded
        }

        switch kind {
        case .text:
            // Messages / iMessage / SMS / messengers — resolve contact photo aggressively
            // so the Peek wash/ring/lip match the contact photo colors.
            return ContactPhotoResolver.imageDataForMessage(title: title, body: subtitle)
                ?? ContactPhotoResolver.imageDataForMessage(title: title, body: note.body)
        case .call:
            // Incoming call name → same photo when available.
            return ContactPhotoResolver.imageData(matchingName: title)
                ?? ContactPhotoResolver.imageDataForMessage(title: title, body: subtitle)
        case .mail, .general:
            return nil
        }
    }

    // MARK: - Kind classification

    enum NotificationKind {
        case call
        case text
        case mail
        case general

        var category: String {
            switch self {
            case .call: return "call"
            case .text: return "text"
            case .mail: return "mail"
            case .general: return "system"
            }
        }

        var systemImage: String {
            switch self {
            case .call: return "phone.fill"
            case .text: return "message.fill"
            case .mail: return "envelope.fill"
            case .general: return "bell.badge.fill"
            }
        }

        static func classify(bundleID: String, title: String, body: String) -> NotificationKind {
            let id = bundleID.lowercased()
            let blob = "\(title) \(body)".lowercased()

            // Calls / FaceTime / Phone Continuity
            if id.contains("facetime")
                || id.contains("incallservice")
                || id.contains("telephony")
                || id.contains("mobilephone")
                || id == "com.apple.phone"
                || id.contains("com.apple.callkit")
                || blob.contains("facetime")
                || blob.contains("is calling")
                || blob.contains("incoming call")
                || blob.contains("missed call") {
                return .call
            }

            // Texts / iMessage / SMS / popular messengers
            if id.contains("mobilesms")
                || id.contains("messages")
                || id.contains("ichat")
                || id == "com.apple.MobileSMS"
                || id.contains("whatsapp")
                || id.contains("telegram")
                || id.contains("signal")
                || id.contains("imessage")
                || id.contains("texts.com")
                || id.contains("discord") && blob.contains("message") {
                return .text
            }

            if id.contains("mail") || id.contains("spark") || id.contains("airmail")
                || id.contains("outlook") || id.contains("superhuman") {
                return .mail
            }

            // Slack/Teams often behave like “texts” for urgency when prioritized.
            if id.contains("slack") || id.contains("teams") || id.contains("discord") {
                return .text
            }

            return .general
        }
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
        /// Optional image payload from the notification blob (rare).
        var imageData: Data? = nil
    }

    private static func resolveDBPath() -> String? {
        let fm = FileManager.default
        for url in dbCandidates {
            if fm.isReadableFile(atPath: url.path) {
                // Skip empty decoys.
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber,
                   size.intValue < 64 {
                    continue
                }
                return url.path
            }
        }
        return nil
    }

    private static func openDB(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        // URI immutable helps when usernoted holds a write lock.
        let uri = "file:\(path)?immutable=1&mode=ro"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 120)
            return db
        }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 120)
            return db
        }
        return nil
    }

    private static func queryMaxRecID() -> Int64? {
        guard let path = resolveDBPath(), let db = openDB(path) else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT IFNULL(MAX(rec_id), 0) FROM record;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func fetchRecords(path: String, afterRecID: Int64, limit: Int) -> [RawRow] {
        guard let db = openDB(path) else { return [] }
        defer { sqlite3_close(db) }

        // Primary schema (Sequoia+ group container).
        let sql = """
        SELECT r.rec_id, r.data, IFNULL(r.delivered_date, 0), IFNULL(a.identifier, '')
        FROM record r
        LEFT JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ?
        ORDER BY r.rec_id ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            // Fallback: some builds omit delivered_date join.
            let alt = """
            SELECT rec_id, data, 0, ''
            FROM record
            WHERE rec_id > ?
            ORDER BY rec_id ASC
            LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, alt, -1, &stmt, nil) == SQLITE_OK else { return [] }
        }
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

    /// Newest-first snapshot for Hub seeding (Notification Center style).
    private static func fetchRecentRecords(path: String, limit: Int) -> [RawRow] {
        guard let db = openDB(path) else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT r.rec_id, r.data, IFNULL(r.delivered_date, 0), IFNULL(a.identifier, '')
        FROM record r
        LEFT JOIN app a ON a.app_id = r.app_id
        ORDER BY r.rec_id DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let alt = """
            SELECT rec_id, data, 0, ''
            FROM record
            ORDER BY rec_id DESC
            LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, alt, -1, &stmt, nil) == SQLITE_OK else { return [] }
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
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
        return rows.reversed()
    }

    private static func parse(_ row: RawRow) -> ParsedNote? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: row.data,
            options: [],
            format: nil
        ) as? [String: Any] else { return nil }

        let app = firstString(in: root, keys: ["app", "bundleID", "bundleId", "appIdentifier"])
            ?? row.appIdentifier

        let uuid: String = {
            if let d = root["uuid"] as? Data {
                return d.map { String(format: "%02x", $0) }.joined()
            }
            if let s = root["uuid"] as? String, !s.isEmpty { return s }
            if let s = root["identifier"] as? String, !s.isEmpty { return s }
            return "\(row.recID)"
        }()

        // Nested request / content shapes vary by OS + app.
        let req = (root["req"] as? [String: Any])
            ?? (root["request"] as? [String: Any])
            ?? [:]
        let content = (req["cont"] as? [String: Any])
            ?? (req["content"] as? [String: Any])
            ?? (root["content"] as? [String: Any])
            ?? [:]
        let userInfo = (req["userInfo"] as? [String: Any])
            ?? (content["userInfo"] as? [String: Any])
            ?? [:]

        var title = firstString(in: req, keys: ["titl", "title", "Title"])
            ?? firstString(in: content, keys: ["title", "titl", "Title"])
            ?? firstString(in: root, keys: ["title", "titl"])
            ?? firstString(in: userInfo, keys: ["title", "aps.alert.title"])
            ?? ""
        var body = firstString(in: req, keys: ["body", "subt", "subtitle", "Subtitle", "Body"])
            ?? firstString(in: content, keys: ["body", "subtitle", "subt", "Body"])
            ?? firstString(in: root, keys: ["body", "subtitle"])
            ?? firstString(in: userInfo, keys: ["body", "message", "aps.alert.body"])
            ?? ""

        // aps.alert nested
        if title.isEmpty || body.isEmpty,
           let aps = userInfo["aps"] as? [String: Any] {
            if let alert = aps["alert"] as? [String: Any] {
                if title.isEmpty { title = stringValue(alert["title"]) }
                if body.isEmpty { body = stringValue(alert["body"] ?? alert["subtitle"]) }
            } else if let alert = aps["alert"] as? String, body.isEmpty {
                body = alert
            }
        }

        let imageData = extractImageData(from: root)
            ?? extractImageData(from: req)
            ?? extractImageData(from: content)
            ?? extractImageData(from: userInfo)

        return ParsedNote(
            appIdentifier: app.isEmpty ? row.appIdentifier : app,
            title: title,
            body: body,
            uuid: uuid,
            imageData: imageData
        )
    }

    /// Best-effort scan for image-bearing Data blobs (attachments / icons).
    private static func extractImageData(from dict: [String: Any]) -> Data? {
        let imageKeys = [
            "image", "icon", "attachment", "attachments", "thumb", "thumbnail",
            "imageData", "iconData", "contentImage", "avatar"
        ]
        for key in imageKeys {
            if let data = dict[key] as? Data, isImageData(data) { return data }
            if let arr = dict[key] as? [Any] {
                for item in arr {
                    if let data = item as? Data, isImageData(data) { return data }
                    if let nested = item as? [String: Any],
                       let data = extractImageData(from: nested) {
                        return data
                    }
                }
            }
            if let nested = dict[key] as? [String: Any],
               let data = extractImageData(from: nested) {
                return data
            }
        }
        // Shallow walk of Data values (limit to avoid heavy scans).
        var checked = 0
        for (_, value) in dict {
            checked += 1
            if checked > 40 { break }
            if let data = value as? Data, isImageData(data) { return data }
        }
        return nil
    }

    private static func isImageData(_ data: Data) -> Bool {
        guard data.count > 24, data.count < 2_500_000 else { return false }
        // JPEG
        if data[0] == 0xFF, data[1] == 0xD8 { return true }
        // PNG
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        // GIF
        if data.starts(with: [0x47, 0x49, 0x46]) { return true }
        // HEIC / ftyp
        if data.count > 12 {
            let ftyp = data.subdata(in: 4..<8)
            if ftyp == Data("ftyp".utf8) { return true }
        }
        // TIFF
        if data.starts(with: [0x49, 0x49]) || data.starts(with: [0x4D, 0x4D]) { return true }
        return false
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if k.contains(".") {
                // Simple one-level dotted path not used; skip.
                continue
            }
            let s = stringValue(dict[k])
            if !s.isEmpty { return s }
        }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let d = any as? Data, let s = String(data: d, encoding: .utf8) { return s }
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
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        switch last.lowercased() {
        case "mobilesms": return "Messages"
        case "facetime": return "FaceTime"
        case "mail": return "Mail"
        default: return last
        }
    }
}
