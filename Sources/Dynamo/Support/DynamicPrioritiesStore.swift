import Foundation

@MainActor
final class DynamicPrioritiesStore: ObservableObject {
    static let shared = DynamicPrioritiesStore()

    struct Priority: Identifiable, Codable {
        let id: UUID
        var text: String
        var isDone: Bool

        init(id: UUID = UUID(), text: String, isDone: Bool = false) {
            self.id = id
            self.text = text
            self.isDone = isDone
        }
    }

    @Published var priorities: [Priority] = []
    @Published var draft: String = ""

    private static let key = "dynamo.dynamic.top3"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Priority].self, from: data) {
            priorities = saved
        }
    }

    func submitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, priorities.count < 3 else { return }
        priorities.append(Priority(text: trimmed))
        draft = ""
        save()
    }

    func toggle(_ id: UUID) {
        guard let idx = priorities.firstIndex(where: { $0.id == id }) else { return }
        priorities[idx].isDone.toggle()
        save()
    }

    func remove(_ id: UUID) {
        priorities.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(priorities) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
