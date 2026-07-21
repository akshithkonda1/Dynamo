import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// Path to the stashed copy under Application Support (preferred), or a
    /// legacy absolute path from older builds.
    var path: String
    var name: String
    var addedAt: Date
    /// Original path when first dropped (display only; may no longer exist).
    var sourcePath: String?
    /// True when Dynamo owns a copy under ShelfFiles.
    var isStashed: Bool

    var url: URL { URL(fileURLWithPath: path) }

    init(
        id: UUID = UUID(),
        url: URL,
        addedAt: Date = Date(),
        sourcePath: String? = nil,
        isStashed: Bool = true
    ) {
        self.id = id
        self.path = url.path
        self.name = url.lastPathComponent
        self.addedAt = addedAt
        self.sourcePath = sourcePath
        self.isStashed = isStashed
    }
}

/// File pocket: **copies** drops into Application Support so items survive
/// when the original is moved or deleted.
@MainActor
final class ShelfStore: ObservableObject {
    private static let fileName = "shelf.json"
    private static let maxItems = 24
    private static let stashFolder = "ShelfFiles"

    @Published private(set) var items: [ShelfItem] = []

    private var stashRoot: URL {
        let dir = AppSupportStore.rootDirectory.appendingPathComponent(Self.stashFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

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
            // Skip if we already stash the same basename + source.
            if items.contains(where: { $0.sourcePath == resolved.path || $0.path == resolved.path }) {
                continue
            }
            if let stashed = stashCopy(of: resolved) {
                items.insert(stashed, at: 0)
                changed = true
            }
        }
        if items.count > Self.maxItems {
            let overflow = items.suffix(from: Self.maxItems)
            for item in overflow {
                deleteStashFiles(for: item)
            }
            items = Array(items.prefix(Self.maxItems))
            changed = true
        }
        if changed { persist() }
    }

    func remove(id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            deleteStashFiles(for: item)
        }
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        for item in items {
            deleteStashFiles(for: item)
        }
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

    func airDrop(_ item: ShelfItem) {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [item.url])
        else { return }
        service.perform(withItems: [item.url])
    }

    // MARK: - Stash

    private func stashCopy(of source: URL) -> ShelfItem? {
        let id = UUID()
        let dir = stashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(source.lastPathComponent)
            // Prefer copy so original can be deleted freely.
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            return ShelfItem(
                id: id,
                url: dest,
                sourcePath: source.path,
                isStashed: true
            )
        } catch {
            // Fallback: reference original path (legacy behaviour).
            return ShelfItem(id: id, url: source, sourcePath: source.path, isStashed: false)
        }
    }

    private func deleteStashFiles(for item: ShelfItem) {
        guard item.isStashed else { return }
        let dir = stashRoot.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var items: [ShelfItem]
    }

    private func load() {
        if let payload = AppSupportStore.load(Payload.self, from: Self.fileName) {
            // Migrate older items missing isStashed (default false for safety).
            items = payload.items.map { item in
                var copy = item
                if copy.sourcePath == nil, copy.path.contains("/ShelfFiles/") {
                    copy.isStashed = true
                }
                return copy
            }
        }
    }

    private func persist() {
        AppSupportStore.save(Payload(items: items), to: Self.fileName)
    }

    private func pruneMissing() {
        let before = items.count
        let missing = items.filter { !FileManager.default.fileExists(atPath: $0.path) }
        for item in missing {
            deleteStashFiles(for: item)
        }
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { persist() }
    }
}
