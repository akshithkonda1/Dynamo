import AppKit
import Foundation

/// Watches the general pasteboard for text + images; pins persist under App Support.
@MainActor
final class ClipboardStore: ObservableObject {
    static var historyLimit: Int {
        let cap = UserDefaults.standard.integer(forKey: "clipboardHistoryCap")
        return cap > 0 ? cap : 20
    }
    private static let fileName = "clipboard.json"
    private static let imageFolder = "ClipboardImages"

    @Published private(set) var history: [ClipboardHistoryItem] = []
    @Published private(set) var snippets: [PinnedSnippet] = []

    var onNewItem: ((ClipboardHistoryItem) -> Void)?

    private var lastChangeCount: Int = -1
    private var timer: Timer?
    private var isStarted = false

    private var imageRoot: URL {
        let dir = AppSupportStore.rootDirectory.appendingPathComponent(Self.imageFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        load()
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    func imageURL(for fileName: String) -> URL {
        imageRoot.appendingPathComponent(fileName)
    }

    func loadImage(fileName: String?) -> NSImage? {
        guard let fileName else { return nil }
        return NSImage(contentsOf: imageURL(for: fileName))
    }

    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    func copyHistoryItem(_ item: ClipboardHistoryItem) {
        switch item.kind {
        case .text:
            copyToPasteboard(item.text)
        case .image:
            guard let image = loadImage(fileName: item.imageFileName) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            lastChangeCount = pb.changeCount
        }
    }

    func copySnippet(_ snippet: PinnedSnippet) {
        switch snippet.kind {
        case .text:
            copyToPasteboard(snippet.text)
        case .image:
            guard let image = loadImage(fileName: snippet.imageFileName) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            lastChangeCount = pb.changeCount
        }
    }

    func pinCurrentOrText(_ text: String, title: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let label = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String
        if let label, !label.isEmpty {
            resolvedTitle = label
        } else {
            resolvedTitle = String(trimmed.prefix(32))
        }
        snippets.insert(PinnedSnippet(title: resolvedTitle, kind: .text, text: trimmed), at: 0)
        persist()
    }

    func pinHistoryItem(_ item: ClipboardHistoryItem) {
        switch item.kind {
        case .text:
            pinCurrentOrText(item.text)
        case .image:
            guard let name = item.imageFileName else { return }
            // Duplicate image file for pin lifetime independence.
            let newName = "\(UUID().uuidString).png"
            let src = imageURL(for: name)
            let dest = imageURL(for: newName)
            try? FileManager.default.copyItem(at: src, to: dest)
            snippets.insert(
                PinnedSnippet(title: "Image", kind: .image, text: "", imageFileName: newName),
                at: 0
            )
            persist()
        }
    }

    func updateSnippet(_ snippet: PinnedSnippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.updatedAt = Date()
        snippets[idx] = updated
        persist()
    }

    func renameSnippet(id: UUID, title: String) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].title = title
        snippets[i].updatedAt = Date()
        persist()
    }

    func deleteSnippet(id: UUID) {
        if let snip = snippets.first(where: { $0.id == id }), let name = snip.imageFileName {
            try? FileManager.default.removeItem(at: imageURL(for: name))
        }
        snippets.removeAll { $0.id == id }
        persist()
    }

    func clearHistory() {
        for item in history {
            if let name = item.imageFileName {
                try? FileManager.default.removeItem(at: imageURL(for: name))
            }
        }
        history.removeAll()
        persist()
    }

    func removeHistoryItem(id: UUID) {
        if let item = history.first(where: { $0.id == id }), let name = item.imageFileName {
            try? FileManager.default.removeItem(at: imageURL(for: name))
        }
        history.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Pasteboard polling

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            if history.first?.kind == .text, history.first?.text == text { return }
            history.insert(ClipboardHistoryItem(kind: .text, text: text), at: 0)
            trimHistory()
            persist()
            return
        }

        // Image (screenshot, copy from Preview, etc.)
        if let image = readImage(from: pb), let fileName = saveImage(image) {
            history.insert(
                ClipboardHistoryItem(kind: .image, text: "", imageFileName: fileName),
                at: 0
            )
            trimHistory()
            persist()
        }
    }

    private func readImage(from pb: NSPasteboard) -> NSImage? {
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = imgs.first {
            return first
        }
        if let data = pb.data(forType: .png), let image = NSImage(data: data) {
            return image
        }
        if let data = pb.data(forType: .tiff), let image = NSImage(data: data) {
            return image
        }
        return nil
    }

    private func saveImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return nil }
        let name = "\(UUID().uuidString).png"
        let url = imageURL(for: name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private func trimHistory() {
        while history.count > Self.historyLimit {
            if let last = history.last {
                if let name = last.imageFileName {
                    try? FileManager.default.removeItem(at: imageURL(for: name))
                }
                history.removeLast()
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        if let payload = AppSupportStore.load(ClipboardStorePayload.self, from: Self.fileName) {
            history = payload.history
            snippets = payload.snippets
        }
    }

    private func persist() {
        let payload = ClipboardStorePayload(history: history, snippets: snippets)
        AppSupportStore.save(payload, to: Self.fileName)
    }
}
