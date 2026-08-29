import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    static func main() {
        // A write into a pipe whose reader died (music helper) raises SIGPIPE,
        // which kills the process before `write` even returns — try? can't catch it
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOLBF, 0)  // widget logs show up immediately, even when output goes to a file
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    private var panelController: PanelController?

    // The app menu exists for a single item — ⌘, for settings. Without it the
    // system shortcut simply doesn't work: an LSUIElement app has no menu by default
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(openSettings),
            keyEquivalent: ",")
        appMenu.items.last?.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Quit Sill"), action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Without an Edit menu, system ⌘C/⌘V/⌘X don't work anywhere at all: with no
        // menu, the app has nothing to handle them. This is exactly why the key wasn't
        // pasting into settings
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(
            withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(
            withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two instances would write one config, poll the clipboard twice, and
        // fight over the notch trap. The earlier instance wins; this one leaves
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            sillLog("[app] another instance is already running (pid \(others[0].processIdentifier)) — quitting")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        panelController = PanelController()
        installMenu()
        // Check for the model key right away, in the background: by the time the
        // panel first opens, the answer is already there, and the "Ask" row doesn't
        // change its label on screen
        LLMClient.shared.checkKeyPresence()
        sillLog("[app] launched")

        #if DEBUG
        // SILL_SEED=1 — seed the "Sill Test" calendar with edge-case events
        if ProcessInfo.processInfo.environment["SILL_SEED"] == "1" {
            Task { await DebugSeed.run() }
        }
        #endif
    }
}
