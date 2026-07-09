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

    func collapsedView() -> AnyView {
        AnyView(CollapsedClipboardView(store: store))
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

private struct CollapsedClipboardView: View {
    @ObservedObject var store: ClipboardStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            if let latest = store.history.first {
                Text(latest.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: 90, alignment: .leading)
            } else {
                Text("Clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

private struct ExpandedClipboardView: View {
    @ObservedObject var plugin: ClipboardPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Pinned")
            if plugin.store.snippets.isEmpty && !plugin.isAddingSnippet {
                Text("No pinned snippets yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
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
                    Label("Add snippet", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.75))
            }

            Divider().overlay(Color.white.opacity(0.12))

            HStack {
                sectionHeader("History")
                Spacer()
                if !plugin.store.history.isEmpty {
                    Button("Clear") { plugin.store.clearHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            if plugin.store.history.isEmpty {
                Text("Copy anything system-wide — it shows up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .textCase(.uppercase)
    }

    private func snippetRow(_ snippet: PinnedSnippet) -> some View {
        HStack(spacing: 8) {
            Button {
                plugin.copy(snippet.text)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(snippet.text)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
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
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Delete snippet")
        }
        .padding(.vertical, 2)
    }

    private func historyRow(_ item: ClipboardHistoryItem) -> some View {
        HStack(spacing: 8) {
            Button {
                plugin.copy(item.text)
            } label: {
                Text(item.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                plugin.store.pinCurrentOrText(item.text)
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Pin as snippet")
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
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }
}
