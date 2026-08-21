import AppKit
import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    /// `behindWindow` blurs the desktop behind the window, `withinWindow` blurs
    /// whatever is drawn in this same window below this view
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

/// Glass backing for the floating bar: on macOS 26 it's native "liquid glass",
/// below that it's the window material. It blurs the window's own content, not
/// the desktop: the bar sits on top of a list, and the glass should show that list
struct GlassBackground: View {
    let shape: RoundedRectangle
    let theme: Theme
    /// Backing under the glass: without it, content reads differently depending
    /// on what ends up beneath the surface. The bar over a list gets a dark
    /// backing, a tile gets the tile's own color, otherwise the tile looks like
    /// a hole in the panel
    var scrim: Double = 0.3
    var scrimColor: Color?
    var border: Bool = true

    var body: some View {
        base
            .background(shape.fill((scrimColor ?? theme.panelBackground.color).opacity(scrim)))
            .overlay(border ? shape.strokeBorder(theme.border.color, lineWidth: 0.5) : nil)
    }

    /// Native "liquid glass" on macOS 26. It tracks window activity — clicking
    /// outside a pinned panel lightens the surfaces — but the fallback material
    /// doesn't look like glass, so Alexander chose glass along with that behavior
    @ViewBuilder
    private var base: some View {
        if #available(macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                .clipShape(shape)
        }
    }
}

// Design B, "notch wings": no sidebar, the top row lives on either side of the
// notch. The window is bigger than the island — margins on the sides and bottom
// leave room so the outer shadow doesn't get clipped.
struct PanelRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let theme = appState.theme
        let visible = appState.isPanelVisible
        // Two ways to appear, one set of modifiers: the difference is only in the
        // collapsed state and the curve. Branching inside the modifiers made the
        // panel jump a frame whenever the appearance mode changed
        let slide = appState.appearing == .slide
        // The row's entrance and exit are their own smooth motion, not a snap.
        // From the notch: the panel is collapsed to notch size; from the top: it
        // has slid off past the edge
        let collapsedScale = slide
            ? CGSize(width: 1, height: 1)
            : appState.collapseScale
        let collapsedOffset = slide ? -PanelMetrics.island.height : 0
        let slow = Motion.filmSlowdown
        let move: Animation = slide
            ? .spring(response: Motion.panelSlide * slow, dampingFraction: 0.9)
            : .easeOut(duration: Motion.panelNotch * slow)
        // Content fades out later than the shape animates: it leaves first, then disappears
        let fade: Animation = slide
            ? .easeOut(duration: 0.14).delay(visible ? 0 : 0.08)
            : .linear(duration: 0.06 * slow).delay(visible ? 0 : 0.24 * slow)

        VStack(spacing: 0) {
            island(theme: theme)
                .frame(width: PanelMetrics.island.width, height: PanelMetrics.island.height)
                .opacity(visible ? 1 : 0)
                .animation(fade, value: visible)
                .scaleEffect(
                    x: visible ? 1 : collapsedScale.width,
                    y: visible ? 1 : collapsedScale.height,
                    anchor: .top)
                .offset(y: visible ? 0 : collapsedOffset)
                .animation(move, value: visible)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, PanelMetrics.sidePad)  // window margins: room for the outer shadow
        .environment(\.theme, theme)
    }

    @ViewBuilder
    private func island(theme: Theme) -> some View {
        // Top corners are square — the panel sits flush against the screen edge
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: theme.cornerRadius + 6,
            bottomTrailingRadius: theme.cornerRadius + 6,
            topTrailingRadius: 0,
            style: .continuous)

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // The row height is always GridMetrics.wingsHeight, and the window
                // height is derived from it
                NotchWingsView()
                    .frame(height: max(appState.topInset, GridMetrics.wingsHeight))

                // Either the board or the conversation goes up top. The "Ask" row
                // is part of the board itself and moves with it
                ZStack {
                    if appState.askOpen {
                        VStack(spacing: 0) {
                            AskChatView {
                                withAnimation(.easeOut(duration: Motion.askOpen)) { appState.askOpen = false }
                            }
                            AskBarView()
                                .padding(.horizontal, GridMetrics.padding)
                                .padding(.top, GridMetrics.askGap)
                        }
                        // The conversation unfolds upward from the input row rather
                        // than swapping the board out in a single frame
                        .transition(.unfoldFromBar)
                    } else {
                        // Swiping: boards sit side by side on one strip, and the
                        // whole strip moves. Each board can't carry its own offset —
                        // that's two subtree layout passes per frame, and the strip
                        // would stutter on a swipe
                        BoardStrip()
                            .clipped()
                            // Tiles sink into the same row the conversation unfolds
                            // from: they slide down toward it and fade
                            .transition(.sinkIntoBar)
                    }
                }
                // The board hugs the wings instead of centering in the remaining
                // space: the free space is the panel's bottom margin, and it
                // belongs at the bottom
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                panelBackground
            }
        }
        .clipShape(shape)
        .modifier(PanelEdgeModifier(style: appState.appearance.edge, shape: shape, theme: theme))
    }
}

