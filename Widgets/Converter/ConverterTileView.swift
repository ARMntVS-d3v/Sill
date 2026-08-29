import SwiftUI

// Converter. Header with the pair and swap — same layout as the translator:
// two codes and an arrow between them. Small — pair, amount, and result large;
// medium — plus the unit rate; large — plus the same amount in the app's other
// currencies.
struct ConverterTileView: View {
    let widget: ConverterWidget
    let size: TileSize

    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if widget.snapshot == nil {
                VStack(spacing: TileMetrics.rowGap) {
                    TilePlaceholder(widget.failure ?? String(localized: "Loading…"), icon: "arrow.left.arrow.right")
                        .fixedSize(horizontal: false, vertical: true)
                    if widget.failure != nil {
                        Button("Retry") { widget.retry() }
                            .buttonStyle(.plain)
                            .tileControl()
                            .font(TileFont.caption.weight(.medium))
                            .foregroundStyle(theme.accent.color)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .animation(.easeOut(duration: Motion.content), value: widget.snapshot?.updated)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }

    // MARK: - Small: pair, amount, result

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: TileMetrics.captionGap)
            amountControl
            resultRow(compact: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium: plus the unit rate

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: TileMetrics.captionGap)
            amountControl
            resultRow(compact: false)
                .padding(.top, 2)
            Spacer(minLength: TileMetrics.captionGap)
            rateLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Large: plus the same amount in other currencies

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: TileMetrics.captionGap)
            amountControl
            resultRow(compact: false)
                .padding(.top, 2)
            rateLine
                .padding(.top, TileMetrics.captionGap)

            let others = widget.others(limit: 5)
            if !others.isEmpty {
                Rectangle()
                    .fill(theme.border.color)
                    .frame(height: 1)
                    .padding(.vertical, TileMetrics.blockGap)

                VStack(spacing: TileMetrics.rowGap) {
                    ForEach(others, id: \.code) { item in
                        HStack(spacing: 6) {
                            Text(item.code)
                                .font(TileFont.row)
                                .foregroundStyle(theme.textPrimary.color)
                            Spacer(minLength: 6)
                            Text(ConverterWidget.value(item.value))
                                .font(TileFont.rowValue)
                                .monospacedDigit()
                                .foregroundStyle(theme.textPrimary.color)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Text(RateStore.shared.sourceNote)
                .font(TileFont.axis)
                .foregroundStyle(theme.textMuted.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header: pair and swap, same as the translator

    private var header: some View {
        HStack(spacing: 6) {
            CodeMenu(code: widget.from, widget: widget) { widget.setFrom($0) }
            Button(action: widget.swap) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(TileIcon.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tileControl()
            .help("Swap currencies")
            CodeMenu(code: widget.to, widget: widget) { widget.setTo($0) }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Amount: tap the number and type your own, like the timer field

    // Amount uses the same size as the result: the converter's two lines are
    // equal partners, distinguished by color, not size
    @ViewBuilder
    private var amountControl: some View {
        if editing {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Field is flexible, code is fixed: with a fixed field width the
                // code didn't fit in the small tile, wrapped letter by letter,
                // and pushed the rows up
                TextField("100", text: $draft)
                    .textFieldStyle(.plain)
                    .font(TileFont.hero)
                    .frame(maxWidth: 120, alignment: .leading)
                    .foregroundStyle(theme.accent.color)
                    .focused($focused)
                    .releasesFocusOnHide($focused)
                    .onSubmit(apply)
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    .tileControl()
                Text(widget.from)
                    .font(TileFont.status)
                    .foregroundStyle(theme.textMuted.color)
                    .fixedSize()
            }
        } else {
            Button {
                draft = amountText
                editing = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(amountText)
                        .font(TileFont.hero)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                    Text(widget.from)
                        .font(TileFont.status)
                        .foregroundStyle(theme.textMuted.color)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Enter a different amount")
            .tileControl()
        }
    }

    private func resultRow(compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(widget.result.map { ConverterWidget.value($0, compact: compact) } ?? "—")
                .font(TileFont.hero)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Text(widget.to)
                .font(TileFont.status)
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    private var rateLine: some View {
        Text(widget.rateLine ?? "")
            .font(TileFont.caption)
            .foregroundStyle(theme.textMuted.color)
            .lineLimit(1)
    }

    private func apply() {
        let normalized = draft.replacingOccurrences(of: ",", with: ".")
        if let value = Double(normalized), value > 0 {
            widget.setAmount(value)
        } else if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            // Rejected input keeps the field open: closing on it looked as if
            // the number had been accepted. Empty input is a cancel
            return
        }
        editing = false
    }

    private var amountText: String {
        widget.amount == widget.amount.rounded()
            ? String(Int(widget.amount))
            : widget.amount.formatted(.number.precision(.fractionLength(2)))
    }
}

// Currency picker: all CBR fiat and coins from the "Currency" settings, native menu
private struct CodeMenu: View {
    let code: String
    let widget: ConverterWidget
    let action: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(widget.fiatOptions, id: \.code) { option in
                Button("\(option.code) — \(option.name)") { action(option.code) }
            }
            if !widget.cryptoOptions.isEmpty {
                Divider()
                ForEach(widget.cryptoOptions, id: \.code) { option in
                    Button("\(option.code) — \(option.name)") { action(option.code) }
                }
            }
        } label: {
            Text(code)
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
