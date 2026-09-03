import AppKit
import SwiftUI

@MainActor
final class ClipboardPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding, WidgetSettingsProviding {
    let id = "clipboard"
    let displayName = "Clipboard"
    let systemImage = "doc.on.clipboard"

    var expandedContentHeight: CGFloat { 268 }
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
                    urgency: .low,
                    category: "clipboard"
                )
            case .image:
                peek = NotchSneakPeek(
                    systemImage: "photo.on.rectangle",
                    title: "Copied",
                    subtitle: "Image",
                    urgency: .low,
                    category: "clipboard"
                )
            case .file:
                peek = NotchSneakPeek(
                    systemImage: "doc",
                    title: "Copied",
                    subtitle: item.text.isEmpty ? "File" : item.text,
                    urgency: .low,
                    category: "clipboard"
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
        let pb = NSPasteboard.general
        let rich: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .html]
        return pb.availableType(from: rich) != nil
    }
}

// MARK: - Views

private struct ExpandedClipboardView: View {
    @ObservedObject var plugin: ClipboardPlugin
    @ObservedObject private var store: ClipboardStore
    @State private var searchQuery = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var showClearHistoryConfirm = false

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
                        trailing: AnyView(
                            HStack(spacing: 8) {
                                if plugin.canStripFormatting {
                                    Button("Paste as plain") { plugin.stripFormatting() }
                                        .buttonStyle(.plain)
                                        .font(NotchTheme.micro)
                                        .foregroundStyle(NotchTheme.textTertiary)
                                        .help("Copy the current pasteboard as plain text")
                                }
                                if !store.history.isEmpty {
                                    Button("Clear") { showClearHistoryConfirm = true }
                                        .buttonStyle(.plain)
                                        .font(NotchTheme.micro)
                                        .foregroundStyle(NotchTheme.textTertiary)
                                }
                            }
                        )
                    )

                    if store.canUndoClearHistory {
                        HStack(spacing: 6) {
                            Text("History cleared")
                                .font(NotchTheme.micro)
                                .foregroundStyle(NotchTheme.textTertiary)
                            Spacer(minLength: 0)
                            Button("Undo") { store.undoClearHistory() }
                                .buttonStyle(.plain)
                                .font(NotchTheme.micro.weight(.semibold))
                                .foregroundStyle(NotchTheme.textPrimary)
                        }
                        .padding(.vertical, 2)
                        .transition(.opacity)
                    }

                    if !store.history.isEmpty {
                        TextField("Search history…", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .font(NotchTheme.caption)
                    }

                    historySection
                }
                .padding(.bottom, 4)
                .animation(.easeInOut(duration: 0.2), value: store.canUndoClearHistory)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchAppear()
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $showClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all unpinned clipboard history. Pinned snippets are kept.")
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if store.snippets.isEmpty && !plugin.isAddingSnippet {
            NotchEmptyState(
                systemImage: "pin",
                title: "Pin your keepers",
                caption: "Star from History or tap Add snippet for go-to text.",
                prominent: false
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(store.snippets.enumerated()), id: \.element.id) { index, snippet in
                    snippetRow(snippet)
                        .notchAppear(delay: Double(min(index, 6)) * 0.03)
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let filtered = store.history.filter { ClipboardHistoryPolicy.matches($0, query: searchQuery) }
        if store.history.isEmpty {
            NotchEmptyState(
                systemImage: "doc.on.clipboard",
                title: "Clipboard is quiet",
                caption: "Copy text, a screenshot, or a Finder file — it lands here automatically.",
                prominent: false
            )
        } else if filtered.isEmpty {
            NotchEmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                caption: "Nothing in history for “\(searchQuery)”.",
                prominent: false
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                    historyRow(item)
                        .notchAppear(delay: 0.06 + Double(min(index, 8)) * 0.028)
                }
            }
        }
    }

    private func snippetRow(_ snippet: PinnedSnippet) -> some View {
        HStack(spacing: 8) {
            Button {
                store.cycleSnippetTag(id: snippet.id)
            } label: {
                Circle()
                    .fill(pinColor(snippet.tag))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().strokeBorder(Color.white.opacity(snippet.tag == .none ? 0.35 : 0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Color tag: \(snippet.tag.accessibilityName). Click to cycle.")
            .accessibilityLabel("Color tag \(snippet.tag.accessibilityName)")

            Button {
                store.copySnippet(snippet)
            } label: {
                HStack(spacing: 8) {
                    if snippet.kind == .image {
                        thumb(fileName: snippet.imageFileName)
                    } else if snippet.kind == .file {
                        Image(systemName: "doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                            .frame(width: 28, height: 28)
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
                        } else if snippet.kind == .file {
                            Text(snippet.filePath ?? "File")
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

            if snippet.kind == .file {
                Button {
                    store.revealFile(path: snippet.filePath)
                } label: {
                    Image(systemName: "folder")
                        .font(NotchTheme.caption)
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
                .buttonStyle(.notchIcon(diameter: 24))
                .help("Reveal in Finder")
            }

            Button {
                store.deleteSnippet(id: snippet.id)
            } label: {
                Image(systemName: "trash")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Delete pin")
            .accessibilityLabel("Delete pin")
        }
        .notchRowBackground()
    }

    private func historyRow(_ item: ClipboardHistoryItem) -> some View {
        HStack(spacing: 8) {
            Button {
                if item.kind == .file {
                    store.openFile(path: item.filePath)
                } else {
                    store.copyHistoryItem(item)
                }
            } label: {
                HStack(spacing: 8) {
                    if item.kind == .image {
                        thumb(fileName: item.imageFileName)
                    } else if item.kind == .file {
                        Image(systemName: "doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                            .frame(width: 28, height: 28)
                    }
                    Group {
                        if item.kind == .text {
                            Text(item.text)
                                .font(NotchTheme.caption)
                                .foregroundStyle(NotchTheme.textPrimary)
                                .lineLimit(2)
                        } else if item.kind == .file {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.text.isEmpty ? "File" : item.text)
                                    .font(NotchTheme.caption)
                                    .foregroundStyle(NotchTheme.textPrimary)
                                    .lineLimit(1)
                                if let path = item.filePath {
                                    Text(path)
                                        .font(NotchTheme.micro)
                                        .foregroundStyle(NotchTheme.textTertiary)
                                        .lineLimit(1)
                                }
                            }
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
            .help(item.kind == .file ? "Open" : "Copy again")

            if item.kind == .file {
                Button {
                    store.copyHistoryItem(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(NotchTheme.caption)
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
                .buttonStyle(.notchIcon(diameter: 24))
                .help("Copy file")
            }

            Button {
                store.pinHistoryItem(item)
            } label: {
                Image(systemName: "pin")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Pin")
            .accessibilityLabel("Pin")

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
                .accessibilityLabel("Remove")
                Text(Self.timeFmt.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
        }
        .notchRowBackground()
    }

    private func pinColor(_ tag: ClipboardPinTag) -> Color {
        switch tag {
        case .none: return Color.white.opacity(0.18)
        case .red: return NotchTheme.negative
        case .orange: return NotchTheme.caution
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return NotchTheme.positive
        case .blue: return NotchTheme.calmGlow
        case .purple: return NotchTheme.mediaGlow
        }
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
            Text("Older items are removed once the limit is reached. Copied files from Finder are stored as paths (not extra copies). Pin color tags are local to Dynamo.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
