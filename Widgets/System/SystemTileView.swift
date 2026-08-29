import SwiftUI

// Mac status: the bigger the tile, the more metrics it shows.
// Numbers come from TileFont, bars look like the weekly forecast's
struct SystemTileView: View {
    let widget: SystemWidget
    let size: TileSize

    var body: some View {
        Group {
            switch size {
            case .small: SystemSmallView(widget: widget)
            case .medium: SystemMediumView(widget: widget)
            case .large: SystemLargeView(widget: widget)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(TileMetrics.padding)
    }
}

// MARK: - shared bits

// A metric row: label, value, fill bar. No per-row graph: the large overview
// moved to rings, and the graph parameter sat dead with no caller passing it
private struct MeterRow: View {
    let title: String
    let value: String
    let share: Double
    var tint: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 6)
                Text(value)
                    .font(TileFont.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.border.color)
                        .frame(height: 3)
                    Capsule()
                        .fill(tint ?? theme.accent.color)
                        .frame(width: max(geo.size.width * min(max(share, 0), 1), 3), height: 3)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 3)
        }
    }
}

private extension SystemMetrics {
    var memoryText: String {
        String(localized: "\(SystemMetrics.gigabytes(memory.used)) of \(SystemMetrics.gigabytes(memory.total))")
    }
    var diskText: String {
        String(localized: "\(SystemMetrics.gigabytes(disk.free)) free")
    }
    var coresText: String {
        let total = cpu.performanceCores + cpu.efficiencyCores
        return String(localized: "\(total) cores · \(SystemMetrics.gigabytes(memory.total)) · \(osVersion)")
    }
}

private extension SystemMetrics.Battery {
    var text: String { "\(percent)%" }

    var statusText: String {
        if charging { return String(localized: "charging") }
        if plugged { return String(localized: "plugged in") }
        if let minutesLeft {
            let hours = minutesLeft / 60
            let minutes = minutesLeft % 60
            return hours > 0
                ? String(localized: "\(hours)h \(minutes)m left")
                : String(localized: "\(minutes)m left")
        }
        return String(localized: "on battery")
    }
}

// MARK: - Square: all metrics at once, one row each

private struct SystemSmallView: View {
    let widget: SystemWidget
    @Environment(\.theme) private var theme

    var body: some View {
        // The point of an overview is not having to pick between metrics: in the
        // square they're just packed tighter, but all present. What gives way is the
        // chrome around them — the layout picks the first variant that fits, so the
        // last row is never cut off by the tile edge (the battery row used to be)
        ViewThatFits(in: .vertical) {
            meters(label: true, gap: TileMetrics.meterGap)
            meters(label: false, gap: TileMetrics.meterGap)
            meters(label: false, gap: TileMetrics.meterGapDense)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func meters(label: Bool, gap: CGFloat) -> some View {
        let metrics = widget.metrics
        return VStack(alignment: .leading, spacing: gap) {
            if label { TileLabel(String(localized: "overview")) }

            CompactMeter(
                title: String(localized: "CPU"), value: SystemMetrics.percent(metrics.cpu.load),
                share: metrics.cpu.load, tint: theme.metricColor(.cpu))
            CompactMeter(
                title: String(localized: "GPU"), value: SystemMetrics.percent(metrics.gpu.utilization),
                share: metrics.gpu.utilization, tint: theme.metricColor(.gpu))
            CompactMeter(
                title: String(localized: "RAM"), value: SystemMetrics.percent(metrics.memory.share),
                share: metrics.memory.share, tint: theme.metricColor(.memory))
            CompactMeter(
                title: String(localized: "disk"), value: SystemMetrics.gigabytes(metrics.disk.free),
                share: metrics.disk.share, tint: theme.metricColor(.disk))
            if let battery = metrics.battery {
                CompactMeter(
                    title: String(localized: "battery"), value: battery.text,
                    share: Double(battery.percent) / 100, tint: theme.metricColor(.battery))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// Overview row: label, value, and a thin bar underneath
private struct CompactMeter: View {
    let title: String
    let value: String
    let share: Double
    let tint: Color
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 0)
                Text(value)
                    .font(TileFont.rowValue)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.border.color).frame(height: 2.5)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(geo.size.width * min(max(share, 0), 1), 2.5), height: 2.5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 2.5)
        }
    }
}

// MARK: - Rectangle: load on the left, metrics on the right

private struct SystemMediumView: View {
    let widget: SystemWidget
    @Environment(\.theme) private var theme

    var body: some View {
        let metrics = widget.metrics
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                TileLabel(String(localized: "overview"))
                Text(SystemMetrics.percent(metrics.cpu.load))
                    .font(TileFont.hero)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
                    .padding(.top, 6)
                Text("CPU")
                    .font(TileFont.status)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: 0)
                if (metrics.cpu.performanceCores + metrics.cpu.efficiencyCores) > 0 {
                    Text("\(metrics.cpu.performanceCores)P + \(metrics.cpu.efficiencyCores)E")
                        .font(TileFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textMuted.color)
                }
            }
            .frame(width: 104, alignment: .leading)

