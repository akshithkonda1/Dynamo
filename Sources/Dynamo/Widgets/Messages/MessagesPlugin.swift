import AppKit
import SwiftUI

/// Messages widget: browse recent conversations and reply, without leaving
/// the notch. Talks only to `MessagesProvider` — never touches chat.db or
/// AppleScript directly. See `ChatDatabaseMessagesProvider`'s doc comment for
/// the two OS permissions this needs and why neither can be requested in-app.
@MainActor
final class MessagesPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding, WidgetSettingsProviding {
    let id = "messages"
    let displayName = "Messages"
    let systemImage = "message.fill"

    @Published private(set) var accessState: MessagesAccessState = .unknown
    @Published private(set) var conversations: [MessageConversationItem] = []
    @Published private(set) var selectedChatGUID: String?
    @Published private(set) var messages: [MessageBubbleItem] = []
    @Published var draft: String = ""
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: MessagesProvider
    private var lastSeenIncomingID: String?
    /// The onChange right after (re)start reports whatever's already the most
    /// recent incoming message — that's Dynamo catching up, not a new
    /// message worth a peek. Same reasoning as MediaControlsPlugin's
    /// suppressNextPeek.
    private var suppressNextPeek = true

    init(provider: MessagesProvider? = nil) {
        let resolved = provider ?? ChatDatabaseMessagesProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in self?.sync() }
    }

    func start() {
        suppressNextPeek = true
        provider.start()
        sync()
    }

    func stop() {
        provider.stop()
    }

    func recheckAccess() {
        provider.recheckAccess()
        sync()
    }

    func selectConversation(_ conversation: MessageConversationItem) {
        provider.selectConversation(guid: conversation.id, rowID: conversation.chatRowID)
    }

    func refresh() {
        provider.refresh()
    }

    func sendDraft() {
        let text = draft
        draft = ""
        provider.send(text: text)
    }

    func openFullDiskAccessSettings() {
        // Prefer modern System Settings deep links; fall back to the legacy pane URL.
        // There is no public API to request Full Disk Access — this only opens the pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func expandedView() -> AnyView { AnyView(ExpandedMessagesView(plugin: self)) }
    func settingsView() -> AnyView { AnyView(MessagesSettingsView(plugin: self)) }

    private func sync() {
        accessState = provider.accessState
        conversations = provider.conversations
        selectedChatGUID = provider.selectedChatGUID
        messages = provider.messages

        if let latest = provider.latestIncoming {
            let shouldSuppress = suppressNextPeek
            suppressNextPeek = false
            if !shouldSuppress, latest.message.id != lastSeenIncomingID {
                onSneakPeek?(NotchSneakPeek(
                    systemImage: "message.fill",
                    title: latest.conversationName,
                    subtitle: latest.message.text
                ))
            }
            lastSeenIncomingID = latest.message.id
        }
    }
}

// MARK: - Views

private struct ExpandedMessagesView: View {
    @ObservedObject var plugin: MessagesPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("Messages")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
            Spacer()
            Button { plugin.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help("Refresh")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch plugin.accessState {
        case .unknown:
            Text("Checking access…")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
        case .needsFullDiskAccess:
            accessPrompt
        case .granted:
            conversationBrowser
        }
    }

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dynamo needs Full Disk Access to read Messages.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Privacy Settings") { plugin.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Check Again") { plugin.recheckAccess() }
                    .controlSize(.small)
            }
        }
    }

    private var conversationBrowser: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(plugin.conversations) { conversation in
                        conversationChip(conversation)
                    }
                }
            }

            if plugin.conversations.isEmpty {
                Text("No recent conversations.")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
            } else {
                messageList
                composer
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plugin.messages) { message in
                        bubble(message).id(message.id)
                    }
                }
            }
            .frame(maxHeight: 84)
            .onChange(of: plugin.messages.count) { _ in
                if let last = plugin.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("iMessage", text: Binding(
                get: { plugin.draft },
                set: { plugin.draft = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { plugin.sendDraft() }
            .disabled(plugin.selectedChatGUID == nil)

            Button {
                plugin.sendDraft()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        canSend ? NotchTheme.textPrimary : NotchTheme.textQuaternary
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        plugin.selectedChatGUID != nil && !plugin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func conversationChip(_ conversation: MessageConversationItem) -> some View {
        let isActive = plugin.selectedChatGUID == conversation.id
        return Button {
            plugin.selectConversation(conversation)
        } label: {
            Text(conversation.displayName)
                .font(isActive ? NotchTheme.caption.weight(.semibold) : NotchTheme.caption)
                .foregroundStyle(isActive ? NotchTheme.textPrimary : NotchTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isActive ? NotchTheme.chipFillActive : NotchTheme.chipFill))
        }
        .buttonStyle(.plain)
    }

    private func bubble(_ message: MessageBubbleItem) -> some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 24) }
            Text(message.text)
                .font(NotchTheme.caption)
                .foregroundStyle(message.isFromMe ? NotchTheme.textPrimary : NotchTheme.textSecondary)
                .lineLimit(4)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(message.isFromMe ? NotchTheme.chipFillActive : NotchTheme.chipFill)
                )
            if !message.isFromMe { Spacer(minLength: 24) }
        }
    }
}

/// Settings panel for Messages — shown generically via `WidgetSettingsProviding`.
private struct MessagesSettingsView: View {
    @ObservedObject var plugin: MessagesPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: plugin.accessState == .granted ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(plugin.accessState == .granted ? Color.green : Color.orange)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plugin.accessState != .granted {
                HStack(spacing: 8) {
                    Button("Open Full Disk Access Settings") { plugin.openFullDiskAccessSettings() }
                        .controlSize(.small)
                    Button("Check Again") { plugin.recheckAccess() }
                        .controlSize(.small)
                }
            }

            Text("Sending a reply the first time will also prompt for Automation access to Messages — that's macOS asking permission to send Apple Events, not Dynamo. Message content is never stored by Dynamo; it's read fresh from Messages' own database each time.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch plugin.accessState {
        case .granted: return "Full Disk Access granted — reading Messages."
        case .needsFullDiskAccess: return "Full Disk Access needed to read Messages."
        case .unknown: return "Checking Full Disk Access…"
        }
    }
}
