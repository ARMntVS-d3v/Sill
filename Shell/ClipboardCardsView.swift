import AppKit
import SwiftUI

// History cards in two columns. Built like widget tiles, not colored plaques:
// content fills the whole card first, metadata is one muted line at the bottom.
// No colored headers or badges on purpose — the entry's type is already visible
// from its content, and a color stripe across the card would clash with the
// board's tiles.
struct ClipboardCardsView: View {
    let items: [ClipboardStore.Item]
    let selected: UUID?
    /// Scroll to follow the selection only when it's being driven by the keyboard
    let follow: Bool
    let onSelect: (ClipboardStore.Item) -> Void
    let onCopy: (ClipboardStore.Item) -> Void
    let onPin: (ClipboardStore.Item) -> Void
    let onRemove: (ClipboardStore.Item) -> Void

    /// Two columns of 316 — the same cell size as a rectangular tile
    private var columns: [GridItem] {
        [GridItem(.fixed(316), spacing: 12), GridItem(.fixed(316), spacing: 12)]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        ClipboardCard(
                            item: item,
                            selected: selected == item.id,
                            onSelect: { onSelect(item) },
                            onCopy: { onCopy(item) },
                            onPin: { onPin(item) },
                            onRemove: { onRemove(item) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selected) { _, new in
                guard let new, follow else { return }
                // No anchor: the card scrolls just enough to come into view.
                // A mouse click doesn't move the scroll position at all
                proxy.scrollTo(new)
            }
        }
    }
}

private struct ClipboardCard: View {
    let item: ClipboardStore.Item
    var selected = false
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onRemove: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @State private var hovered = false

    private static let height: CGFloat = 152

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
            // A darkening gradient under the metadata line: it needs to read
            // even over an image
            if item.isImage {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            meta
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        // Same surface, same style as the tiles: a clipboard card is a tile too,
        // and should look like one
        .background {
            Surface.fill(
                style: appState.appearance.tile, hovered: hovered,
                shape: RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous),
                theme: theme)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
        // Selection needs to read on images too: border plus an inner accent
        // outline — a single border over a busy photo gets lost
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .strokeBorder(
                    selected ? theme.accent.color : theme.border.color.opacity(hovered ? 0.8 : 0),
                    lineWidth: selected ? 2 : 0.5)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .fill(theme.accent.color.opacity(item.isImage ? 0.14 : 0.2))
                    .allowsHitTesting(false)
            }
        }
        // Buttons live in the corner, like the remove button on a tile in edit
        // mode, and only appear under the cursor — at rest the card shows its
        // content, not chrome
        .overlay(alignment: .topTrailing) {
            if hovered {
                HStack(spacing: 4) {
                    CardButton(icon: item.pinned ? "pin.slash.fill" : "pin.fill", action: onPin)
                    CardButton(icon: "xmark", action: onRemove)
                }
                .padding(7)
            } else if item.pinned {
                Image(systemName: "pin.fill")
                    .font(TileIcon.badge)
                    .foregroundStyle(theme.accent.color)
                    .padding(10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onCopy)
        // Selection happens on button release, not on a single tap: SwiftUI
        // holds a single tap for a quarter second to check for a second one,
        // and the selection border used to appear with a visible delay
        .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in onSelect() })
        .contextMenu {
            Button("Restore to clipboard", action: onCopy)
            Button(item.pinned ? "Unpin" : "Pin", action: onPin)
            Button("Delete", role: .destructive, action: onRemove)
        }
        .help("Double-click to restore to clipboard")
        .animation(.easeOut(duration: Motion.hover), value: hovered)
    }

    @ViewBuilder
    private var content: some View {
        if let image = ClipboardStore.shared.image(for: item), !item.isFile {
            // Fills the card completely: aspect ratio preserved, overflow
            // cropped. A small image is scaled up — empty margins around it
            // used to look like an unloaded tile
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 316, height: Self.height)
                .clipped()
        } else if item.isFile {
            file
        } else {
            // Text fades out at the edge instead of cutting off sharply: it's
            // clear there's more of it
            Text(ClipboardStore.preview(item))
                .font(TileFont.row)
                .foregroundStyle(theme.textPrimary.color)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, TileMetrics.padding)
                .padding(.top, 12)
                .padding(.bottom, 30)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.72),
                            .init(color: .clear, location: 0.96),
                        ],
                        startPoint: .top, endPoint: .bottom))
        }
    }

    // A file is identified by icon and name rather than a preview — a document
    // has no preview to show anyway
    private var file: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let image = ClipboardStore.shared.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: TileMetrics.thumbRadius, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .font(TileIcon.hero)
                    .foregroundStyle(theme.textMuted.color)
            }
            Text(ClipboardStore.preview(item))
                .font(TileFont.row)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, TileMetrics.padding)
        .padding(.top, TileMetrics.padding)
        .padding(.bottom, 30)
    }

    // A single muted line at the bottom: where from, when, and how much
    private var meta: some View {
        HStack(spacing: 6) {
            if let icon = ClipboardStore.sourceIcon(item.sourceID) {
                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
            }
            Text(ClipboardCard.ago(item.date))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(item.measure)
                .lineLimit(1)
        }
        .font(TileFont.caption)
        .foregroundStyle(item.isImage ? Color.white.opacity(0.8) : theme.textMuted.color)
        .padding(.horizontal, TileMetrics.padding)
        .padding(.bottom, 11)
    }

    /// "4m" is kept short: the card is about content, not exact timing
    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return String(localized: "just now")
        case ..<3600: return String(localized: "\(Int(seconds / 60))m")
        case ..<86400: return String(localized: "\(Int(seconds / 3600))h")
        default: return String(localized: "\(Int(seconds / 86400))d")
        }
    }
}

private struct CardButton: View {
    let icon: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TileIcon.badge)
                .foregroundStyle(theme.panelBackground.color)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(
                        hovered ? theme.textPrimary.color : theme.textPrimary.color.opacity(0.75)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
