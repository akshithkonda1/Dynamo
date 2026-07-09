import Foundation

/// Resolves the Finnhub API key from a gitignored local file.
///
/// Setup (see README):
/// 1. Create a free key at https://finnhub.io/register
/// 2. Write it to `~/Library/Application Support/Dynamo/finnhub_api_key`
///    (single line, no quotes) — or set the `FINNHUB_API_KEY` environment variable.
enum StockAPIKey {
    static func resolve() -> String? {
        if let env = ProcessInfo.processInfo.environment["FINNHUB_API_KEY"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = AppSupportStore.fileURL(named: "finnhub_api_key")
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }
}
