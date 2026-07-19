import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// Absolute path to the **stashed** copy under Application Support.
    var path: String
    var name: String
    var addedAt: Date
    /// Optional original path (for display / “reveal original” when still present).
    var originalPath: String?

    var url: URL { URL(fileURLWithPath: path) }

    init(
        id: UUID = UUID(),
        stashedURL: URL,
        originalURL: URL? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.path = stashedURL.path
        self.name = stashedURL.lastPathComponent
        self.addedAt = addedAt
        self.originalPath = originalURL?.path
    }

    var byteCount: Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory == true { return nil }
        if let size = values?.totalFileAllocatedSize { return Int64(size) }
        if let size = values?.fileSize { return Int64(size) }
        return nil
    }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// File pocket: dropped files are **copied** into Application Support so the
/// shelf stays usable after relaunch even if the original moves.
@MainActor
final class ShelfStore: ObservableObject {
    private static let fileName = "shelf.json"
    private static let maxItems = 24
    private static let stashFolderName = "ShelfFiles"

    @Published private(set) var items: [ShelfItem] = []

    private var stashRoot: URL {
        let dir = AppSupportStore.rootDirectory.appendingPathComponent(Self.stashFolderName, isDirectory: true)
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

    // MARK: - Mutations

    @discardableResult
    func add(urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            // Resolve security-scoped / standardized paths.
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }

            // Skip if we already stash the same original path or same name recently.
            if items.contains(where: { $0.originalPath == resolved.path || $0.path == resolved.path }) {
                continue
            }

            guard let stashed = stashCopy(of: resolved) else { continue }
            items.insert(ShelfItem(stashedURL: stashed, originalURL: resolved), at: 0)
            added += 1
        }
        if items.count > Self.maxItems {
            let overflow = items.suffix(from: Self.maxItems)
            for item in overflow {
                removeStashFiles(for: item)
            }
            items = Array(items.prefix(Self.maxItems))
        }
        if added > 0 { persist() }
        return added
    }

    func remove(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        removeStashFiles(for: item)
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        for item in items {
            removeStashFiles(for: item)
        }
        items.removeAll()
        persist()
    }

    func revealInFinder(_ item: ShelfItem) {
        // Prefer stashed copy (always ours); fall back to original if present.
        let target = FileManager.default.fileExists(atPath: item.path)
            ? item.url
            : (item.originalPath.map { URL(fileURLWithPath: $0) } ?? item.url)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func open(_ item: ShelfItem) {
        guard FileManager.default.fileExists(atPath: item.path) else {
            pruneMissing()
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    func copyToPasteboard(_ item: ShelfItem) {
        guard FileManager.default.fileExists(atPath: item.path) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.url as NSURL])
        // Also put the path as a string for apps that only accept text.
        pb.setString(item.path, forType: .string)
    }

    func airDrop(_ item: ShelfItem) {
        guard FileManager.default.fileExists(atPath: item.path),
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [item.url])
        else { return }
        service.perform(withItems: [item.url])
    }

    // MARK: - Stash filesystem

    private func stashCopy(of source: URL) -> URL? {
        let id = UUID()
        let folder = stashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(source.lastPathComponent)
            // If dest exists (unlikely), uniquify.
            let finalDest: URL
            if FileManager.default.fileExists(atPath: dest.path) {
                finalDest = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)")
            } else {
                finalDest = dest
            }
            try FileManager.default.copyItem(at: source, to: finalDest)
            return finalDest
        } catch {
            NSLog("Dynamo Shelf: copy failed — %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    private func removeStashFiles(for item: ShelfItem) {
        // Remove the per-item UUID folder if path is under stash root.
        let url = item.url
        let parent = url.deletingLastPathComponent()
        if parent.path.hasPrefix(stashRoot.path) {
            try? FileManager.default.removeItem(at: parent)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
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
        let missing = items.filter { !FileManager.default.fileExists(atPath: $0.path) }
        for item in missing {
            removeStashFiles(for: item)
        }
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { persist() }
    }
}
