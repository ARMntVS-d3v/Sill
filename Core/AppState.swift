import SwiftUI

@MainActor @Observable
final class AppState {
    private(set) var config: AppConfig = .makeDefault()
    private(set) var isPanelVisible = false
    var pinned = false

    let themeEngine = ThemeEngine()
    let appearance = Appearance()
    var theme: Theme { themeEngine.current }
    var showSettings = false
    var isEditing = false
    /// Whether the chat is expanded in place of the board. Survives the panel
    /// closing: minimized mid-chat means it reopens in chat — that's its own
    /// state, not a one-off mode
    var askOpen = UserDefaults.standard.bool(forKey: "ask.open") {
        didSet { UserDefaults.standard.set(askOpen, forKey: "ask.open") }
    }

    @ObservationIgnored private var undoStack: [AppConfig] = []

    /// How the panel appears. From the notch — when opened by clicking it: the
    /// gesture and the animation are the same thing. The hotkey has nothing to
    /// do with the notch, so the panel just slides down from the top like a drawer
    enum Appearing: Sendable {
        case notch, slide

        /// How long to wait before removing the window from screen: exactly as
        /// long as the exit animation takes, otherwise the window vanishes mid-motion
        var hideDuration: TimeInterval {
            switch self {
            case .notch: Motion.afterMove(Motion.panelNotch)
            case .slide: Motion.afterMove(Motion.panelSlideSettle)
            }
        }
    }
    var appearing: Appearing = .notch

    // Starting scale for the "flowing out" animation: the notch's size as a fraction of the panel
    var collapseScale = CGSize(width: 0.25, height: 0.12)
    // Top content inset: notch area + gap. Content never sits under the notch,
    // the panel's top strip stays plain background — the notch dissolves into it
    var topInset: CGFloat = 12
    // Width of this screen's notch — the middle of the top row ("wings") routes around it
    var notchWidth: CGFloat = 185

    // The shell (view) requests the panel be closed — the controller owns the window.
    @ObservationIgnored var requestHide: (() -> Void)?

    @ObservationIgnored private var clipboardObserver: NSObjectProtocol?
    @ObservationIgnored private var hosts: [UUID: TileHost] = [:]
    @ObservationIgnored private var loaded = false

    var activeBoard: Board? {
        config.boards.first { $0.id == config.activeBoardID }
    }

