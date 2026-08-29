import SwiftUI

// Tiles sit at their own origin in the 4×2 unit grid. The unit is the
// GridMetrics.unit square; tile sizes are multiples of it: S 1×1, M 2×1, L 2×2.
struct BoardGridView: View {
    // Which board to draw: the active one, or the neighbor sliding in while
    // swiping. The neighbor is shown only as a picture — only the active board
    // can be edited
    var board: Board?
    var interactive = true

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    // What the preview frame shows while a gesture is in progress. The actual
    // change is applied only on release — otherwise the tile changes under the
    // cursor and the gesture breaks
    @State private var preview: TilePreview?
    @State private var activeTile: UUID?

    private static let step = GridMetrics.unit + GridMetrics.gap

    var body: some View {
        Group {
            if shownBoard?.kind == .clipboard {
                ClipboardBoardView(interactive: interactive)
            } else {
                tileBoard
            }
        }
        // The neighbor in the strip is a picture, not a board: without this,
        // its tiles kept answering taps, context menus, and long presses
        // during a swipe and the ~340 ms settle — a tap could run
        // primaryAction and close the panel mid-gesture
        .allowsHitTesting(interactive)
    }

    private var tileBoard: some View {
        VStack(spacing: 0) {
            grid
            // The "Ask" bar belongs to the board, not the panel: the clipboard
            // board has none at all, and while swiping it travels with its own
            // board — just like the tiles, not as a separate motion
            if AppSettings.shared.askBar {
                // Same view in both roles, no branching: with `if/else` SwiftUI
                // treats the branches as different views and rebuilds the bar
                // on every role change — along with whatever was typed into it
                AskBarView(live: interactive)
                    .padding(.horizontal, GridMetrics.padding)
                    .padding(.top, GridMetrics.askGap)
                    // Bottom panel padding: zeroed out on the grid because the
                    // bar sits below it — the padding belongs to the bar instead
                    .padding(.bottom, GridMetrics.bottomPadding)
            }
        }
    }