// Board strip: the active board and, mid-gesture, its neighbor — left or right of it
private struct BoardStrip: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let width = PanelMetrics.island.width
        let neighbor = appState.boardDragNeighborBoard
        let neighborOnRight = appState.boardDragSide > 0

        // The offset itself is read by a nested view: reading it here would
        // rebuild the whole strip — both boards and all their content — on every
        // gesture event. This way only the offset modifier recomputes
        StripOffset {
            // Top alignment is required: the clipboard board and a regular board
            // differ in height, and center alignment made the neighbor ride a
            // third of a tile too high
            HStack(alignment: .top, spacing: 0) {
                if let neighbor, !neighborOnRight {
                    BoardGridView(board: neighbor, interactive: false).frame(width: width)
                }
                BoardGridView().frame(width: width)
                if let neighbor, neighborOnRight {
                    BoardGridView(board: neighbor, interactive: false).frame(width: width)
                }
            }
            .frame(
                width: width,
                alignment: neighbor != nil && !neighborOnRight ? .trailing : .leading)
        }
    }
}

/// Thin wrapper that only moves the strip. Everything it receives is already
/// built by the parent and doesn't get rebuilt on every gesture event
private struct StripOffset<Content: View>: View {
    @Environment(AppState.self) private var appState
    @ViewBuilder var content: Content

    var body: some View {
        content.offset(x: appState.boardDragOffset)
    }
}


extension PanelRootView {
    private var theme: Theme { appState.theme }

