import EventKit
import SwiftUI

// Tile chrome: background per the chosen style, error badge, placeholders — the
// shell draws this, not the widget.
struct TileView: View {
    let host: TileHost
    var onPreview: ((TilePreview?) -> Void)?
    var onCommit: ((TileChange) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var hovered = false
    // Offset lives here rather than in the parent: only this tile redraws, so
    // dragging doesn't stutter on heavy widgets
    @State private var dragOffset: CGSize = .zero
    /// Cursor position inside the tile. Kept in an object, not @State: the point
    /// changes on every mouse move, and going through state would redraw the
    /// tile on every pixel
    @State private var cursor = CursorPoint()
    @State private var isDragging = false
    // Bounds of the widget's active controls: we don't drag the tile from inside them
    @State private var controls: [CGRect] = []

    private var style: TileStyle { appState.appearance.tile }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Fixed tile size: the widget has no right to stretch it. Without
                // this, content that overflows would push the card outward — the
                // tile would spill past its own cell and overlap its neighbor
                .frame(
                    width: host.tile.size.width, height: host.tile.size.height,
                    alignment: .topLeading)
                .clipped()
            if let error = host.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning.color)
                    .padding(6)
                    .help(error)
            }
        }
        .background { Surface.fill(style: style, hovered: hovered, shape: shape, theme: theme) }
        .clipShape(shape)
        .overlay { Surface.edge(style: style, hovered: hovered, shape: shape, theme: theme) }
        .modifier(TileShadow(style: style))
        .animation(.easeOut(duration: Motion.hover), value: hovered)
        .onHover { hovered = $0 }
        .overlay {
            if appState.isEditing {
                editingChrome.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Motion.editing), value: appState.isEditing)
        .coordinateSpace(name: TileCoordinateSpace.name)
        .onPreferenceChange(TileControlBounds.self) { controls = $0 }
        // Cursor position for the long-press gesture, which has no point of its own
        .onContinuousHover(coordinateSpace: .named(TileCoordinateSpace.name)) { phase in
            switch phase {
            case .active(let point): cursor.point = point
            case .ended: cursor.point = nil
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // In edit mode the tap is claimed by dragging
            guard !appState.isEditing else { return }
            // The panel closes only if the widget actually had somewhere to send you
            if host.widget?.primaryAction() == true { appState.requestHide?() }
        }
        .contextMenu { tileMenu }
        .offset(dragOffset)
        .scaleEffect(isDragging ? 1.03 : 1)
        .shadow(color: theme.shadow.color.opacity(isDragging ? 0.5 : 0), radius: 12, y: 6)
        .animation(.easeOut(duration: 0.14), value: isDragging)
        .gesture(moveGesture)
        // Edit-mode jiggle, like a home screen: signals that tiles can be moved.
        // Phases differ per tile — jiggling in unison would read as mechanical.
        // Started and stopped only via explicit withAnimation: a forever animation
        // attached declaratively (.animation(value:)) didn't stop when edit mode
        // reset inside a no-animation transaction — tiles kept jiggling after reopening
        .rotationEffect(.degrees(jiggleAngle))
        .onChange(of: appState.isEditing, initial: true) { _, editing in
            if editing {
                jiggleAngle = -jiggleAmplitude
                withAnimation(
                    .easeInOut(duration: Motion.jiggle).repeatForever(autoreverses: true)
                        .delay(jigglePhase)
                ) {
                    jiggleAngle = jiggleAmplitude
                }
            } else {
                // A regular animation retargets and kills the repeatForever
                withAnimation(.easeOut(duration: Motion.editing)) { jiggleAngle = 0 }
            }
        }
    }

    // Jiggle: a larger tile has a longer arm, so the same angle sweeps further at
    // the edge — hence amplitude shrinks as size grows (standards.md)
    @State private var jiggleAngle: Double = 0
    @State private var jigglePhase = Double.random(in: 0...Motion.jiggle)

    private var jiggleAmplitude: Double {
        switch host.tile.size {
        case .small: 1.2
        case .medium: 0.8
        case .large: 0.6
        }
    }



    // Edit-mode chrome: remove button and resize handle
    @State private var removeHovered = false

    private var editingChrome: some View {
        ZStack(alignment: .topLeading) {
            // 18-pt circle, 26-pt hit zone (docs/standards.md, "hit zones"):
            // offset by 4 extra in each direction so the circle itself stays put
            Button {
                appState.removeTile(id: host.id)
            } label: {
                Image(systemName: "minus")
                    .font(TileIcon.badge)
                    .foregroundStyle(theme.panelBackground.color)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.textPrimary.color))
                    .frame(width: TileChromeMetrics.removeHit, height: TileChromeMetrics.removeHit)
                    // The zone is bigger than the circle — a hover highlight is required (standards)
                    .background(Circle().fill(removeHovered ? theme.tileHover.color : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { removeHovered = $0 }
            .animation(.easeOut(duration: Motion.hover), value: removeHovered)
            .help("Remove Widget")
            // The button extends sideways (the panel has a 22-pt side margin) but
            // not upward: the circle sits flush with the tile's top edge,
            // otherwise the grid would need to leave room below the wings for it
            .offset(x: -10, y: -4)

            if onCommit != nil {
                ResizeHandle(host: host, onPreview: { onPreview?($0) }, onCommit: { onCommit?(.resize($0)) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 7, y: 7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Outside edit mode the tile only catches a long press (enters edit mode);
    // inside edit mode only dragging: a combined gesture behaves unpredictably in SwiftUI
    private var moveGesture: AnyGesture<Void> {
        guard appState.isEditing, onCommit != nil else {
            let press = LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    // A long press on a button, menu, or field isn't an entry into
                    // edit mode — the person is using that control. The translator's
                    // language picker opens on press-and-hold, and edit mode kept
                    // triggering right under it. LongPressGesture has no point of
                    // its own, so we use the last known cursor position — presses
                    // happen where the cursor already is
                    if let point = cursor.point, isOnControl(point) { return }
                    appState.toggleEditing(true)
                }
            return AnyGesture(press.map { _ in () })
        }
        let drag = DragGesture(minimumDistance: 3, coordinateSpace: .named(TileCoordinateSpace.name))
            .onChanged { value in
                // Gesture started on a button or field — the tile stays put
                guard !isOnControl(value.startLocation) else { return }
                isDragging = true
                dragOffset = value.translation
                let target = targetOrigin(for: value.translation)
                // A swap is a valid outcome too, not a rejection
                let canPlace = BoardLayout.canPlace(
                    size: host.tile.size, at: target, ignoring: host.id, in: appState.activeTiles)
                let swaps = !canPlace
                    && BoardLayout.swapTarget(
                        for: host.tile, at: target, in: appState.activeTiles) != nil
                onPreview?(
                    TilePreview(
                        origin: target, size: host.tile.size,
                        valid: canPlace || swaps, swaps: swaps))
            }
            .onEnded { value in
                guard !isOnControl(value.startLocation) else { return }
                let target = targetOrigin(for: value.translation)
                // Offset is cleared instantly, at the same moment the move applies:
                // any animation here would desync from the parent's own reflow,
                // and the tile would jump sideways for a frame
                isDragging = false
                dragOffset = .zero
                onCommit?(.move(target))
            }
        return AnyGesture(drag.map { _ in () })
    }

    private func isOnControl(_ point: CGPoint) -> Bool {
        controls.contains { $0.contains(point) }
    }

    private func targetOrigin(for translation: CGSize) -> GridPoint {
        let step = GridMetrics.unit + GridMetrics.gap
        let col = Int(((CGFloat(host.tile.origin.col) * step) + translation.width) / step + 0.5)
        let row = Int(((CGFloat(host.tile.origin.row) * step) + translation.height) / step + 0.5)
        return GridPoint(
            col: min(max(col, 0), GridMetrics.columns - host.tile.size.columns),
            row: min(max(row, 0), GridMetrics.rows - host.tile.size.rows))
    }

    @ViewBuilder
    private var tileMenu: some View {
        if let descriptor = host.descriptor {
            // Sizes as a plain list, no icons: the system already draws a checkmark
            // next to the current one. A custom "square/checkmark" on the left
            // shifted the rest of the menu items and looked homemade
            Picker(
                "Size",
                selection: Binding(
                    get: { host.tile.size },
                    set: { onCommit?(.resize($0)) })
            ) {
                ForEach(availableSizes(descriptor), id: \.self) { size in
                    Text(size.label).tag(size)
                }
            }
            .pickerStyle(.inline)
            Divider()
        }
        Button(appState.isEditing ? "Done" : "Edit board") {
            appState.toggleEditing()
        }
        Button("Remove Widget", role: .destructive) { appState.removeTile(id: host.id) }
    }

    // Sizes the tile can actually fit into. The current size is always shown —
    // otherwise it would vanish from the list along with its checkmark
    private func availableSizes(_ descriptor: WidgetDescriptor) -> [TileSize] {
        descriptor.sizes.filter { size in
            size == host.tile.size
                || BoardLayout.placement(
                    for: size, preferring: host.tile.origin, ignoring: host.id,
                    in: appState.activeTiles) != nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let permission = host.missingPermission {
            PermissionPlaceholder(permission: permission) {
                Task {
                    await PermissionPlaceholder.ask(permission)
                    host.reactivate()
                }
            }
        } else if let widget = host.widget {
            widget.body
        } else {
            VStack(spacing: 4) {
                Image(systemName: "questionmark.square.dashed")
                Text(host.tile.widgetID).font(TileFont.caption)
            }
            .foregroundStyle(theme.textMuted.color)
        }
    }
}

// The shell draws the placeholder, not the widget — the widget only signals WidgetError.permissionDenied
private struct PermissionPlaceholder: View {
    /// Show the system access-request dialog for this permission
    @MainActor
    static func ask(_ permission: PermissionKind) async {
        switch permission {
        case .calendar, .calendarLimited: _ = await CalendarAccess.ask(.event, store: CalendarAccess.store)
        case .reminders: _ = await CalendarAccess.ask(.reminder, store: CalendarAccess.store)
        default:
            if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
        }
    }

    let permission: PermissionKind
    var onAsk: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "lock")
                .font(TileIcon.hero)
                .foregroundStyle(theme.warning.color)
            Text(permission.title)
                .font(TileFont.caption)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            // Before the system has ever asked, sending the person to System
            // Settings is pointless: the app isn't listed there yet — it only
            // shows up after the first request. So we offer the request itself first
            if permission.canAsk {
                Button("Allow") { onAsk?() }
                    .buttonStyle(.plain)
                    .font(TileFont.caption.weight(.medium))
                    .foregroundStyle(theme.accent.color)
                    .tileControl()
            } else if let url = permission.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain)
                    .font(TileFont.caption.weight(.medium))
                    .foregroundStyle(theme.accent.color)
                    .tileControl()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// Resize handle: drag it and the tile snaps between the allowed sizes.
// Only sizes the widget declares, and that fit on the board, are allowed.
private struct ResizeHandle: View {
    let host: TileHost
    let onPreview: (TilePreview?) -> Void
    let onCommit: (TileSize) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var dragging = false
    // Size at gesture start: the target is computed from this, otherwise steps
    // stack on top of each other and the handle behaves unpredictably
    @State private var startSize: TileSize?

    private var available: [TileSize] {
        guard let descriptor = host.descriptor else { return [] }
        return BoardLayout.availableSizes(
            for: host.tile, supported: descriptor.sizes, in: appState.activeTiles)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(dragging ? theme.accent.color : theme.textPrimary.color.opacity(0.85))
                .frame(width: 20, height: 20)
            Image(systemName: "arrow.down.right")
                .font(TileIcon.badge)
                .foregroundStyle(theme.panelBackground.color)
        }
        .opacity(available.count > 1 ? 1 : 0.35)
        .scaleEffect(dragging ? 1.15 : 1)
        .animation(.easeOut(duration: 0.12), value: dragging)
        // 20-pt handle, 28-pt hit zone: dragged with a mouse, not a finger on glass
        .frame(width: TileChromeMetrics.resizeHit, height: TileChromeMetrics.resizeHit)
        .contentShape(Rectangle())
        // Higher priority than the tile's own drag gesture, otherwise that one wins
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    dragging = true
                    if startSize == nil { startSize = host.tile.size }
                    // While dragging, only the preview frame moves. The tile
                    // under the cursor can't change mid-gesture — it would slide
                    // out from under the handle and break the gesture
                    let size = size(for: value.translation)
                    let spot = BoardLayout.placement(
                        for: size, preferring: host.tile.origin, ignoring: host.id,
                        in: appState.activeTiles)
                    onPreview(
                        TilePreview(
                            origin: spot ?? host.tile.origin, size: size, valid: spot != nil))
                }
                .onEnded { value in
                    let final = size(for: value.translation)
                    dragging = false
                    startSize = nil
                    if final != host.tile.size {
                        onCommit(final)
                    } else {
                        onPreview(nil)
                    }
                }
        )
        .help("Drag to resize")
    }

    // Step in cells, relative to the size at gesture start. The threshold is
    // small and independent of tile size: a tile in a board corner has nowhere
    // for the cursor to go for a half-cell drag — it hits the panel edge and
    // could never be resized.
    private static let threshold: CGFloat = 26

    private func size(for translation: CGSize) -> TileSize {
        let base = startSize ?? host.tile.size
        let cols = clampToBoard(base.columns + step(translation.width))
        let rows = clampToBoard(base.rows + step(translation.height))

        let wanted: TileSize = switch (cols, rows) {
        case (1, 1): .small
        case (2, 1): .medium
        default: .large
        }
        if available.contains(wanted) { return wanted }
        // Closest allowed size, if the wanted one doesn't fit
        let order: [TileSize] = [.small, .medium, .large]
        guard let wantedIndex = order.firstIndex(of: wanted) else { return host.tile.size }
        return available.min {
            abs((order.firstIndex(of: $0) ?? 0) - wantedIndex)
                < abs((order.firstIndex(of: $1) ?? 0) - wantedIndex)
        } ?? host.tile.size
    }

    private func step(_ delta: CGFloat) -> Int {
        if delta > Self.threshold { return 1 }
        if delta < -Self.threshold { return -1 }
        return 0
    }

    private func clampToBoard(_ value: Int) -> Int { min(max(value, 1), 2) }
}

private struct TileShadow: ViewModifier {
    let style: TileStyle
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if style == .raised {
            content.shadow(color: theme.shadow.color.opacity(0.85), radius: 8, y: 4)
        } else {
            content
        }
    }
}

