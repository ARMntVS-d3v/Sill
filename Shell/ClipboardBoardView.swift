import AppKit
import SwiftUI

// Clipboard fills the whole board: search on top, list below. This is built
// around search, not a showcase — a single tile doesn't fit that job.
struct ClipboardBoardView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    var interactive = true

    @State private var store = ClipboardStore.shared
    @State private var settings = AppSettings.shared
    // Selection and search live in an object, not @State: the key monitor is a
    // closure that captures a copy of the view. Writes through the @State wrapper
    // landed fine, but reads returned the value from when the monitor was
    // installed — arrow keys "stopped working", Esc closed the panel instead of
    // clearing search, and Enter pasted the wrong entry
    @State private var selection = Selection()
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !settings.clipboardEnabled {
                disabled
            } else {
                // The neighbor in the strip renders exactly what the active board
                // does: swapping a cheap placeholder for the real list at the end
                // of the gesture would read as the clipboard "loading". Only the
                // input field and handlers are inert there — `interactive` controls
                // that
                if items.isEmpty {
                    TilePlaceholder(
                        selection.query.isEmpty
                            ? String(localized: "Clipboard is empty") : String(localized: "Nothing found"),
                        icon: "doc.on.clipboard")
                } else if settings.clipboardCards {
                    ClipboardCardsView(
                        items: items,
                        selected: selection.id,
                        follow: selection.byKeyboard,
                        onSelect: { selection.select($0.id) },
                        onCopy: copy,
                        onPin: { store.togglePin($0) },
                        onRemove: { store.remove($0) })
                } else {
                    list
                }
            }
        }
        .allowsHitTesting(interactive)
        .frame(
            width: GridMetrics.contentWidth,
            // No "Ask" bar here — the list gets its space instead. The height is
            // the same as a tile board plus its bar though: boards in the strip
            // must all be the same height
            height: GridMetrics.contentHeight + GridMetrics.askBarHeight,
            alignment: .topLeading)
        .padding(.horizontal, GridMetrics.padding)
        .padding(.top, GridMetrics.topGap)
        // Same math as a regular board: the "Ask" bar's space is already accounted
        // for in the height above, so no second bottom padding is needed
        .padding(.bottom, GridMetrics.askBarHeight > 0 ? 0 : GridMetrics.bottomPadding)
        // Search and the view switcher sit bottom-trailing over the content. As a
        // top bar they'd claim a whole strip just for two icons
        .overlay(alignment: .bottomTrailing) {
            if settings.clipboardEnabled {
                // The neighbor in the strip gets the same capsule, drawn but
                // inert: without it, it would appear only after the gesture
                // settled and read as the clipboard "slowly loading"
                controls(live: interactive)
                    .padding(.trailing, GridMetrics.padding)
            }
        }
        // View identity must stay the same across roles (no per-role .id):
        // swapping identity tears down and rebuilds the ScrollView, the search
        // field, and the key monitor on the very frame the board swaps in. Keys
        // and focus are instead re-armed on role change below
        .onChange(of: interactive) { _, active in
            guard active else {
                stopKeys()
                return
            }
            selection.id = items.first?.id
            searchFocused = true
            startKeys()
        }
        // Opening the board — cursor goes straight into search: that's what
        // brings people here
        .onAppear {
            guard interactive else { return }
            searchFocused = true
            selection.id = items.first?.id
            startKeys()
        }
        // Reopening the panel — selection resets to the top of the list, not
        // wherever it was left
        .onChange(of: appState.isPanelVisible) { _, visible in
            guard interactive else { return }
            // Panel gone — keys are no longer ours. The view isn't removed from
            // the hierarchy when this happens (the window just hides), so
            // onDisappear doesn't help: Enter used to paste an entry into
            // whatever app was underneath, and Cmd-C hijacked the system clipboard
            guard visible else {
                stopKeys()
                return
            }
            startKeys()
            selection.query = ""
            selection.searchOpened = false
            selection.id = items.first?.id
            searchFocused = true
        }
        .onDisappear(perform: stopKeys)
    }

    private var items: [ClipboardStore.Item] {
        let sorted = store.ordered
        let text = selection.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return sorted }
        return sorted.filter { ($0.text ?? "Image").lowercased().contains(text) }
    }

    /// Search takes no space until needed: two icons sit in the corner, and the
    /// field expands to the left as soon as typing starts. The field itself
    /// always exists and is always focused — just invisible, like in Paste
    private var searching: Bool { selection.searching }

    /// One capsule in two roles: live on the active board, drawn for the
    /// neighbor in the strip. Both need the same input field (even when inert),
    /// or the missing gap shifts the capsule's width (90 pt vs 94 pt) and it
    /// visibly jumps on the frame the board swaps in
    private func controls(live: Bool) -> some View {
        // Same icons as the panel wings, with the same hover highlight. No gap
        // between them: each has its own 26×26 box, and a nonzero gap around the
        // collapsed field between them added two extra gaps, leaving more space
        // to the left of the list icon than to the right
        HStack(spacing: 0) {
            WingButton(icon: "magnifyingglass", active: live && searching, help: String(localized: "Search")) {
                selection.searchOpened.toggle()
                searchFocused = selection.searchOpened
            }

            // The field always exists: collapsed, it's zero width, just to catch
            // typing. The inert copy has empty space of the same zero width in
            // its place — without it the gaps don't line up
            if live {
                TextField("", text: $selection.query)
                    .textFieldStyle(.plain)
                    .font(TileFont.row)
                    .foregroundStyle(theme.textPrimary.color)
                    .focused($searchFocused)
                    .releasesFocusOnHide($searchFocused)
                    .frame(width: searching ? 190 : 0)
                    .opacity(searching ? 1 : 0)
            } else {
                // Strictly zero size on both axes. An unconstrained `Color`
                // stretches to fill all available space, and the neighbor's
                // capsule used to become a black pill spanning the whole board
                Color.clear.frame(width: 0, height: 0)
            }

            if live && searching {
                WingButton(icon: "xmark", help: String(localized: "Clear search")) {
                    selection.query = ""
                    selection.searchOpened = false
                }
            } else {
                WingButton(
                    icon: settings.clipboardCards ? "list.bullet" : "square.grid.2x2",
                    help: settings.clipboardCards
                        ? String(localized: "Show as list") : String(localized: "Show as cards")
                ) {
                    // No animation: this swaps one hierarchy (grid) for another
                    // (list) — there's nothing to animate, SwiftUI just builds
                    // both and moves them "from nowhere"
                    settings.clipboardCards.toggle()
                }

                // The counter sits in the same box size as the icons — otherwise
                // it hangs at its own height and the row looks uneven
                Text("\(store.items.count)")
                    .font(TileFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
                    .frame(height: WingMetrics.hit)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .background {
            // A rounded square, not a pill: the tile radius at this height gives
            // exactly a pill shape. The backing is glass — the bar sits over the list
            let shape = RoundedRectangle(cornerRadius: TileMetrics.floatRadius, style: .continuous)
            GlassBackground(shape: shape, theme: theme)
                .shadow(color: theme.shadow.color.opacity(0.35), radius: 5, y: 2)
        }
        .animation(.easeOut(duration: Motion.hover), value: searching)
        .allowsHitTesting(live)
    }

    /// Row list: single column, scrolling catches up to the selection only when
    /// it's being driven by the keyboard
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        ClipboardEntryRow(
                            item: item,
                            selected: selection.id == item.id,
                            onSelect: { selection.select(item.id) },
                            onCopy: { copy(item) },
                            onPin: { store.togglePin(item) },
                            onRemove: { store.remove(item) })
                            .id(item.id)
                        if item.id != items.last?.id {
                            Divider()
                                .overlay(theme.border.color.opacity(0.4))
                                .padding(.leading, 46)
                        }
                    }
                }
            }
            // Arrow keys drive the list: the row moves into view, but without
            // animation. An animated scrollTo on every step used to lag behind
            // the previous one and stutter
            .onChange(of: selection.id) { _, new in
                guard let new, selection.byKeyboard else { return }
                // No anchor set: the list scrolls just enough to bring the row
                // into view, not to center it on screen
                proxy.scrollTo(new)
            }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .fill(theme.tileBackground.color.opacity(0.55)))
    }

    private var disabled: some View {
        VStack(spacing: 9) {
            Image(systemName: "doc.on.clipboard")
                .font(TileIcon.hero)
                .foregroundStyle(theme.textMuted.color.opacity(0.75))
            Text("Clipboard history is off")
                .font(TileFont.title)
                .foregroundStyle(theme.textMuted.color)
            Text("Nothing is recorded while it's off")
                .font(TileFont.caption)
                .foregroundStyle(theme.textMuted.color.opacity(0.8))
            Button("Turn On") { settings.clipboardEnabled = true }
                .buttonStyle(.plain)
                .font(TileFont.row.weight(.medium))
                .foregroundStyle(theme.accent.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // Keyboard: arrows drive the list, Cmd-C copies to the clipboard, Enter
    // pastes directly at the cursor. Caught with a local monitor rather than
    // .onKeyPress: focus sits in the search field at this point, and arrow keys
    // need to be intercepted before it gets them
    private func startKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let command = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 125: move(1); return nil                       // down
            case 126: move(-1); return nil                      // up
            case 124: moveSideways(1); return nil               // right
            case 123: moveSideways(-1); return nil              // left
            // Enter — paste at the cursor position: that's the main action, what
            // brings people here in the first place. Cmd-C — just copy and leave
            // Esc: clear search first, an empty search closes the panel on Esc
            case 53 where selection.searching:
                selection.query = ""
                selection.searchOpened = false
                return nil
            case 36: pasteSelected(); return nil                // Enter — paste
            case 8 where command: copySelected(); return nil    // Cmd-C — copy and close
            default: return event
            }
        }
    }

    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func move(_ delta: Int) {
        let list = items
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection.id } ?? 0
        // In card view, down moves a full row: there are two per row
        let step = settings.clipboardCards ? delta * 2 : delta
        // No wrapping past the edge — the cursor stays put. Clamping to bounds
        // instead used to send "down" on the last row sideways into the
        // neighboring column: a vertical arrow moving horizontally
        guard list.indices.contains(current + step) else {
            // Except a partial last row: with an odd count, "down" from the
            // right column used to be unable to reach the lone last card
            if settings.clipboardCards, delta > 0, current / 2 < (list.count - 1) / 2 {
                selection.select(list[list.count - 1].id, byKeyboard: true)
            }
            return
        }
        selection.select(list[current + step].id, byKeyboard: true)
    }

    /// Left/right are only needed for cards — the list is a single column
    private func moveSideways(_ delta: Int) {
        guard settings.clipboardCards else { return }
        let list = items
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection.id } ?? 0
        let next = min(max(current + delta, 0), list.count - 1)
        selection.select(list[next].id, byKeyboard: true)
    }

    private func selected() -> ClipboardStore.Item? {
        items.first { $0.id == selection.id } ?? items.first
    }

    private func copySelected() {
        guard let item = selected() else { return }
        copy(item)
    }

    private func pasteSelected() {
        guard let item = selected() else { return }
        // The panel hides first, and the app follows it: the paste needs to land
        // in whatever window was underneath, and while we're active, we hold focus
        appState.requestHide?()
        NSApp.hide(nil)
        if !store.pasteToFrontApp(item) {
            // No permission — the entry is at least on the clipboard, and the
            // system showed its own prompt
            ClipboardActivity.copied()
        }
    }

    /// Double-click and Cmd-C: restore to the clipboard, hide the panel, and show
    /// a confirmation near the notch — visible only after the app has minimized
    private func copy(_ item: ClipboardStore.Item) {
        // Couldn't restore the entry — don't close the panel or lie about "Copied"
        guard store.copy(item) else { return }
        selection.id = item.id
        ClipboardActivity.copied()
        appState.requestHide?()
        // The app follows the panel out, same as on paste-by-Enter: while we're
        // active we hold focus, and the next Cmd-V lands in our window instead of
        // the one the entry was meant for
        NSApp.hide(nil)
    }
}

