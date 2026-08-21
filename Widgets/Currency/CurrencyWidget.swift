import AppKit
import SwiftUI

/// A chosen currency: code and where to get the rate. One list instead of
/// two — so the tile's order matches the order they were added in
struct CurrencyChoice: Codable, Sendable, Equatable, Identifiable {
    var code: String
    var isCrypto: Bool

    var id: String { code }
}

// CBR exchange rates. Source — cbr-xml-daily.ru: the same official rate, but in
// JSON and without a key. The rate changes once a day, so we refresh every six
// hours and live off the cache — the panel opens with numbers already in place.
@MainActor @Observable
final class CurrencyWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "currency",
        name: "Currency",
        icon: "banknote",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    struct Rate: Codable, Sendable, Identifiable, Equatable {
        /// Fiat comes from CBR, crypto from CoinGecko. Different sources, but
        /// in the tile it's one list: rubles per unit
        enum Kind: String, Codable, Sendable { case fiat, crypto }

        var code: String
        var name: String
        var value: Double
        var previous: Double
        var nominal: Int
        var kind: Kind = .fiat

        var id: String { code }
        /// Rubles per single unit — CBR reports the rate per nominal (e.g. per 10 yuan)
        var perUnit: Double { nominal > 0 ? value / Double(nominal) : value }
        var previousPerUnit: Double { nominal > 0 ? previous / Double(nominal) : previous }
        var change: Double { perUnit - previousPerUnit }
        var changeShare: Double { previousPerUnit > 0 ? change / previousPerUnit : 0 }
    }

    struct Snapshot: Codable, Sendable {
        var date: Date
        var updated: Date
        var rates: [Rate]
        /// When crypto was last refreshed — it runs on its own rhythm
        var cryptoUpdated: Date?
    }

    /// Default shown currencies: dollar, euro, and lari — the rest is in tile settings
    static let defaultCodes = ["USD", "EUR", "GEL"]

    private let context: WidgetContext
    /// Rates, networking, and cache live in the shared RateStore: shared by
    /// "Currency" and "Converter"
    var snapshot: Snapshot? { RateStore.shared.snapshot }
    var failure: String? { RateStore.shared.failure }
    /// How many units we're converting — 1 by default, changed by typing
    var amount: Double = 1

    init(context: WidgetContext) {
        self.context = context
        amount = context.settings.get("amount", as: Double.self) ?? 1
        // Frequent tick, but cheap: the network is only touched once data goes stale
        context.schedule(every: .seconds(60)) {
            await RateStore.shared.refreshIfStale()
        }
    }

    func activate() async throws { await RateStore.shared.refreshIfStale() }

    /// "Retry" button in the placeholder
    func retry() { RateStore.shared.retry() }

    func refresh() async throws { await RateStore.shared.refreshIfStale() }

    var body: AnyView {
        AnyView(CurrencyTileView(widget: self, size: context.tileSize))
    }

    // Click opens nothing: the app isn't only for Russia, and sending everyone
    // to the CBR site would be wrong. Everything needed is already in the tile

    /// Shown currencies: chosen in app settings, "Currency" section.
    /// Used to read a tile setting, which had nowhere to write to
    var codes: [String] {
        let chosen = AppSettings.shared.currencies.map(\.code)
        return chosen.isEmpty ? Self.defaultCodes : chosen
    }

    func setAmount(_ value: Double) {
        amount = max(value, 0)
        context.settings.set("amount", amount)
    }

    /// What we display in. CBR's rate comes in rubles, so everything else is
    /// divided by the base currency's rate: a currency's rate to itself is
    /// meaningless, so the base currency drops out of the list
    var base: String { AppSettings.shared.baseCurrency }

    /// How many rubles a unit of the base currency costs
    private var baseUnit: Double {
        guard base != "RUB", let snapshot else { return 1 }
        return snapshot.rates.first { $0.code == base }?.perUnit ?? 1
    }

    private func converted(_ rate: Rate) -> Rate {
        guard baseUnit != 1 else { return rate }
        var copy = rate
        copy.value = rate.perUnit / baseUnit
        copy.previous = rate.previousPerUnit / baseUnit
        copy.nominal = 1
        return copy
    }

    func rates(limit: Int) -> [Rate] {
        guard let snapshot else { return [] }
        let wanted = codes.filter { $0 != base }
        let selected = wanted.compactMap { code in snapshot.rates.first { $0.code == code } }
        return Array(selected.prefix(limit)).map(converted)
    }

    /// Where the numbers come from — shared caption from the rate store
    var sourceNote: String { RateStore.shared.sourceNote }

    /// Base currency symbol
    nonisolated static func symbol(_ base: String) -> String {
        switch base {
        case "USD": "$"
        case "EUR": "€"
        default: "₽"
        }
    }

    /// What can be picked as the base currency. Three options: the rest have
    /// nothing to compute against, and a long list would turn the setting into
    /// another search
    static let baseOptions = [
        ("RUB", String(localized: "Ruble")),
        ("USD", String(localized: "Dollar")),
        ("EUR", String(localized: "Euro")),
    ]

    // "85.01 ₽" — with kopecks, the way CBR prints it. Bitcoin has no kopecks:
    // a seven-digit number with cents is unreadable and doesn't fit
    nonisolated static func money(_ value: Double, base: String = "RUB") -> String {
        let digits: Int
        switch value {
        case ..<100: digits = 2
        case ..<1000: digits = 1
        default: digits = 0
        }
        return value.formatted(.number.precision(.fractionLength(digits)))
            + " " + symbol(base)
    }

    nonisolated static func changeText(_ rate: Rate) -> String {
        let sign = rate.change >= 0 ? "+" : "−"
        // For crypto, the absolute change is thousands of rubles — unreadable:
        // show percent there instead
        if rate.kind == .crypto {
            return sign
                + abs(rate.changeShare * 100).formatted(.number.precision(.fractionLength(1)))
                + " %"
        }
        return sign + abs(rate.change).formatted(.number.precision(.fractionLength(2)))
    }
}

