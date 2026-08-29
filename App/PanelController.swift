import AppKit
import SwiftUI

// Panel: NSPanel, not MenuBarExtra — see docs/architecture.md, "Panel shell" section.
final class SillPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // The panel sits flush with the top of the screen (menu bar area) — AppKit forbids that by default
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class PanelController: NSObject {
    // The window is wider than the island: side and bottom margins keep the outer
    // edge shadow from being clipped. The island's own size is PanelMetrics.island.
    static var windowSize: NSSize { NSSize(width: PanelMetrics.window.width, height: PanelMetrics.window.height) }
    static var islandSize: NSSize { NSSize(width: PanelMetrics.island.width, height: PanelMetrics.island.height) }

    private let statusItem: NSStatusItem
    private let panel: SillPanel
    private let appState = AppState()
    private var clickMonitor: Any?
    private var swipeMonitor: Any?
    private var signalSource: DispatchSourceSignal?
    private var snapshotSource: DispatchSourceSignal?
    private var filmSource: DispatchSourceSignal?
    private var openFilmSource: DispatchSourceSignal?
    private var islandFilmSource: DispatchSourceSignal?
    private var debugIslandSource: DispatchSourceSignal?
    #if DEBUG
    /// `kill -INFO` calls alternate: the compact charging capsule and the expanded
    /// copy confirmation are two different animations
    private var debugIslandTurn = 0
    private func debugIsland() {
        debugIslandTurn += 1
        if debugIslandTurn.isMultiple(of: 2) {
            ClipboardActivity.copied()
        } else {
            BatteryActivity.debugShow()
        }
    }
    #endif
    private var seedSource: DispatchSourceSignal?
    private var notchTrigger: NotchTrigger?
    private var island: IslandController?
    private var screenObserver: NSObjectProtocol?
    #if DEBUG
    private var debugSwipeSource: DispatchSourceSignal?
    #endif

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        panel = SillPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // edges fade out via gradient; a shadow would add a hard outline
        panel.isReleasedWhenClosed = false

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.grid.2x2", accessibilityDescription: String(localized: "Sill"))
            button.action = #selector(togglePanel)
            button.target = self
        }

        let root = PanelRootView().environment(appState)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.windowSize)
        panel.contentView = hosting

        // Esc exits edit mode first, and only then closes the panel
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if appState.askOpen {
                appState.askOpen = false
            } else if appState.isEditing {
                appState.toggleEditing(false)
            } else if appState.showSettings {
                appState.showSettings = false
            } else {
                hidePanel()
            }
        }
        appState.requestHide = { [weak self] in self?.hidePanel() }

        // Main gesture: clicking the notch area slides the panel out from under it
        // Settings live in a separate window and need to know the app's state
        SettingsWindowController.shared.attach(appState: appState)

        // Clipboard history is collected even while the panel is closed — otherwise
        // it would only contain what was copied while it was open
        ClipboardStore.shared.syncWithSettings()

        // Quick clipboard invocation: the panel opens straight to its board
        GlobalHotkey.shared.onFire = { [weak self] in
            Task { @MainActor in self?.showClipboard() }
        }
        GlobalHotkey.shared.apply(AppSettings.shared.clipboardHotkey)

        // Island by the notch: live activity while the panel is closed
        island = IslandController(appState: appState) { [weak self] in
            Task { @MainActor in
                // The capsule lives in the notch, so the panel should flow out of it too.
                self?.appState.appearing = .notch
                self?.showPanel(on: NSScreen.main)
            }
        }
        island?.start()
        // A file can be dropped straight onto the capsule — that's what it expands for
        IslandHostingView.onFilesHover = { [weak self] inside in
            self?.showShelfInvite(inside)
        }
        IslandHostingView.onFilesDrop = { [weak self] urls in
            self?.dropOnShelf(urls) ?? false
        }

        notchTrigger = NotchTrigger(
            onClick: { [weak self] screen in
                self?.toggle(on: screen)
            },
            onFilesHover: { [weak self] inside in
                self?.showShelfInvite(inside)
            },
            // Dropped straight on the notch without reaching a tile — put it on the shelf
            onFilesDrop: { [weak self] urls in
                self?.dropOnShelf(urls) ?? false
            },
            // No shelf anywhere — the drag is refused before the drop, instead
            // of accepting the file and announcing "Shelf is full" over a
            // shelf that doesn't exist
            acceptsFiles: { [weak self] in
                guard let self else { return false }
                appState.loadIfNeeded()
                return appState.hasWidget(ShelfWidget.descriptor.id)
            })

        // The "Ask" row was toggled on or off — the panel height changed
        NotificationCenter.default.addObserver(
            forName: .sillPanelSizeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resize() }
        }

        // Monitor disconnected, lid closed, resolution changed — an open panel must reposition itself.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.appState.isPanelVisible else { return }
                // Geometry too, not just position: unplugging the monitor with
                // the panel open left the wings laid out for the old screen's notch
                self.applyNotchGeometry(for: NSScreen.main)
                self.position(on: NSScreen.main)
            }
        }

        #if DEBUG
        // Dev trigger: kill -USR1 <pid> toggles the panel (a menu bar manager can hide
        // the icon). The global hotkey will arrive through the same path later.
        signal(SIGUSR1, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        sigSource.setEventHandler {
            MainActor.assumeIsolated { self.togglePanel() }
        }
        sigSource.resume()
        self.signalSource = sigSource

        // kill -USR2 <pid> — snapshot the panel to /tmp/sill_panel.png to check appearance
        signal(SIGUSR2, SIG_IGN)
        let snapSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        snapSource.setEventHandler {
            MainActor.assumeIsolated { self.snapshot() }
        }
        snapSource.resume()
        self.snapshotSource = snapSource

        // kill -PROF <pid> — run a paging swipe programmatically: synthetic trackpad
        // events with phases aren't delivered to the app, but the strip's physics
        // still need checking somehow
        // kill -INFO <pid> — show the charging capsule for three seconds. The real
        // event comes from the hardware: the only way to check its animation was to
        // plug in the cable, and nobody had ever watched it retract
        signal(SIGINFO, SIG_IGN)
        let islandSource = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        islandSource.setEventHandler {
            MainActor.assumeIsolated { self.debugIsland() }
        }
        islandSource.resume()
        self.debugIslandSource = islandSource

        signal(SIGPROF, SIG_IGN)
        let swipeSource = DispatchSource.makeSignalSource(signal: SIGPROF, queue: .main)
        swipeSource.setEventHandler {
            MainActor.assumeIsolated { self.debugSwipe() }
        }
        swipeSource.resume()
        self.debugSwipeSource = swipeSource

        // kill -WINCH <pid> — seed the "Sill Test" calendar with test events
        signal(SIGWINCH, SIG_IGN)
        let seedSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        seedSource.setEventHandler { Task { await DebugSeed.run() } }
        seedSource.resume()
        self.seedSource = seedSource
        // kill -VTALRM <pid> — filmstrip of the swipe to the clipboard board: frames of the real window
        signal(SIGVTALRM, SIG_IGN)
        let filmSource = DispatchSource.makeSignalSource(signal: SIGVTALRM, queue: .main)
        filmSource.setEventHandler {
            MainActor.assumeIsolated { self.filmSwipe() }
        }
        filmSource.resume()
        self.filmSource = filmSource

        // kill -XCPU <pid> — filmstrip of the panel opening and closing: frames of the
        // real window with true timestamps, for assembling the README GIF
        signal(SIGXCPU, SIG_IGN)
        let openFilmSource = DispatchSource.makeSignalSource(signal: SIGXCPU, queue: .main)
        openFilmSource.setEventHandler {
            MainActor.assumeIsolated {
                // Scene selector for the README GIFs: /tmp/sill_scene names the
                // scene, no file means the plain panel-opening film
                switch self.filmSceneName() {
                case "clipboard": self.filmClipboardScene()
                case "edit": self.filmEditScene()
                case "themes": self.filmThemesScene()
                default: self.filmOpening()
                }
            }
        }
        openFilmSource.resume()
        self.openFilmSource = openFilmSource

        // kill -XFSZ <pid> — filmstrip of the notch capsule: morph out with the
        // current track, expand with artwork and title, collapse back — then a
        // frame of each static state for the README strip
        signal(SIGXFSZ, SIG_IGN)
        let islandFilmSource = DispatchSource.makeSignalSource(signal: SIGXFSZ, queue: .main)
        islandFilmSource.setEventHandler {
            MainActor.assumeIsolated {
                if self.filmSceneName() == "shelf" {
                    self.filmShelfScene()
                } else {
                    self.filmIslandTrack()
                }
            }
        }
        islandFilmSource.resume()
        self.islandFilmSource = islandFilmSource
        sillLog("[dev] signals installed: USR1 panel, USR2 snapshot, PROF swipe, VTALRM film, XCPU open-film, XFSZ island-film")
        #endif
    }

    #if DEBUG
    /// Filmstrip of the swipe to the clipboard board: drive the strip by hand and
    /// capture the window's real content. `cacheDisplay` draws its own window, so no
    /// screen-recording permission is needed, and the frames show exactly what the user sees
    private func filmSwipe() {
        guard phase == .shown else {
            showPanel()
            after(0.7) { $0.filmSwipe() }
            return
        }
        // Land on the board before the clipboard one, so the swipe lands exactly on it
        guard let clipboardIndex = appState.config.boards.firstIndex(where: { $0.kind == .clipboard }),
              clipboardIndex > 0
        else {
            sillLog("[film] no clipboard board")
            return
        }
        appState.selectBoard(appState.config.boards[clipboardIndex - 1].id)
        after(0.5) { controller in
            controller.appState.beginBoardDrag()
            controller.filmStep(0)
        }
    }

    private static let filmSteps = 12

    private func filmStep(_ index: Int) {
        let width = PanelMetrics.island.width
        shootFrame(index)
        guard index < Self.filmSteps else {
            appState.endBoardDrag(width: width, velocity: -2000)
            // Settling finished — capture the result and walk through every board in turn
            after(0.6) { controller in
                controller.shootFrame(99)
                controller.filmBoard(0)
            }
            return
        }
        appState.updateBoardDrag(by: -width / CGFloat(Self.filmSteps), width: width)
        after(0.1) { $0.filmStep(index + 1) }
    }

    /// Walk through every board: one frame each — to see what's drawn on them
    private func filmBoard(_ index: Int) {
        let boards = appState.config.boards
        guard index < boards.count else {
            sillLog("[film] boards captured: \(boards.count)")
            filmBackFromClipboard()
            return
        }
        // A click outside the panel may have closed it — reopen it for the capture
        if phase != .shown { showPanel() }
        appState.selectBoard(boards[index].id)
        after(0.9) { controller in
            controller.shootFrame(200 + index)
            controller.filmBoard(index + 1)
        }
    }

    /// Translator square: set the tile to 1x1, capture it, then restore it. Otherwise
    /// there's no way to check a size that isn't currently on the board
    private func filmSmallTranslate() {
        if phase != .shown { showPanel() }
        guard let board = appState.config.boards.first(where: { board in
            board.tiles.contains { $0.widgetID == "translate" }
        }), let tile = board.tiles.first(where: { $0.widgetID == "translate" })
        else {
            sillLog("[film] no translator tile")
            filmIsland()
            return
        }
        let was = tile.size
        appState.selectBoard(board.id)
        after(0.6) { controller in
            controller.appState.resize(tileID: tile.id, to: .small)
            controller.after(1.0) { c2 in
                c2.shootFrame(300)
                c2.appState.resize(tileID: tile.id, to: was)
                c2.after(0.5) { $0.filmIsland() }
            }
        }
    }

    /// Every capsule mode in turn: each one shows, waits out its animation, and gets
    /// captured. Half of them can't be triggered live — music needs a player, weather
    /// needs the network — so we write the activity straight to the center, the way
    /// the widgets themselves do
    private func filmIsland() {
        if phase == .shown { hidePanel() }
        after(0.8) { $0.filmIslandStep(0) }
    }

    private static let islandModes: [(String, LiveActivity)] = [
        ("battery", LiveActivity(
            id: "film", icon: "battery.100.bolt", value: "46%",
            tint: Color(red: 0.35, green: 0.85, blue: 0.45))),
        ("weather", LiveActivity(
            id: "film", icon: "cloud.rain.fill", value: "00:20",
            tint: Color(red: 0.39, green: 0.72, blue: 1))),
        ("timer", LiveActivity(id: "film", icon: "timer", value: "4:32", tint: .orange)),
        ("music", LiveActivity(
            id: "film", icon: "music.note", value: "", showsEqualizer: true, tint: .white)),
        ("message", LiveActivity(
            id: "film", icon: "checkmark.circle.fill", value: "Copied",
            tint: .white, expanded: true)),
        ("shelf", LiveActivity(
            id: "film", icon: "tray.and.arrow.down.fill", value: "File on shelf",
            tint: .white, expanded: true)),
        ("track", LiveActivity(
            id: "film", icon: "music.note", value: "Bohemian Rhapsody",
            showsEqualizer: true, tint: .white, subtitle: "Queen", expanded: true)),
    ]

    private func filmIslandStep(_ index: Int) {
        guard index < Self.islandModes.count else {
            LiveActivityCenter.shared.clear("film")
            sillLog("[film] capsule captured in every mode")
            return
        }
        let (name, activity) = Self.islandModes[index]
        LiveActivityCenter.shared.update(activity)
        // Wait out the animation: a snapshot mid-motion catches a transition frame
        after(1.0) { controller in
            controller.island?.shoot(to: "/tmp/sill_island_\(name).png")
            controller.filmIslandStep(index + 1)
        }
    }

    /// Reverse swipe: from the clipboard back to the widgets. Separately, a few
    /// frames right after the switch: the "Ask" row rebuilds itself exactly there
    private func filmBackFromClipboard() {
        guard let index = appState.config.boards.firstIndex(where: { $0.kind == .clipboard }),
              index > 0
        else { return }
        if phase != .shown { showPanel() }
        appState.selectBoard(appState.config.boards[index].id)
        after(0.8) { controller in
            controller.appState.beginBoardDrag()
            controller.filmBackStep(50)
        }
    }

    private func filmBackStep(_ index: Int) {
        let width = PanelMetrics.island.width
        shootFrame(index)
        guard index < 50 + Self.filmSteps else {
            appState.endBoardDrag(width: width, velocity: 2000)
            // Right after the swap, half a second later, and a second and a half later
            after(0.15) { $0.shootFrame(63) }
            after(0.6) { $0.shootFrame(64) }
            after(1.5) { controller in
                controller.shootFrame(65)
                controller.filmSmallTranslate()
            }
            return
        }
        appState.updateBoardDrag(by: width / CGFloat(Self.filmSteps), width: width)
        after(0.1) { $0.filmBackStep(index + 1) }
    }

    /// Filmstrip of the panel opening and closing. SwiftUI animations advance by wall
    /// clock, so uneven capture intervals don't distort poses — each frame is written
    /// with its true timestamp into /tmp/sill_open.txt, and the GIF is assembled from
    /// that manifest. Frames are kept in memory and written after the take: a disk
    /// write per frame would stall the very animation being filmed
    private var openFilmFrames: [(time: TimeInterval, rep: NSBitmapImageRep)] = []

    /// Only the opening is filmed: after hidePanel the model values are already
    /// final (opacity 0), and cacheDisplay captures nothing — the closing is
    /// assembled by reversing the opening frames. Slowed down 4x: at normal
    /// speed the 0.28 s motion fits in four captures
    private func filmOpening() {
        // Warm-up: the CPU graph needs two minutes of an open panel to fill its
        // one-minute history. Pin against stray outside clicks, and re-open every
        // couple of seconds if something still closed it (a notch click toggles
        // the panel regardless of the pin) — a short gap doesn't clear the history
        appState.pinned = true
        filmWarmupLeft = 65
        sillLog("[film] warm-up: 130 s, keeping the panel open")
        filmWarmupTick()
    }

    private var filmWarmupLeft = 0

    private func filmWarmupTick() {
        if phase != .shown {
            appState.appearing = .notch
            showPanel()
        }
        filmWarmupLeft -= 1
        guard filmWarmupLeft > 0 else {
            hidePanel()
            after(0.9) { c in
                c.openFilmFrames.removeAll()
                Motion.filmSlowdown = 4
                c.appState.appearing = .notch
                c.showPanel()
                c.filmOpeningFrame(start: CACurrentMediaTime())
            }
            return
        }
        after(2) { $0.filmWarmupTick() }
    }

    private func filmOpeningFrame(start: TimeInterval) {
        let elapsed = CACurrentMediaTime() - start
        // 4x slowdown: the 0.28 s motion takes 1.12 s, capture with a margin
        if elapsed < 1.7 {
            if let view = panel.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                openFilmFrames.append((elapsed, rep))
            }
            after(0.02) { $0.filmOpeningFrame(start: start) }
            return
        }
        Motion.filmSlowdown = 1
        writeOpeningFilm()
    }

    // MARK: - README GIF scenes (selected via /tmp/sill_scene)

    private func filmSceneName() -> String? {
        (try? String(contentsOfFile: "/tmp/sill_scene", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The showcase board for the public GIFs — found by content, never by
    /// name: the personal boards must not end up in a published frame
    private func selectShowcaseBoard() {
        guard let board = appState.config.boards.first(where: { board in
            board.tiles.contains { $0.widgetID == "calendar" }
                && board.tiles.contains { $0.widgetID == "cpu" }
        }) else { return }
        appState.selectBoard(board.id)
    }

    /// Generic take: capture window frames until `until`, then write and
    /// run the completion (restore state the scene changed)
    private var filmDone: ((PanelController) -> Void)?

    private func filmCapture(start: TimeInterval, until: TimeInterval) {
        let elapsed = CACurrentMediaTime() - start
        if elapsed < until {
            if let view = panel.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                openFilmFrames.append((elapsed, rep))
            }
            after(0.02) { $0.filmCapture(start: start, until: until) }
            return
        }
        Motion.filmSlowdown = 1
        writeOpeningFilm()
        filmDone?(self)
        filmDone = nil
    }

    /// Clipboard board slides down from the top edge — the keyboard-invocation motion
    private func filmClipboardScene() {
        if phase == .shown { hidePanel() }
        after(1.0) { c in
            Motion.filmSlowdown = 4
            c.appState.showClipboardBoard()
            c.appState.appearing = .slide
            c.showPanel()
            c.openFilmFrames.removeAll()
            c.filmCapture(start: CACurrentMediaTime(), until: 2.8)
        }
    }

    /// Edit mode: a calm board, then the iOS-style jiggle with dashed cells
    private func filmEditScene() {
        appState.pinned = true
        selectShowcaseBoard()
        if phase != .shown {
            appState.appearing = .notch
            showPanel()
        }
        after(1.5) { c in
            Motion.filmSlowdown = 4
            c.openFilmFrames.removeAll()
            c.filmCapture(start: CACurrentMediaTime(), until: 9.0)
            c.after(1.2) { $0.appState.toggleEditing(true) }
            c.filmDone = { done in
                done.appState.toggleEditing(false)
            }
        }
    }

    /// Theme carousel: one settled frame per theme, crossfaded at assembly
    private func filmThemesScene() {
        appState.pinned = true
        selectShowcaseBoard()
        if phase != .shown {
            appState.appearing = .notch
            showPanel()
        }
        after(1.2) { c in
            c.openFilmFrames.removeAll()
            c.filmThemeStep(0, themes: ["midnight", "tokyo-night", "phosphor"])
        }
    }

    private func filmThemeStep(_ index: Int, themes: [String]) {
        guard index < themes.count else {
            appState.themeEngine.select(name: "midnight")
            writeOpeningFilm()
            return
        }
        appState.themeEngine.select(name: themes[index])
        after(0.8) { c in
            if let view = c.panel.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                c.openFilmFrames.append((TimeInterval(index), rep))
            }
            c.filmThemeStep(index + 1, themes: themes)
        }
    }

    /// Shelf at the notch: the capsule invites the file, confirms, tucks away.
    /// Driven with copies of the real ShelfActivity states so the timings can
    /// be slowed for filming
    private func filmShelfScene() {
        if phase == .shown { hidePanel() }
        island?.beginFilm()
        LiveActivityCenter.shared.clear(MusicActivity.id)
        after(1.0) { c in
            Motion.filmSlowdown = 4
            let blue = Color(red: 0.04, green: 0.52, blue: 1)
            var invite = LiveActivity(
                id: "film", icon: "tray.and.arrow.down.fill", value: "Drop file here",
                tint: blue)
            invite.expanded = true
            invite.priority = 95
            var confirm = LiveActivity(
                id: "film", icon: "checkmark.circle.fill", value: "File on shelf",
                tint: blue)
            confirm.expanded = true
            confirm.priority = 95
            LiveActivityCenter.shared.update(invite)
            c.after(3.4) { _ in LiveActivityCenter.shared.update(confirm) }
            c.after(6.2) { _ in LiveActivityCenter.shared.clear("film") }
            c.islandFilmFrames.removeAll()
            c.filmShelfFrame(start: CACurrentMediaTime())
        }
    }

    private func filmShelfFrame(start: TimeInterval) {
        let elapsed = CACurrentMediaTime() - start
        if elapsed < 8.4 {
            if let rep = island?.filmFrame() {
                islandFilmFrames.append((elapsed, rep))
            }
            after(0.02) { $0.filmShelfFrame(start: start) }
            return
        }
        Motion.filmSlowdown = 1
        var manifest = ""
        for (index, frame) in islandFilmFrames.enumerated() {
            guard let data = frame.rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: String(format: "/tmp/sill_isl_%03d.png", index)))
            manifest += String(format: "%03d %.4f\n", index, frame.time)
        }
        try? manifest.write(toFile: "/tmp/sill_isl.txt", atomically: true, encoding: .utf8)
        sillLog("[film] shelf frames: \(islandFilmFrames.count)")
        islandFilmFrames.removeAll()
        island?.endFilm()
    }

    /// Filmstrip of the capsule with the current track: morph out compact,
    /// expand with artwork, collapse back into the notch. Same slow-motion
    /// trick as the panel film. Content opacity animates through Core
    /// Animation and isn't captured mid-flight — the shape morphs are, and
    /// they carry the motion
    private var islandFilmFrames: [(time: TimeInterval, rep: NSBitmapImageRep)] = []

    private func filmIslandTrack() {
        guard let track = NowPlayingCenter.shared.track else {
            sillLog("[film] island: no track playing")
            return
        }
        if phase == .shown { hidePanel() }
        island?.beginFilm()
        LiveActivityCenter.shared.clear(MusicActivity.id)
        after(1.0) { c in
            Motion.filmSlowdown = 4
            let art = track.artwork.flatMap { NSImage(data: $0) }
            var compact = LiveActivity(
                id: "film", icon: "music.note", value: track.title,
                image: art, showsEqualizer: true, tint: .white)
            compact.priority = 95
            var expanded = compact
            expanded.subtitle = track.artist
            expanded.expanded = true
            // Timeline in slowed-down seconds (4x): morph out compact, expand,
            // retract straight from the expanded state — the capsule tucks away
            // expanded by design, and the expanded→compact content swap caught
            // mid-fade read as a glitch in the frames
            LiveActivityCenter.shared.update(compact)
            c.after(2.2) { _ in LiveActivityCenter.shared.update(expanded) }
            c.after(5.2) { _ in LiveActivityCenter.shared.clear("film") }
            c.islandFilmFrames.removeAll()
            c.filmIslandFrame(start: CACurrentMediaTime(), track: track)
        }
    }

    private func filmIslandFrame(start: TimeInterval, track: NowPlayingTrack) {
        let elapsed = CACurrentMediaTime() - start
        if elapsed < 7.4 {
            if let rep = island?.filmFrame() {
                islandFilmFrames.append((elapsed, rep))
            }
            after(0.02) { $0.filmIslandFrame(start: start, track: track) }
            return
        }
        Motion.filmSlowdown = 1
        var manifest = ""
        for (index, frame) in islandFilmFrames.enumerated() {
            guard let data = frame.rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: String(format: "/tmp/sill_isl_%03d.png", index)))
            manifest += String(format: "%03d %.4f\n", index, frame.time)
        }
        try? manifest.write(toFile: "/tmp/sill_isl.txt", atomically: true, encoding: .utf8)
        sillLog("[film] island frames: \(islandFilmFrames.count)")
        islandFilmFrames.removeAll()
        // Static states for the README strip, one frame each, at normal speed
        let art = track.artwork.flatMap { NSImage(data: $0) }
        var music = LiveActivity(
            id: "film", icon: "music.note", value: track.title,
            image: art, showsEqualizer: true, tint: .white)
        music.priority = 95
        let states: [(String, LiveActivity)] = [
            ("timer", LiveActivity(id: "film", icon: "timer", value: "4:32", tint: .orange, priority: 95)),
            ("battery", LiveActivity(
                id: "film", icon: "battery.100.bolt", value: "46%",
                tint: Color(red: 0.35, green: 0.85, blue: 0.45), priority: 95)),
            ("rain", LiveActivity(
                id: "film", icon: "cloud.rain.fill", value: "00:20",
                tint: Color(red: 0.39, green: 0.72, blue: 1), priority: 95)),
            ("music", music),
        ]
        filmIslandState(0, states: states)
    }

    private func filmIslandState(_ index: Int, states: [(String, LiveActivity)]) {
        guard index < states.count else {
            LiveActivityCenter.shared.clear("film")
            island?.endFilm()
            sillLog("[film] island states done")
            return
        }
        LiveActivityCenter.shared.update(states[index].1)
        after(1.2) { c in
            if let rep = c.island?.filmFrame(),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(
                    to: URL(fileURLWithPath: "/tmp/sill_isl_state_\(states[index].0).png"))
            }
            c.filmIslandState(index + 1, states: states)
        }
    }

    private func writeOpeningFilm() {
        var manifest = ""
        for (index, frame) in openFilmFrames.enumerated() {
            guard let data = frame.rep.representation(using: .png, properties: [:]) else { continue }
            let path = String(format: "/tmp/sill_open_%03d.png", index)
            try? data.write(to: URL(fileURLWithPath: path))
            manifest += String(format: "%03d %.4f\n", index, frame.time)
        }
        try? manifest.write(
            toFile: "/tmp/sill_open.txt", atomically: true, encoding: .utf8)
        sillLog("[film] opening frames: \(openFilmFrames.count), manifest /tmp/sill_open.txt")
        openFilmFrames.removeAll()
        appState.pinned = false
    }

    private func after(_ delay: TimeInterval, _ body: @escaping (PanelController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
    }

    /// The window frame as-is: with lists, the input field, and everything drawn
    private func shootFrame(_ index: Int) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let path = String(format: "/tmp/sill_film_%02d.png", index)
        try? data.write(to: URL(fileURLWithPath: path))
        sillLog("[film] \(path)")
    }

    private var debugSwipeDirection: CGFloat = -1

    /// Programmatic swipe: the same calls the trackpad monitor makes. Each press
    /// flips direction — so both ends of the strip get exercised
    private func debugSwipe() {
        let width = PanelMetrics.island.width
        let before = appState.activeBoard?.name ?? "—"
        let step = 40 * debugSwipeDirection
        debugSwipeDirection *= -1
        appState.beginBoardDrag()
        for _ in 0..<10 { appState.updateBoardDrag(by: step, width: width) }
        appState.endBoardDrag(width: width, velocity: step * 22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            sillLog("[swipe-test] was \"\(before)\", now \"\(appState.activeBoard?.name ?? "—")\"")
        }
    }

    // Snapshot the panel on a gray checkered background: shows exactly where the shadow falls.
    private func snapshot() {
        appState.loadIfNeeded()
        appState.showSettings = false  // the snapshot shows the board, not settings
        appState.setPanelVisibleForSnapshot(true)
        let size = Self.windowSize
        let view = ZStack {
            Color(white: 0.10)
            PanelRootView().environment(appState)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/sill_panel.png"))
        sillLog("[snapshot] /tmp/sill_panel.png \(image.width)x\(image.height)")
        // The same panel as the window itself draws it. ImageRenderer paints every
        // live text field as a yellow block, so input layout can only be checked here
        snapshotLive()
        snapshotSettings()
        if !panel.isVisible { appState.setPanelVisibleForSnapshot(false) }
        snapshotIsland()
    }

    /// Frame of the real window: text fields, lists and scroll views are drawn as
    /// they actually are. No screen-recording permission needed — the window draws itself
    private func snapshotLive() {
        guard panel.isVisible, let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/sill_panel_live.png"))
        sillLog("[snapshot] /tmp/sill_panel_live.png")
    }

    // Snapshot the settings section: the settings window doesn't appear in the panel
    // snapshot, and there's no other way to see its layout. We supply the data
    // ourselves — there's no network in the render
    private func snapshotSettings() {
        let sample: [CurrencyWidget.Rate] = [
            .init(code: "RUB", name: "Russian Ruble", value: 1, previous: 1, nominal: 1),
            .init(code: "USD", name: "US Dollar", value: 84.5, previous: 84.1, nominal: 1),
            .init(code: "EUR", name: "Euro", value: 98.2, previous: 98.9, nominal: 1),
            .init(code: "GEL", name: "Georgian Lari", value: 31.2, previous: 31.1, nominal: 1),
            .init(
                code: "BTC", name: "Bitcoin", value: 5_500_874, previous: 5_460_000,
                nominal: 1, kind: .crypto),
            .init(
                code: "ETH", name: "Ethereum", value: 163_744, previous: 160_800,
                nominal: 1, kind: .crypto),
        ]
        let view = VStack(alignment: .leading, spacing: 0) {
            // The sections that are hard to check any other way: boards, the notch
            // rows (weather city, media-key access) and the currency search
            BoardSettings()
            NotchSettings()
            CurrencySettings(
                sample: sample, sampleQuery: "u",
                sampleChosen: [
                    CurrencyChoice(code: "EUR", isCrypto: false),
                    CurrencyChoice(code: "GEL", isCrypto: false),
                    CurrencyChoice(code: "BTC", isCrypto: true),
                ])
        }
        // ImageRenderer crops the top 20 points — pad the top generously, otherwise
        // the first section's header doesn't make it into the snapshot
        .padding(.top, 40)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 500, alignment: .leading)
        .background(appState.theme.panelBackground.color)
        .environment(\.theme, appState.theme)
        .environment(appState)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/sill_settings.png"))
        sillLog("[snapshot] /tmp/sill_settings.png \(image.width)x\(image.height)")
    }

    // Separate snapshot of the notch capsule in every state: there's no other way to
    // see it, since it lives above the menu bar and doesn't appear in the panel snapshot
    private func snapshotIsland() {
        let notchWidth: CGFloat = 185
        let notchHeight: CGFloat = 32
        let track = NowPlayingCenter.shared.track

        let states: [(String, LiveActivity)] = [
            ("timer", LiveActivity(id: "1", icon: "timer", value: "4:32", tint: .orange)),
            ("stopwatch", LiveActivity(
                id: "2", icon: "stopwatch", value: "1:23", tint: .orange)),
            ("rain", LiveActivity(
                id: "3", icon: "cloud.rain.fill", value: "15:00",
                tint: Color(red: 0.39, green: 0.72, blue: 1))),
            ("battery", LiveActivity(
                id: "4", icon: "battery.100.bolt", value: "48%", tint: .green)),
            ("music, expanded", LiveActivity(
                id: "7", icon: "music.note", value: track?.title ?? "Track title",
                image: track?.artwork.flatMap { NSImage(data: $0) },
                showsEqualizer: true, tint: .white,
                subtitle: track?.artist ?? "Artist", expanded: true)),
            ("shelf inviting", LiveActivity(
                id: "10", icon: "tray.and.arrow.down.fill", value: "Drop file here",
                tint: Color(red: 0.04, green: 0.52, blue: 1), expanded: true)),
            ("shelf full", LiveActivity(
                id: "12", icon: "tray.full.fill", value: "Shelf is full",
                tint: Color(red: 1, green: 0.62, blue: 0.04), expanded: true)),
            ("file on shelf", LiveActivity(
                id: "11", icon: "checkmark.circle.fill", value: "File on shelf",
                tint: Color(red: 0.04, green: 0.52, blue: 1), expanded: true)),
            ("copied", LiveActivity(
                id: "9", icon: "checkmark.circle.fill", value: "Copied",
                tint: .white, expanded: true)),
            ("music", LiveActivity(
                id: "5", icon: "music.note", value: track?.title ?? "track",
                image: track?.artwork.flatMap { NSImage(data: $0) },
                showsEqualizer: true, tint: .white)),
        ]

        // Mac without a notch (external display, mini): the capsule draws as a solid
        // shape. Checked here so those machines don't go untested
        let noNotch = VStack(spacing: 4) {
            IslandView(
                preview: LiveActivity(
                    id: "8", icon: "cloud.rain.fill", value: "00:00",
                    tint: Color(red: 0.39, green: 0.72, blue: 1)),
                notchWidth: 0, notchHeight: notchHeight)
            Text("screen without a notch")
                .font(TileFont.axis)
                .foregroundStyle(Color.white.opacity(0.4))
        }

        // Last block: the capsule inside an actual window — shows whether it's
        // centered on the notch or pushed to one side
        let inWindow = ZStack {
            Color.white.opacity(0.07)
            IslandView(
                preview: LiveActivity(id: "6", icon: "timer", value: "4:32", tint: .orange),
                notchWidth: notchWidth, notchHeight: notchHeight)
        }
        .frame(width: notchWidth + 300, height: notchHeight)

        let view = VStack(spacing: 18) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                VStack(spacing: 4) {
                    IslandView(
                        preview: state.1, notchWidth: notchWidth, notchHeight: notchHeight)
                        .frame(
                            height: state.1.expanded
                                ? notchHeight + IslandView.expandedDrop : notchHeight)
                    Text(state.0)
                        .font(TileFont.axis)
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            // Equalizer storyboard: eight frames in a row — shows the bars aren't
            // moving in lockstep
            VStack(spacing: 4) {
                HStack(spacing: 14) {
                    ForEach(0..<8, id: \.self) { step in
                        Equalizer(tint: .white, active: true, frozenTime: Double(step) * 0.09)
                    }
                }
                .padding(.vertical, 6)
                Text("animation frames")
                    .font(TileFont.axis)
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            noNotch

            VStack(spacing: 4) {
                inWindow
                Text("position in window")
                    .font(TileFont.axis)
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .padding(24)
        .frame(width: notchWidth + 480)
        .background(Color(white: 0.16))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/sill_island.png"))
        sillLog("[snapshot] /tmp/sill_island.png \(image.width)x\(image.height)")
    }
    #endif

    // Clipboard hotkey: if the panel is already open on it, close it; otherwise open
    // and switch to it. The same shortcut acts as a toggle
    private func showClipboard() {
        appState.loadIfNeeded()
        let onClipboard = appState.activeBoard?.kind == .clipboard
        if phase == .shown, onClipboard {
            hidePanel()
            return
        }
        // Clipboard invoked from the keyboard — the notch has nothing to do with it,
        // the panel simply slides down from the top. Only change the appearance mode
        // for a closed panel: on an open one this retargets the animation already in
        // flight — the curve and start point change mid-motion, and the panel jitters
        if phase == .hidden { appState.appearing = .slide }
        appState.showClipboardBoard()
        if phase == .hidden { showPanel() }
        // The clipboard is driven from the keyboard, and keystrokes go to whichever
        // app is active — without activating ourselves, neither arrow keys nor ⌘C
        // would reach the panel. Unlike a normal panel open, we steal focus here;
        // changing styleMask on the fly isn't safe — it breaks a borderless panel's
        // position (verified: the panel slid off the edge of the screen)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    /// Rebuild the window for the panel's new size
    private func resize() {
        let size = Self.windowSize
        // The view's type is ModifiedContent because of .environment, so casting to
        // NSHostingView<PanelRootView> never worked. Set the size on contentView
        // directly, whatever type it actually is
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        position(on: panel.screen ?? NSScreen.main)
    }

    /// The notch capsule invites a file to be dropped. Only show it if a shelf
    /// actually exists: nowhere to invite it to, no point inviting. The panel doesn't open
    private func showShelfInvite(_ inside: Bool) {
        appState.loadIfNeeded()  // a drag can arrive before the panel ever opened
        guard appState.hasWidget(ShelfWidget.descriptor.id) else { return }
        if inside {
            ShelfActivity.invite(full: shelves().allSatisfy(\.isFull))
        } else {
            ShelfActivity.cancel()
        }
    }

    /// All shelves across all boards, in board and tile order
    private func shelves() -> [ShelfWidget] {
        appState.allWidgets(ShelfWidget.descriptor.id).compactMap { $0 as? ShelfWidget }
    }

    /// Files dropped on the notch: distribute them across shelves in order — fill the
    /// first one before moving to the next. Don't open the panel: the file already landed
    private func dropOnShelf(_ urls: [URL]) -> Bool {
        appState.loadIfNeeded()
        // Refused up front in acceptsFiles, but the guard stays: "full" must
        // only ever be said about a shelf that exists
        guard !urls.isEmpty, appState.hasWidget(ShelfWidget.descriptor.id) else { return false }
        var rest = urls
        var added = 0
        for shelf in shelves() where !rest.isEmpty {
            let free = max(shelf.capacity - shelf.items.count, 0)
            guard free > 0 else { continue }
            let portion = Array(rest.prefix(free))
            added += shelf.add(portion)
            rest.removeFirst(portion.count)
        }
        if added > 0 {
            ShelfActivity.dropped(added)
        } else {
            // No room anywhere — say so instead of silently swallowing the file
            ShelfActivity.full()
        }
        sillLog("[shelf] dropped on notch \(urls.count), landed \(added)")
        return added > 0
    }

    @objc private func togglePanel() {
        toggle(on: statusItem.button?.window?.screen)
    }

    /// Panel phase as the controller itself sees it. `isPanelVisible` in AppState
    /// only updates on the next run-loop pass (otherwise there's nothing to animate
    /// from), and during that gap a click on the notch would see "panel closed" and
    /// open it a second time, while a close would go nowhere
    private enum Phase { case hidden, shown }
    private var phase: Phase = .hidden
    /// Deferred removal of the window from the screen. A second open-close cycle used
    /// to cancel it silently, and the window would vanish on the first close's
    /// deadline — mid-animation
    private var hideTask: DispatchWorkItem?

    private func toggle(on screen: NSScreen?) {
        if phase == .shown {
            hidePanel()  // close with the same motion we opened with
        } else {
            // Opened by hand via the notch or the icon — animate from the notch
            appState.appearing = .notch
            showPanel(on: screen)
        }
    }

    // Starting point of the "flowing out" — the real notch size on this screen
    private func applyNotchGeometry(for target: NSScreen?) {
        if let target, let notch = NotchTrigger.notchRect(of: target) {
            appState.collapseScale = CGSize(
                width: notch.width / Self.islandSize.width,
                height: notch.height / Self.islandSize.height)
            appState.topInset = notch.height + 6
            appState.notchWidth = notch.width
        } else {
            // Screen without a notch: the hole's width must be zeroed, otherwise the
            // wings keep reserving space for the previous screen's notch — on an
            // external display the top row showed a gaping empty strip
            appState.topInset = 12
            appState.notchWidth = 0
            appState.collapseScale = CGSize(width: 0.25, height: 0.12)
        }
    }

    func showPanel(on screen: NSScreen? = nil) {
        appState.loadIfNeeded()
        // Cancel the pending removal: the panel is needed again
        hideTask?.cancel()
        hideTask = nil
        phase = .shown
        let target = screen ?? NSScreen.main
        applyNotchGeometry(for: target)
        position(on: target)
        // The capsule hides as part of opening, not on its own tick: before this fix
        // it could hang over an open panel for up to two seconds. We can't just ask
        // the island — it watches isPanelVisible, which only updates on the next pass
        island?.panelOpened()
        // Settings steps aside, the same way it pushes the panel out when it opens
        SettingsWindowController.shared.hideForPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        // The window became key — AppKit puts focus on the first input field on its
        // own, landing the cursor in the "Ask" row. The panel opens with nothing
        // focused: whoever needs focus (clipboard search) grabs it themselves
        panel.makeFirstResponder(nil)
        appState.panelDidShow()  // isPanelVisible=true kicks off the appearance animation in PanelRootView
        installClickMonitor()
        installSwipeMonitor()
        // The key is requested once at launch (see start); no need to touch it here —
        // Keychain has no business on the panel-open path
    }

    // Hiding happens in two steps: content exit animation first (isPanelVisible=false),
    // then the window is hidden after it. Widgets go to sleep immediately.
    func hidePanel() {
        guard phase == .shown else { return }
        phase = .hidden
        // The cursor shouldn't survive the panel closing: without this the field stays
        // first responder, and the cursor blinks in it on the next open
        panel.makeFirstResponder(nil)
        appState.panelDidHide()
        // The island decides again right now: the copy confirmation should slide out
        // together with the panel closing, not on the next tick
        island?.panelClosed()
        removeClickMonitor()
        removeSwipeMonitor()
        // Each close schedules its own window removal and cancels the previous one:
        // without this a second open-close cycle got dropped, and the window was
        // removed on the first close's deadline — mid-animation
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            hideTask = nil
            guard phase == .hidden else { return }
            panel.orderOut(nil)
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + appState.appearing.hideDuration, execute: task)
    }

    // Flush against the top of the screen, centered on the notch: the panel covers
    // the menu bar area and looks like its continuation. Screen: wherever was clicked, otherwise the main one.
    private func position(on screen: NSScreen?) {
        // The status item's window can sit off-screen (a menu bar manager
        // parked the icon at x≈-9700 on this very machine) — main screen then
        guard let screen = screen ?? NSScreen.main else { return }
        let size = Self.windowSize
        // Clamped to the screen: centering alone let the panel open cut off on
        // both sides of a narrow external display. When it's narrower than the
        // panel, the left edge wins — a fixed anchor beats two clipped edges
        let x = max(
            min(screen.frame.midX - size.width / 2, screen.frame.maxX - size.width),
            screen.frame.minX)
        let y = screen.frame.maxY - size.height
        // display: false — synchronously rendering the whole tree right before
        // showing was the most expensive step on the panel-open path
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    // Two-finger swipe on the panel pages through boards. Caught at the app level,
    // not in a single view: otherwise the gesture would only work over empty board
    // space, not over a tile — and fingers are usually right over a tile
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // Handle the event right here, not via Task: the monitor already fires on
            // the main thread, and hopping added a frame of latency — the finger and
            // the strip drifted apart, making the motion feel laggy
            // NSEvent isn't Sendable — only the decision crosses out, the event itself
            // never travels between isolation domains
            let keep = MainActor.assumeIsolated { self.handleSwipe(event) }
            return keep ? event : nil
        }
    }

    private func removeSwipeMonitor() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
        appState.cancelBoardDrag()
    }

    // Recent finger deltas — used to compute velocity at the moment of release
    private var swipeSamples: [(time: TimeInterval, delta: CGFloat)] = []
    /// The gesture already switched boards — ignore any remaining momentum
    private var swipeResolved = false

    /// Gesture direction is decided once at the start and never revisited: otherwise
    /// a horizontal swipe would hand events to a list inside a tile mid-motion, and
    /// vertical scrolling could suddenly start paging boards
    private enum SwipeAxis { case undecided, horizontal, vertical }
    private var swipeAxis: SwipeAxis = .undecided

    /// true — pass the event further down the chain, false — we consumed it
    private func handleSwipe(_ event: NSEvent) -> Bool {
        // The gesture belongs to the panel. Scrolling over the settings window or the
        // notch capsule shouldn't page boards
        guard event.window === panel else { return true }
        // There's no board strip at all in a conversation — nothing to page, and the
        // board underneath the chat would silently switch
        guard !appState.askOpen else { return true }
        // A mouse wheel arrives without phases: it can't produce paging, so we mustn't
        // grab it either — otherwise horizontal scrolling inside tiles would be dead
        guard event.hasPreciseScrollingDeltas else { return true }

        let width = PanelMetrics.island.width
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // Momentum after release: only needed while the gesture is still undecided.
        // Once the board has committed to a neighbor, continuing momentum would page
        // yet another board, and one sharp swipe could skip past two or three screens
        if event.momentumPhase == .changed {
            guard swipeAxis == .horizontal else { return true }
            guard !swipeResolved, appState.boardDragNeighbor != nil else { return false }
            appState.updateBoardDrag(by: dx, width: width)
            return false
        }
        if event.momentumPhase == .ended {
            guard swipeAxis == .horizontal else { return true }
            if !swipeResolved { appState.endBoardDrag(width: width, velocity: 0) }
            swipeResolved = false
            swipeAxis = .undecided
            return false
        }

        switch event.phase {
        case .began:
            swipeSamples.removeAll()
            swipeResolved = false
            // Direction often can't be read on the very first event — decide it on
            // the first noticeable delta, and until then the event doesn't get in anyone's way
            swipeAxis = axis(dx: dx, dy: dy)
            guard swipeAxis == .horizontal else { return true }
            appState.beginBoardDrag()
            return false
        case .changed:
            if swipeAxis == .undecided {
                swipeAxis = axis(dx: dx, dy: dy)
                guard swipeAxis == .horizontal else { return true }
                appState.beginBoardDrag()
            }
            guard swipeAxis == .horizontal else { return true }
            swipeSamples.append((event.timestamp, dx))
            // Keep only the last 100 ms: velocity should reflect the end of the gesture
            swipeSamples.removeAll { event.timestamp - $0.time > 0.1 }
            appState.updateBoardDrag(by: dx, width: width)
            return false
        case .ended:
            guard swipeAxis == .horizontal else {
                swipeAxis = .undecided
                return true
            }
            appState.endBoardDrag(width: width, velocity: currentVelocity(at: event.timestamp))
            // Decision made: momentum doesn't concern us until the next gesture.
            // A snap-back also counts as a decision — otherwise momentum would keep
            // adding offset on top of the return animation, and the strip could bounce
            // back and page in the wrong direction
            swipeResolved = true
            return false
        case .cancelled:
            let ours = swipeAxis == .horizontal
            swipeAxis = .undecided
            guard ours else { return true }
            appState.cancelBoardDrag()
            swipeResolved = true
            return false
        default:
            return true
        }
    }

    /// Threshold of 2 pt: below that the trackpad is noise, and the axis would be
    /// decided at random
    private func axis(dx: CGFloat, dy: CGFloat) -> SwipeAxis {
        guard max(abs(dx), abs(dy)) > 2 else { return .undecided }
        return abs(dx) > abs(dy) ? .horizontal : .vertical
    }

    // Points per second over the last few milliseconds of the gesture
    private func currentVelocity(at time: TimeInterval) -> CGFloat {
        guard let first = swipeSamples.first else { return 0 }
        let span = max(time - first.time, 0.016)
        let distance = swipeSamples.reduce(0) { $0 + $1.delta }
        return distance / span
    }

    // A click outside the panel closes it, unless it's pinned.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.appState.pinned else { return }
                self.hidePanel()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