    var activeHosts: [TileHost] {
        (activeBoard?.tiles ?? []).map { host(for: $0) }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        config = ConfigStore.load()
        syncClipboardBoard()
        clipboardObserver = NotificationCenter.default.addObserver(
            forName: .sillClipboardToggled, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncClipboardBoard() }
        }
        themeEngine.loadIfNeeded()
        applyBoardTheme()
    }

    /// A board can have its own theme. Applied on every switch, not just at
    /// load — otherwise the config's themeName field would mean nothing
    private func applyBoardTheme() {
        guard let name = activeBoard?.themeName else { return }
        themeEngine.select(name: name)
    }

    /// Clipboard isn't a widget, it's a whole board: enabled in settings, the
    /// board appears last; disabled, it disappears along with its dot in the wing
    func syncClipboardBoard() {
        let wanted = AppSettings.shared.clipboardEnabled
        let index = config.boards.firstIndex { $0.kind == .clipboard }
        if wanted, index == nil {
            config.boards.append(
                Board(
                    id: UUID(), name: String(localized: "Clipboard"), icon: "doc.on.clipboard",
                    themeName: nil, tiles: [], kind: .clipboard))
            persist()
        } else if !wanted, let index {
            let id = config.boards[index].id
            // Never remove the last board: an empty list is a dead end for the
            // panel — no dots, "Add Widget" silently does nothing, and that would
            // hit disk
            guard config.boards.count > 1 else {
                sillLog("[boards] clipboard is the last board, not removing")
                return
            }
            forgetBoard(id)
            config.boards.remove(at: index)
            if config.activeBoardID == id {
                config.activeBoardID = config.boards.first?.id ?? id
            }
            persist()
        }
    }

    /// Open the clipboard: the panel shows its board right away. Remember where
    /// to return on close — otherwise the panel would always reopen on the
    /// clipboard after the first hotkey press, even if nobody navigated there by hand
    @ObservationIgnored private var boardBeforeClipboard: UUID?

    func showClipboardBoard() {
        loadIfNeeded()
        guard let board = config.boards.first(where: { $0.kind == .clipboard }) else { return }
        // The panel was minimized mid-conversation — the clipboard hotkey should
        // open the clipboard, not the chat: this call is a direct request for history
        askOpen = false
        if config.activeBoardID != board.id { boardBeforeClipboard = config.activeBoardID }
        selectBoard(board.id)
    }

    func panelDidShow() {
        // Order matters. First, the visibility flag on the next run-loop pass:
        // SwiftUI needs to render the collapsed state before there's anything to
        // animate from. Only then, on a separate pass, wake the widgets — waking
        // them triggers the first metrics read and a poll of every system process,
        // and doing that in the same tick where the animation starts is a sure
        // way to get a stutter instead of motion. The content is already there
        // either way: widgets keep their own state and show the last data they had
        let count = activeHosts.count
        if !isPanelVisible {
            DispatchQueue.main.async { [weak self] in
                guard let self, !panelIsClosing else { return }
                isPanelVisible = true
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, isPanelVisible || !panelIsClosing else { return }
            for host in activeHosts { host.wake() }
            sillLog("[panel] show, awake tiles: \(count)")
        }
    }

    #if DEBUG
    // For snapshots only: show content without actually starting widgets
    func setPanelVisibleForSnapshot(_ value: Bool) { isPanelVisible = value }
    #endif

    /// The panel is being closed right now: a deferred flag flip shouldn't wake it back up
    @ObservationIgnored private var panelIsClosing = false

    func panelDidHide() {
        panelIsClosing = true
        isPanelVisible = false
        // Everything else happens without animation: switching boards and
        // leaving edit mode used to land in the same transaction as the panel
        // leaving, and played out on its curve. You could see the content change
        // while the panel was collapsing
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { resetOnHide() }
        for host in hosts.values { host.sleep() }
        sillLog("[panel] hide, all tiles asleep")
        DispatchQueue.main.async { [weak self] in self?.panelIsClosing = false }
    }

    private func resetOnHide() {
        // Panel closed — edit mode ends, like the iOS home screen: leaving the
        // screen is the same as tapping "Done". Every action is already saved,
        // there's nothing to accumulate undo for across sessions — otherwise the
        // next "undo" would revert something the person doesn't even remember doing
        isEditing = false
        undoStack.removeAll()
        showSettings = false
        // Opened the clipboard via hotkey — return to the board we were on before it.
        // Navigated there by hand (the dot in the wing) — stay there
        if let previous = boardBeforeClipboard, activeBoard?.kind == .clipboard {
            boardBeforeClipboard = nil
            config.activeBoardID = previous
            ConfigStore.save(config)
        }
        // If a board-swipe gesture wasn't finished, the strip snaps into place
        // instantly: a spring-back animation on top of the panel collapsing
        // would be two motions at once
        boardDragOffset = 0
        boardDragNeighbor = nil
    }

    // A new board starts empty and becomes active right away: the person tapped
    // "+" to fill it, not to look at the old one
    func addBoard() {
        undoStack.append(config)
        let board = Board(
            id: UUID(),
            name: String(localized: "Board \(config.boards.count + 1)"),
            icon: "square.grid.2x2",
            themeName: nil,
            tiles: [])
        for host in hosts.values { host.sleep() }
        config.boards.append(board)
        config.activeBoardID = board.id
        persist()
        isEditing = true
    }

    /// Move a board one position left or right. Board order is the order of
    /// dots in the wing and the order swiping pages through them, so it needs
    /// to be controllable
    func moveBoard(_ id: UUID, by offset: Int) {
        guard let index = config.boards.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard config.boards.indices.contains(target) else { return }
        undoStack.append(config)
        config.boards.swapAt(index, target)
        persist()
    }

    /// Move to a specific spot — one config change and one undo entry: dragging
    /// a dot writes the order on release, not step by step
    func moveBoard(_ id: UUID, to target: Int) {
        guard let index = config.boards.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(target, 0), config.boards.count - 1)
        guard clamped != index else { return }
        undoStack.append(config)
        let board = config.boards.remove(at: index)
        config.boards.insert(board, at: clamped)
        persist()
    }

    func renameBoard(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = config.boards.firstIndex(where: { $0.id == id })
        else { return }
        undoStack.append(config)
        config.boards[index].name = trimmed
        persist()
    }

    // Never remove the last board: a panel with zero boards is a dead end
    /// When a board is removed, no reference to it may remain: not as a neighbor
    /// in an in-flight gesture, not as "where to return from the clipboard".
    /// Otherwise the panel would reopen empty, pointing at a board that no longer exists
    private func forgetBoard(_ id: UUID) {
        if boardBeforeClipboard == id { boardBeforeClipboard = nil }
        if boardDragNeighbor == id {
            boardDragNeighbor = nil
            boardDragOffset = 0
            boardDragRaw = 0
        }
        if pendingSettle == id {
            pendingSettle = nil
            isSettlingBoard = false
        }
    }

    func removeBoard(_ id: UUID) {
        guard config.boards.count > 1, let index = config.boards.firstIndex(where: { $0.id == id })
        else { return }
        undoStack.append(config)
        // The clipboard board lives by the setting — clear the setting and the
        // board follows. Push undo here too: board removal is promised to be reversible
        if config.boards[index].kind == .clipboard {
            AppSettings.shared.clipboardEnabled = false
            return
        }
        for tile in config.boards[index].tiles {
            host(for: tile).willRemove()
            hosts[tile.id]?.sleep()
            hosts[tile.id] = nil
        }
        forgetBoard(id)
        config.boards.remove(at: index)
        if config.activeBoardID == id {
            config.activeBoardID = config.boards[max(index - 1, 0)].id
        }
        persist()
        if isPanelVisible {
            for host in activeHosts { host.wake() }
        }
    }

    // Live paging: the board follows the finger, the neighbor slides in from the side.
    // Offset in points, zero means the active board is exactly in place
    private(set) var boardDragOffset: CGFloat = 0
    private(set) var boardDragNeighbor: UUID?
    // Which side the neighbor is on: +1 right (next), -1 left (previous).
    // The side is locked for the duration of the gesture. It can't be derived
    // from the offset's sign: on the way back the offset passes through zero,
    // and the neighbor would jump across the screen
    private(set) var boardDragSide: CGFloat = 1

    // Neighbor in the given direction: 1 — next, -1 — previous
    private func neighborBoard(_ direction: Int) -> Board? {
        guard let index = config.boards.firstIndex(where: { $0.id == config.activeBoardID })
        else { return nil }
        let target = index + direction
        return config.boards.indices.contains(target) ? config.boards[target] : nil
    }

    @ObservationIgnored private var wakeTask: Task<Void, Never>?

    func beginBoardDrag() {
        // A new swipe started while the strip was still moving — settle the
        // previous one instantly so the gesture starts from a clean state
        // instead of mid-animation
        applySettleNow()
        boardDragOffset = 0
        boardDragRaw = 0
        boardDragNeighbor = nil
        wokenNeighbor = nil
        // A deferred block from the previous cancel shouldn't clear the neighbor mid-new-gesture
        cancelToken += 1
    }

    /// How far the finger actually moved. Near the edge the strip lags behind
    /// the finger (resistance), and resistance can't be computed from the
    /// already-dampened offset — it would compound the damping on itself
    @ObservationIgnored private var boardDragRaw: CGFloat = 0
    @ObservationIgnored private var cancelToken = 0

    /// Palette moved: drag the board along with it. Width — how far to the neighbor.
    /// A settle-to-neighbor is in progress — ignore new gesture events entirely.
    /// Without this, trackpad inertia kept paging past the next board, and one
    /// sharp swipe could skip two or three screens
    @ObservationIgnored private(set) var isSettlingBoard = false

    func updateBoardDrag(by delta: CGFloat, width: CGFloat) {
        guard !isSettlingBoard else { return }
        boardDragRaw += delta
        let raw = boardDragRaw
        // Fingers move left — heading to the next board. Right at zero, the side
        // isn't reconsidered: otherwise on the way back the neighbor would swap
        // to the opposite one and flicker mid-motion
        let direction: Int
        if abs(raw) < 8, let current = boardDragNeighbor,
           let index = config.boards.firstIndex(where: { $0.id == current }),
           let active = config.boards.firstIndex(where: { $0.id == config.activeBoardID }) {
            direction = index > active ? 1 : -1
        } else {
            direction = raw < 0 ? 1 : -1
        }
        let neighbor = neighborBoard(direction)

        // Nowhere to go past the last board: resistance grows gradually and
        // eases into a limit, like the system does. The old approach (delta/4
        // and a hard stop) gave free travel, then a wall
        if neighbor == nil {
            let limit = width / 6
            boardDragOffset = limit * tanh(raw / limit)
        } else {
            boardDragOffset = max(min(raw, width), -width)
        }

        if neighbor?.id != boardDragNeighbor {
            // Don't put the previous neighbor to sleep mid-gesture: on a zigzag
            // around zero, heavy widgets would get chased up and down. Whatever's
            // unused sleeps once at the end
            boardDragNeighbor = neighbor?.id
            boardDragSide = direction > 0 ? 1 : -1
            wokenNeighbor = nil
            wakeTask?.cancel()
            // Slow movement: wait, in case the person just twitched a finger and
            // pulled back — no reason to wake heavy widgets for that
            if let neighbor, isPanelVisible {
                let id = neighbor.id
                wakeTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard let self, !Task.isCancelled, boardDragNeighbor == id else { return }
                    wakeNeighbor(id)
                }
            }
        }

        // Fast flick: settling takes the same 180 ms, and on a timer widgets used
        // to wake up only AFTER the board was already in place — empty tiles would
        // flash by on screen. So as soon as the gesture looks like a page turn, wake right away
        if let id = boardDragNeighbor, isPanelVisible,
           abs(boardDragOffset) > width * 0.12 || abs(delta) > 8 {
            wakeTask?.cancel()
            wakeNeighbor(id)
        }
    }

    /// Who's already been woken for this gesture — so wake isn't called on every frame
    @ObservationIgnored private var wokenNeighbor: UUID?

    private func wakeNeighbor(_ id: UUID) {
        guard wokenNeighbor != id,
              let board = config.boards.first(where: { $0.id == id })
        else { return }
        wokenNeighbor = id
        for host in hosts(of: board) { host.wake() }
    }

    /// Finger lifted: settle onto the neighbor or roll back.
    /// Decided not just by distance traveled but also by speed — a short sharp
    /// swipe should page the same way a slow, long one does
    func endBoardDrag(width: CGFloat, velocity: CGFloat = 0) {
        guard let neighborID = boardDragNeighbor else {
            cancelBoardDrag(velocity: velocity)
            return
        }
        // A flick only counts toward the neighbor: a jerk back should roll back instead
        let towardsNeighbor = boardDragSide > 0 ? boardDragOffset < 0 : boardDragOffset > 0
        let flung = abs(velocity) > 220 && (velocity < 0) == (boardDragSide > 0)
        guard towardsNeighbor, abs(boardDragOffset) > width * 0.18 || flung else {
            cancelBoardDrag(velocity: velocity)
            return
        }
        finishDrag(to: neighborID, width: width, velocity: velocity)
    }

    /// Where we're headed and which settle pass is running now. The token
    /// keeps a stale settle's deferred block from firing after a new swipe interrupted it
    @ObservationIgnored private var pendingSettle: UUID?
    @ObservationIgnored private var settleToken = 0

    // Settle onto the neighbor — shared by both swiping and tapping a board dot
    private func finishDrag(to neighborID: UUID, width: CGFloat, velocity: CGFloat = 0) {
        // A second swipe right after the first doesn't wait for it to finish:
        // settle the previous one instantly and start the new one from the
        // already-switched board, or the strip stutters mid-transition
        applySettleNow()
        isSettlingBoard = true
        pendingSettle = neighborID
        settleToken += 1
        let token = settleToken

        // The settle animation starts — the board must already be alive, not wake up at the end
        if isPanelVisible { wakeNeighbor(neighborID) }
        // Left the clipboard by hand — nowhere to return to later
        if config.boards.first(where: { $0.id == neighborID })?.kind != .clipboard {
            boardBeforeClipboard = nil
        }
        let target: CGFloat = boardDragSide > 0 ? -width : width
        withAnimation(strip(from: boardDragOffset, to: target, velocity: velocity)) {
            boardDragOffset = target
            boardDragRaw = target
        }
        // The last frame of the settle and the first frame after switching boards
        // line up pixel for pixel: the neighbor is already dead center, so
        // swapping the active board is invisible
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.afterMove(Motion.boardSettle)) { [weak self] in
            guard let self, token == settleToken else { return }
            applySettleNow()
        }
    }

    /// Finish the switch right now, with no animation
    private func applySettleNow() {
        guard let neighborID = pendingSettle else {
            isSettlingBoard = false
            return
        }
        pendingSettle = nil
        // The board could have been deleted mid-gesture (from settings or a
        // context menu). Can't switch to one that no longer exists — the panel
        // would end up empty
        guard config.boards.contains(where: { $0.id == neighborID }) else {
            boardDragOffset = 0
            boardDragRaw = 0
            boardDragNeighbor = nil
            isSettlingBoard = false
            return
        }
        let leaving = config.activeBoardID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            config.activeBoardID = neighborID
            boardDragOffset = 0
            boardDragRaw = 0
            boardDragNeighbor = nil
        }
        // The board just became active — its widgets need to be running, even if
        // the gesture didn't wake them. But not on this exact frame: waking
        // triggers the first refresh of every widget on the new board, and
        // measurements showed 32 ms of work landing right on the swap frame —
        // the swipe would stutter right at the very end. Same order as opening
        // the panel: frame first, widgets after
        wakeTask?.cancel()
        wokenNeighbor = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, config.activeBoardID == neighborID else { return }
            if isPanelVisible {
                for host in activeHosts { host.wake() }
            }
            if leaving != neighborID { sleepBoard(leaving) }
            sleepBoardsAside()
        }
        // Edit mode survives paging, like the iPhone home screen: swiping in
        // edit mode pages through screens without turning it off. It only ends
        // via "Done", Esc, or the panel closing
        // The board's theme is applied on every switch, not just at load
        applyBoardTheme()
        // Config isn't written on the board-swap frame: a synchronous JSON write
        // to disk right when the strip settles into place is a micro-freeze at
        // the most noticeable moment. Write it a bit later, once the motion is done
        scheduleConfigSave()
        isSettlingBoard = false
    }

    func cancelBoardDrag(velocity: CGFloat = 0) {
        guard !isSettlingBoard else { return }
        wakeTask?.cancel()
        guard boardDragNeighbor != nil || boardDragOffset != 0 else { return }
        let neighbor = boardDragNeighbor
        cancelToken += 1
        let token = cancelToken
        withAnimation(strip(from: boardDragOffset, to: 0, velocity: velocity)) {
            boardDragOffset = 0
            boardDragRaw = 0
        }
        // The neighbor is only cleared after the rollback finishes. Clearing it
        // right away would make it disappear mid-motion — you'd see the board
        // vanish halfway through the return. Token: a new gesture to the same
        // neighbor could have started in the meantime
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.afterMove(Motion.boardCancel)) { [weak self] in
            guard let self, token == cancelToken, boardDragNeighbor == neighbor else { return }
            boardDragNeighbor = nil
            if let neighbor { sleepBoard(neighbor) }
        }
    }

    /// One spring for both settling and cancelling. Finger velocity converts
    /// into animation units (fraction of the remaining distance per second) so
    /// the strip keeps moving at exactly the speed it was released at
    private func strip(from: CGFloat, to: CGFloat, velocity: CGFloat) -> Animation {
        let distance = abs(to - from)
        guard distance > 1 else { return .interpolatingSpring(Motion.boardStrip) }
        // Sign: velocity toward the target counts as positive
        let towards = (to - from) > 0 ? velocity : -velocity
        return .interpolatingSpring(Motion.boardStrip, initialVelocity: towards / distance)
    }

    /// Put everything but the active board to sleep: during a gesture nobody
    /// gets put to sleep, so a zigzag doesn't chase heavy widgets around
    private func sleepBoardsAside() {
        for board in config.boards where board.id != config.activeBoardID {
            sleepBoard(board.id)
        }
    }

    @ObservationIgnored private var configSaveTask: Task<Void, Never>?

    private func scheduleConfigSave() {
        configSaveTask?.cancel()
        configSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            ConfigStore.save(config)
        }
    }

    // Tapping a board dot pages with the same motion as a swipe
    func selectBoardAnimated(_ id: UUID) {
        guard id != config.activeBoardID,
              let from = config.boards.firstIndex(where: { $0.id == config.activeBoardID }),
              let to = config.boards.firstIndex(where: { $0.id == id })
        else { return }
        // Jump straight over a non-adjacent board: no reason to animate through every board in between
        guard abs(to - from) == 1 else {
            selectBoard(id)
            return
        }
        let width = GridMetrics.islandSize.width
        // Finish the previous settle BEFORE assigning the new neighbor: otherwise
        // applySettleNow inside finishDrag would reset the one just set, and a
        // fast second tap would send the strip off into empty space
        applySettleNow()
        boardDragNeighbor = id
        boardDragSide = to > from ? 1 : -1
        if isPanelVisible, let board = config.boards.first(where: { $0.id == id }) {
            for host in hosts(of: board) { host.wake() }
        }
        finishDrag(to: id, width: width)
    }

    /// Whether to show the "Ask" bar: not on the clipboard board and not during a gesture.
    /// A paging gesture is in progress right now (including settling). While it
    /// runs, the panel's contents shouldn't change: the "Ask" bar used to
    /// appear and disappear mid-motion, making the panel jitter
    var isBoardDragging: Bool { boardDragNeighbor != nil || isSettlingBoard }

    var boardDragNeighborBoard: Board? {
        config.boards.first { $0.id == boardDragNeighbor }
    }

    /// Whether this widget exists on any board at all
    func hasWidget(_ widgetID: String) -> Bool {
        config.boards.contains { board in
            board.tiles.contains { $0.widgetID == widgetID }
        }
    }

    /// Every instance of this widget type — across all boards, in board and
    /// tile order. Files dropped on the notch are distributed among them in
    /// turn: two large shelves mean twice the space, and they fill up one after the other
    func allWidgets(_ widgetID: String) -> [any Widget] {
        // host(for:) specifically, not a ready-made dictionary: a tile might
        // never have been rendered yet — then there's no instance, and a
        // dropped file would have nowhere to go
        config.boards
            .flatMap { $0.tiles }
            .filter { $0.widgetID == widgetID }
            .compactMap { host(for: $0).widget }
    }

    func hosts(of board: Board) -> [TileHost] {
        board.tiles.map { host(for: $0) }
    }

    private func sleepBoard(_ id: UUID) {
        guard let board = config.boards.first(where: { $0.id == id }) else { return }
        for tile in board.tiles { hosts[tile.id]?.sleep() }
    }

    func selectBoard(_ id: UUID) {
        guard id != config.activeBoardID else { return }
        // Left the clipboard by hand — nowhere to return to later
        if config.boards.first(where: { $0.id == id })?.kind != .clipboard {
            boardBeforeClipboard = nil
        }
        for host in hosts.values { host.sleep() }
        config.activeBoardID = id
        applyBoardTheme()
        ConfigStore.save(config)
        if isPanelVisible {
            for host in activeHosts { host.wake() }
        }
    }

    private func host(for tile: Tile) -> TileHost {
        if let existing = hosts[tile.id] {
            if existing.tile.size != tile.size || existing.tile.origin != tile.origin {
                existing.update(tile: tile)
            }
            return existing
        }
        let host = TileHost(tile: tile, theme: theme)
        hosts[tile.id] = host
        return host
    }

    // MARK: - Edit mode

    var activeTiles: [Tile] { activeBoard?.tiles ?? [] }

    func toggleEditing(_ value: Bool? = nil) {
        // Nothing to edit on the clipboard board
        if activeBoard?.kind == .clipboard, value != false { return }
        withAnimation(.easeOut(duration: 0.2)) {
            isEditing = value ?? !isEditing
        }
    }

    func resize(tileID: UUID, to size: TileSize) {
        guard let boardIndex = boardIndex(),
              let tileIndex = config.boards[boardIndex].tiles.firstIndex(where: { $0.id == tileID })
        else { return }
        let tile = config.boards[boardIndex].tiles[tileIndex]
        guard tile.size != size,
              let spot = BoardLayout.placement(
                for: size, preferring: tile.origin, ignoring: tileID, in: activeTiles)
        else { return }
        undoStack.append(config)
        config.boards[boardIndex].tiles[tileIndex].size = size
        config.boards[boardIndex].tiles[tileIndex].origin = spot
        persist()
    }

    func move(tileID: UUID, to origin: GridPoint) {
        guard let boardIndex = boardIndex(),
              let tileIndex = config.boards[boardIndex].tiles.firstIndex(where: { $0.id == tileID })
        else { return }
        let tile = config.boards[boardIndex].tiles[tileIndex]
        guard tile.origin != origin else { return }

        if BoardLayout.canPlace(
            size: tile.size, at: origin, ignoring: tileID, in: activeTiles) {
            undoStack.append(config)
            config.boards[boardIndex].tiles[tileIndex].origin = origin
            persist()
            return
        }

        // Spot's taken — swap places if both tiles fit
        guard let other = BoardLayout.swapTarget(for: tile, at: origin, in: activeTiles),
              let otherIndex = config.boards[boardIndex].tiles.firstIndex(where: { $0.id == other.id })
        else { return }

        undoStack.append(config)
        let tileOrigin = tile.origin
        withAnimation(.easeOut(duration: 0.2)) {
            config.boards[boardIndex].tiles[tileIndex].origin = other.origin
            config.boards[boardIndex].tiles[otherIndex].origin = tileOrigin
        }
        persist()
    }

    func removeTile(id: UUID) {
        guard let boardIndex = boardIndex() else { return }
        undoStack.append(config)
        // The widget gets to clear what outlives it (island state, per-tile
        // storage) — via host(for:), because the tile may never have been drawn
        if let tile = config.boards[boardIndex].tiles.first(where: { $0.id == id }) {
            host(for: tile).willRemove()
        }
        config.boards[boardIndex].tiles.removeAll { $0.id == id }
        hosts[id]?.sleep()
        hosts[id] = nil
        persist()
    }

    func addTile(widgetID: String, size: TileSize, at origin: GridPoint? = nil) {
        guard let boardIndex = boardIndex() else { return }
        let spot = origin ?? BoardLayout.firstFreeSpot(for: size, in: activeTiles)
        guard let spot,
              BoardLayout.canPlace(size: size, at: spot, ignoring: nil, in: activeTiles)
        else { return }
        undoStack.append(config)
        let tile = Tile(id: UUID(), widgetID: widgetID, size: size, origin: spot)
        config.boards[boardIndex].tiles.append(tile)
        persist()
        if isPanelVisible { host(for: tile).wake() }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        config = previous
        // No need to keep hosts for tiles that no longer exist on any board:
        // the dictionary was only cleaned up on tile removal, and undo never touched it
        let alive = Set(previous.boards.flatMap { $0.tiles.map(\.id) })
        for (id, host) in hosts where !alive.contains(id) {
            host.sleep()
            hosts[id] = nil
        }
        persist()
        if isPanelVisible {
            for host in activeHosts { host.wake() }
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    private func boardIndex() -> Int? {
        config.boards.firstIndex { $0.id == config.activeBoardID }
    }

    private func persist() {
        ConfigStore.save(config)
    }
}
