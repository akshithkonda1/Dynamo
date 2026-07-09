import Foundation

/// OpenAI-compatible Chat Completions client.
/// Defaults to xAI (`https://api.x.ai/v1`, model `grok-3-mini`).
/// Swap base URL + model via `AIConfig` for OpenAI or a local server — UI unchanged.
@MainActor
final class OpenAICompatibleProvider: AIProvider {
    private static let historyFile = "ai_history.json"
    private static let maxHistory = 40

    private(set) var isBusy = false
    private(set) var lastError: String?
    private(set) var messages: [AIMessage] = []
    var onChange: (() -> Void)?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    func start() {
        loadHistory()
    }

    func stop() {}

    func clearHistory() {
        messages.removeAll()
        lastError = nil
        persistHistory()
        onChange?()
    }

    func send(prompt: String, system: String? = nil) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = AIProviderError.emptyPrompt.localizedDescription
            onChange?()
            return
        }
        await complete(
            userContent: trimmed,
            system: system ?? "You are Dynamo AI, a concise assistant living in the MacBook notch. Prefer short, useful answers. No preamble."
        )
    }

    func runQuickAction(_ action: AIQuickAction, clipboardText: String) async {
        let text = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            lastError = AIProviderError.emptyClipboard.localizedDescription
            onChange?()
            return
        }
        // Cap clipboard payload so free-tier keys aren't blown up by megabyte pastes.
        let clipped = String(text.prefix(12_000))
        await complete(userContent: clipped, system: action.systemHint)
    }

    // MARK: - Network

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let stream: Bool
    }

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message?
        }
        let choices: [Choice]?
        let error: APIErrorBody?
    }

    private struct APIErrorBody: Decodable {
        let message: String?
    }

    private func complete(userContent: String, system: String) async {
        guard let apiKey = AIConfig.apiKey else {
            lastError = AIProviderError.missingAPIKey.localizedDescription
            onChange?()
            return
        }

        isBusy = true
        lastError = nil
        let userMessage = AIMessage(role: .user, content: userContent)
        messages.append(userMessage)
        // Keep history bounded before the request so the UI shows the prompt immediately.
        trimHistory()
        onChange?()

        do {
            let reply = try await requestCompletion(
                apiKey: apiKey,
                system: system,
                user: userContent
            )
            messages.append(AIMessage(role: .assistant, content: reply))
            trimHistory()
            persistHistory()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep the user prompt so they can retry contextually.
        }

        isBusy = false
        onChange?()
    }

    private func requestCompletion(apiKey: String, system: String, user: String) async throws -> String {
        let url = AIConfig.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Include a short recent conversation tail for multi-turn (exclude system from store).
        var payloadMessages: [ChatMessage] = [
            ChatMessage(role: "system", content: system)
        ]
        let recent = messages.suffix(8)
        for message in recent {
            switch message.role {
            case .user:
                payloadMessages.append(ChatMessage(role: "user", content: message.content))
            case .assistant:
                payloadMessages.append(ChatMessage(role: "assistant", content: message.content))
            case .system:
                break
            }
        }
        // Ensure the latest user turn is present even if trim raced.
        if payloadMessages.last?.role != "user" {
            payloadMessages.append(ChatMessage(role: "user", content: user))
        }

        let body = ChatRequest(
            model: AIConfig.model,
            messages: payloadMessages,
            temperature: 0.4,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.transport("Invalid response.")
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            let snippet = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let short = String(snippet.prefix(180))
            throw AIProviderError.httpStatus(http.statusCode, short.isEmpty ? "no body" : short)
        }

        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw AIProviderError.decoding
        }
        if let apiError = decoded.error?.message {
            throw AIProviderError.httpStatus(http.statusCode, apiError)
        }
        guard let content = decoded.choices?.first?.message?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else {
            throw AIProviderError.decoding
        }
        return content
    }

    // MARK: - History persistence

    private struct HistoryPayload: Codable {
        var messages: [AIMessage]
    }

    private func loadHistory() {
        if let payload = AppSupportStore.load(HistoryPayload.self, from: Self.historyFile) {
            messages = payload.messages
        }
    }

    private func persistHistory() {
        AppSupportStore.save(HistoryPayload(messages: messages), to: Self.historyFile)
    }

    private func trimHistory() {
        if messages.count > Self.maxHistory {
            messages = Array(messages.suffix(Self.maxHistory))
        }
    }
}