    /// Panel background: four choices. What they share is that the notch strip
    /// stays black, otherwise the notch shows up as a dark rectangle
    @ViewBuilder
    var panelBackground: some View {
        switch appState.appearance.background {
        case .black:
            theme.panelBackground.color
        case .graphite:
            ZStack {
                theme.panelBackground.color
                bodyTint(theme.tileBackground.color.opacity(0.45))
            }
        case .halo:
            ZStack {
                theme.panelBackground.color
                // Glow emanates from under the notch and fades toward the middle:
                // the panel "flows out" of the notch, and the background echoes that
                RadialGradient(
                    colors: [theme.accent.color.opacity(0.16), .clear],
                    center: UnitPoint(x: 0.5, y: notchStop),
                    startRadius: 0,
                    endRadius: PanelMetrics.island.height * 0.75)
                bodyTint(theme.tileBackground.color.opacity(0.35))
            }
        case .aurora:
            // Two spots below the notch strip: one accent-colored, one neutral
            // and weaker. Both offset toward the edges so they don't shine into
            // the notch itself
            ZStack {
                theme.panelBackground.color
                RadialGradient(
                    colors: [theme.accent.color.opacity(0.16), .clear],
                    center: UnitPoint(x: 0.18, y: 0.38),
                    startRadius: 0, endRadius: PanelMetrics.island.height * 0.8)
                RadialGradient(
                    colors: [theme.textPrimary.color.opacity(0.05), .clear],
                    center: UnitPoint(x: 0.86, y: 0.6),
                    startRadius: 0, endRadius: PanelMetrics.island.height * 0.7)
                bodyTint(theme.tileBackground.color.opacity(0.3))
            }
        case .underGlow:
            // Light from below: the panel looks like it's resting on a glow.
            // The top is untouched — that's where the notch is
            ZStack {
                theme.panelBackground.color
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: theme.accent.color.opacity(0.13), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
                bodyTint(theme.tileBackground.color.opacity(0.3))
            }
        case .spot:
            // A neutral spot in the center of the board: light without color,
            // the quietest of the options
            ZStack {
                theme.panelBackground.color
                RadialGradient(
                    colors: [theme.textPrimary.color.opacity(0.08), .clear],
                    center: UnitPoint(x: 0.5, y: 0.72),
                    startRadius: 0, endRadius: PanelMetrics.island.height * 0.62)
                bodyTint(theme.tileBackground.color.opacity(0.25))
            }
        case .material:
            ZStack {
                // Desktop blur: the panel's own tone is set by whatever is behind
                // the window, so on a dark desktop it reads almost black — the
                // same way system panels behave
                VisualEffectBackground()
                LinearGradient(
                    stops: [
                        .init(color: theme.panelBackground.color, location: 0),
                        .init(color: theme.panelBackground.color, location: notchStop),
                        .init(
                            color: theme.panelBackground.color.opacity(0.78),
                            location: min(notchStop + 0.14, 1)),
                        .init(color: theme.panelBackground.color.opacity(0.78), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
        }
    }

    /// Tint over the panel body below the notch strip, stretched over a
    /// transition — without the stretch the seam is visible
    private func bodyTint(_ color: Color) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: notchStop),
                .init(color: color, location: min(notchStop + 0.14, 1)),
                .init(color: color, location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    /// Share of the panel height taken up by the notch strip
    var notchStop: CGFloat {
        max(0.06, min(appState.topInset / PanelMetrics.island.height, 0.5))
    }
}

enum PanelMetrics {
    @MainActor static var island: CGSize { GridMetrics.islandSize }
    static let sidePad: CGFloat = 10   // window margin around the island — room for the shadow
    static let bottomPad: CGFloat = 12
    @MainActor static var window: CGSize {
        CGSize(width: island.width + sidePad * 2, height: island.height + bottomPad)
    }
}

// Panel edge. The top face is never visible in any style — that's the screen edge.
struct PanelEdgeModifier: ViewModifier {
    let style: PanelEdgeStyle
    let shape: UnevenRoundedRectangle
    let theme: Theme

    func body(content: Content) -> some View {
        switch style {
        case .none:
            content

        // All shadows are short and faint: a long shadow on a black background
        // reads as a dirty halo around the panel. Lines are one pixel (0.5 pt on Retina).
        case .depth:
            content.shadow(color: theme.shadow.color.opacity(0.5), radius: 6, y: 3)

        case .innerGlow:
            content
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.textPrimary.color.opacity(0.04),
                                    theme.textPrimary.color.opacity(0.10),
                                ],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                        .mask(fadeTop(0.22))
                }
                .shadow(color: theme.shadow.color.opacity(0.4), radius: 5, y: 2)

        case .underLight:
            content
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.6),
                                    .init(color: theme.accent.color.opacity(0.22), location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                }
                .shadow(color: theme.accent.color.opacity(0.06), radius: 6, y: 3)

        case .softThick:
            content
                .overlay {
                    shape
                        .strokeBorder(theme.accent.color.opacity(0.12), lineWidth: 1)
                        .mask(fadeTop(0.18))
                }
                .shadow(color: theme.accent.color.opacity(0.04), radius: 6, y: 2)

        case .phosphorRim:
            content
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.08),
                                    .init(color: theme.accent.color.opacity(0.07), location: 0.55),
                                    .init(color: theme.accent.color.opacity(0.28), location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                }
                .shadow(color: theme.shadow.color.opacity(0.35), radius: 5, y: 2)
        }
    }

