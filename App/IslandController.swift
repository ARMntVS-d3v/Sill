import AppKit
import SwiftUI

// Island window by the notch: shows live activity while the panel is closed.
// Built like the notch click trap — a non-activating panel above the menu bar, but
// wider than the notch with "ears" on the sides. Clicking it opens the panel.
// The window is wider than the capsule so the capsule can grow inside it. But it must
// only catch clicks over the capsule itself: otherwise the transparent margins would
// steal clicks meant for the menu bar icons on either side of the notch.
final class IslandHostingView: NSHostingView<AnyView> {
    /// A file is hovering over the capsule, or has left it. The controller sets these.
    @MainActor static var onFilesHover: ((Bool) -> Void)?
    @MainActor static var onFilesDrop: (([URL]) -> Bool)?

    @MainActor
    func acceptFiles() { registerForDraggedTypes([.fileURL]) }

    @MainActor
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        Self.onFilesHover?(true)
        return .copy
    }

    @MainActor
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender) ? .copy : []
    }

    @MainActor
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        Self.onFilesHover?(false)
    }

    @MainActor
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        Self.onFilesHover?(false)
    }

    @MainActor
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)
        let urls = (objects as? [URL] ?? []).filter(\.isFileURL)
        return Self.onFilesDrop?(urls) ?? false
    }

    @MainActor
    private func hasFiles(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    @MainActor
    override func hitTest(_ point: NSPoint) -> NSView? {
        let width = IslandPresentation.shared.capsuleWidth
        let height = max(IslandPresentation.shared.capsuleHeight, 1)
        guard width > 0 else { return nil }
        // The capsule sits flush with the top of the window: the window is taller than
        // it to leave room for the capsule to expand.
        let capsule = NSRect(
            x: bounds.midX - width / 2, y: bounds.maxY - height, width: width, height: height)
        guard capsule.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class IslandController {
    private var panel: NotchPanel?
    /// Margin on each side that the capsule can grow into
    private static let reserve: CGFloat = 220

    private let appState: AppState
    private let onClick: () -> Void
    private var tick: Task<Void, Never>?
    private var hideTask: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    /// A source sweep is in progress: defer showing until it's done. Otherwise the
    /// capsule can retract and come back within a single sweep — each source writes
    /// to the center, and every write triggers a show
    private var sweeping = false
    /// Whether the panel is open, according to whoever opens it. `isPanelVisible` in
    /// AppState only updates on the next run-loop pass, and during that gap
    /// (measured at 79 ms) the capsule could briefly show over an already-open panel
    private var panelIsOpen = false
    /// Until when the capsule is still animating. While it is, we don't talk to the system
    private var animatingUntil: Date?
    private var isAnimating: Bool { animatingUntil.map { Date() < $0 } ?? false }


    init(appState: AppState, onClick: @escaping () -> Void) {
        self.appState = appState
        self.onClick = onClick
    }

    /// Watch activities for as long as the app runs. The tick is one second and only
    /// runs while there's an activity: with nothing to show, the timer is silent
    /// Music source subscriber: as long as it exists, the bridge stays alive and the
    /// capsule knows the current track
    private static let musicSubscriber = UUID()

    func start() {
        // Monitor connected, lid closed — the screen changed, rebuild the window.
        // Guarded so a restart after filming doesn't stack a second observer
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.drop() }
            }
        }
        // The player announces track changes and pauses itself — react to that event
        // rather than waiting for the next tick: otherwise the capsule lagged a
        // second or two behind the click. We ask only the player here: a full sweep
        // costs 1-3 ms and pulls IOKit for battery, while player messages arrive
        // continuously
        NowPlayingCenter.shared.onChange = { [weak self] in
            MusicActivity.refresh()
            self?.present()
        }
        // Show a new activity on the same frame it appears. Otherwise the copy
        // confirmation would slide out only after the panel had already moved
        LiveActivityCenter.shared.onChange = { [weak self] in self?.present() }
        // Build the window up front, not on the first event: otherwise the first
        // show loses a frame to building the window and the first layout pass
        build()
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                // The controller is gone — the loop must end, not spin idle
                guard let self else { return }
                // Don't touch sources while the capsule is animating: an IOKit battery
                // request mid-retraction was exactly the stutter that made it look janky
                let deferred = isAnimating
                if !deferred { sweep() }
                present()
                // Half a second is only needed where seconds are actually ticking by —
                // the timer. Music, weather, and battery are fine with two: their value
                // changes by event, not by tick. This is the only thing that runs at
                // all while the panel is closed, so it has to be nearly free
                let current = LiveActivityCenter.shared.current
                let ticking = current?.id == TimerActivity.id || current?.expanded == true
                    || current?.id == ClipboardActivity.id || current?.id == ShelfActivity.id
                // Sweep was deferred for the animation — resume right after it ends,
                // not after a full tick: otherwise the capsule would hang around for
                // up to two extra seconds
                try? await Task.sleep(
                    for: deferred
                        ? .seconds(max(0.06, animatingUntil?.timeIntervalSinceNow ?? 0.06))
                        : .milliseconds(ticking ? 500 : 2000))
            }
        }
    }

    /// The panel opened — the capsule hides immediately and doesn't come back.
    /// `isPanelVisible` lags by one run-loop pass, and checking it here let the
    /// capsule show briefly over an already-open panel.
    func panelOpened() {
        panelIsOpen = true
        hide()
    }

    /// The panel closed — the island decides again whether to show itself. Don't
    /// touch sources here: the panel is mid-animation at this point
    func panelClosed() {
        panelIsOpen = false
        present()
    }

    func stop() {
        tick?.cancel()
        tick = nil
        hideTask?.cancel()
        hideTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        hide()
    }

    /// Sweep all sources: expensive. This is what hits IOKit for battery, UserDefaults
    /// for the timer, and parses the weather cache. Only called by the tick — never
    /// by an event, and never during an animation frame
    private func sweep() {
        sweeping = true
        defer { sweeping = false }
        // The music source only stays alive while something is subscribed to it. We
        // subscribe ourselves for the capsule's sake — otherwise there'd be no track
        // at all while the panel is closed, and the notch would always show a music
        // note instead of the artwork
        if AppSettings.shared.musicInNotch {
            NowPlayingCenter.shared.subscribe(Self.musicSubscriber, background: true)
            // Capsule expansion is tied to media keys, so we need to be listening for them
            MediaKeys.start()
        } else {
            NowPlayingCenter.shared.unsubscribe(Self.musicSubscriber)
            MediaKeys.stop()
        }

        ShelfActivity.refresh()
        ClipboardActivity.refresh()
        TimerActivity.refresh()
        BatteryActivity.refresh()
        WeatherActivity.refresh()
        MusicActivity.refresh()
        present()
    }

    /// Show whatever is already known: no system requests at all. This is the entire
    /// path an event takes — an activity appears, the capsule slides out
    private func present() {
        // Every source in a sweep writes to the center, and the center triggers a
        // show: without this lock the capsule could retract and come back within a
        // single sweep
        guard !sweeping else { return }
        // No need for the island while the panel is open: everything is already on screen
        guard !panelIsOpen, !appState.isPanelVisible,
              let activity = LiveActivityCenter.shared.current
        else {
            hide()
            return
        }
        show(activity)
    }

    private func show(_ activity: LiveActivity) {
        build()
        guard let panel else { return }
        // Cancel any pending retraction: the activity is back, the window is already on screen
        hideTask?.cancel()
        hideTask = nil
        // The capsule's content and width live inside the view: no need to touch the window
        IslandPresentation.shared.activity = activity
        guard !panel.isVisible else {
            IslandPresentation.shared.visible = true
            return
        }
        panel.orderFrontRegardless()
        appear()
        sillLog("[island] shown: \(activity.icon) \(activity.value)")
    }

    /// The capsule window is built up front, at startup: on the first show, building
    /// the window and the first SwiftUI layout pass ate a whole frame — a measured
    /// 39 ms stall right on the first move. An empty hidden window costs nothing
    private func build() {
        guard panel == nil, let screen = NSScreen.main else { return }
        // On Macs without a notch (external display, Mini, older laptops) the capsule
        // is still needed: draw it centered on the top edge, just without a hole in
        // the middle. Otherwise live activity would simply vanish on half the fleet
        let notch = NotchTrigger.notchRect(of: screen)
            ?? NSRect(
                x: screen.frame.midX, y: screen.frame.maxY - NSStatusBar.system.thickness,
                width: 0, height: NSStatusBar.system.thickness)
        let view = IslandView(notchWidth: notch.width, notchHeight: notch.height)
        let host = hostingView(view)
        // Window with margin: the capsule grows and shrinks inside it, so the
        // animation happens in SwiftUI rather than jerking through setFrame
        let width = notch.width + Self.reserve * 2
        // The window is taller than the notch: expanded, the capsule drops down and
        // needs somewhere to draw. Clicks outside the capsule itself still pass through
        let height = notch.height + IslandView.expandedDrop + 8
        let frame = NSRect(
            x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height)

        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // A click on the capsule opens the panel, same as clicking the notch itself.
        // Outside the capsule the window lets clicks through: see IslandHostingView.hitTest
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = host
        // Below the click trap, but above the menu bar: the island stays visible, and
        // clicking the notch still opens the panel
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        // display: false — synchronously rendering the whole tree before showing was
        // the most expensive step on this path
        panel.setFrame(frame, display: false)
        self.panel = panel
        sillLog("[island] window ready, width \(Int(width))")
    }

    private func hostingView(_ view: some View) -> NSView {
        let host = IslandHostingView(
            rootView: AnyView(view.onTapGesture { [onClick] in onClick() }))
        host.wantsLayer = true
        // The capsule is a visible drop target, so it should be the one to catch the file
        host.acceptFiles()
        return host
    }

    /// One frame in the collapsed state, then spring outward
    private func appear() {
        animatingUntil = Date().addingTimeInterval(Motion.islandCollapse)
        IslandPresentation.shared.visible = false
        DispatchQueue.main.async { IslandPresentation.shared.visible = true }
    }

    private func hide() {
        guard let panel, panel.isVisible, hideTask == nil else { return }
        sillLog("[island] hidden")
        // Retract first, remove the window after. The window itself lives on:
        // rebuilding it on every appearance would cost a frame with no animation and
        // a fresh view starting from scratch
        animatingUntil = Date().addingTimeInterval(Motion.islandCollapse)
        IslandPresentation.shared.visible = false
        // Don't touch the content yet: the capsule must retract with the same icon
        // and value it was showing. Clear it only once the window is actually gone
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hideTask = nil
                panel.orderOut(nil)
                IslandPresentation.shared.activity = nil
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.islandCollapse, execute: task)
    }

    #if DEBUG
    /// Filming: the sequence is driven by hand through the activity center, so
    /// the tick and player events must not interfere — a sweep mid-take would
    /// resurrect the real activity and abort the collapse being filmed
    func beginFilm() {
        tick?.cancel()
        tick = nil
        NowPlayingCenter.shared.onChange = nil
    }

    func endFilm() { start() }

    /// One frame of the capsule window as-is, for the filmstrip
    func filmFrame() -> NSBitmapImageRep? {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The capsule frame as-is: the window draws itself, no screen-recording
    /// permission needed
    func shoot(to path: String) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        sillLog("[film] \(path)")
    }
    #endif

    /// The screen changed — rebuild the window for the new notch
    private func drop() {
        hideTask?.cancel()
        hideTask = nil
        IslandPresentation.shared.visible = false
        IslandPresentation.shared.activity = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
