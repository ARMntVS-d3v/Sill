import AppKit
import ApplicationServices

// Media key presses (F7/F8/F9). Needed for exactly one thing: detecting that the
// user changed tracks NOT from the player window — then the notch capsule is
// appropriate, since the player isn't in view. If the track changed on its own
// (finished, a YouTube ad) or the user is browsing music inside the app itself,
// showing them what's already on screen is pointless.
//
// Media keys don't arrive as regular keyDown events but as NSSystemDefined system
// events with subtype 8. Catching them from another app requires a global monitor,
// which needs Accessibility access. Without access the capsule simply never
// expands; everything else keeps working.
@MainActor
enum MediaKeys {
    /// IOKit codes (NX_KEYTYPE_*): play/pause, next, previous
    private static let playPause = 16
    private static let next = 19
    private static let previous = 20
    /// How long after a press a state change is considered "ours"
    private static let window: TimeInterval = 2.5

    private static var lastPress: Date?
    private static var monitors: [Any] = []

    static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Show the system access prompt — from a settings button, not at launch:
    /// an unsolicited "Accessibility" dialog is scary
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func start() {
        guard isAvailable, monitors.isEmpty else { return }
        let match: NSEvent.EventTypeMask = .systemDefined
        if let global = NSEvent.addGlobalMonitorForEvents(matching: match, handler: handle) {
            monitors.append(global)
        }
        // Local monitor — for when our app is active (clipboard open).
        // `as Any` would wrap an Optional, making the monitor impossible to remove
        if let local = NSEvent.addLocalMonitorForEvents(matching: match, handler: { event in
            handle(event)
            return event
        }) {
            monitors.append(local)
        }
        sillLog("[mediakeys] listening for F7/F8/F9")
    }

    static func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// Was a media key pressed just now
    static func pressedRecently() -> Bool {
        guard let lastPress else { return false }
        return Date().timeIntervalSince(lastPress) < window
    }

    /// Mark the press as used: one press — one capsule expansion
    static func consume() { lastPress = nil }

    private static func handle(_ event: NSEvent) {
        // Subtype 8 — top-row keyboard buttons (NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        guard event.subtype.rawValue == 8 else { return }
        let code = Int((event.data1 & 0xFFFF_0000) >> 16)
        let flags = event.data1 & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0x0A
        guard isDown, [playPause, next, previous].contains(code) else { return }
        Task { @MainActor in lastPress = Date() }
    }
}
