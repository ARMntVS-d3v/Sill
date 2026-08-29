import SwiftUI

// Shared tile parts. A widget doesn't invent its own look for things that
// are already decided: the empty state, the corner label. Otherwise the
// board fragments into different handwriting — one tile's caption sits
// small and left-aligned, the next one's large and centered.

/// Nothing for the tile to show: "No events", "Nothing playing", "All done".
/// Always centered, always TileFont.title muted — the same across every
/// widget and all three sizes.
struct TilePlaceholder: View {
    let text: String
    /// Widget icon: the text alone doesn't always say whose tile this is —
    /// "Nothing playing" without a note reads as anything
    var icon: String?
    @Environment(\.theme) private var theme

    init(_ text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        VStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(TileIcon.hero)
                    .foregroundStyle(theme.textMuted.color.opacity(0.75))
            }
            Text(text)
                .font(TileFont.title)
                .foregroundStyle(theme.textMuted.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Corner label on a tile: date, city, counter. Uppercase with letter
/// spacing, muted.
struct TileLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(TileFont.label)
            .kerning(0.5)
            .foregroundStyle(theme.textMuted.color)
            .lineLimit(1)
    }
}


/// Text input inside a tile. The hint is drawn under the field itself, same size
/// and color (docs/standards.md, "empty states") — a hint placed beside the field
/// stands away from the cursor.
///
/// The field is a `TextField`, even for several lines. `TextEditor` was the obvious
/// choice for multi-line text, but it carries its own 5-pt line inset — cancelled by
/// a negative padding in every widget separately — and it draws the caret a line
/// above the text: the bar ended at the baseline instead of below it.
struct TileTextField: View {
    @Binding var text: String
    let placeholder: String
    /// How far the field may grow. One line stays a single-line field
    var lines: ClosedRange<Int> = 1...1
    var focus: FocusState<Bool>.Binding
    /// Clearing the field. The circled cross lives in the field itself, where every
    /// system search field keeps it — a bare cross in the tile's corner didn't read
    /// as "clear" at all
    var onClear: (() -> Void)?
    /// Return pressed. A single-line field submits on Return; a multi-line one
    /// treats it the same way — the text is short and there is nothing to break
    var onSubmit: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var clearHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(TileFont.row)
                        .foregroundStyle(theme.textMuted.color)
                        .allowsHitTesting(false)
                }
                field
                    .textFieldStyle(.plain)
                    .font(TileFont.row)
                    .foregroundStyle(theme.textPrimary.color)
                    .focused(focus)
                    .releasesFocusOnHide(focus)
                    .onSubmit { onSubmit?() }
            }
            if let onClear, !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(TileIcon.glyph)
                        .foregroundStyle(
                            clearHovered ? theme.textSecondary.color : theme.textMuted.color)
                        .frame(width: TileControlMetrics.fieldClearHit, height: TileControlMetrics.fieldClearHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { clearHovered = $0 }
                .animation(.easeOut(duration: Motion.hover), value: clearHovered)
                .help("Clear")
                .tileControl()
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        if lines.upperBound > 1 {
            TextField("", text: $text, axis: .vertical)
                .lineLimit(lines)
        } else {
            TextField("", text: $text)
        }
    }
}
