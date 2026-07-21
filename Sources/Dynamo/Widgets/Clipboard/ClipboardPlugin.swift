import SwiftUI

@MainActor
final class ClipboardPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "clipboard"
    let displayName = "Clipboard"
    let systemImage = "doc.on.clipboard"

    let store = ClipboardStore()

    @Published var draftTitle: String = ""
    @Published var draftBody: String = ""
    @Published var isAddingSnippet = false

    func start() {
        store.start()
    }

    func stop() {
        store.stop()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedClipboardView(plugin: self))
    }

    func copy(_ text: String) {
        store.copyToPasteboard(text)
    }

    func saveDraftSnippet() {
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        store.pinCurrentOrText(body, title: draftTitle)
        draftTitle = ""
        draftBody = ""
        isAddingSnippet = false
    }
}

// MARK: - Views

private struct ExpandedClipboardView: View {
    @ObservedObject var plugin: ClipboardPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotchSectionHeader("Pinned")
            if plugin.store.snippets.isEmpty && !plugin.isAddingSnippet {
                NotchEmptyState(
                    systemImage: "pin",
                    title: "No pinned snippets",
                    caption: "Pin from history or add one below."
                )
            } else {
                ForEach(plugin.store.snippets) { snippet in
                    snippetRow(snippet)
                }
            }

            if plugin.isAddingSnippet {
                addSnippetForm
            } else {
                Button {
                    plugin.isAddingSnippet = true
                } label: {
                    NotchChipLabel(title: "Add snippet", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(NotchTheme.separator)

            NotchSectionHeader(
                "History",
                trailing: plugin.store.history.isEmpty
                    ? nil
                    : AnyView(
                        Button("Clear") { plugin.store.clearHistory() }
                            .buttonStyle(.plain)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                    )
            )

            if plugin.store.history.isEmpty {
                NotchEmptyState(
                    systemImage: "doc.on.clipboard",
                    title: "Clipboard history is empty",
                    caption: "Copy anything system-wide — it shows up here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plugin.store.history) { item in
                            historyRow(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func snippetRow(_ snippet: PinnedSnippet) -> some View {
        HStack(spacing: 4) {
            Button {
                plugin.copy(snippet.text)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.title)
                        .font(NotchTheme.body.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    Text(snippet.text)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                plugin.store.deleteSnippet(id: snippet.id)
            } label: {
                Image(systemName: "trash")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Delete snippet")
        }
        .padding(.vertical, 2)
    }

    private func historyRow(_ item: ClipboardHistoryItem) -> some View {
        HStack(spacing: 4) {
            Button {
                plugin.copy(item.text)
            } label: {
                Text(item.text)
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy again")

            Button {
                plugin.store.pinCurrentOrText(item.text)
            } label: {
                Image(systemName: "pin")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Pin as snippet")

            Button {
                plugin.store.removeHistoryItem(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Remove from history")
        }
    }

    private var addSnippetForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: Binding(
                get: { plugin.draftTitle },
                set: { plugin.draftTitle = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            TextField("Body", text: Binding(
                get: { plugin.draftBody },
                set: { plugin.draftBody = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") { plugin.saveDraftSnippet() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") {
                    plugin.isAddingSnippet = false
                    plugin.draftTitle = ""
                    plugin.draftBody = ""
                }
                .buttonStyle(.plain)
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous).fill(NotchTheme.chipFill))
    }
}
