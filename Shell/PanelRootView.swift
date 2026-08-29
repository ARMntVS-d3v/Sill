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
                            .clipShape(BoardClipShape(overhang: TileChromeMetrics.topOverhang))
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
                // The wordmark keeps its width no matter how many boards there are.
                // Without this the dots pushed it out: at eight boards it wrapped to
                // two lines ("Si/ll"), past that it vanished altogether
                Text("Sill")
                    .font(TileFont.row.weight(.bold))
                    .kerning(0.4)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize()
                    .layoutPriority(1)
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
        .animation(.easeOut(duration: Motion.hover), value: hovered)
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
// every drag step jerked the whole row.
//
// The row never grows past the space it was given. It used to: at eight boards the
// wordmark wrapped, past a dozen the dots slid under the notch, where the click trap
// window sits above the panel and ate them — "not a single button works". Now the row
// behaves like the iOS page indicator: it holds a window of dots and the ones running
// off the edge shrink.
private struct BoardDotsView: View {
    @Environment(AppState.self) private var appState

    /// Spacing between dot centers: the zones overlap, dots sit tight like a page
    /// indicator. One step in every mode — renaming, reordering and deleting boards
    /// live in Settings, so there is nothing here to aim at but the dot itself
    private var step: CGFloat { WingMetrics.dotStep }

    /// Overlap between neighbouring hit zones: the row is `step * count` plus this
    private var overhang: CGFloat { WingMetrics.dotHit - step }

    var body: some View {
        // The row takes the width left over by the wordmark and lays out inside it.
        // GeometryReader is greedy, which is exactly right here: whatever the left
        // wing has is the row's budget
        GeometryReader { geometry in
            row(available: geometry.size.width)
                .frame(width: geometry.size.width, height: WingMetrics.dotHit, alignment: .leading)
        }
        .frame(height: WingMetrics.dotHit)
    }

    private func row(available: CGFloat) -> some View {
        let boards = appState.config.boards
        // The plus keeps its own slot: it is part of the row, not a bonus
        let plus = appState.isEditing ? WingMetrics.dotHit : 0
        let capacity = max(1, Int((available - plus - overhang) / step))
        let window = window(count: boards.count, capacity: capacity)
        return HStack(spacing: 0) {
            // The dots keep their tight page-indicator step; the plus stands apart
            HStack(spacing: -5) {
                ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                    if window.contains(index) {
                        BoardDot(
                            board: board,
                            diameter: diameter(at: index, window: window, count: boards.count))
                    }
                }
            }
            // Adding a board is the one board action left in the panel: it's how a
            // board gets made in the first place, right where the dots are.
            // Deleting is only in Settings — an action you can't undo by eye
            // shouldn't sit a pixel away from the one you use constantly
            if appState.isEditing {
                BoardAddButton()
            }
        }
        .animation(.easeOut(duration: Motion.editing), value: window)
        .animation(.easeOut(duration: Motion.editing), value: appState.isEditing)
    }

    /// Which dots are on screen. The window follows the active dot — it stays in
    /// the middle, so both directions are visible
    private func window(count: Int, capacity: Int) -> Range<Int> {
        guard count > capacity else { return 0..<count }
        let active = appState.config.boards.firstIndex { $0.id == appState.config.activeBoardID }
        let start = min(max((active ?? 0) - capacity / 2, 0), count - capacity)
        return start..<(start + capacity)
    }

    /// Edge dots shrink when there is more beyond them — the same two steps as the
    /// iOS page indicator. Below four visible dots there is nothing to hint with:
    /// shrinking half the row would just look broken
    private func diameter(at index: Int, window: Range<Int>, count: Int) -> CGFloat {
        let full = WingMetrics.dot
        guard window.count >= 4, window.count < count else { return full }
        if window.lowerBound > 0 {
            if index == window.lowerBound { return WingMetrics.dotFar }
            if index == window.lowerBound + 1 { return WingMetrics.dotNear }
        }
        if window.upperBound < count {
            if index == window.upperBound - 1 { return WingMetrics.dotFar }
            if index == window.upperBound - 2 { return WingMetrics.dotNear }
        }
        return full
    }

}

// Board dot: 7 pt itself, 22-pt hit zone. A dot only switches boards — adding,
// renaming, reordering and deleting live in Settings → Boards, where they're
// visible and where a menu bar manager can't swallow the right-click
private struct BoardDot: View {
    let board: Board
    /// Set by the row: full size, or shrunk if the dot is running off the edge
    var diameter: CGFloat = WingMetrics.dot

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var hovered = false

    private var isActive: Bool { board.id == appState.config.activeBoardID }

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: diameter, height: diameter)
            .animation(.easeOut(duration: Motion.editing), value: diameter)
            .frame(width: WingMetrics.dotHit, height: WingMetrics.dotHit)
            // The dot's hit zone is 22 — the highlight shows where to aim
            .background(Circle().fill(hovered ? theme.tileHover.color : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: Motion.hover), value: hovered)
            .onTapGesture { appState.selectBoardAnimated(board.id) }
            .help(board.name)
    }

    private var fill: Color {
        if isActive { return theme.accent.color }
        return hovered ? theme.textPrimary.color : theme.textMuted.color.opacity(0.5)
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
        .animation(.easeOut(duration: Motion.hover), value: hovered)
        .onHover { hovered = $0 }
        .help("Add a board")
    }
}

enum WingMetrics {
    static let hit: CGFloat = 26
    static let hitRadius: CGFloat = 7
    static let dotHit: CGFloat = 22
    /// Spacing between dot centers at rest: a 22-pt zone at -5 spacing.
    /// In edit mode the step equals dotHit — zones don't overlap, right-click lands
    static let dotStep: CGFloat = 17
    /// Dot diameter
    static let dot: CGFloat = 7
    /// When there are more boards than fit, the row keeps its width and the dots
    /// running off the edge shrink — the same page indicator as on iOS. Two steps:
    /// the next-to-last slot, then the last one
    static let dotNear: CGFloat = 5
    static let dotFar: CGFloat = 3
}
