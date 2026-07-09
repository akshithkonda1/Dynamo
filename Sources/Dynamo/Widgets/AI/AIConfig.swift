import Foundation

/// Resolves AI credentials and endpoint from gitignored local config.
///
/// Defaults target the **xAI Grok** OpenAI-compatible Chat Completions API.
/// Any OpenAI-compatible server works if you override base URL + model.
///
/// Setup (see README):
/// 1. Create a key at https://console.x.ai/
/// 2. Write it to `~/Library/Application Support/Dynamo/xai_api_key`
///    (single line) — or set `XAI_API_KEY` / `OPENAI_API_KEY`
/// 3. Optional overrides in the same directory:
///    - `ai_base_url` (default `https://api.x.ai/v1`)
///    - `ai_model` (default `grok-3-mini`)
enum AIConfig {
    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["XAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return readFile("xai_api_key") ?? readFile("openai_api_key")
    }

    static var baseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["DYNAMO_AI_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw) {
            return url
        }
        if let raw = readFile("ai_base_url"), let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://api.x.ai/v1")!
    }

    static var model: String {
        if let env = ProcessInfo.processInfo.environment["DYNAMO_AI_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return readFile("ai_model") ?? "grok-3-mini"
    }

    private static func readFile(_ name: String) -> String? {
        let url = AppSupportStore.fileURL(named: name)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }
}
