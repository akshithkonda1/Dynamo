import AppKit
import Foundation

/// Watches the general pasteboard for transient history and owns pinned snippets.
/// Both lists persist as JSON under Application Support (not UserDefaults).
@MainActor
final class ClipboardStore: ObservableObject {
    static let historyLimit = 20
    private static let fileName = "clipboard.json"

    @Published private(set) var history: [ClipboardHistoryItem] = []
    @Published private(set) var snippets: [PinnedSnippet] = []

    private var lastChangeCount: Int = -1
    private var timer: Timer?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        load()
        lastChangeCount = NSPasteboard.general.changeCount
        // ~2 Hz is enough for the "within ~1s" requirement without thrashing.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
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

    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Avoid immediately re-recording what we just put back.
        lastChangeCount = pb.changeCount
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
        snippets.insert(PinnedSnippet(title: resolvedTitle, text: trimmed), at: 0)
        persist()
    }

    func updateSnippet(_ snippet: PinnedSnippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.updatedAt = Date()
        snippets[idx] = updated
        persist()
    }

    func deleteSnippet(id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    func clearHistory() {
        history.removeAll()
        persist()
    }

    func removeHistoryItem(id: UUID) {
        history.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Pasteboard polling

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return }

        // De-dupe consecutive identical copies.
        if history.first?.text == text { return }

        history.insert(ClipboardHistoryItem(text: text), at: 0)
        if history.count > Self.historyLimit {
            history = Array(history.prefix(Self.historyLimit))
        }
        persist()
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
