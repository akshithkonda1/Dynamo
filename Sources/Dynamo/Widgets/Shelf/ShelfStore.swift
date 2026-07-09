import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String
    var name: String
    var addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date()) {
        self.id = id
        self.path = url.path
        self.name = url.lastPathComponent
        self.addedAt = addedAt
    }
}

/// Temporary file pocket. Paths are persisted so items survive relaunch while
/// the underlying files still exist; missing files are pruned on load.
@MainActor
final class ShelfStore: ObservableObject {
    private static let fileName = "shelf.json"
    private static let maxItems = 24

    @Published private(set) var items: [ShelfItem] = []

    func start() {
        load()
        pruneMissing()
    }

    func stop() {}

    func add(urls: [URL]) {
        var changed = false
        for url in urls {
            let resolved = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }
            if items.contains(where: { $0.path == resolved.path }) { continue }
            items.insert(ShelfItem(url: resolved), at: 0)
            changed = true
        }
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
            changed = true
        }
        if changed { persist() }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    func revealInFinder(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func copyToPasteboard(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.url as NSURL])
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var items: [ShelfItem]
    }

    private func load() {
        if let payload = AppSupportStore.load(Payload.self, from: Self.fileName) {
            items = payload.items
        }
    }

    private func persist() {
        AppSupportStore.save(Payload(items: items), to: Self.fileName)
    }

    private func pruneMissing() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { persist() }
    }
}
