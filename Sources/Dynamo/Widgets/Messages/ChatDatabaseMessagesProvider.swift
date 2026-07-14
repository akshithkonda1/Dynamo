import Foundation
import SQLite3

/// Reads recent iMessage/SMS conversations directly from Messages.app's own
/// local SQLite database (`~/Library/Messages/chat.db`) — read-only,
/// never written to. Sending replies goes through `MessagesSendService`
/// (AppleScript driving Messages.app itself), never by inserting rows
/// directly, which would be fragile and risk corrupting the user's real
/// message history.
///
/// **Two separate OS permissions, neither requestable in-app:**
/// - **Full Disk Access** (System Settings → Privacy & Security → Full Disk
///   Access) to read chat.db at all. There is no API to prompt for this —
///   `accessState` reflects whether it's been granted by attempting a read,
///   not by any permission callback.
/// - **Automation** (System Settings → Privacy & Security → Automation), to
///   let `MessagesSendService` send Apple Events to Messages.app. macOS
///   prompts for this the first time a reply is actually sent.
///
/// No message content is ever written to Dynamo's own storage
/// (`AppSupportStore`) — conversations and messages are held only in memory
/// and re-read from chat.db on each poll. The source of truth stays exactly
/// where the user already trusts it: Messages.app's own database.
///
/// **Schema note:** chat.db's schema is stable but entirely
/// Apple-undocumented, and message text storage changed around macOS
/// Ventura — many messages now store an archived `NSAttributedString` in
/// `attributedBody` instead of plain `text`. This implementation handles
/// both. Built and reviewed without a Mac or real Messages data to test
/// against — treat the exact SQL/decoding as best-effort against a
/// community-documented-but-not-Apple-documented, version-drifting format.
@MainActor
final class ChatDatabaseMessagesProvider: MessagesProvider {
    private(set) var accessState: MessagesAccessState = .unknown
    private(set) var conversations: [MessageConversationItem] = []
    private(set) var selectedChatGUID: String?
    private(set) var messages: [MessageBubbleItem] = []
    private(set) var latestIncoming: (conversationName: String, message: MessageBubbleItem)?
    var onChange: (() -> Void)?

    private let sendService = MessagesSendService()
    private var timer: Timer?
    private var selectedChatRowID: Int64?

    private static let refreshInterval: TimeInterval = 5
    private static let conversationLimit: Int32 = 12
    private static let messageLimit: Int32 = 40

    private static let databasePath: String =
        NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath

    func start() {
        recheckAccess()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func recheckAccess() {
        accessState = FileManager.default.isReadableFile(atPath: Self.databasePath)
            ? .granted
            : .needsFullDiskAccess
    }

    func selectConversation(guid: String, rowID: Int64) {
        selectedChatGUID = guid
        selectedChatRowID = rowID
        refreshMessages()
        onChange?()
    }

    func refresh() {
        recheckAccess()
        guard accessState == .granted else {
            conversations = []
            messages = []
            latestIncoming = nil
            onChange?()
            return
        }
        refreshConversations()
        if selectedChatGUID == nil, let first = conversations.first {
            selectedChatGUID = first.id
            selectedChatRowID = first.chatRowID
        }
        refreshMessages()
        refreshLatestIncoming()
        onChange?()
    }

    @discardableResult
    func send(text: String) -> Bool {
        guard let guid = selectedChatGUID else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = sendService.send(text: trimmed, chatGUID: guid)
        if ok {
            // Optimistic echo — the next poll reconciles with the real row
            // once Messages.app actually writes it to chat.db.
            messages.append(MessageBubbleItem(
                id: "pending-\(UUID().uuidString)",
                text: trimmed,
                date: Date(),
                isFromMe: true,
                senderLabel: "Me"
            ))
            onChange?()
        }
        return ok
    }

    // MARK: - Reads

    private func refreshConversations() {
        guard let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT c.ROWID, c.guid, c.display_name, c.chat_identifier,
               (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS participant_count,
               MAX(m.date) AS last_date,
               (SELECT m2.text FROM message m2
                  JOIN chat_message_join cmj2 ON cmj2.message_id = m2.ROWID
                  WHERE cmj2.chat_id = c.ROWID AND m2.associated_message_type = 0
                  ORDER BY m2.date DESC LIMIT 1) AS last_text,
               (SELECT m3.attributedBody FROM message m3
                  JOIN chat_message_join cmj3 ON cmj3.message_id = m3.ROWID
                  WHERE cmj3.chat_id = c.ROWID AND m3.associated_message_type = 0
                  ORDER BY m3.date DESC LIMIT 1) AS last_attributed_body
        FROM chat c
        JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        JOIN message m ON m.ROWID = cmj.message_id
        WHERE m.associated_message_type = 0
        GROUP BY c.ROWID
        ORDER BY last_date DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Self.conversationLimit)

        var results: [MessageConversationItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            let guid = columnText(statement, 1) ?? "chat-\(rowID)"
            let displayNameColumn = columnText(statement, 2)
            let chatIdentifier = columnText(statement, 3) ?? "Unknown"
            let participantCount = sqlite3_column_int(statement, 4)
            let lastDateRaw = sqlite3_column_int64(statement, 5)
            let lastText = columnText(statement, 6)
            let lastAttributedBody = columnBlob(statement, 7)

            let preview = (lastText?.isEmpty == false ? lastText! : Self.decodeAttributedBody(lastAttributedBody)) ?? "…"
            let name = (displayNameColumn?.isEmpty == false ? displayNameColumn! : nil) ?? chatIdentifier

            results.append(MessageConversationItem(
                id: guid,
                chatRowID: rowID,
                displayName: name,
                lastMessagePreview: preview,
                lastMessageDate: Self.date(fromAppleTimestamp: lastDateRaw),
                isGroupChat: participantCount > 1
            ))
        }
        conversations = results
    }

    private func refreshMessages() {
        guard accessState == .granted, let rowID = selectedChatRowID, let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, h.id
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE cmj.chat_id = ? AND m.associated_message_type = 0
        ORDER BY m.date DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, rowID)
        sqlite3_bind_int(statement, 2, Self.messageLimit)

        var results: [MessageBubbleItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let msgRowID = sqlite3_column_int64(statement, 0)
            let guid = columnText(statement, 1) ?? "msg-\(msgRowID)"
            let text = columnText(statement, 2)
            let attributedBody = columnBlob(statement, 3)
            let dateRaw = sqlite3_column_int64(statement, 4)
            let isFromMe = sqlite3_column_int(statement, 5) != 0
            let senderHandle = columnText(statement, 6)

            let body = (text?.isEmpty == false ? text! : Self.decodeAttributedBody(attributedBody)) ?? ""
            guard !body.isEmpty else { continue }

            results.append(MessageBubbleItem(
                id: guid,
                text: body,
                date: Self.date(fromAppleTimestamp: dateRaw),
                isFromMe: isFromMe,
                senderLabel: isFromMe ? "Me" : (senderHandle ?? "Unknown")
            ))
        }
        // Query is newest-first; display oldest-first. Drops any "pending-"
        // optimistic echo now that the real row (or rows) have arrived.
        messages = results.reversed()
    }

    private func refreshLatestIncoming() {
        guard let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, h.id, c.display_name, c.chat_identifier
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.is_from_me = 0 AND m.associated_message_type = 0
        ORDER BY m.date DESC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            latestIncoming = nil
            return
        }

        let msgRowID = sqlite3_column_int64(statement, 0)
        let guid = columnText(statement, 1) ?? "msg-\(msgRowID)"
        let text = columnText(statement, 2)
        let attributedBody = columnBlob(statement, 3)
        let dateRaw = sqlite3_column_int64(statement, 4)
        let senderHandle = columnText(statement, 5)
        let displayName = columnText(statement, 6)
        let chatIdentifier = columnText(statement, 7)

        let body = (text?.isEmpty == false ? text! : Self.decodeAttributedBody(attributedBody)) ?? ""
        guard !body.isEmpty else {
            latestIncoming = nil
            return
        }

        let name = (displayName?.isEmpty == false ? displayName! : nil)
            ?? senderHandle
            ?? chatIdentifier
            ?? "Message"

        latestIncoming = (
            conversationName: name,
            message: MessageBubbleItem(
                id: guid,
                text: body,
                date: Self.date(fromAppleTimestamp: dateRaw),
                isFromMe: false,
                senderLabel: name
            )
        )
    }

    // MARK: - SQLite helpers

    private func openDatabase() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(Self.databasePath, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0 else { return nil }
        return Data(bytes: bytes, count: length)
    }

    // MARK: - Decoding helpers

    /// macOS 10.13+ (our minimum is 13) stores `message.date` as nanoseconds
    /// since the Core Data reference date (2001-01-01T00:00:00Z) — which is
    /// exactly `Date`'s own reference date, so no manual epoch offset is needed.
    private static func date(fromAppleTimestamp raw: Int64) -> Date {
        guard raw > 0 else { return .distantPast }
        return Date(timeIntervalSinceReferenceDate: Double(raw) / 1_000_000_000.0)
    }

    /// Since roughly macOS Ventura, `message.text` is frequently NULL and the
    /// real text lives in `attributedBody` as an archived `NSAttributedString`.
    private static func decodeAttributedBody(_ data: Data?) -> String? {
        guard let data else { return nil }
        guard let attributed = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) else {
            return nil
        }
        return attributed.string.isEmpty ? nil : attributed.string
    }
}