// Hit zones for tile chrome — docs/standards.md, "hit zones" section
enum TileChromeMetrics {
    static let removeHit: CGFloat = 26
    static let resizeHit: CGFloat = 28
}


/// Last known cursor position inside the tile — for gestures that have no point of their own
@MainActor
final class CursorPoint {
    var point: CGPoint?
}

// App surface: tile, clipboard card, "Ask" bar. One style for all of them, chosen
// in Appearance — two different surfaces in the same window is a mistake we've
// already made once
enum Surface {
    @ViewBuilder
    static func fill(
        style: TileStyle, hovered: Bool, shape: RoundedRectangle, theme: Theme
    ) -> some View {
        switch style {
        case .flat:
            (hovered ? theme.tileHover.color : theme.tileBackground.color)
        case .screen:
            ZStack {
                theme.tileBackground.color
                RadialGradient(
                    colors: [
                        theme.accent.color.opacity(hovered ? 0.10 : 0.06),
                        theme.accent.color.opacity(0),
                    ],
                    center: .top, startRadius: 0, endRadius: 120)
            }
        case .topHighlight:
            theme.tileBackground.color
        case .outline:
            hovered ? theme.tileHover.color.opacity(0.5) : Color.clear
        case .raised:
            (hovered ? theme.tileHover.color : theme.tileBackground.color)
                .brightness(0.02)
        case .bare:
            hovered ? theme.tileHover.color : Color.clear
        case .glass:
            // Apple's own approach: a light film over the blur, reading neutral
            // gray — systemic
            GlassBackground(
                shape: shape, theme: theme,
                scrim: hovered ? 0.15 : 0.09,
                scrimColor: theme.textPrimary.color, border: false)
        case .matte:
            // Flat surface with a thin edge — exactly what shows up in window
            // screenshots, where glass doesn't render and only the film is left.
            // The panel background is darker than the tile color, so a thinner
            // film means a darker surface
            (hovered ? theme.tileHover.color : theme.tileBackground.color)
                .opacity(hovered ? 0.75 : 0.55)
        case .glassDark:
            // Film in the tile's own color, but thinner: the panel background is
            // darker than the tile itself, so the thinner the film, the darker the
            // surface reads. A solid black film doesn't work — it makes the tile
            // darker than the background and reads as a hole
            GlassBackground(
                shape: shape, theme: theme,
                scrim: hovered ? 0.75 : 0.55,
                scrimColor: hovered ? theme.tileHover.color : theme.tileBackground.color,
                border: false)
        }
    }

    @ViewBuilder
    static func edge(
        style: TileStyle, hovered: Bool, shape: RoundedRectangle, theme: Theme
    ) -> some View {
        switch style {
        case .flat, .screen, .bare:
            EmptyView()
        case .glass, .glassDark, .matte:
            // Thin edge: without it the surface blends into the panel background
            shape.strokeBorder(theme.border.color.opacity(0.7), lineWidth: 0.5)
        case .outline:
            shape.strokeBorder(
                hovered ? theme.textMuted.color.opacity(0.6) : theme.border.color, lineWidth: 1)
        case .raised:
            shape.strokeBorder(theme.textPrimary.color.opacity(0.05), lineWidth: 1)
        case .topHighlight:
            // A short light streak along the top edge, fading toward the corners
            LinearGradient(
                colors: [
                    .clear,
                    theme.textPrimary.color.opacity(hovered ? 0.38 : 0.26),
                    .clear,
                ],
                startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}
