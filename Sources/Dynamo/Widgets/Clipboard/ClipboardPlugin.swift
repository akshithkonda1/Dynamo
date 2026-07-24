import AppKit
import SwiftUI

@MainActor
final class ClipboardPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding, WidgetSettingsProviding {
    let id = "clipboard"
    let displayName = "Clipboard"
    let systemImage = "doc.on.clipboard"

    var expandedContentHeight: CGFloat { 255 }
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    let store = ClipboardStore()

    @Published var draftTitle: String = ""
    @Published var draftBody: String = ""
    @Published var isAddingSnippet = false

    func start() {
        store.start()
        store.onNewItem = { [weak self] item in
            guard let self else { return }
            let peek: NotchSneakPeek
            switch item.kind {
            case .text:
                let preview = String(item.text.prefix(60))
                peek = NotchSneakPeek(
                    systemImage: "doc.on.clipboard",
                    title: "Copied",
                    subtitle: preview,
                    urgency: .low
                )
            case .image:
                peek = NotchSneakPeek(
                    systemImage: "photo.on.rectangle",
                    title: "Copied",
                    subtitle: "Image",
                    urgency: .low
                )
            }
            guard !FocusController.shared.shouldSuppress(peek: peek) else { return }
            self.onSneakPeek?(peek)
        }
    }

    func stop() {
        store.onNewItem = nil
        store.stop()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedClipboardView(plugin: self))
    }

    func settingsView() -> AnyView {
        AnyView(ClipboardSettingsView())
    }

    func saveDraftSnippet() {
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        store.pinCurrentOrText(body, title: draftTitle)
        draftTitle = ""
        draftBody = ""
        isAddingSnippet = false
    }

    func stripFormatting() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.copyToPasteboard(text)
    }

    var canStripFormatting: Bool {
        NSPasteboard.general.availableType(from: [.string]) != nil
    }
}

// MARK: - Views

private struct ExpandedClipboardView: View {
    @ObservedObject var plugin: ClipboardPlugin
    @ObservedObject private var store: ClipboardStore
    @State private var searchQuery = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""

    private static let timeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init(plugin: ClipboardPlugin) {
        self.plugin = plugin
        self._store = ObservedObject(wrappedValue: plugin.store)
    }

    var body: some View {
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

                    if !store.history.isEmpty {
                        TextField("Search history…", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .font(NotchTheme.caption)
                    }

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
            Text("No pins yet — pin from History or add text.")
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
        let filtered = store.history.filter {
            searchQuery.isEmpty || $0.text.localizedCaseInsensitiveContains(searchQuery)
        }
        if store.history.isEmpty {
            Text("Copy text or a screenshot — it shows up here.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
                .padding(.vertical, 2)
        } else if filtered.isEmpty {
            Text("No results for \"\(searchQuery)\".")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
                .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(filtered) { item in
                    historyRow(item)
                }
            }
        }
    }

    private func snippetRow(_ snippet: PinnedSnippet) -> some View {
        HStack(spacing: 8) {
            Button {
                store.copySnippet(snippet)
            } label: {
                HStack(spacing: 8) {
                    if snippet.kind == .image {
                        thumb(fileName: snippet.imageFileName)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if renamingID == snippet.id {
                            TextField("Title", text: $renameText)
                                .font(NotchTheme.body.weight(.semibold))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !t.isEmpty { store.renameSnippet(id: snippet.id, title: t) }
                                    renamingID = nil
                                }
                        } else {
                            Text(snippet.title)
                                .font(NotchTheme.body.weight(.semibold))
                                .foregroundStyle(NotchTheme.textPrimary)
                                .lineLimit(1)
                                .onTapGesture {
                                    renameText = snippet.title
                                    renamingID = snippet.id
                                }
                        }
                        if snippet.kind == .text {
                            Text(snippet.text)
                                .font(NotchTheme.micro)
                                .foregroundStyle(NotchTheme.textTertiary)
                                .lineLimit(1)
                        } else {
                            Text("Image")
                                .font(NotchTheme.micro)
                                .foregroundStyle(NotchTheme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")

            Button {
                store.deleteSnippet(id: snippet.id)
            } label: {
                Image(systemName: "trash")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Delete pin")
        }
        .notchRowBackground()
    }

    private func historyRow(_ item: ClipboardHistoryItem) -> some View {
        HStack(spacing: 8) {
            Button {
                store.copyHistoryItem(item)
            } label: {
                HStack(spacing: 8) {
                    if item.kind == .image {
                        thumb(fileName: item.imageFileName)
                    }
                    Group {
                        if item.kind == .text {
                            Text(item.text)
                                .font(NotchTheme.caption)
                                .foregroundStyle(NotchTheme.textPrimary)
                                .lineLimit(2)
                        } else {
                            Text("Image")
                                .font(NotchTheme.caption)
                                .foregroundStyle(NotchTheme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy again")

            Button {
                store.pinHistoryItem(item)
            } label: {
                Image(systemName: "pin")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Pin")

            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    store.removeHistoryItem(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
                .buttonStyle(.notchIcon(diameter: 24))
                .help("Remove")
                Text(Self.timeFmt.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
        }
        .notchRowBackground()
    }

    @ViewBuilder
    private func thumb(fileName: String?) -> some View {
        if let image = store.loadImage(fileName: fileName) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(NotchTheme.chipFill)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textQuaternary)
                )
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

private struct ClipboardSettingsView: View {
    @AppStorage("clipboardHistoryCap") private var cap: Int = 0

    private var selectedCap: Int {
        cap > 0 ? cap : 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History limit")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("History limit", selection: Binding(
                get: { selectedCap },
                set: { cap = $0 }
            )) {
                Text("20 items").tag(20)
                Text("50 items").tag(50)
                Text("100 items").tag(100)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Older items are removed once the limit is reached.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
