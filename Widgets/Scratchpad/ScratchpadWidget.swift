import AppKit
import SwiftUI

// A note that lives in the panel: open it, jot something down, close it.
// The text is stored in the tile's own settings, so two tiles on a board are two
// separate notes, and both survive a restart.
@MainActor @Observable
final class ScratchpadWidget: Widget {
    static let descriptor = WidgetDescriptor(
        id: "scratchpad",
        name: "Note",
        icon: "square.and.pencil",
        sizes: [.small, .medium, .large],
        defaultSize: .medium
    )

    private let context: WidgetContext

    var text: String {
        didSet {
            guard text != oldValue else { return }
            context.settings.set("text", text)
        }
    }

    init(context: WidgetContext) {
        self.context = context
        text = context.settings.get("text", as: String.self) ?? ""
    }

    var body: AnyView {
        AnyView(ScratchpadTileView(widget: self, size: context.tileSize))
    }

    // Clicking the tile doesn't open anything: the whole note is right here

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clear() { text = "" }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // "12 words" — a count under the text so the tile doesn't look empty at the bottom
    var wordsText: String {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return words == 1 ? String(localized: "1 word") : String(localized: "\(words) words")
    }
}