// History row: thumbnail or type icon on the left, text next, time and hover
// buttons on the right
private struct ClipboardEntryRow: View {
    let item: ClipboardStore.Item
    var selected = false
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onRemove: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(ClipboardStore.preview(item))
                    .font(TileFont.row)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Text(meta)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Buttons always reserve their space — appearing only on hover would
            // compress the text and re-truncate the line right under the cursor.
            // The same rule already applies in the shelf and in settings
            ZStack(alignment: .trailing) {
                if item.pinned, !hovered {
                    Image(systemName: "pin.fill")
                        .font(TileIcon.badge)
                        .foregroundStyle(theme.accent.color)
                }
                HStack(spacing: 0) {
                    RowIcon(icon: item.pinned ? "pin.slash" : "pin", action: onPin)
                    RowIcon(icon: "xmark", action: onRemove)
                }
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
            .frame(width: 40, alignment: .trailing)
            .animation(.easeOut(duration: Motion.hover), value: hovered)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onCopy)
        // Selection happens on button release, not on a single tap: SwiftUI
        // holds a single tap for a quarter second to check for a second one,
        // and the selection border used to appear with a visible delay
        .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in onSelect() })
        .help("Double-click to restore to clipboard")
    }

    private var background: Color {
        if selected { return theme.accent.color.opacity(0.22) }
        return hovered ? theme.tileHover.color.opacity(0.5) : .clear
    }

    // The entry's preview, with the source app's icon in the corner. Same as
    // Paste: origin is visible before you even read the label
    @ViewBuilder
    private var icon: some View {
        if let image = ClipboardStore.shared.image(for: item) {
            // For an image, the preview is the image itself. An app icon on top
            // of it would be redundant — it's already obviously an image
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: TileMetrics.thumbRadius, style: .continuous))
        } else if let icon = ClipboardStore.sourceIcon(item.sourceID) {
            // For text there's nothing to preview, so the app icon fills the
            // whole square: it shows at a glance where the entry came from
            Image(nsImage: icon)
                .resizable()
                .frame(width: 30, height: 30)
        } else {
            RoundedRectangle(cornerRadius: TileMetrics.thumbRadius, style: .continuous)
                .fill(theme.tileHover.color)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: item.kindIcon)
                        .font(TileIcon.glyph)
                        .foregroundStyle(theme.textMuted.color)
                }
        }
    }

    private var meta: String {
        let time = item.date.formatted(
            Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        guard let source = item.source else { return time }
        return "\(source) · \(time)"
    }
}

private struct RowIcon: View {
    let icon: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TileIcon.badge)
                .foregroundStyle(hovered ? theme.textPrimary.color : theme.textMuted.color)
                // Icon 9, hit target 20 — docs/standards.md, "hit zones"
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// The currently selected row. A separate object because it's read from the
// key monitor's closure
@MainActor @Observable
private final class Selection {
    var id: UUID?
    /// Search text and whether it's expanded: both read by the key monitor
    var query = ""
    var searchOpened = false

    var searching: Bool { !query.isEmpty || searchOpened }
    /// Selected via keyboard — then the list scrolls to follow. A mouse click
    /// doesn't scroll: the person can already see where they clicked, and
    /// scrolling under the cursor would look presumptuous
    var byKeyboard = false

    func select(_ id: UUID?, byKeyboard: Bool = false) {
        self.byKeyboard = byKeyboard
        self.id = id
    }
}
