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
        /// Name in the app's language. CBR sends Russian names, and in an English UI
        /// they read as someone else's window; the system knows the name of every
        /// currency in every locale. Coins keep their CoinGecko name — those are
        /// English by nature, and "Bitcoin" needs no translating
        var title: String { CurrencyWidget.displayName(code: code, fallback: name, kind: kind) }
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

    nonisolated static func displayName(code: String, fallback: String, kind: Rate.Kind) -> String {
        guard kind == .fiat,
              let name = Locale.current.localizedString(forCurrencyCode: code),
              !name.isEmpty
        else { return fallback }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Search in settings: by code, and by name in any of the three spellings —
    /// the source's own, the app's language, and English. Before this, "eur" and
    /// "dollar" found nothing in a Russian list from the Central Bank
    nonisolated static func matches(_ rate: Rate, query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return false }
        if rate.code.lowercased().hasPrefix(text) { return true }
        if rate.name.lowercased().contains(text) { return true }
        if rate.title.lowercased().contains(text) { return true }
        let english = Locale(identifier: "en").localizedString(forCurrencyCode: rate.code)
        return english?.lowercased().contains(text) ?? false
    }

    private let context: WidgetContext
    /// Rates, networking, and cache live in the shared RateStore: shared by
    /// "Currency" and "Converter"
    var snapshot: Snapshot? { RateStore.shared.snapshot }
    var failure: String? { RateStore.shared.failure }
    /// How many units we're converting — 1 by default, changed by typing
    var amount: Double = 1

    /// Bounds for the conversion amount, shared with the converter. The cap
    /// keeps `Int(amount)` in the display path from trapping: 1e20 typed into
    /// the field is finite, equals its own `rounded()`, and Int(1e20) crashes —
    /// and the value used to be persisted before rendering, so the tile
    /// crashed again on every launch until the key was deleted by hand
    static let maxAmount: Double = 999_999_999_999

    static func sanitizedAmount(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, 0), maxAmount)
    }

    init(context: WidgetContext) {
        self.context = context
        amount = Self.sanitizedAmount(context.settings.get("amount", as: Double.self), fallback: 1)
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
        amount = Self.sanitizedAmount(value, fallback: 1)
        context.settings.set("amount", amount)
    }

    /// What we display in. CBR's rate comes in rubles, so everything else is
    /// divided by the base currency's rate: a currency's rate to itself is
    /// meaningless, so the base currency drops out of the list.
    /// Coins have their own base — see AppSettings.cryptoBase
    var base: String { AppSettings.shared.baseCurrency }

    /// How many rubles a unit of that currency costs. nil — its own rate is missing
    /// and conversion is impossible: substituting 1 used to leave ruble numbers
    /// labeled with the base currency's symbol
    private func unit(of code: String) -> Double? {
        guard code != "RUB" else { return 1 }
        return snapshot?.rates.first { $0.code == code }?.perUnit
    }

    /// The base actually applied to this kind: falls back to rubles when the chosen
    /// base's own rate is missing, so numbers and symbol always agree
    func effectiveBase(for kind: Rate.Kind) -> String {
        let wanted = kind == .crypto ? AppSettings.shared.cryptoBase : base
        return unit(of: wanted) == nil ? "RUB" : wanted
    }

    /// Which base a given row is shown in
    func base(for rate: Rate) -> String { effectiveBase(for: rate.kind) }

    /// The currencies' base — the one that drops out of the list
    var effectiveBase: String { effectiveBase(for: .fiat) }

    private func converted(_ rate: Rate) -> Rate {
        guard let unit = unit(of: effectiveBase(for: rate.kind)), unit != 1 else { return rate }
        var copy = rate
        copy.value = rate.perUnit / unit
        copy.previous = rate.previousPerUnit / unit
        copy.nominal = 1
        return copy
    }

    func rates(limit: Int) -> [Rate] {
        guard let snapshot else { return [] }
        // Only the currencies' base drops out: a coin never equals it, and the same
        // currency shown in another base is still worth reading
        let wanted = codes.filter { $0 != effectiveBase }
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
        let (data, response) = try await session.data(from: url)
        // Status is checked like the other sources' (Open-Meteo, CoinGecko):
        // an error page parsed as JSON used to slip through as a valid answer
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

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

        // Valid JSON with an empty Valute is not an answer: storing it would
        // overwrite a good cached snapshot with nothing — the offline fallback lost
        guard !rates.isEmpty else { throw URLError(.cannotParseResponse) }

        // The ruble isn't in the Central Bank list — it is the quote currency there,
        // everything is priced in it. Without this row the ruble could be removed
        // from the tile and never added back
        let ruble = CurrencyWidget.Rate(
            code: "RUB", name: "Russian Ruble", value: 1, previous: 1, nominal: 1)
        return .init(date: day, updated: Date(), rates: ([ruble] + rates).sorted { $0.code < $1.code })
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
