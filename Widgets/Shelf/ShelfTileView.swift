import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Three sizes following the usual rule: the square shows the last file and a
// count, the rectangle three rows, the large size a grid plus "Clear".
// The shelf accepts files at any size — that's its main job.
struct ShelfTileView: View {
    let widget: ShelfWidget
    let size: TileSize

    @Environment(\.theme) private var theme
    @State private var targeted = false

    var body: some View {
        Group {
            if widget.isEmpty {
                empty
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
        // A border rather than a fill: with a file over the cursor, the tile
        // should show it's the drop target without recoloring its content.
        // A full tile responds with a warning color instead of blue: the file
        // won't fit here, and that has to be clear before the drop
        .overlay {
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .strokeBorder(
                    (widget.isFull ? theme.warning.color : theme.accent.color)
                        .opacity(targeted ? 0.9 : 0),
                    lineWidth: 2)
        }
        .animation(.easeOut(duration: Motion.hover), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard !widget.isFull else { return false }
            load(providers)
            return true
        }
        .contextMenu {
            if !widget.isEmpty {
                Button("Clear shelf", role: .destructive) { widget.clear() }
            }
        }
    }

    /// Files arrive as URLs, each one a separate provider
    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in widget.add([url]) }
            }
        }
    }

    // MARK: - empty

    private var empty: some View {
        TilePlaceholder(
            size == .small ? String(localized: "Drop a file") : String(localized: "Drop files"),
            icon: "tray.and.arrow.down")
    }

    /// One header for every size: how many files, and a way to clear them
    private var header: some View {
        HStack(spacing: 6) {
            TileLabel(widget.countText)
            Spacer(minLength: 0)
            Button("Clear") { widget.clear() }
                .buttonStyle(.plain)
                .tileControl()
                .font(TileFont.caption.weight(.medium))
                .foregroundStyle(theme.accent.color)
        }
    }

    // MARK: - square: one file

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 0)
            if let item = widget.shown.first {
                VStack(spacing: TileMetrics.captionGap) {
                    FileIcon(widget: widget, item: item, side: 46)
                    Text(item.name)
                        .font(TileFont.title)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .strikethrough(!widget.exists(item))
                }
                .frame(maxWidth: .infinity)
                // The file is picked up right here: the square is the whole file,
                // and dragging it should work from anywhere inside the tile
                .overlay { DragLayer(widget: widget, item: item) }
                .contextMenu { FileMenu(widget: widget, item: item) }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - rectangle: three rows

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: TileMetrics.rowGap) {
                ForEach(widget.shown) { item in
                    FileRow(widget: widget, item: item)
                }
            }
            .padding(.top, TileMetrics.blockGap)
            Spacer(minLength: 0)
        }
    }

    // MARK: - large: grid and clear

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                ForEach(widget.shown) { item in
                    FileCard(widget: widget, item: item)
                }
            }
            .padding(.top, TileMetrics.blockGap)

            Spacer(minLength: 0)
        }
    }
}

// A list row: icon, name, size. Dragging it with the mouse is how the file gets handed off
private struct FileRow: View {
    let widget: ShelfWidget
    let item: ShelfWidget.Item

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(widget: widget, item: item, side: 22)
            // Name and size share one line: at two lines per file, three rows
            // no longer fit within 152 and the tile outgrew its cell
            Text(item.name)
                .font(TileFont.row)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(!widget.exists(item))
            Spacer(minLength: 6)
            Text(widget.measure(of: item))
                .font(TileFont.caption)
                .foregroundStyle(theme.textMuted.color)
                .lineLimit(1)
            // Space for the close button is always reserved: appearing on hover
            // would shift the row under the cursor. The drag layer doesn't cover it
            Button { widget.remove(item) } label: {
                Image(systemName: "xmark")
                    .font(TileIcon.badge)
                    .foregroundStyle(theme.textMuted.color)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tileControl()
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .help("Remove from shelf")
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .overlay(alignment: .leading) {
            DragLayer(widget: widget, item: item)
                .padding(.trailing, 26)
        }
        .contextMenu { FileMenu(widget: widget, item: item) }
    }
}

// A card at the large size: a big icon with the name underneath
private struct FileCard: View {
    let widget: ShelfWidget
    let item: ShelfWidget.Item

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 5) {
            FileIcon(widget: widget, item: item, side: 38)
            Text(item.name)
                .font(TileFont.caption)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: TileMetrics.hitRadius, style: .continuous)
                .fill(hovered ? theme.tileHover.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // The whole card is draggable, so it has no close button: removing a file
        // is done via right-click. A button on top of the card would steal half the gesture
        .overlay { DragLayer(widget: widget, item: item) }
        .contextMenu { FileMenu(widget: widget, item: item) }
    }
}

private struct FileIcon: View {
    let widget: ShelfWidget
    let item: ShelfWidget.Item
    let side: CGFloat

    var body: some View {
        Image(nsImage: widget.icon(of: item))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .opacity(widget.exists(item) ? 1 : 0.4)
    }
}

// A transparent layer on top: this is what starts dragging the file out
private struct DragLayer: View {
    let widget: ShelfWidget
    let item: ShelfWidget.Item

    var body: some View {
        FileDragHandle(
            url: widget.url(of: item), icon: widget.icon(of: item),
            onOpen: { widget.open(item) })
            .allowsHitTesting(widget.exists(item))
            // The tile itself isn't dragged by the file: the gesture belongs to the file
            .tileControl()
    }
}

private struct FileMenu: View {
    let widget: ShelfWidget
    let item: ShelfWidget.Item

    var body: some View {
        Button("Open") { widget.open(item) }
        Button("Show in Finder") { widget.reveal(item) }
        Divider()
        Button("Remove from shelf", role: .destructive) { widget.remove(item) }
    }
}
