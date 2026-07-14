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
        store.add(urls: urls)
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedShelfView(store: store))
    }
}

// MARK: - Views

private struct ExpandedShelfView: View {
    @ObservedObject var store: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceMD) {
            HStack {
                Text("File Shelf")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear") { store.clear() }
                        .buttonStyle(.plain)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                }
            }

            Text("Drop files onto the notch to stash them here.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)

            if store.items.isEmpty {
                dropHint
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleProviders(providers)
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(NotchTheme.separator)
            .frame(height: 72)
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Drop files")
                        .font(NotchTheme.caption)
                }
                .foregroundStyle(NotchTheme.textTertiary)
            )
    }

    private func row(_ item: ShelfItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 20, height: 20)

            Button {
                store.open(item)
            } label: {
                Text(item.name)
                    .font(NotchTheme.body)
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.revealInFinder(item)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")

            Button {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
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