    /// Which board we're actually drawing — the one passed in, or the active one
    private var shownBoard: Board? { board ?? appState.activeBoard }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            // A long press on empty board space is the same entry into edit mode as
            // on a tile. The gesture is removed once in edit mode — empty cells are
            // occupied by "+ Widget" there instead
            if !appState.isEditing {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: GridMetrics.contentWidth, height: GridMetrics.contentHeight)
                    .onLongPressGesture(minimumDuration: 0.4) { appState.toggleEditing(true) }
            }

            if editing {
                // Dashed outlines only on free cells: tiles are translucent, and the
                // grid used to show through them, reading as dirt on the card
                EditGridBackdrop(cells: BoardLayout.freeCells(in: tiles))
                    .transition(.opacity)
                ForEach(BoardLayout.freeCells(in: tiles), id: \.self) { cell in
                    AddTileCell(origin: cell)
                        .frame(width: GridMetrics.unit, height: GridMetrics.unit)
                        .offset(x: offsetX(cell.col), y: offsetY(cell.row))
                }
            }

            // An empty board with no hint reads as broken, not as a clean slate
            if tiles.isEmpty && !editing {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(TileIcon.hero)
                        .foregroundStyle(theme.textMuted.color.opacity(0.7))
                    Text("This board is empty")
                        .font(TileFont.title)
                        .foregroundStyle(theme.textMuted.color)
                    Button("Add a widget") { appState.toggleEditing(true) }
                        .disabled(!interactive)
                        .buttonStyle(.plain)
                        .font(TileFont.caption.weight(.medium))
                        .foregroundStyle(theme.accent.color)
                }
                .frame(
                    width: GridMetrics.contentWidth,
                    height: GridMetrics.contentHeight,
                    alignment: .center)
            }

            ForEach(shownHosts) { host in
                TileView(
                    host: host,
                    onPreview: interactive ? { preview = $0; activeTile = $0 == nil ? nil : host.id } : nil,
                    onCommit: interactive ? { commit($0, host: host) } : nil)
                .frame(width: host.tile.size.width, height: host.tile.size.height)
                .offset(x: offsetX(host.tile.origin.col), y: offsetY(host.tile.origin.row))
                .zIndex(activeTile == host.id ? 10 : 0)
            }

            // Preview frame drawn above the tiles: when shrinking a large tile, the
            // frame falls inside its own area and would be hidden underneath it
            if let preview, editing {
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .fill(previewColor(preview).opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                            .strokeBorder(
                                previewColor(preview),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                    .overlay(alignment: .topTrailing) {
                        // Swap badge: shows that the neighboring tile won't
                        // disappear, it'll move into the space left behind
                        if preview.swaps {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(TileIcon.badge)
                                .foregroundStyle(theme.panelBackground.color)
                                .padding(4)
                                .background(Circle().fill(theme.success.color))
                                .padding(6)
                        }
                    }
                    .frame(width: preview.size.width, height: preview.size.height)
                    .offset(x: offsetX(preview.origin.col), y: offsetY(preview.origin.row))
                    .animation(.easeOut(duration: Motion.hover), value: preview)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .frame(
            width: GridMetrics.contentWidth,
            height: GridMetrics.contentHeight,
            alignment: .topLeading)
        .animation(.easeOut(duration: Motion.editing), value: editing)
        .padding(.horizontal, GridMetrics.padding)
        .padding(.top, GridMetrics.topGap)
        // The panel can be closed mid-edit-gesture — the preview frame must not
        // survive that: on the next entry into edit mode it would otherwise be
        // left hanging on the board on its own
        .onChange(of: appState.isPanelVisible) { _, visible in
            guard !visible else { return }
            preview = nil
            activeTile = nil
        }

        .padding(.bottom, GridMetrics.askBarHeight > 0 ? 0 : GridMetrics.bottomPadding)
    }

    // Edit-mode chrome is drawn for the neighbor in the strip too: edit mode
    // survives swiping, and a page sliding in without the dashed grid and
    // remove buttons would read as leaving edit mode. The neighbor has no live
    // handlers regardless (allowsHitTesting)
    private var editing: Bool { appState.isEditing }
    private var tiles: [Tile] { board?.tiles ?? appState.activeTiles }
    private var shownHosts: [TileHost] {
        guard let board else { return appState.activeHosts }
        return appState.hosts(of: board)
    }

    private func previewColor(_ preview: TilePreview) -> Color {
        if preview.swaps { return theme.success.color }
        return preview.valid ? theme.accent.color : theme.error.color
    }

    private func offsetX(_ col: Int) -> CGFloat { CGFloat(col) * Self.step }
    private func offsetY(_ row: Int) -> CGFloat { CGFloat(row) * Self.step }

    private func commit(_ change: TileChange, host: TileHost) {
        switch change {
        case .move(let origin):
            appState.move(tileID: host.id, to: origin)
        case .resize(let size):
            appState.resize(tileID: host.id, to: size)
        }
        preview = nil
        activeTile = nil
    }
}

// What the gesture is proposing: where the tile would land and at what size
struct TilePreview: Equatable {
    var origin: GridPoint
    var size: TileSize
    var valid: Bool
    /// The tiles will swap places — the frame shows this with a different color
    var swaps = false
}

enum TileChange {
    case move(GridPoint)
    case resize(TileSize)
}

// Dashed grid of free cells: shows where a tile will land. Apple's version has
// none, which leaves it unclear what's happening while dragging
private struct EditGridBackdrop: View {
    /// Free cells only: under occupied ones the dashes would show through the
    /// tiles' translucent glass
    let cells: [GridPoint]
    @Environment(\.theme) private var theme

    var body: some View {
        let step = GridMetrics.unit + GridMetrics.gap
        ForEach(cells, id: \.self) { cell in
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .strokeBorder(theme.textMuted.color.opacity(0.16), lineWidth: 1)
                .frame(width: GridMetrics.unit, height: GridMetrics.unit)
                .offset(x: CGFloat(cell.col) * step, y: CGFloat(cell.row) * step)
        }
        .allowsHitTesting(false)
    }
}

// A free cell in edit mode is an "add widget" button. Clicking it opens the
// native macOS menu: widgets listed, sizes in a submenu
private struct AddTileCell: View {
    let origin: GridPoint
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button {
            showMenu()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(TileIcon.hero)
                Text("Widget")
                    .font(TileFont.row)
            }
            .foregroundStyle(hovered ? theme.accent.color : theme.textMuted.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private func showMenu() {
        let descriptors = WidgetRegistry.all.map { $0.descriptor }
        let menu = WidgetMenu { widgetID, size in
            let fits = BoardLayout.canPlace(
                size: size, at: origin, ignoring: nil, in: appState.activeTiles)
            appState.addTile(widgetID: widgetID, size: size, at: fits ? origin : nil)
        }
        menu.show(
            descriptors: descriptors,
            available: { size in
                BoardLayout.canPlace(size: size, at: origin, ignoring: nil, in: appState.activeTiles)
                    || BoardLayout.firstFreeSpot(for: size, in: appState.activeTiles) != nil
            },
            at: NSEvent.mouseLocation)
    }
}
