import Foundation

struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

struct PinnedSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var text: String
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, text: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.updatedAt = updatedAt
    }
}

struct ClipboardStorePayload: Codable, Equatable {
    var history: [ClipboardHistoryItem]
    var snippets: [PinnedSnippet]
}
