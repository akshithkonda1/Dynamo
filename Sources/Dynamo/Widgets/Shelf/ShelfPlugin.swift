import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfPlugin: ObservableObject, NotchWidgetPlugin, FileDropAccepting {
    let id = "shelf"
    let displayName = "Shelf"
    let systemImage = "tray.and.arrow.down.fill"

    var expandedContentHeight: CGFloat { 260 }

    let store = ShelfStore()

    func start() {
        store.start()
    }

    func stop() {
        store.stop()
    }

    func handleFileDrop(urls: [URL]) {
        store.add(urls: urls)
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedShelfView(plugin: self))
    }

    /// Open a system file picker and stash the chosen files.
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shelf"
        panel.message = "Choose files or folders to stash on the File Shelf."
        // Activate so the panel isn't buried under the nonactivating notch.
        NSApp.activate(ignoringOtherApps: true)
        // Hold collapse while the modal is up (hover-only would otherwise slam shut).
        NotificationCenter.default.post(name: .dynamoHoldCollapse, object: true)
        defer { NotificationCenter.default.post(name: .dynamoHoldCollapse, object: false) }
        guard panel.runModal() == .OK else { return }
        store.add(urls: panel.urls)
    }
}

extension Notification.Name {
    /// object: Bool — true begins a collapse hold, false ends it.
    static let dynamoHoldCollapse = Notification.Name("dynamoHoldCollapse")
}

// MARK: - Views

private struct ExpandedShelfView: View {
    @ObservedObject var plugin: ShelfPlugin
    @ObservedObject private var store: ShelfStore
    @State private var isDropTargeted = false

    init(plugin: ShelfPlugin) {
        self.plugin = plugin
        self._store = ObservedObject(wrappedValue: plugin.store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceMD) {
            NotchSectionHeader(
                "File Shelf",
                trailing: AnyView(
                    HStack(spacing: 6) {
                        Button {
                            plugin.pickFiles()
                        } label: {
                            NotchChipLabel(title: "Add", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("Add files from Finder")

                        if !store.items.isEmpty {
                            Button("Clear") { store.clear() }
                                .buttonStyle(.plain)
                                .font(NotchTheme.micro)
                                .foregroundStyle(NotchTheme.textTertiary)
                        }
                    }
                )
            )

            if store.items.isEmpty {
                dropHint
                    .contentShape(Rectangle())
                    .onTapGesture { plugin.pickFiles() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.items) { item in
                            row(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleProviders(providers)
        }
    }

    private var dropHint: some View {
        NotchCard {
            VStack(spacing: 8) {
                Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isDropTargeted ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                    .scaleEffect(isDropTargeted ? 1.12 : 1.0)
                Text(isDropTargeted ? "Drop to stash" : "Drop files here")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("or use Add to pick from Finder")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? NotchTheme.mediaGlow : Color.clear,
                    lineWidth: isDropTargeted ? 2 : 0
                )
                .shadow(color: isDropTargeted ? NotchTheme.mediaGlow.opacity(0.5) : .clear, radius: 10)
        )
        .scaleEffect(isDropTargeted ? 1.02 : 1.0)
        .animation(NotchTheme.snappy, value: isDropTargeted)
    }

    private func row(_ item: ShelfItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 20, height: 20)

            Button {
                store.open(item)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(NotchTheme.body)
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    if let size = fileSizeString(for: item) {
                        Text(size)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag {
                NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
            }

            Button {
                store.airDrop(item)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Share via AirDrop")

            Button {
                store.revealInFinder(item)
            } label: {
                Image(systemName: "folder")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Reveal in Finder")

            Button {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
        }
        .notchRowBackground()
    }

    private func fileSizeString(for item: ShelfItem) -> String? {
        guard let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
              values.isDirectory != true,
              let bytes = values.fileSize
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func handleProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    } else {
                        url = nil
                    }
                    if let url {
                        Task { @MainActor in
                            store.add(urls: [url])
                        }
                    }
                }
            }
        }
        return handled
    }
}
