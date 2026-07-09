import AppKit
import SwiftUI

/// Notch AI assistant. Talks only to `AIProvider` — swap xAI / OpenAI / local
/// by changing config or constructor, never the views.
@MainActor
final class AIPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "ai"
    let displayName = "AI"
    let systemImage = "sparkles"

    @Published private(set) var messages: [AIMessage] = []
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published var draft: String = ""

    private let provider: AIProvider

    init(provider: AIProvider? = nil) {
        let resolved = provider ?? OpenAICompatibleProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in
            guard let self else { return }
            self.messages = self.provider.messages
            self.isBusy = self.provider.isBusy
            self.lastError = self.provider.lastError
        }
    }

    func start() {
        provider.start()
        messages = provider.messages
        isBusy = provider.isBusy
        lastError = provider.lastError
    }

    func stop() {
        provider.stop()
    }

    func collapsedView() -> AnyView {
        AnyView(CollapsedAIView(isBusy: isBusy, lastAssistant: lastAssistantSnippet))
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedAIView(plugin: self))
    }

    var lastAssistantSnippet: String? {
        messages.last(where: { $0.role == .assistant })?.content
    }

    func sendDraft() {
        let text = draft
        draft = ""
        Task { await provider.send(prompt: text, system: nil) }
    }

    func run(_ action: AIQuickAction) {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        Task { await provider.runQuickAction(action, clipboardText: clip) }
    }

    func clear() {
        provider.clearHistory()
    }

    func copyLastResponse() {
        guard let text = lastAssistantSnippet else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Views

private struct CollapsedAIView: View {
    let isBusy: Bool
    let lastAssistant: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(NotchTheme.caption.weight(.semibold))
                .foregroundStyle(isBusy ? NotchTheme.caution : NotchTheme.textPrimary)
            if isBusy {
                Text("Thinking…")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
            } else if let lastAssistant, !lastAssistant.isEmpty {
                Text(lastAssistant)
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 90, alignment: .leading)
            } else {
                Text("AI")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }
}

private struct ExpandedAIView: View {
    @ObservedObject var plugin: AIPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            HStack {
                Text("Dynamo AI")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                if plugin.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                }
                if plugin.lastAssistantSnippet != nil {
                    Button {
                        plugin.copyLastResponse()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy last reply")
                }
                if !plugin.messages.isEmpty {
                    Button("Clear") { plugin.clear() }
                        .buttonStyle(.plain)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                }
            }

            // Quick actions on clipboard — the highest-value notch interaction.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(AIQuickAction.allCases) { action in
                        Button(action.rawValue) {
                            plugin.run(action)
                        }
                        .buttonStyle(.plain)
                        .font(NotchTheme.micro.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(NotchTheme.chipFill))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .disabled(plugin.isBusy)
                    }
                }
            }

            if let error = plugin.lastError {
                Text(error)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Conversation
            if plugin.messages.isEmpty {
                Text("Ask anything, or run a clipboard action above.")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(plugin.messages.suffix(12)) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                    .onChange(of: plugin.messages.count) { _ in
                        if let last = plugin.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask Grok…", text: Binding(
                    get: { plugin.draft },
                    set: { plugin.draft = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { plugin.sendDraft() }
                .disabled(plugin.isBusy)

                Button {
                    plugin.sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            plugin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plugin.isBusy
                                ? NotchTheme.textQuaternary
                                : NotchTheme.textPrimary
                        )
                }
                .buttonStyle(.plain)
                .disabled(plugin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || plugin.isBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func messageBubble(_ message: AIMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 24) }
            Text(message.content)
                .font(NotchTheme.caption)
                .foregroundStyle(isUser ? NotchTheme.textPrimary : NotchTheme.textSecondary)
                .lineLimit(6)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isUser ? NotchTheme.chipFillActive : NotchTheme.chipFill)
                )
            if !isUser { Spacer(minLength: 24) }
        }
    }
}
