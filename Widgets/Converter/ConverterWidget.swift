import AppKit
import SwiftUI

// Converter: an arbitrary pair and amount, recalculated either way with the
// swap button. Rates come from the shared RateStore — the widget has no
// network of its own. Pair and amount are per-instance settings: two tiles on
// the board can hold two different pairs.
// Choices are all CBR fiat plus coins added in the "Currency" settings: the
// "which coins matter" list lives in one place in the app, the converter
// doesn't keep its own.
@MainActor @Observable
final class ConverterWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "converter",
        name: "Converter",
        icon: "arrow.left.arrow.right",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    private let context: WidgetContext
    private(set) var from = "USD"
    private(set) var to = "RUB"
    /// How much we're converting — in the `from` currency
    private(set) var amount: Double = 100

    init(context: WidgetContext) {
        self.context = context
        from = context.settings.get("from", as: String.self) ?? "USD"
        to = context.settings.get("to", as: String.self) ?? "RUB"
        amount = CurrencyWidget.sanitizedAmount(
            context.settings.get("amount", as: Double.self), fallback: 100)
        context.schedule(every: .seconds(60)) {
            await RateStore.shared.refreshIfStale()
        }
    }

    var snapshot: CurrencyWidget.Snapshot? { RateStore.shared.snapshot }
    var failure: String? { RateStore.shared.failure }

    func activate() async throws { await RateStore.shared.refreshIfStale() }
    func refresh() async throws { await RateStore.shared.refreshIfStale() }
    func retry() { RateStore.shared.retry() }

    var body: AnyView {
        AnyView(ConverterTileView(widget: self, size: context.tileSize))
    }

    // MARK: - Conversion

    /// Rubles per unit of the code; ruble is the unit by definition
    func perUnit(_ code: String) -> Double? {
        if code == "RUB" { return 1 }
        return snapshot?.rates.first { $0.code == code }?.perUnit
    }

    /// What it comes out to in `to`; nil — a rate for one of the sides is missing
    var result: Double? {
        guard let f = perUnit(from), let t = perUnit(to), t > 0 else { return nil }
        return amount * f / t
    }

    /// "1 USD = 92.50 RUB" — unit rate, context under the result
    var rateLine: String? {
        guard let f = perUnit(from), let t = perUnit(to), t > 0 else { return nil }
        return "1 \(from) = \(Self.value(f / t)) \(to)"
    }

    /// The same amount in the app's other currencies — the large size.
    /// Continues the "Currency" settings' selection; the converter has none of its own
    func others(limit: Int) -> [(code: String, value: Double)] {
        guard let f = perUnit(from) else { return [] }
        var codes = AppSettings.shared.currencies.map(\.code)
        if !codes.contains("RUB") { codes.insert("RUB", at: 0) }
        let rest = codes.filter { $0 != from && $0 != to }
        return rest.prefix(limit).compactMap { code in
            guard let t = perUnit(code), t > 0 else { return nil }
            return (code, amount * f / t)
        }
    }

    // MARK: - Controls

    func setAmount(_ value: Double) {
        amount = CurrencyWidget.sanitizedAmount(value, fallback: 100)
        context.settings.set("amount", amount)
    }

    func setFrom(_ code: String) {
        from = code
        context.settings.set("from", from)
    }

    func setTo(_ code: String) {
        to = code
        context.settings.set("to", to)
    }

    func swap() {
        (from, to) = (to, from)
        context.settings.set("from", from)
        context.settings.set("to", to)
    }

    // MARK: - Picker menus

    /// Fiat — the full CBR list from the snapshot. The ruble is in it too: the
    /// source adds it itself, so there's no second, hand-written entry here
    var fiatOptions: [(code: String, name: String)] {
        (snapshot?.rates ?? [])
            .filter { $0.kind == .fiat }
            .map { (code: $0.code, name: $0.title) }
    }

    /// Coins — only the ones chosen in the "Currency" settings: that's the whole snapshot
    var cryptoOptions: [(code: String, name: String)] {
        (snapshot?.rates ?? [])
            .filter { $0.kind == .crypto }
            .map { (code: $0.code, name: $0.title) }
    }

    // MARK: - Formatting

    /// Number without the currency symbol: the code sits next to it separately.
    /// Precision matches money(): cents down to a hundred, no cents from a
    /// thousand up. Very small values (a ruble in bitcoin) use significant
    /// digits, otherwise it prints a bare zero.
    /// compact — seven-digit sums don't fit in the small tile, so "6.02M" there
    nonisolated static func value(_ value: Double, compact: Bool = false) -> String {
        guard value != 0 else { return "0" }
        if value < 0.01 {
            return value.formatted(.number.precision(.significantDigits(3)))
        }
        if compact && value >= 100_000 {
            return value.formatted(.number.notation(.compactName).precision(.significantDigits(3)))
        }
        let digits: Int
        switch value {
        case ..<100: digits = 2
        case ..<1000: digits = 1
        default: digits = 0
        }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }
}