    private func fadeTop(_ end: Double) -> some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .black, location: end)],
            startPoint: .top, endPoint: .bottom)
    }
}

// Top row: left wing holds the wordmark and board dots, right wing holds settings, pin, quit.
struct NotchWingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Sill")
                    .font(TileFont.row.weight(.bold))
                    .kerning(0.4)
                    .foregroundStyle(theme.textPrimary.color)
                BoardDotsView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Room for the notch. On a screen without a notch (external display,
            // Mac mini) its width is zero — the wings simply spread to the edges
            Color.clear.frame(width: appState.notchWidth > 0 ? appState.notchWidth + 24 : 0)

            HStack(spacing: 2) {
                if appState.isEditing {
                    if appState.canUndo {
                        wingButton(
                            icon: "arrow.uturn.backward", active: false,
                            help: String(localized: "Undo (⌘Z)")
                        ) {
                            appState.undo()
                        }
                    }
                    Button("Done") { appState.toggleEditing(false) }
                        .buttonStyle(.plain)
                        .font(TileFont.row.weight(.medium))
                        .foregroundStyle(theme.accent.color)
                } else if appState.activeBoard?.kind != .clipboard {
                    // Nothing to edit on the clipboard board — the pencil would
                    // only get in the way there
                    wingButton(icon: "pencil", active: false, help: String(localized: "Edit board")) {
                        appState.toggleEditing(true)
                    }
                }
                wingButton(icon: "gearshape", active: false, help: String(localized: "Settings (⌘,)")) {
                    SettingsWindowController.shared.show()
                }
                wingButton(
                    icon: appState.pinned ? "pin.fill" : "pin",
                    active: appState.pinned,
                    help: String(localized: "Pin: keep panel open when clicking outside")
                ) {
                    appState.pinned.toggle()
                }
                // Quit lives in Settings (and ⌘Q): a power button an inch from
                // the pin got hit by accident and killed the whole app
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func wingButton(
        icon: String, active: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        WingButton(icon: icon, active: active, help: help, action: action)
    }
}

// Wing icon: drawn at 13, hit at 26. The hit zone matching the icon size would
// require aiming; the hover highlight shows where that zone is.
/// Shell icon button: panel wings and the floating clipboard bar. One view for
/// both — the hover highlight must look the same everywhere
struct WingButton: View {
    let icon: String
    var active = false
    let help: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TileFont.row)  // 13 — system icon size in the row
                .foregroundStyle(color)
                .frame(width: WingMetrics.hit, height: WingMetrics.hit)
                .background(
                    RoundedRectangle(cornerRadius: WingMetrics.hitRadius, style: .continuous)
                        .fill(hovered ? theme.tileHover.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .help(help)
    }

    private var color: Color {
        if active { return theme.accent.color }
        return hovered ? theme.textPrimary.color : theme.textMuted.color
    }
}

// Row of board dots. Edit gestures live here rather than in the dot itself: for
// neighbors to make way under a dragged dot, the row needs to know about the
// whole gesture. Config is written once on release — writing and undoing it on
// every drag step jerked the whole row
private struct BoardDotsView: View {
    @Environment(AppState.self) private var appState

    @State private var draggingID: UUID?
    @State private var dragX: CGFloat = 0
    @State private var startIndex = 0
    @State private var proposedIndex = 0

    /// Spacing between dot centers. At rest the hit zones overlap (dots sit tight,
    /// like a page indicator); in edit mode dots spread out to full 22-pt zones —
    /// that's what right-click and drag aim at, and overlap gave "wrong dot" clicks
    private var step: CGFloat {
        appState.isEditing ? WingMetrics.dotHit : WingMetrics.dotStep
    }

    var body: some View {
        HStack(spacing: appState.isEditing ? 0 : -5) {
            ForEach(appState.config.boards) { board in
                BoardDot(board: board, dragging: draggingID == board.id)
                    .offset(x: offsetX(for: board))
                    .zIndex(draggingID == board.id ? 1 : 0)
                    .animation(.easeOut(duration: Motion.editing), value: proposedIndex)
                    .gesture(appState.isEditing ? reorderGesture(board) : nil)
            }
            // The plus button only appears in edit mode, same as the tile
            // remove buttons: boards get added once you're already rearranging widgets
            if appState.isEditing {
                BoardAddButton()
            }
        }
        .animation(.easeOut(duration: Motion.editing), value: appState.isEditing)
    }

    private func offsetX(for board: Board) -> CGFloat {
        guard let draggingID else { return 0 }
        if board.id == draggingID { return dragX }
        // Neighbors make way for the proposed slot
        guard let index = appState.config.boards.firstIndex(where: { $0.id == board.id })
        else { return 0 }
        if startIndex < proposedIndex, index > startIndex, index <= proposedIndex {
            return -step
        }
        if startIndex > proposedIndex, index >= proposedIndex, index < startIndex {
            return step
        }
        return 0
    }

    private func reorderGesture(_ board: Board) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if draggingID != board.id {
                    draggingID = board.id
                    startIndex = appState.config.boards.firstIndex { $0.id == board.id } ?? 0
                    proposedIndex = startIndex
                }
                dragX = value.translation.width
                let shift = Int((dragX / step).rounded())
                proposedIndex = min(
                    max(startIndex + shift, 0), appState.config.boards.count - 1)
            }
            .onEnded { _ in
                let target = proposedIndex
                // Offsets are cleared instantly, at the same moment the change
                // applies — same as tiles
                draggingID = nil
                dragX = 0
                if target != startIndex {
                    appState.moveBoard(board.id, to: target)
                }
            }
    }
}

