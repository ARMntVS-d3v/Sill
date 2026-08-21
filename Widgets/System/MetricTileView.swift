import SwiftUI

// A shared metric tile: label, headline number, a live one-minute graph, and details.
// Every system widget is built on it — otherwise CPU, memory, and network would
// drift apart in layout despite showing the same kind of thing.
struct MetricTileView: View {
    struct ProcessLine: Identifiable {
        let name: String
        let value: String
        let share: Double
        var id: String { name }
    }

    struct Detail: Identifiable {
        let title: String
        let value: String
        var share: Double?
        var id: String { title }
    }

    let label: String
    let value: String
    let caption: String
    let history: [Double]
    let size: TileSize
    var tint: Color?
    var details: [Detail] = []
    /// Per-core bars — only on the CPU widget at the large size
    var bars: [Double] = []
    /// Percentages are drawn on a fixed 0-100 scale; bytes/sec scale to their own peak
    var scaleToPeak = false
    /// Role sets the tile's base color
    var role: MetricRole = .cpu
    /// Current load 0...1: past the ceiling, the tile colors itself as a warning
    var load: Double?
    /// Top processes — the reason people open Activity Monitor: see exactly what's loading it
    var processes: [MetricTileView.ProcessLine] = []
    /// Battery level for headphones, mouse, keyboard — only at the battery widget's large size
    var devices: [SystemMetrics.DeviceBattery] = []

    @Environment(\.theme) private var theme

    // Each metric has its own color, but under overload it yields to the warning
    // color: color should carry meaning, not just distinguish tiles
    // How many detail rows fit: process and device lists crowd them out
    private var detailLimit: Int {
        guard size == .large else { return 2 }
        if !devices.isEmpty { return 2 }
        return processes.isEmpty ? 5 : 2
    }

