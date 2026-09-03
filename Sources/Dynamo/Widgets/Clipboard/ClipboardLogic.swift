import Foundation

/// Color tags for pinned snippets (F4). `none` is untagged; cycling walks this order.
enum ClipboardPinTag: String, Codable, CaseIterable, Equatable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    var next: ClipboardPinTag {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .none }
        return all[(idx + 1) % all.count]
    }

    var accessibilityName: String {
        switch self {
        case .none: return "No color"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }
}

/// Pure helpers so clipboard history / search / trim can be unit-tested without
/// the pasteboard or App Support.
enum ClipboardHistoryPolicy {
    /// Drops oldest items past `limit`. Returns kept prefix + overflow (oldest last).
    static func trim(
        _ history: [ClipboardHistoryItem],
        limit: Int
    ) -> (kept: [ClipboardHistoryItem], dropped: [ClipboardHistoryItem]) {
        let cap = max(1, limit)
        guard history.count > cap else { return (history, []) }
        return (Array(history.prefix(cap)), Array(history.suffix(from: cap)))
    }

    static func matches(_ item: ClipboardHistoryItem, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        if item.text.localizedCaseInsensitiveContains(q) { return true }
        if let path = item.filePath, path.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    static func isDuplicate(_ existing: ClipboardHistoryItem?, of incoming: ClipboardHistoryItem) -> Bool {
        guard let existing else { return false }
        guard existing.kind == incoming.kind else { return false }
        switch incoming.kind {
        case .text:
            return existing.text == incoming.text
        case .image:
            return existing.imageFileName == incoming.imageFileName && incoming.imageFileName != nil
        case .file:
            return existing.filePath == incoming.filePath && incoming.filePath != nil
        }
    }
}
