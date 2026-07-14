import Foundation

struct MessageConversationItem: Identifiable, Equatable {
    var id: String // chat.guid
    var chatRowID: Int64
    var displayName: String
    var lastMessagePreview: String
    var lastMessageDate: Date
    var isGroupChat: Bool
}

struct MessageBubbleItem: Identifiable, Equatable {
    var id: String // message.guid (or a synthetic id for an optimistic send)
    var text: String
    var date: Date
    var isFromMe: Bool
    var senderLabel: String
}

/// There is no API to request Full Disk Access programmatically — the user
/// must grant it manually in System Settings. `.needsFullDiskAccess` is
/// detected by attempting to read chat.db, not by a permission callback.
enum MessagesAccessState: Equatable {
    case unknown
    case granted
    case needsFullDiskAccess
}

/// Decouples the Messages UI from *how* conversations are read and replies
/// are sent — same seam shape as `CalendarProvider` / `NowPlayingProvider`.
@MainActor
protocol MessagesProvider: AnyObject {
    var accessState: MessagesAccessState { get }
    var conversations: [MessageConversationItem] { get }
    var selectedChatGUID: String? { get }
    /// Messages for the currently selected conversation, oldest first.
    var messages: [MessageBubbleItem] { get }
    /// The single most recent incoming (not sent by the user) message across
    /// every conversation, with that conversation's display name. Whether
    /// this counts as "new" (versus already seen) is the plugin's job, not
    /// the provider's — mirrors how `MediaControlsPlugin` diffs track changes
    /// itself rather than the provider deciding what's peek-worthy.
    var latestIncoming: (conversationName: String, message: MessageBubbleItem)? { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    /// Re-checks Full Disk Access by attempting a read; call after the user
    /// might have just granted it in System Settings.
    func recheckAccess()
    func selectConversation(guid: String, rowID: Int64)
    func refresh()
    /// Sends to the currently selected conversation. Returns whether the
    /// AppleScript call reported success (not a delivery receipt).
    @discardableResult
    func send(text: String) -> Bool
}