    private var accent: Color {
        if let tint { return tint }
        guard let load else { return theme.metricColor(role) }
        if load >= 0.9 { return theme.error.color }
        if load >= 0.75 { return theme.warning.color }
        return theme.metricColor(role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileLabel(label)

            Text(value)
                .font(TileFont.hero)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .padding(.top, 6)

            Text(caption)
                .font(TileFont.status)
                .foregroundStyle(theme.textSecondary.color)
                // Two lines: "full in 1h 20m" doesn't fit on one, and there's
                // room underneath for it
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if size == .small {
                Spacer(minLength: 6)
                Sparkline(values: history, tint: accent, scaleToPeak: scaleToPeak)
                    .frame(height: 26)
            } else {
                // Heights are tuned so the content fits the tile exactly: the
                // rectangle has only 126 points total for the graph and two detail rows
                Sparkline(values: history, tint: accent, scaleToPeak: scaleToPeak)
                    .frame(height: size == .large ? 54 : 26)
                    .padding(.top, size == .large ? 10 : 8)

                if !bars.isEmpty, size == .large {
                    CoreBars(values: bars, tint: accent)
                        .padding(.top, TileMetrics.blockGap)
                }

                if !devices.isEmpty, size == .large {
                    VStack(spacing: 6) {
                        ForEach(devices.prefix(4)) { device in
                            DeviceRow(device: device, tint: accent)
                        }
                    }
                    .padding(.top, TileMetrics.blockGap)
                }

                if !processes.isEmpty, size == .large {
                    VStack(spacing: 5) {
                        ForEach(processes.prefix(4)) { process in
                            ProcessRow(process: process, tint: accent)
                        }
                    }
                    .padding(.top, TileMetrics.blockGap)
                }

                Spacer(minLength: 6)

                VStack(spacing: size == .large ? 8 : 5) {
                    ForEach(details.prefix(detailLimit)) { detail in
                        // Bars only at the large size: the rectangle has no height for them
                        DetailRow(detail: detail, tint: accent, showsBar: size == .large)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// A one-minute graph: a smoothed curve, a fill beneath it, and a "now" dot.
// A raw sixty-segment polyline reads as an engineering log, not a tile
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var scaleToPeak = false
    var showsLevel = true
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            // For percentages the scale is fixed: otherwise a calm 5% would draw at full height
            let peak = scaleToPeak ? max(values.max() ?? 1, 0.0001) : 1
            let points = points(in: geo.size, peak: peak)
            ZStack {
                if showsLevel {
                    // Midline: a faint visual anchor, almost invisible
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                    }
                    .stroke(
                        theme.textMuted.color.opacity(0.18),
                        style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                }

                if points.count > 1 {
                    curve(points, closedAt: geo.size.height)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.45), tint.opacity(0.03)],
                                startPoint: .top, endPoint: .bottom))

                    curve(points, closedAt: nil)
                        .stroke(
                            LinearGradient(
                                colors: [tint.opacity(0.75), tint],
                                startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                    // The "now" dot with a halo: makes it obvious where the history ends
                    if let last = points.last {
                        Circle()
                            .fill(tint.opacity(0.25))
                            .frame(width: 12, height: 12)
                            .position(last)
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .position(last)
                    }
                } else {
                    Rectangle()
                        .fill(theme.border.color)
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    // Smoothing via quadratic curves through segment midpoints: the line runs
    // soft but doesn't "overshoot" past values the way a cubic spline would
    private func curve(_ points: [CGPoint], closedAt bottom: CGFloat?) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        if let bottom {
            path.move(to: CGPoint(x: first.x, y: bottom))
            path.addLine(to: first)
        } else {
            path.move(to: first)
        }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let middle = CGPoint(
                x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: middle, control: previous)
        }
        if let last = points.last {
            path.addLine(to: last)
            if let bottom {
                path.addLine(to: CGPoint(x: last.x, y: bottom))
                path.closeSubpath()
            }
        }
        return path
    }

    private func points(in size: CGSize, peak: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(max(values.count - 1, 1))
        // Top and bottom are inset so the line and dot aren't clipped by the tile edge
        let inset: CGFloat = 4
        let usable = max(size.height - inset * 2, 1)
        return values.enumerated().map { index, value in
            let share = min(max(value / peak, 0), 1)
            return CGPoint(x: CGFloat(index) * step, y: inset + usable * (1 - share))
        }
    }
}

// Per-core bars: makes it visible that not every core is loaded
private struct CoreBars: View {
    let values: [Double]
    let tint: Color
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(theme.border.color)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(tint)
                            .frame(height: max(geo.size.height * min(max(value, 0), 1), 1.5))
                    }
                }
            }
        }
        .frame(height: 18)
    }
}

// Process row: name on the left, number on the right, a thin bar as background
private struct ProcessRow: View {
    let process: MetricTileView.ProcessLine
    let tint: Color
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(TileFont.caption)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(process.value)
                .font(TileFont.rowValue)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity(0.16))
                    .frame(width: max(geo.size.width * min(max(process.share, 0), 1), 2))
            }
        }
    }
}

// Device row: icon, name, battery level, and a case-detail caption
private struct DeviceRow: View {
    let device: SystemMetrics.DeviceBattery
    let tint: Color
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.icon)
                .font(TileIcon.glyph)
                .foregroundStyle(device.percent <= 20 ? theme.error.color : tint)
                .frame(width: 18)
            Text(device.name)
                .font(TileFont.caption)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if let detail = device.detail {
                Text(detail)
                    .font(TileFont.axis)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
            }
            Text("\(device.percent)%")
                .font(TileFont.rowValue)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
    }
}

private struct DetailRow: View {
    let detail: MetricTileView.Detail
    let tint: Color
    var showsBar = true
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(detail.title)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 6)
                Text(detail.value)
                    .font(TileFont.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
            }
            if let share = detail.share, showsBar {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.border.color).frame(height: 3)
                        Capsule()
                            .fill(tint)
                            .frame(width: max(geo.size.width * min(max(share, 0), 1), 3), height: 3)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 3)
            }
        }
    }
}
