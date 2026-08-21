import SwiftUI

@MainActor @Observable
final class WidgetContext {
    private(set) var tileSize: TileSize
    private(set) var isPanelVisible = false
    private(set) var isBoardActive = false
    private(set) var isFocused = false
    private(set) var theme: Theme

    // Own tile's id: prefixes cache keys for per-instance data (the cache
    // itself is shared across the widget)
    @ObservationIgnored let tileID: UUID
    @ObservationIgnored let settings: WidgetSettings
    @ObservationIgnored let cache: WidgetCache
    @ObservationIgnored let secrets: SecretsStore

    // Widget noticed the reason it failed is gone (access was granted) —
    // asks the shell to retry activation: the shell drew the placeholder,
    // only the shell can clear it
    @ObservationIgnored var requestReactivate: (@MainActor () -> Void)?

    @ObservationIgnored private let widgetID: String
    @ObservationIgnored private var tickers: [(interval: Duration, tick: @MainActor () async -> Void)] = []
    @ObservationIgnored private var tickerTasks: [Task<Void, Never>] = []

    var isAwake: Bool { isPanelVisible && isBoardActive }

    init(widgetID: String, tileID: UUID, tileSize: TileSize, theme: Theme) {
        self.widgetID = widgetID
        self.tileID = tileID
        self.tileSize = tileSize
        self.theme = theme
        self.settings = WidgetSettings(widgetID: widgetID, tileID: tileID)
        self.cache = WidgetCache(widgetID: widgetID)
        self.secrets = SecretsStore(widgetID: widgetID)
    }

    func log(_ message: String) {
        sillLog("[\(widgetID)] \(message)")
    }

    // The widget's only legal timer: runs only while the widget is active.
    func schedule(every interval: Duration, _ tick: @escaping @MainActor () async -> Void) {
        tickers.append((interval, tick))
        if isAwake { startTicker(interval: interval, tick: tick) }
    }

    // Internal API for the shell (TileHost) — widgets don't call these.

    func setState(panelVisible: Bool? = nil, boardActive: Bool? = nil, focused: Bool? = nil) {
        if let panelVisible { isPanelVisible = panelVisible }
        if let boardActive { isBoardActive = boardActive }
        if let focused { isFocused = focused }
    }

    func setTheme(_ theme: Theme) { self.theme = theme }
    func setTileSize(_ size: TileSize) { tileSize = size }

    func startTickers() {
        guard tickerTasks.isEmpty else { return }
        for t in tickers { startTicker(interval: t.interval, tick: t.tick) }
    }

    func stopTickers() {
        for task in tickerTasks { task.cancel() }
        tickerTasks.removeAll()
    }

    private func startTicker(interval: Duration, tick: @escaping @MainActor () async -> Void) {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: interval)
            }
        }
        tickerTasks.append(task)
    }
}
