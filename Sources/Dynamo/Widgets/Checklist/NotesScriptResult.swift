import Foundation

/// Parse Notes AppleScript `OK` / `ERR|code:message` results (never `ERR|||`).
enum NotesScriptResult: Equatable {
    case ok(String)
    case error(String)
    case unavailable

    static func parse(_ raw: String?) -> NotesScriptResult {
        guard let raw else { return .unavailable }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable }
        if trimmed.hasPrefix("ERR") {
            var rest = trimmed
            if rest.hasPrefix("ERR|||") {
                rest.removeFirst(6)
            } else if rest.hasPrefix("ERR|") {
                rest.removeFirst(4)
            } else if rest.hasPrefix("ERR\t") {
                rest.removeFirst(4)
            } else {
                rest.removeFirst(3)
            }
            if rest.hasPrefix("|") { rest.removeFirst() }
            let message = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(message.isEmpty ? "Notes error" : message)
        }
        return .ok(trimmed)
    }

    var isFailure: Bool {
        switch self {
        case .ok: return false
        case .error, .unavailable: return true
        }
    }

    var errorMessage: String? {
        switch self {
        case .error(let m): return m
        case .unavailable: return "Could not reach Notes"
        case .ok: return nil
        }
    }
}
