import SwiftUI

// The "Ask" bar sits at the bottom of the panel on every board and never moves.
// Tap it, type — the board stays put, nothing jumps. Press Enter — the tiles slide
// up and the conversation unfolds above the bar. The bar itself stays where it is:
// that's what makes the transition read as a continuation, not a new screen.
// The conversation unfolds out of the input bar: it starts collapsed into the
// bar's height and expands upward, rather than sliding in whole from below.
// Scaling is vertical only — the content must not stretch horizontally.
private struct Unfold: ViewModifier {
    /// 0 — collapsed into the bar, 1 — expanded
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: 0.82 + 0.18 * progress, anchor: .bottom)
            .opacity(progress)
    }
}

// Tiles sink into that same bar: they shrink slightly and slide down toward it
private struct SinkIntoBar: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.94 + 0.06 * progress, anchor: .bottom)
            .offset(y: (1 - progress) * 18)
            .opacity(progress)
    }
}

extension AnyTransition {
    /// Unfolding out of the "Ask" bar
    static var unfoldFromBar: AnyTransition {
        .modifier(active: Unfold(progress: 0), identity: Unfold(progress: 1))
    }

    /// Board sinking into the same bar
    static var sinkIntoBar: AnyTransition {
        .modifier(active: SinkIntoBar(progress: 0), identity: SinkIntoBar(progress: 1))
    }
}

struct AskBarView: View {
    /// True for the live bar on the active board; false for the drawn copy shown
    /// on the neighbor board while swiping. Both roles share one view — a separate
    /// view per role would rebuild on every swipe, and without a key the live bar
    /// would show "Add a key" while the neighbor showed "Ask", flashing on each swipe
    var live = true

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var session = AskSession.shared
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var askShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(TileIcon.glyph)
                .foregroundStyle(session.isAsking ? theme.textMuted.color : theme.accent.color)
                .symbolEffect(.pulse, isActive: session.isAsking)
                .frame(width: 16)

            // The field has no placeholder of its own: it's drawn underneath in the
            // same font and color as the real text, so the label and cursor sit on
            // the same baseline
            ZStack(alignment: .leading) {
                if session.draft.isEmpty {
                    Text(placeholder)
                        .font(TileFont.row)
                        .foregroundStyle(theme.textMuted.color)
                        .allowsHitTesting(false)
                }
                // The live field exists only on the active board: on the neighbor
                // it would rebuild every frame of the gesture, with no visible
                // difference on screen
                if live {
                    TextField("", text: Binding(
                        get: { session.draft }, set: { session.draft = $0 }))
                        .textFieldStyle(.plain)
                        .font(TileFont.row)
                        .foregroundStyle(theme.textPrimary.color)
                        .focused($focused)
                        .releasesFocusOnHide($focused)
                        .onSubmit(send)
                }
            }
            // The bar's own frame holds the width, not its content. `Spacer` inside
            // a `ZStack` doesn't expand — it's only flexible inside a stack — so the
            // neighbor's bar used to shrink to the width of its label (113 pt instead
            // of 644 pt), showing as a stub instead of a full bar during the swipe
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, TileMetrics.padding)
        .frame(height: GridMetrics.askBar)
        // Same surface as the tiles, same style from Appearance settings. Clipping
        // to the shape is required — without it the background shape leaks through
        // while swiping the strip
        .background {
            Surface.fill(
                style: appState.appearance.tile, hovered: focused || hovered,
                shape: askShape, theme: theme)
        }
        .clipShape(askShape)
        .overlay {
            if focused {
                askShape.strokeBorder(theme.accent.color.opacity(0.5), lineWidth: 0.5)
            } else {
                Surface.edge(
                    style: appState.appearance.tile, hovered: hovered,
                    shape: askShape, theme: theme)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: Motion.hover), value: focused)
        .allowsHitTesting(live)
    }

    @ViewBuilder
    private var trailing: some View {
        if session.isAsking {
            Button { session.cancel() } label: {
                Image(systemName: "stop.circle")
                    .font(TileIcon.glyph)
                    .foregroundStyle(theme.textMuted.color)
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else if !session.draft.isEmpty {
            Text("⏎")
                .font(TileFont.caption)
                .foregroundStyle(theme.textMuted.color)
        } else if appState.askOpen, !session.isEmpty {
            Button { session.newChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(TileIcon.glyph)
                    .foregroundStyle(theme.textMuted.color)
            }
            .buttonStyle(.plain)
            .help("New chat")
        }
    }

    private var placeholder: String {
        if session.needsKey { return String(localized: "Add a key — Settings, Model section") }
        return appState.askOpen ? String(localized: "Ask something else") : String(localized: "Ask")
    }

    private func send() {
        let question = session.draft
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.draft = ""
        // The conversation only unfolds on Enter: while someone is still typing,
        // the board stays put — no need to shift tiles on every keystroke
        withAnimation(.easeOut(duration: Motion.askOpen)) { appState.askOpen = true }
        session.ask(question)
    }
}

// The conversation above the bar: questions on the right, answers full width.
struct AskChatView: View {
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var session = AskSession.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
        }
        .frame(
            width: GridMetrics.contentWidth,
            height: GridMetrics.contentHeight,
            alignment: .top)
        .padding(.horizontal, GridMetrics.padding)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(AppSettings.shared.llmModel)
                .font(TileFont.caption)
                .foregroundStyle(theme.textMuted.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(TileIcon.badge)
                    .foregroundStyle(theme.textMuted.color)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to board (Esc)")
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { message in
                        bubble(message)
                            .id(message.id)
                            // A message arrives from below rather than popping in on
                            // a frame: it comes from where it was typed
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let failure = session.failure {
                        Text(failure)
                            .font(TileFont.caption)
                            .foregroundStyle(theme.warning.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.bottom, 4)
                .animation(.easeOut(duration: Motion.content), value: session.messages.count)
            }
            .scrollIndicators(.never)
            .onChange(of: session.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    // The question is a highlighted block on the right, the answer is plain text
    // on the left: it's clear who's speaking without avatars or borders
    @ViewBuilder
    private func bubble(_ message: AskSession.Message) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Group {
                if message.text.isEmpty {
                    Thinking()
                } else {
                    Text(message.text)
                        .font(TileFont.row)
                        .foregroundStyle(
                            message.role == .user
                                ? theme.textPrimary.color : theme.textSecondary.color)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, message.role == .user ? 11 : 0)
            .padding(.vertical, message.role == .user ? 8 : 0)
            .background {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                        .fill(theme.tileBackground.color)
                }
            }
            if message.role == .model { Spacer(minLength: 60) }
        }
    }
}

// Waiting for a reply: the icon breathes gently, growing and shrinking. Every
// chat with a model shows something like this, and it's the only honest
// animation — there's no completion percentage for a reply, a progress bar
// would be a lie. The app's logo will go here once it exists.
private struct Thinking: View {
    @Environment(\.theme) private var theme

    var body: some View {
        // Twelve frames a second: plenty for a slow breathing motion — thirty
        // rebuilt the subtree twice as often with no visible difference
        TimelineView(.periodic(from: .now, by: 1.0 / 12)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // One cycle is a second and a half: slower reads as asleep,
            // faster reads as fidgety
            let wave = (sin(time * 4.2) + 1) / 2

            Image(systemName: "sparkles")
                .font(TileIcon.hero)
                .foregroundStyle(theme.accent.color.opacity(0.55 + 0.45 * wave))
                .scaleEffect(0.86 + 0.14 * wave)
                .frame(height: 26, alignment: .leading)
        }
    }
}