            Rectangle()
                .fill(theme.border.color)
                .frame(width: 1)

            VStack(spacing: 10) {
                MeterRow(
                    title: String(localized: "GPU"),
                    value: SystemMetrics.percent(metrics.gpu.utilization),
                    share: metrics.gpu.utilization,
                    tint: theme.metricColor(.gpu))
                MeterRow(
                    title: String(localized: "RAM"),
                    value: SystemMetrics.gigabytes(metrics.memory.used),
                    share: metrics.memory.share,
                    tint: theme.metricColor(.memory))
                MeterRow(
                    title: String(localized: "disk"),
                    value: SystemMetrics.gigabytes(metrics.disk.free),
                    share: metrics.disk.share,
                    tint: theme.metricColor(.disk))
                if let battery = metrics.battery {
                    MeterRow(
                        title: battery.statusText,
                        value: battery.text,
                        share: Double(battery.percent) / 100,
                        tint: batteryTint(battery))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func batteryTint(_ battery: SystemMetrics.Battery) -> Color {
        if battery.charging { return theme.success.color }
        return battery.percent <= 20 ? theme.error.color : theme.accent.color
    }
}

// MARK: - Large: four rings and battery

private struct SystemLargeView: View {
    let widget: SystemWidget
    @Environment(\.theme) private var theme

    var body: some View {
        let metrics = widget.metrics
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metrics.cpu.chip)
                    .font(TileFont.title)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
                Text(metrics.coresText)
                    .font(TileFont.caption)
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
            }

            // Four rings instead of four bars: a circle reads at a glance and
            // keeps the tile's shape instead of stretching it into a table
            HStack(spacing: 10) {
                MetricRing(
                    title: String(localized: "CPU"), value: SystemMetrics.percent(metrics.cpu.load),
                    share: metrics.cpu.load, tint: theme.metricColor(.cpu),
                    history: metrics.cpuHistory)
                MetricRing(
                    title: String(localized: "GPU"), value: SystemMetrics.percent(metrics.gpu.utilization),
                    share: metrics.gpu.utilization, tint: theme.metricColor(.gpu),
                    history: metrics.gpuHistory)
            }
            .padding(.top, 12)

            HStack(spacing: 10) {
                MetricRing(
                    title: String(localized: "RAM"), value: SystemMetrics.percent(metrics.memory.share),
                    share: metrics.memory.share, tint: theme.metricColor(.memory),
                    history: metrics.memoryHistory,
                    caption: SystemMetrics.gigabytes(metrics.memory.used))
                MetricRing(
                    title: String(localized: "disk"), value: SystemMetrics.percent(metrics.disk.share),
                    share: metrics.disk.share, tint: theme.metricColor(.disk),
                    history: [],
                    caption: String(localized: "\(SystemMetrics.gigabytes(metrics.disk.free)) free"))
            }
            .padding(.top, TileMetrics.blockGap)

            Spacer(minLength: 8)

            if let battery = metrics.battery {
                MeterRow(
                    title: String(localized: "battery · \(battery.statusText)"),
                    value: battery.text,
                    share: Double(battery.percent) / 100,
                    tint: battery.charging ? theme.success.color : theme.metricColor(.battery))
            }

            HStack(spacing: 10) {
                if let cycles = metrics.battery?.cycles {
                    Text("\(cycles) cycles")
                }
                if let health = metrics.battery?.health {
                    Text("\(health)% capacity")
                }
                Spacer(minLength: 0)
                Text("up \(SystemMetrics.uptimeText(metrics.uptime))")
            }
            .font(TileFont.axis)
            .monospacedDigit()
            .foregroundStyle(theme.textMuted.color)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Metric ring: a fill arc, the number in the center, a graph as background
private struct MetricRing: View {
    let title: String
    let value: String
    let share: Double
    let tint: Color
    var history: [Double] = []
    var caption: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(theme.border.color, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(max(share, 0), 1))
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.55), tint],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: Motion.fill), value: share)

                VStack(spacing: 1) {
                    Text(value)
                        .font(TileFont.title)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                    Text(title)
                        .font(TileFont.axis)
                        .foregroundStyle(theme.textMuted.color)
                }
            }
            .frame(height: 74)

            if let caption {
                Text(caption)
                    .font(TileFont.axis)
                    .monospacedDigit()
                    .foregroundStyle(theme.textMuted.color)
                    .lineLimit(1)
            } else if !history.isEmpty {
                Sparkline(values: history, tint: tint, showsLevel: false)
                    .frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
