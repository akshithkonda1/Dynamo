import Foundation

/// Ordered checklist persisted as Application Support JSON.
@MainActor
final class ChecklistStore: ObservableObject {
    private static let fileName = "checklist.json"

    @Published private(set) var items: [ChecklistItem] = []

    func start() {
        load()
    }

    func stop() {}

    func add(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(ChecklistItem(text: trimmed))
        persist()
    }

    func toggle(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isDone.toggle()
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func updateText(id: UUID, text: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[idx].text = trimmed
        persist()
    }

    private func load() {
        if let payload = AppSupportStore.load(ChecklistPayload.self, from: Self.fileName) {
            items = payload.items
        }
    }

    private func persist() {
        AppSupportStore.save(ChecklistPayload(items: items), to: Self.fileName)
    }
}
