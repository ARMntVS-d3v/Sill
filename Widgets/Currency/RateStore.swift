import Foundation

// Shared rate store: "Currency" and "Converter" look at one snapshot, one
// network layer, one cache. Otherwise each widget would hit CBR and CoinGecko
// on its own, and CoinGecko's free tier is rate-limited — two widgets polling
// every five minutes would exhaust it.
@MainActor @Observable
final class RateStore {
    static let shared = RateStore()

    /// CBR publishes the official rate once a day (around 11:30 MSK) — asking
    /// more often just returns the same number. Check every six hours
    private static let fiatStale: TimeInterval = 6 * 3600
    /// Crypto moves constantly, hence five minutes. Can't go faster: CoinGecko's
    /// free tier is rate-limited, and exceeding it gets a refusal, not a fresh price
    private static let cryptoStale: TimeInterval = 300

    /// Cache namespaced "currency": the converter also opens with ready
    /// numbers after a restart, even when there's no currency tile on the board
    private let cache = WidgetCache(widgetID: "currency")
    private(set) var snapshot: CurrencyWidget.Snapshot?
    /// The network didn't answer and there's nothing to show
    private(set) var failure: String?
    /// Shared task: parallel ticks from several tiles don't duplicate the request
    private var loading: Task<Void, Never>?

    private init() {
        snapshot = cache.load("rates", as: CurrencyWidget.Snapshot.self).map(Self.withRuble)
    }

    /// The ruble row is added by the Central Bank source, but a snapshot cached
    /// before that change has no ruble — and the cache is only refreshed once every
    /// six hours. Add it on read too, so it's there right away
    private static func withRuble(_ value: CurrencyWidget.Snapshot) -> CurrencyWidget.Snapshot {
        guard !value.rates.contains(where: { $0.code == "RUB" }) else { return value }
        var copy = value
        copy.rates = ([
            CurrencyWidget.Rate(
                code: "RUB", name: "Russian Ruble", value: 1, previous: 1, nominal: 1)
        ] + value.rates).sorted { $0.code < $1.code }
        return copy
    }

    /// Where the numbers come from: CBR publishes once a day, coins refresh
    /// continuously. Shared caption for "Currency" and "Converter"
    var sourceNote: String {
        AppSettings.shared.cryptoCodes.isEmpty
            ? String(localized: "official CBR rate, updated daily")
            : String(localized: "CBR rate — daily; coins — every 5 minutes")
    }

    /// "Retry" button in the placeholder
    func retry() {
        failure = nil
        Task { await refreshIfStale() }
    }

    func refreshIfStale() async {
        if let loading {
            await loading.value
            return
        }
        let task = Task { await check() }
        loading = task
        await task.value
        loading = nil
    }

    private func check() async {
        let now = Date()
        // Fiat and crypto go stale on different schedules, so they're checked
        // separately: one shared interval would mean hitting CBR every ten
        // minutes for a rate that changes once a day
        let fiatStale = snapshot.map { now.timeIntervalSince($0.updated) > Self.fiatStale } ?? true
        if fiatStale {
            do {
                try await refreshFiat()
                failure = nil
            } catch {
                // The rate is good for a day — yesterday's beats an empty tile.
                // But without a cache, "Loading…" forever isn't a state, it's a lie
                sillLog("rates didn't refresh: \(error)")
                if snapshot == nil { failure = String(localized: "Couldn't load rates") }
                // No early return: crypto refreshes even while CBR is down —
                // the sources are independent, and bailing out here froze coin
                // prices for as long as the fiat fetch kept failing
            }
        }
        guard snapshot != nil, !AppSettings.shared.cryptoCodes.isEmpty else { return }
        let cryptoStale = snapshot?.cryptoUpdated
            .map { now.timeIntervalSince($0) > Self.cryptoStale } ?? true
        if cryptoStale { await refreshCrypto() }
    }

    private func refreshFiat() async throws {
        var loaded = try await CentralBank.rates()
        // Keep crypto rates from the previous response: they live on their own rhythm
        loaded.rates += snapshot?.rates.filter { $0.kind == .crypto } ?? []
        loaded.cryptoUpdated = snapshot?.cryptoUpdated
        store(loaded)
    }

    /// Crypto is a separate, optional source: no answer just means fiat-only
    /// in the list, not an empty tile
    private func refreshCrypto() async {
        guard var current = snapshot, !AppSettings.shared.cryptoCodes.isEmpty else { return }
        do {
            let crypto = try await CoinGecko.rates()
            current.rates = current.rates.filter { $0.kind == .fiat } + crypto
            current.cryptoUpdated = Date()
            store(current)
        } catch {
            // Fiat may still be fine — only complain when the tile would show
            // nothing at all: every chosen currency is a coin and none is
            // cached. That case used to leave a silently empty tile with no Retry
            sillLog("crypto rates didn't refresh: \(error)")
            let cryptoCached = current.rates.contains { $0.kind == .crypto }
            let fiatChosen = AppSettings.shared.currencies.contains { !$0.isCrypto }
            if !cryptoCached, !fiatChosen {
                failure = String(localized: "Couldn't load rates")
            }
        }
    }

    private func store(_ value: CurrencyWidget.Snapshot) {
        snapshot = value
        cache.save("rates", value)
    }
}
