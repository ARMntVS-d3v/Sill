import SwiftUI

// Exchange rates. Small — one main currency, medium — three rows, large — a
// list with the day's change. Conversion amount is entered from the keyboard.
struct CurrencyTileView: View {
    let widget: CurrencyWidget
    let size: TileSize

    @Environment(\.theme) private var theme
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            // The placeholder also covers "snapshot exists but holds nothing to
            // show" — only coins chosen and none loaded left a tile with just a date
            if widget.snapshot == nil || widget.rates(limit: 1).isEmpty {
                VStack(spacing: TileMetrics.rowGap) {
                    TilePlaceholder(widget.failure ?? String(localized: "Loading…"), icon: "banknote")
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

    // MARK: - Small: one currency, large

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileLabel(dateText)
            if let rate = widget.rates(limit: 1).first {
                Text(CurrencyWidget.money(rate.perUnit * widget.amount, base: widget.base(for: rate)))
                    .font(TileFont.hero)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                    .padding(.top, 8)
                Text("\(amountText) \(rate.code)")
                    .font(TileFont.status)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 6)
                ChangeBadge(rate: rate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium: four currencies as rows

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TileLabel(dateText)
                Spacer(minLength: 0)
                amountField
            }
            Spacer(minLength: 6)
            // Four rows, tightening the step if that's what it takes — and dropping
            // to three only if even the dense step doesn't fit (a longer locale,
            // a larger system font). The layout decides, not a number picked by hand
            ViewThatFits(in: .vertical) {
                rows(4, gap: TileMetrics.rowGap)
                rows(4, gap: TileMetrics.meterGap)
                rows(4, gap: TileMetrics.meterGapDense)
                rows(3, gap: TileMetrics.rowGap)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rows(_ count: Int, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            ForEach(widget.rates(limit: count)) { rate in
                RateRow(rate: rate, amount: widget.amount, base: widget.base(for: rate))
            }
        }
    }

    // MARK: - Large: own currencies plus the rest

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TileLabel(dateText)
                Spacer(minLength: 0)
                amountField
            }

            // One list, one look: name and change on every row. The divider
            // and the "compact continuation" were removed — rows 4–7 looked
            // like a different widget
            VStack(spacing: TileMetrics.rowGap) {
                ForEach(widget.rates(limit: 7)) { rate in
                    RateRow(
                        rate: rate, amount: widget.amount, base: widget.base(for: rate),
                        showsName: true)
                }
            }
            .padding(.top, TileMetrics.blockGap)

            Spacer(minLength: 4)

            // Honest caption: CBR really does publish one rate a day, coins don't
            Text(widget.sourceNote)
                .font(TileFont.axis)
                .foregroundStyle(theme.textMuted.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Conversion amount: tap the number and type your own, like the timer field
    @ViewBuilder
    private var amountField: some View {
        if editing {
            TextField("1", text: $draft)
                .textFieldStyle(.plain)
                .font(TileFont.rowValue)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
                .foregroundStyle(theme.accent.color)
                .focused($focused)
                .releasesFocusOnHide($focused)
                .onSubmit(apply)
                .onExitCommand { editing = false }
                .onAppear { focused = true }
                .tileControl()
        } else {
            Button {
                draft = amountText
                editing = true
            } label: {
                Text("× \(amountText)")
                    .font(TileFont.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }
            .buttonStyle(.plain)
            .help("Convert a different amount")
            .tileControl()
        }
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

    private var dateText: String {
        guard let snapshot = widget.snapshot else { return String(localized: "currency") }
        return snapshot.date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// Currency row: code, name, rate, and day's change
private struct RateRow: View {
    let rate: CurrencyWidget.Rate
    let amount: Double
    var base = "RUB"
    var showsName = false
    var compact = false

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(rate.code)
                .font(compact ? TileFont.caption : TileFont.row)
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: compact ? 34 : 40, alignment: .leading)

            if showsName {
                Text(rate.title)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if !compact {
                ChangeBadge(rate: rate)
            }

            Text(CurrencyWidget.money(rate.perUnit * amount, base: base))
                .font(compact ? TileFont.rowValue : TileFont.row)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
    }
}

// Day's change: color carries the sign, so no arrow is needed
private struct ChangeBadge: View {
    let rate: CurrencyWidget.Rate
    @Environment(\.theme) private var theme

    var body: some View {
        Text(CurrencyWidget.changeText(rate))
            .font(TileFont.axis)
            .monospacedDigit()
            .foregroundStyle(rate.change >= 0 ? theme.success.color : theme.error.color)
    }
}
