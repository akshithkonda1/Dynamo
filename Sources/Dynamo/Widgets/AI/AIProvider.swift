import Foundation

struct AIMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var role: Role
    var content: String
    var createdAt: Date

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

enum AIQuickAction: String, CaseIterable, Identifiable {
    case summarizeClipboard = "Summarize"
    case rewriteClipboard = "Rewrite"
    case explainClipboard = "Explain"
    case fixGrammar = "Fix grammar"

    var id: String { rawValue }

    var systemHint: String {
        switch self {
        case .summarizeClipboard:
            return "Summarize the following text concisely in plain language. Use short bullets if helpful."
        case .rewriteClipboard:
            return "Rewrite the following text to be clearer and more polished. Keep the original meaning and language. Output only the rewritten text."
        case .explainClipboard:
            return "Explain the following text simply, as if to a smart colleague. Be brief."
        case .fixGrammar:
            return "Fix grammar, spelling, and punctuation. Keep the original tone. Output only the corrected text."
        }
    }
}

enum AIProviderError: LocalizedError {
    case missingAPIKey
    case emptyPrompt
    case emptyClipboard
    case httpStatus(Int, String)
    case decoding
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an xAI API key (see README)."
        case .emptyPrompt:
            return "Enter a prompt first."
        case .emptyClipboard:
            return "Clipboard is empty."
        case .httpStatus(let code, let body):
            return "API error \(code): \(body)"
        case .decoding:
            return "Couldn't parse the model response."
        case .transport(let message):
            return message
        }
    }
}

@MainActor
protocol AIProvider: AnyObject {
    var isBusy: Bool { get }
    var lastError: String? { get }
    var messages: [AIMessage] { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    func send(prompt: String, system: String?) async
    func runQuickAction(_ action: AIQuickAction, clipboardText: String) async
    func clearHistory()
}
