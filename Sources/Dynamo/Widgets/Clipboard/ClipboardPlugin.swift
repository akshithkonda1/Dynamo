import SwiftUI

@MainActor
final class ClipboardPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "clipboard"
    let displayName = "Clipboard"
    let systemImage = "doc.on.clipboard"

    /// Tall enough for Pinned + History without compressing content upward.
    var expandedContentHeight: CGFloat { 280 }

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
    @ObservedObject private var store: ClipboardStore

    init(plugin: ClipboardPlugin) {
        self.plugin = plugin
        self._store = ObservedObject(wrappedValue: plugin.store)
    }

    var body: some View {
        // Fixed section chrome + scrollable body so Pinned items never
        // compress History / empty states upward into the tray.
        VStack(alignment: .leading, spacing: 0) {
            NotchSectionHeader("Pinned")
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    pinnedSection

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

                    Divider()
                        .overlay(NotchTheme.separator)
                        .padding(.vertical, 4)

                    NotchSectionHeader(
                        "History",
                        trailing: store.history.isEmpty
                            ? nil
                            : AnyView(
                                Button("Clear") { store.clearHistory() }
                                    .buttonStyle(.plain)
                                    .font(NotchTheme.micro)
                                    .foregroundStyle(NotchTheme.textTertiary)
                            )
                    )

                    historySection
                }
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if store.snippets.isEmpty && !plugin.isAddingSnippet {
            Text("No pins yet — star items from History or add one.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
                .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.snippets) { snippet in
                    snippetRow(snippet)
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if store.history.isEmpty {
            Text("Copy anything system-wide — it shows up here.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
                .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.history) { item in
                    historyRow(item)
                }
            }
        }
    }

    private func snippetRow(_ snippet: PinnedSnippet) -> some View {
        HStack(spacing: 6) {
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
            .help("Copy snippet")

            Button {
                store.deleteSnippet(id: snippet.id)
            } label: {
                Image(systemName: "trash")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Delete snippet")
        }
        .notchRowBackground()
    }

    private func historyRow(_ item: ClipboardHistoryItem) -> some View {
        HStack(spacing: 6) {
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
                store.pinCurrentOrText(item.text)
            } label: {
                Image(systemName: "pin")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Pin as snippet")

            Button {
                store.removeHistoryItem(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Remove from history")
        }
        .notchRowBackground()
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                .fill(NotchTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                        .strokeBorder(NotchTheme.hairline, lineWidth: 1)
                )
        )
    }
}
