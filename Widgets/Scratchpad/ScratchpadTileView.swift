import SwiftUI

// The whole tile is a text field. Minimal chrome: a word count and two buttons
// that appear on hover
struct ScratchpadTileView: View {
    let widget: ScratchpadWidget
    let size: TileSize

    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TileLabel(String(localized: "note"))
                Spacer(minLength: 0)
                if hovered, !widget.isEmpty {
                    Button { widget.copyToClipboard() } label: {
                        Image(systemName: "doc.on.doc")
                            .font(TileIcon.glyph)
                            .foregroundStyle(theme.textMuted.color)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    .tileControl()

                    Button { widget.clear() } label: {
                        Image(systemName: "trash")
                            .font(TileIcon.glyph)
                            .foregroundStyle(theme.textMuted.color)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                    .tileControl()
                }
            }

            // TextEditor has a built-in 5pt line inset, which threw off any placeholder
            // next to it. Cancel that inset with a negative padding so the text and the
            // placeholder both start flush with the tile edge
            ZStack(alignment: .topLeading) {
                if widget.isEmpty {
                    Text("Jot down…")
                        .font(TileFont.row)
                        .foregroundStyle(theme.textMuted.color)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { widget.text },
                    set: { widget.text = $0 }))
                    .font(TileFont.row)
                    .foregroundStyle(theme.textPrimary.color)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.leading, -5)
                    .focused($focused)
                    .releasesFocusOnHide($focused)
                    .tileControl()
            }
            .padding(.top, 7)

            if size != .small, !widget.isEmpty {
                Text(widget.wordsText)
                    .font(TileFont.axis)
                    .foregroundStyle(theme.textMuted.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
        .animation(.easeOut(duration: Motion.hover), value: hovered)
        .onHover { hovered = $0 }
    }
}
