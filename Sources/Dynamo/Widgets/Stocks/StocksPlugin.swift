import SwiftUI

@MainActor
final class StocksPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "stocks"
    let displayName = "Stocks"
    let systemImage = "chart.line.uptrend.xyaxis"

    @Published private(set) var quotes: [StockQuote] = []
    @Published private(set) var lastError: String?
    @Published var draftSymbol: String = ""

    private let provider: StockQuoteProvider

    init(provider: StockQuoteProvider? = nil) {
        let resolved = provider ?? FinnhubQuoteProvider()
        self.provider = resolved
        resolved.onChange = { [weak self] in
            guard let self else { return }
            self.quotes = self.provider.quotes
            self.lastError = self.provider.lastError
        }
    }

    func start() {
        provider.start()
        quotes = provider.quotes
        lastError = provider.lastError
    }

    func stop() {
        provider.stop()
    }

    func collapsedView() -> AnyView {
        AnyView(CollapsedStocksView(quotes: quotes))
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedStocksView(plugin: self))
    }

    func addDraftSymbol() {
        provider.addSymbol(draftSymbol)
        draftSymbol = ""
    }

    func removeSymbol(_ symbol: String) {
        provider.removeSymbol(symbol)
    }

    func refresh() {
        Task { await provider.refresh() }
    }
}

// MARK: - Views

private struct CollapsedStocksView: View {
    let quotes: [StockQuote]

    var body: some View {
        HStack(spacing: 6) {
            if let primary = quotes.first, primary.price > 0 {
                MiniSparkline(values: primary.history.isEmpty ? [primary.price - primary.change, primary.price] : primary.history)
                    .frame(width: 28, height: 12)
                    .foregroundStyle(primary.isPositive ? NotchTheme.positive : NotchTheme.negative)
                Text(primary.symbol)
                    .font(NotchTheme.caption.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(String(format: "%@%.2f%%", primary.percentChange >= 0 ? "+" : "", primary.percentChange))
                    .font(NotchTheme.micro)
                    .foregroundStyle(primary.isPositive ? NotchTheme.positive : NotchTheme.negative)
            } else {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(NotchTheme.caption.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                Text("Stocks")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }
}

private struct ExpandedStocksView: View {
    @ObservedObject var plugin: StocksPlugin

    private static let priceFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Watchlist")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    plugin.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Refresh quotes")
            }

            if let error = plugin.lastError {
                Text(error)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plugin.quotes.isEmpty {
                Text("No symbols yet.")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textTertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(plugin.quotes) { quote in
                            quoteRow(quote)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add ticker", text: Binding(
                    get: { plugin.draftSymbol },
                    set: { plugin.draftSymbol = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { plugin.addDraftSymbol() }

                Button {
                    plugin.addDraftSymbol()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(plugin.draftSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func quoteRow(_ quote: StockQuote) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.symbol)
                    .font(NotchTheme.body.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                if quote.price > 0 {
                    Text(Self.priceFormatter.string(from: NSNumber(value: quote.price)) ?? "—")
                        .font(NotchTheme.caption.monospacedDigit())
                        .foregroundStyle(NotchTheme.textSecondary)
                } else {
                    Text("—")
                        .font(NotchTheme.caption)
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
            }

            Spacer(minLength: 0)

            MiniSparkline(values: quote.history.isEmpty && quote.price > 0
                          ? [quote.price - quote.change, quote.price]
                          : quote.history)
                .frame(width: 48, height: 18)
                .foregroundStyle(quote.isPositive ? NotchTheme.positive : NotchTheme.negative)

            Text(String(format: "%@%.2f%%", quote.percentChange >= 0 ? "+" : "", quote.percentChange))
                .font(NotchTheme.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(quote.isPositive ? NotchTheme.positive : NotchTheme.negative)
                .frame(width: 64, alignment: .trailing)

            Button {
                plugin.removeSymbol(quote.symbol)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Tiny path sparkline used in collapsed + expanded stock rows.
struct MiniSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let pts = normalized(in: geo.size)
            if pts.count >= 2 {
                Path { path in
                    path.move(to: pts[0])
                    for p in pts.dropFirst() {
                        path.addLine(to: p)
                    }
                }
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Path { path in
                    let y = geo.size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .opacity(0.4)
            }
        }
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2,
              let minV = values.min(),
              let maxV = values.max()
        else { return [] }
        let range = max(maxV - minV, 0.0001)
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height * (1 - CGFloat((value - minV) / range))
            return CGPoint(x: x, y: y)
        }
    }
}
