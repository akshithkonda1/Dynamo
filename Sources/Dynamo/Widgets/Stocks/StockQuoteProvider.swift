import Foundation

struct StockQuote: Identifiable, Equatable {
    var id: String { symbol }
    var symbol: String
    var price: Double
    var change: Double
    var percentChange: Double
    /// Recent closing prices for the sparkline (oldest → newest). Optional.
    var history: [Double]
    var updatedAt: Date

    var isPositive: Bool { change >= 0 }
}

@MainActor
protocol StockQuoteProvider: AnyObject {
    var quotes: [StockQuote] { get }
    var watchlist: [String] { get }
    var lastError: String? { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    func setWatchlist(_ symbols: [String])
    func addSymbol(_ symbol: String)
    func removeSymbol(_ symbol: String)
    func refresh() async
}
