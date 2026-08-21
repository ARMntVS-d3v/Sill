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
