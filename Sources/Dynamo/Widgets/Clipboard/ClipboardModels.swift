import Foundation

enum ClipboardItemKind: String, Codable, Equatable {
    case text
    case image
}

struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipboardItemKind
    /// Text body for `.text`; empty for images.
    var text: String
    /// Relative file name under ClipboardImages/ for `.image`.
    var imageFileName: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: ClipboardItemKind = .text,
        text: String = "",
        imageFileName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.createdAt = createdAt
    }

    /// Backward-compatible decode (older JSON had only text).
    enum CodingKeys: String, CodingKey {
        case id, kind, text, imageFileName, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(ClipboardItemKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct PinnedSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var kind: ClipboardItemKind
    var text: String
    var imageFileName: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        kind: ClipboardItemKind = .text,
        text: String = "",
        imageFileName: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, text, imageFileName, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decodeIfPresent(ClipboardItemKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct ClipboardStorePayload: Codable, Equatable {
    var history: [ClipboardHistoryItem]
    var snippets: [PinnedSnippet]
}