// Board dot: 7 pt itself (9 in edit mode, where it's a target), 22-pt hit zone.
// Dots don't jiggle: horizontal shake on a small circle reads as a glitch, not an
// invitation, and a wandering target would get in the way of right-clicking
private struct BoardDot: View {
    let board: Board
    var dragging = false

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var hovered = false

    private var isActive: Bool { board.id == appState.config.activeBoardID }

    var body: some View {
        Circle()
            .fill(fill)
            .frame(
                width: appState.isEditing ? 9 : 7,
                height: appState.isEditing ? 9 : 7)
            .scaleEffect(dragging ? 1.4 : 1)
            .frame(width: WingMetrics.dotHit, height: WingMetrics.dotHit)
            // The dot's hit zone is 22 — the highlight shows where to aim
            .background(Circle().fill(hovered ? theme.tileHover.color : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: Motion.hover), value: dragging)
            // In edit mode the dot bobs gently up and down — slow and by a
            // single pixel: at tile-jiggle speed a small circle reads as shaking
            .modifier(DotBob(active: appState.isEditing && !dragging))
            // A tap switches boards even in edit mode; removal is a right-click
            .onTapGesture { appState.selectBoardAnimated(board.id) }
            // Long press opens the same menu natively: menu bar managers
            // (Bartender, Thaw) grab right-clicks in the menu bar strip with a
            // global tap, above our panel — the wings sit exactly there, and
            // .contextMenu never gets the click on such setups
            .onLongPressGesture(minimumDuration: 0.45) { showMenu() }
            .help(board.name)
        .contextMenu {
            Button("Move Left") { appState.moveBoard(board.id, by: -1) }
                .disabled(appState.config.boards.first?.id == board.id)
            Button("Move Right") { appState.moveBoard(board.id, by: 1) }
                .disabled(appState.config.boards.last?.id == board.id)
            if board.kind == .tiles {
                Button("Rename…") { rename() }
            }
            Divider()
            Button("Delete Board", role: .destructive) {
                appState.removeBoard(board.id)
            }
            .disabled(appState.config.boards.count < 2)
        }
    }

