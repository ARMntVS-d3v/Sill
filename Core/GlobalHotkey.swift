import AppKit
import Carbon.HIToolbox

// Global keyboard shortcut. Uses Carbon's RegisterEventHotKey rather than an
// NSEvent global monitor: a monitor requires Accessibility access, Carbon needs
// none. Requesting permission to read every keystroke just to open a panel
// would be excessive.
@MainActor @Observable
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// Registration refused — the combo is taken by another app. Settings read
    /// this: a log line alone left the field showing the shortcut as if it worked
    private(set) var failed = false

    struct Combo: Codable, Equatable, Sendable {
        var keyCode: UInt32
        /// Modifiers as NSEvent.ModifierFlags.rawValue — convenient for both
        /// display and storage; converted to Carbon's form when registering
        var modifiers: UInt

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

        /// "⌥⌘V" — the way macOS menus write it
        var text: String {
            var result = ""
            if flags.contains(.control) { result += "⌃" }
            if flags.contains(.option) { result += "⌥" }
            if flags.contains(.shift) { result += "⇧" }
            if flags.contains(.command) { result += "⌘" }
            return result + Self.keyName(keyCode)
        }

        static func keyName(_ code: UInt32) -> String {
            // Layout doesn't matter: show the physical key in Latin letters, as menus do
            let names: [UInt32: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
                11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
                34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
                18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
                29: "0", 49: "Space", 36: "↩", 48: "⇥", 53: "Esc",
            ]
            return names[code] ?? "#\(code)"
        }
    }

    @ObservationIgnored var onFire: (() -> Void)?

    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    private static let signature = OSType(0x53494C4C)  // 'SILL'

    private init() {}

    func apply(_ combo: Combo?) {
        unregister()
        failed = false
        guard let combo else { return }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            combo.keyCode, Self.carbonModifiers(combo.flags), id, GetEventDispatcherTarget(), 0,
            &ref)
        if status == noErr {
            hotKey = ref
        } else {
            failed = true
            sillLog("[hotkey] registration failed, code \(status) — combo taken by another app")
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                // The callback arrives as a C function, so hop back to the main actor
                DispatchQueue.main.async { GlobalHotkey.shared.onFire?() }
                return noErr
            },
            1, &spec, nil, &handler)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