enum CentralBank {
    private static let url = URL(string: "https://www.cbr-xml-daily.ru/daily_json.js")!

    nonisolated static func rates() async throws -> CurrencyWidget.Snapshot {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        let (data, _) = try await session.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valutes = json["Valute"] as? [String: [String: Any]]
        else { throw URLError(.cannotParseResponse) }

        let day = (json["Date"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        } ?? Date()

        let rates: [CurrencyWidget.Rate] = valutes.compactMap { code, item in
            guard let value = item["Value"] as? Double,
                  let previous = item["Previous"] as? Double,
                  let nominal = item["Nominal"] as? Int,
                  let name = item["Name"] as? String
            else { return nil }
            return .init(
                code: code, name: name, value: value, previous: previous, nominal: nominal)
        }
        .sorted { $0.code < $1.code }

        return .init(date: day, updated: Date(), rates: rates)
    }
}


// Crypto — CoinGecko: public API without a key, price already in rubles and
// 24h change in one request. Free access is rate-limited (a handful of
// requests per minute), so we ask no more often than the widget itself refreshes.
enum CoinGecko {
    /// How many coins we offer to choose from — top by market cap
    static let listLimit = 50

    private static func marketsURL(limit: Int) -> URL {
        URL(string: "https://api.coingecko.com/api/v3/coins/markets"
            + "?vs_currency=rub&order=market_cap_desc&per_page=\(limit)&page=1"
            + "&price_change_percentage=24h")!
    }

    /// Rates of the chosen coins in rubles
    nonisolated static func rates() async throws -> [CurrencyWidget.Rate] {
        let all = try await markets(limit: listLimit)
        let wanted = Set(await AppSettings.shared.cryptoCodes)
        return all.filter { wanted.contains($0.code) }
    }

    /// Top coins by market cap — used both for the settings list and the rates themselves
    nonisolated static func markets(limit: Int = listLimit) async throws -> [CurrencyWidget.Rate] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: marketsURL(limit: limit))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return items.compactMap { item in
            guard let symbol = item["symbol"] as? String,
                  let name = item["name"] as? String,
                  let price = item["current_price"] as? Double
            else { return nil }
            // Yesterday's price is derived from the 24h change: there's no
            // separate "price a day ago" field in the response
            let change = item["price_change_percentage_24h"] as? Double ?? 0
            let previous = change == -100 ? price : price / (1 + change / 100)
            return CurrencyWidget.Rate(
                code: symbol.uppercased(), name: name, value: price,
                previous: previous, nominal: 1, kind: .crypto)
        }
    }
}
