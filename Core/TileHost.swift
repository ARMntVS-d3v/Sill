import SwiftUI

// Shell wrapper around a widget instance: lifecycle, errors, isolation.
// Timeout: a watchdog task cancels activate/refresh after 10 s — a hung
// widget doesn't hold anything up, the panel is already running on cache
// by then.
// A widget with an unknown id (removed from the registry) — widget == nil,
// placeholder tile.
@MainActor @Observable
final class TileHost: Identifiable {
    static let timeout: Duration = .seconds(10)

    nonisolated let id: UUID
    private(set) var tile: Tile
    let context: WidgetContext
    private(set) var widget: (any Widget)?
    private(set) var lastError: String?
    private(set) var missingPermission: PermissionKind?

    @ObservationIgnored private var activateTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// Which activation is current; stale activate() completions check it
    @ObservationIgnored private var activationID = 0

    private func ifCurrent(_ generation: Int, _ body: (TileHost) -> Void) {
        guard activationID == generation else { return }
        body(self)
    }

    var descriptor: WidgetDescriptor? { widget.map { type(of: $0).descriptor } }

    init(tile: Tile, theme: Theme) {
        self.id = tile.id
        self.tile = tile
        self.context = WidgetContext(
            widgetID: tile.widgetID, tileID: tile.id, tileSize: tile.size, theme: theme)
        if let widgetType = WidgetRegistry.type(for: tile.widgetID) {
            self.widget = widgetType.init(context: context)
        }
        context.requestReactivate = { [weak self] in self?.reactivate() }
    }

    // Re-activate without a sleep cycle: access was granted while the panel
    // was open, the placeholder needs to go away
    func reactivate() {
        guard context.isAwake else { return }
        missingPermission = nil
        lastError = nil
        context.setState(panelVisible: true, boardActive: true)
        activateTask?.cancel()
        activateTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        wake()
    }

    func wake() {
        guard let widget, !context.isAwake || activateTask == nil else { return }
        context.setState(panelVisible: true, boardActive: true)
        context.startTickers()
        activateTask?.cancel()
        // Cancellation is cooperative: a stale activate() (e.g. awaiting a
        // permission prompt) can outlive sleep() and finish after the next
        // wake() has started. Its completion must not overwrite the current
        // activation's state or kill the current watchdog — the generation
        // check ignores anything that is no longer the live activation
        activationID += 1
        let generation = activationID
        let task = Task { [weak self] in
            do {
                try await widget.activate()
                self?.ifCurrent(generation) {
                    $0.lastError = nil
                    $0.missingPermission = nil
                }
            } catch is CancellationError {
            } catch let error as WidgetError {
                if case .permissionDenied(let kind) = error {
                    self?.ifCurrent(generation) {
                        $0.missingPermission = kind
                        $0.context.log("missing permission: \(kind.rawValue)")
                    }
                }
            } catch {
                self?.ifCurrent(generation) {
                    $0.lastError = "\(error)"
                    $0.context.log("activate failed: \(error)")
                }
            }
            self?.ifCurrent(generation) { $0.watchdogTask?.cancel() }
        }
        activateTask = task
        watchdogTask = Task {
            try? await Task.sleep(for: Self.timeout)
            task.cancel()
        }
    }

    /// The tile is leaving the board for good — let the widget clear what
    /// outlives it (published island state, file copies, cache entries), then
    /// drop the instance settings here: every widget's per-tile settings die
    /// with the tile, so the shell does it once instead of eighteen widgets
    /// each remembering to
    func willRemove() {
        widget?.tileWillRemove()
        context.settings.removeAll()
    }

    func sleep() {
        guard context.isAwake else { return }
        context.setState(panelVisible: false, boardActive: false)
        context.stopTickers()
        activationID += 1
        activateTask?.cancel()
        activateTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        widget?.deactivate()
    }

    func refreshNow() async {
        guard let widget else { return }
        let task = Task { try await widget.refresh() }
        let watchdog = Task {
            try? await Task.sleep(for: Self.timeout)
            task.cancel()
        }
        do {
            try await task.value
            lastError = nil
        } catch is CancellationError {
        } catch {
            lastError = "\(error)"
            context.log("refresh failed: \(error)")
        }
        watchdog.cancel()
    }

    func themeChanged(_ theme: Theme) { context.setTheme(theme) }

    // Layout changes come from the user in edit mode — the widget learns its
    // new size through the context and redraws for it
    func update(tile newTile: Tile) {
        tile = newTile
        context.setTileSize(newTile.size)
    }
}
