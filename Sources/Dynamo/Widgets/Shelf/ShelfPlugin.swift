import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfPlugin: ObservableObject, NotchWidgetPlugin, FileDropAccepting {
    let id = "shelf"
    let displayName = "Shelf"
    let systemImage = "tray.and.arrow.down.fill"

    let store = ShelfStore()

    func start() {
        store.start()
    }

    func stop() {
        store.stop()
    }

    func handleFileDrop(urls: [URL]) {
        _ = store.add(urls: urls)
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedShelfView(plugin: self))
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shelf"
        panel.message = "Files are copied into Dynamo’s shelf (originals stay put)."
        // Accessory app: briefly activate so the panel is usable.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                _ = self?.store.add(urls: panel.urls)
            }
        }
    }
}

// MARK: - Views

private struct ExpandedShelfView: View {
    @ObservedObject var plugin: ShelfPlugin
    @State private var isDropTargeted = false

    private var store: ShelfStore { plugin.store }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            header

            Text("Drop files on the notch or here — Dynamo keeps a local copy.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            dropZone

            if store.items.isEmpty {
                Text("Nothing stashed yet.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
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

    private var header: some View {
        HStack {
            Text("File Shelf")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
            Spacer()
            Button {
                plugin.pickFiles()
            } label: {
                Label("Add", systemImage: "plus")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(NotchTheme.chipFill))
            }
            .buttonStyle(.plain)
            .help("Choose files or folders to stash")

            if !store.items.isEmpty {
                Button("Clear") { store.clear() }
                    .buttonStyle(.plain)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .help("Remove all stashed copies")
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
            .strokeBorder(
                style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: isDropTargeted ? [] : [5, 4])
            )
            .foregroundStyle(isDropTargeted ? Color.white.opacity(0.55) : NotchTheme.separator)
            .background(
                RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
                    .fill(isDropTargeted ? Color.white.opacity(0.08) : Color.clear)
            )
            .frame(height: 56)
            .overlay(
                HStack(spacing: 8) {
                    Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "plus.rectangle.on.folder")
                        .font(.system(size: 14, weight: .semibold))
                    Text(isDropTargeted ? "Release to stash" : "Drop files here")
                        .font(NotchTheme.caption)
                }
                .foregroundStyle(isDropTargeted ? NotchTheme.textPrimary : NotchTheme.textTertiary)
            )
            .contentShape(Rectangle())
            .onTapGesture { plugin.pickFiles() }
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }

    private func row(_ item: ShelfItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 22, height: 22)

            // Drag the file out of Dynamo into Finder / other apps.
            Text(item.name)
                .font(NotchTheme.body)
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.path)
                .onDrag {
                    NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                }
                .onTapGesture {
                    store.open(item)
                }

            if let bytes = item.byteCount {
                Text(Self.formatBytes(bytes))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textQuaternary)
            } else if item.isDirectory {
                Text("Folder")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }

            Button {
                store.copyToPasteboard(item)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 24))
            .help("Copy file")

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
            .help("Remove from shelf")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(NotchTheme.chipFill.opacity(0.55))
        )
    }

    private func handleProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            handled = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let s = item as? String {
                    url = URL(fileURLWithPath: s)
                } else {
                    url = nil
                }
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            _ = store.add(urls: urls)
        }
        return handled
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
