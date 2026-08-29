import SwiftUI
import Translation

// Square — just the result and the "from clipboard" button: an input field
// doesn't fit in 152 points, and shrinking it instead of dropping it isn't an option.
// Rectangle — input and translation. Large — plus history and all actions.
struct TranslateTileView: View {
    let widget: TranslateWidget
    let size: TileSize

    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(short: size == .small)
            switch size {
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
        // SwiftUI hands out the translation session: the system translator has
        // no standalone object, it lives alongside the view
        .translationTask(widget.configuration) { session in
            await widget.run(TranslationBox(session: session))
        }
        .task { await widget.loadLanguages() }
    }

    // MARK: - header: languages and swap

    private func header(short: Bool) -> some View {
        HStack(spacing: 6) {
            LanguageButton(
                title: short ? widget.sourceShort : widget.sourceTitle,
                languages: widget.languages
            ) {
                widget.setSource($0)
            }
            Button(action: widget.swap) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(TileIcon.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tileControl()
            .help("Swap languages")
            LanguageButton(
                title: short ? widget.targetShort : widget.targetTitle,
                languages: widget.languages
            ) {
                widget.setTarget($0)
            }
            Spacer(minLength: 0)
            if widget.isTranslating {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
    }

    // MARK: - square: translation and "from clipboard"

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Typing works in the square too: without a field it could only show
            // the translation of whatever was on the clipboard, and typing did nothing
            // A divider splits the tile in half: your language on top, the other below.
            // Both halves are stretchy, so the divider sits exactly in the middle
            field
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, TileMetrics.blockGap)
            Divider()
                .overlay(theme.border.color.opacity(0.4))
                .padding(.vertical, 6)
            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // In the square, buttons are icon-only — with labels they don't fit.
            // Clearing lives in the field itself, next to the text it clears
            HStack(spacing: 10) {
                if widget.packMissing {
                    ActionButton(icon: "arrow.down.circle", title: nil) { widget.downloadPack() }
                }
                Spacer(minLength: 0)
                if !widget.output.isEmpty {
                    ActionButton(icon: "doc.on.doc", title: nil) { widget.copyResult() }
                }
            }
        }
    }

    // MARK: - rectangle: input and translation

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, TileMetrics.blockGap)
            Divider()
                .overlay(theme.border.color.opacity(0.4))
                .padding(.vertical, 7)
            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            actions
        }
    }

    // MARK: - large: plus history

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, TileMetrics.blockGap)
            Divider()
                .overlay(theme.border.color.opacity(0.4))
                .padding(.vertical, 8)
            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            actions
        }
    }

    // MARK: - parts

    /// Input field — one component for the whole app (see TileTextField): the hint
    /// sits under the field, and the caret lands exactly on it
    private var field: some View {
        TileTextField(
            text: Binding(get: { widget.input }, set: { widget.input = $0 }),
            placeholder: String(localized: "Text to translate"),
            lines: 1...(size == .small ? 3 : 4),
            focus: $focused,
            onClear: widget.isEmpty ? nil : { widget.clear() },
            // Return doesn't wait out the debounce — the model path is slow enough
            onSubmit: { widget.translateNow() }
        )
        .onChange(of: widget.input) { _, _ in widget.retranslate() }
        .tileControl()
    }

    @ViewBuilder
    private var result: some View {
        if let failure = widget.failure {
            Text(failure)
                .font(TileFont.row)
                .foregroundStyle(theme.warning.color)
                .lineLimit(2)
        } else if widget.output.isEmpty {
            Text(widget.isEmpty ? "Translation appears here" : "…")
                .font(TileFont.row)
                .foregroundStyle(theme.textMuted.color)
        } else {
            Text(widget.output)
                .font(TileFont.row)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(size == .large ? 4 : 2)
                .textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            // Download the missing pack — the only way out of "no RU → EN pack".
            // The system window is shown by our own press, never on its own
            if widget.packMissing {
                ActionButton(icon: "arrow.down.circle", title: String(localized: "Download language")) {
                    widget.downloadPack()
                }
            }
            Spacer(minLength: 0)
            if !widget.output.isEmpty {
                ActionButton(icon: "doc.on.doc", title: String(localized: "Copy")) { widget.copyResult() }
            }
        }
    }
}

// Language picker: the list comes from the system, so it won't go stale with a new macOS
private struct LanguageButton: View {
    let title: String
    let languages: [String]
    let action: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(languages, id: \.self) { code in
                Button(TranslateWidget.title(of: code)) { action(code) }
            }
        } label: {
            Text(title)
                .font(TileFont.label)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tileControl()
    }
}


private struct ActionButton: View {
    let icon: String
    let title: String?
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(TileIcon.caption)
                if let title {
                    Text(title)
                        .font(TileFont.caption.weight(.medium))
                }
            }
            .foregroundStyle(hovered ? theme.accent.color : theme.textMuted.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: TileMetrics.hitRadius, style: .continuous)
                    .fill(hovered ? theme.tileHover.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tileControl()
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Motion.hover), value: hovered)
    }
}
