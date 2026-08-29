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

            // The note stays on TextEditor, unlike the translator and "Ask": a
            // TextField with a vertical axis submits on Return instead of breaking
            // the line (checked on a bare harness — four Returns left one line), and
            // a note you can't press Enter in isn't a note. The price is TextEditor's
            // own 5-pt line inset, cancelled here so the text and the hint start on
            // the same vertical
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
