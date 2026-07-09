import Foundation

/// Finnhub free-tier quote source.
///
/// **Why Finnhub:** free tier allows ~60 calls/minute (vs Alpha Vantage's ~25/day
/// and Twelve Data's 8/min with 800/day). A 60s refresh of a small watchlist
/// (e.g. 5 symbols → 5 quote + 5 candle calls) stays well under the limit.
///
/// API key is never committed — see `StockAPIKey` and the README setup steps.
@MainActor
final class FinnhubQuoteProvider: StockQuoteProvider {
    private static let watchlistFile = "stocks_watchlist.json"
    private static let defaultWatchlist = ["AAPL", "MSFT", "GOOGL"]
    /// Respect free-tier rate limits; 60s is comfortable for a few symbols.
    private static let refreshInterval: TimeInterval = 60

    private(set) var quotes: [StockQuote] = []
    private(set) var watchlist: [String] = FinnhubQuoteProvider.defaultWatchlist
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var isStarted = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadWatchlist()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    func setWatchlist(_ symbols: [String]) {
        watchlist = Self.normalize(symbols)
        persistWatchlist()
        Task { await refresh() }
    }

    func addSymbol(_ symbol: String) {
        let s = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty, !watchlist.contains(s) else { return }
        watchlist.append(s)
        persistWatchlist()
        Task { await refresh() }
    }

    func removeSymbol(_ symbol: String) {
        watchlist.removeAll { $0 == symbol.uppercased() }
        quotes.removeAll { $0.symbol == symbol.uppercased() }
        persistWatchlist()
        onChange?()
    }

    func refresh() async {
        guard let apiKey = StockAPIKey.resolve() else {
            lastError = "Add a Finnhub API key (see README)."
            // Surface empty placeholders so the UI still shows the watchlist.
            quotes = watchlist.map {
                StockQuote(symbol: $0, price: 0, change: 0, percentChange: 0, history: [], updatedAt: Date())
            }
            onChange?()
            return
        }

        var next: [StockQuote] = []
        var errorMessage: String?

        for symbol in watchlist {
            do {
                let quote = try await fetchQuote(symbol: symbol, apiKey: apiKey)
                let history = (try? await fetchSparkline(symbol: symbol, apiKey: apiKey)) ?? []
                next.append(StockQuote(
                    symbol: symbol,
                    price: quote.price,
                    change: quote.change,
                    percentChange: quote.percentChange,
                    history: history,
                    updatedAt: Date()
                ))
            } catch {
                errorMessage = error.localizedDescription
                if let existing = quotes.first(where: { $0.symbol == symbol }) {
                    next.append(existing)
                } else {
                    next.append(StockQuote(
                        symbol: symbol,
                        price: 0,
                        change: 0,
                        percentChange: 0,
                        history: [],
                        updatedAt: Date()
                    ))
                }
            }
        }

        quotes = next
        lastError = errorMessage
        onChange?()
    }

    // MARK: - Finnhub REST

    private struct QuoteDTO: Decodable {
        let c: Double  // current
        let d: Double? // change
        let dp: Double? // percent change
        let pc: Double? // previous close
    }

    private struct CandleDTO: Decodable {
        let c: [Double]?
        let s: String?
    }

    private func fetchQuote(symbol: String, apiKey: String) async throws -> (price: Double, change: Double, percentChange: Double) {
        var components = URLComponents(string: "https://finnhub.io/api/v1/quote")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw NSError(domain: "Finnhub", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Finnhub API key."
            ])
        }
        let dto = try JSONDecoder().decode(QuoteDTO.self, from: data)
        guard dto.c > 0 else {
            throw NSError(domain: "Finnhub", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No quote for \(symbol)."
            ])
        }
        return (dto.c, dto.d ?? 0, dto.dp ?? 0)
    }

    private func fetchSparkline(symbol: String, apiKey: String) async throws -> [Double] {
        let to = Int(Date().timeIntervalSince1970)
        let from = to - 7 * 24 * 60 * 60
        var components = URLComponents(string: "https://finnhub.io/api/v1/stock/candle")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "resolution", value: "D"),
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "to", value: String(to)),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let dto = try JSONDecoder().decode(CandleDTO.self, from: data)
        guard dto.s == "ok", let closes = dto.c, !closes.isEmpty else { return [] }
        return closes
    }

    // MARK: - Watchlist persistence

    private struct WatchlistPayload: Codable {
        var symbols: [String]
    }

    private func loadWatchlist() {
        if let payload = AppSupportStore.load(WatchlistPayload.self, from: Self.watchlistFile),
           !payload.symbols.isEmpty {
            watchlist = Self.normalize(payload.symbols)
        } else {
            watchlist = Self.defaultWatchlist
            persistWatchlist()
        }
    }

    private func persistWatchlist() {
        AppSupportStore.save(WatchlistPayload(symbols: watchlist), to: Self.watchlistFile)
    }

    private static func normalize(_ symbols: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in symbols {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !s.isEmpty, !seen.contains(s) else { continue }
            seen.insert(s)
            result.append(s)
        }
        return result
    }
}