    private func showMenu() {
        let boards = appState.config.boards
        var entries: [BoardDotMenu.Entry?] = [
            .init(title: String(localized: "Move Left"), enabled: boards.first?.id != board.id) {
                appState.moveBoard(board.id, by: -1)
            },
            .init(title: String(localized: "Move Right"), enabled: boards.last?.id != board.id) {
                appState.moveBoard(board.id, by: 1)
            },
        ]
        if board.kind == .tiles {
            entries.append(.init(title: String(localized: "Rename…"), enabled: true) { rename() })
        }
        entries.append(nil)
        entries.append(
            .init(title: String(localized: "Delete Board"), enabled: boards.count > 1) {
                appState.removeBoard(board.id)
            })
        BoardDotMenu().show(entries)
    }

    // Renaming uses a system input dialog: a field of its own wouldn't fit in
    // the wing, and opening Settings for a single line would be overkill
    private func rename() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Board Name")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = board.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            appState.renameBoard(board.id, to: field.stringValue)
        }
    }

    private var fill: Color {
        if isActive { return theme.accent.color }
        return hovered ? theme.textPrimary.color : theme.textMuted.color.opacity(0.5)
    }
}

// Native menu for a board dot, same items as its .contextMenu. Shown on long
// press because right-clicks over the menu bar strip belong to whoever grabbed
// them globally (Bartender, Thaw) — see BoardDot.showMenu
@MainActor
private final class BoardDotMenu: NSObject {
    struct Entry {
        let title: String
        let enabled: Bool
        let action: () -> Void

        init(title: String, enabled: Bool, action: @escaping () -> Void) {
            self.title = title
            self.enabled = enabled
            self.action = action
        }
    }

    private var actions: [Int: () -> Void] = [:]
    private var strongSelf: BoardDotMenu?

    /// nil entry = separator
    func show(_ entries: [Entry?]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in entries.enumerated() {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = entry.enabled
            actions[index] = entry.action
            menu.addItem(item)
        }
        strongSelf = self  // the menu keeps us alive while open
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        strongSelf = nil
    }

    @objc private func run(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }
}

// Dot bob in edit mode. Started and stopped only via explicit withAnimation:
// a declarative repeatForever doesn't die when state resets in a no-animation transaction
private struct DotBob: ViewModifier {
    let active: Bool
    @State private var shift: CGFloat = 0
    @State private var phase = Double.random(in: 0...Motion.dotBob)

    func body(content: Content) -> some View {
        content
            .offset(y: shift)
            .onChange(of: active, initial: true) { _, on in
                if on {
                    shift = -WingMetrics.dotBob
                    withAnimation(
                        .easeInOut(duration: Motion.dotBob).repeatForever(autoreverses: true)
                            .delay(phase)
                    ) {
                        shift = WingMetrics.dotBob
                    }
                } else {
                    withAnimation(.easeOut(duration: Motion.editing)) { shift = 0 }
                }
            }
    }
}

private struct BoardAddButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button { appState.addBoard() } label: {
            Image(systemName: "plus")
                .font(TileIcon.caption)
                .foregroundStyle(hovered ? theme.textPrimary.color : theme.textMuted.color)
                .frame(width: WingMetrics.dotHit, height: WingMetrics.dotHit)
                // Hit zone is twice the icon size — without the highlight it's
                // unclear where to aim (docs/standards.md, "hit zones")
                .background(
                    RoundedRectangle(cornerRadius: TileMetrics.hitRadius, style: .continuous)
                        .fill(hovered ? theme.tileHover.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .help("Add a board")
    }
}

// Hit zones in the wings — docs/standards.md, "hit zones" section
enum WingMetrics {
    static let hit: CGFloat = 26
    static let hitRadius: CGFloat = 7
    static let dotHit: CGFloat = 22
    /// Spacing between dot centers at rest: a 22-pt zone at -5 spacing.
    /// In edit mode the step equals dotHit — zones don't overlap, right-click lands
    static let dotStep: CGFloat = 17
    /// Bob amplitude for a dot in edit mode, pt
    static let dotBob: CGFloat = 1
}
