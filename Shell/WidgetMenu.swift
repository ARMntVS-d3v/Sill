import AppKit
import SwiftUI

// Native macOS menu: widgets as a list, sizes in a hover submenu on the right.
// SwiftUI Menu with custom content renders its own way on macOS, so this is
// a plain NSMenu.
@MainActor
final class WidgetMenu: NSObject {
    private let onPick: (String, TileSize) -> Void
    private var strongSelf: WidgetMenu?

    init(onPick: @escaping (String, TileSize) -> Void) {
        self.onPick = onPick
        super.init()
    }

    func show(descriptors: [WidgetDescriptor], available: (TileSize) -> Bool, at point: NSPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for descriptor in descriptors {
            let item = NSMenuItem(title: String(localized: descriptor.name), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: descriptor.icon, accessibilityDescription: nil)

            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for size in descriptor.sizes {
                let sizeItem = NSMenuItem(
                    title: size.label, action: #selector(pick(_:)), keyEquivalent: "")
                sizeItem.target = self
                sizeItem.representedObject = Choice(widgetID: descriptor.id, size: size)
                sizeItem.isEnabled = available(size)
                submenu.addItem(sizeItem)
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        strongSelf = self  // the menu keeps us alive while open
        menu.popUp(positioning: nil, at: point, in: nil)
        strongSelf = nil
    }

    private struct Choice {
        let widgetID: String
        let size: TileSize
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        onPick(choice.widgetID, choice.size)
    }
}
