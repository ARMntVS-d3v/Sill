import AppKit
import SwiftUI

// Six system widgets sharing one collector and one tile view.
// Each contributes only its own bits: what to show large, and what to reveal at larger sizes.
@MainActor
protocol MetricWidget: Widget {
    var metrics: SystemMetrics { get }
    var context: WidgetContext { get }
    var tile: MetricTileView { get }
}

extension MetricWidget {
    var metrics: SystemMetrics { .shared }
    var body: AnyView { AnyView(tile) }
    func activate() async throws { SystemMetrics.shared.refresh() }
    // Click opens Activity Monitor — it has details this tile doesn't
    func primaryAction() -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        return true
    }
}

// MARK: - CPU

@MainActor @Observable
final class CpuWidget: MetricWidget {
    static let descriptor = WidgetDescriptor(
        id: "cpu", name: "CPU", icon: "cpu",
        sizes: [.small, .medium, .large], defaultSize: .small)

    let context: WidgetContext

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(2)) { SystemMetrics.shared.refresh() }
    }

    var tile: MetricTileView {
        let cpu = metrics.cpu
        return MetricTileView(
            label: String(localized: "CPU"),
            value: SystemMetrics.percent(cpu.load),
            caption: String(localized: "load"),
            history: metrics.cpuHistory,
            size: context.tileSize,
            details: [
                .init(
                    title: String(localized: "performance"),
                    value: String(localized: "\(cpu.performanceCores) cores")),
                .init(
                    title: String(localized: "efficiency"),
                    value: String(localized: "\(cpu.efficiencyCores) cores")),
                .init(
                    title: String(localized: "uptime"),
                    value: SystemMetrics.uptimeText(metrics.uptime)),
            ],
            bars: context.tileSize == .large ? cpu.perCore : [],
            role: .cpu,
            load: cpu.load,
            processes: metrics.topByCpu.map {
                .init(
                    name: $0.name,
                    value: SystemMetrics.percent($0.cpuShare),
                    share: $0.cpuShare)
            })
    }
}

// MARK: - Memory

@MainActor @Observable
final class MemoryWidget: MetricWidget {
    static let descriptor = WidgetDescriptor(
        id: "memory", name: "Memory", icon: "memorychip",
        sizes: [.small, .medium, .large], defaultSize: .small)

    let context: WidgetContext

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(2)) { SystemMetrics.shared.refresh() }
    }

    var tile: MetricTileView {
        let memory = metrics.memory
        return MetricTileView(
            label: String(localized: "RAM"),
            value: SystemMetrics.percent(memory.share),
            caption: String(
                localized: "\(SystemMetrics.gigabytes(memory.used)) of \(SystemMetrics.gigabytes(memory.total))"),
            history: metrics.memoryHistory,
            size: context.tileSize,
            details: [
                // Swap and pressure matter more than the breakdown: when swap fills
                // up, the machine bogs down even with "free" memory
                .init(
                    title: String(localized: "swap"), value: SystemMetrics.gigabytes(memory.swapUsed),
                    share: memory.swapShare),
                .init(title: String(localized: "memory pressure"), value: memory.pressureText),
                .init(
                    title: String(localized: "compressed"), value: SystemMetrics.gigabytes(memory.compressed),
                    share: memory.total > 0 ? Double(memory.compressed) / Double(memory.total) : 0),
                .init(
                    title: String(localized: "wired"), value: SystemMetrics.gigabytes(memory.wired),
                    share: memory.total > 0 ? Double(memory.wired) / Double(memory.total) : 0),
            ],
            role: .memory,
            load: memory.share,
            processes: metrics.topByMemory.map {
                .init(
                    name: $0.name,
                    value: SystemMetrics.gigabytes($0.memory),
                    share: memory.total > 0 ? Double($0.memory) / Double(memory.total) : 0)
            })
    }
}

// MARK: - GPU

@MainActor @Observable
final class GpuWidget: MetricWidget {
    static let descriptor = WidgetDescriptor(
        id: "gpu", name: "GPU", icon: "cube.transparent",
        sizes: [.small, .medium, .large], defaultSize: .small)

    let context: WidgetContext

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(2)) { SystemMetrics.shared.refresh() }
    }

    var tile: MetricTileView {
        let gpu = metrics.gpu
        return MetricTileView(
            label: String(localized: "GPU"),
            value: SystemMetrics.percent(gpu.utilization),
            caption: String(localized: "load"),
            history: metrics.gpuHistory,
            size: context.tileSize,
            details: [
                .init(
                    title: String(localized: "Renderer"), value: SystemMetrics.percent(gpu.renderer),
                    share: gpu.renderer),
                .init(
                    title: String(localized: "Tiler"), value: SystemMetrics.percent(gpu.tiler),
                    share: gpu.tiler),
                .init(title: String(localized: "memory"), value: SystemMetrics.gigabytes(gpu.memoryUsed)),
            ],
            role: .gpu,
            load: gpu.utilization)
    }
}

// MARK: - Network

@MainActor @Observable
final class NetworkWidget: MetricWidget {
    static let descriptor = WidgetDescriptor(
        id: "network", name: "Network", icon: "network",
        sizes: [.small, .medium, .large], defaultSize: .small)

    let context: WidgetContext

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(2)) { SystemMetrics.shared.refresh() }
    }

    var tile: MetricTileView {
        let network = metrics.network
        return MetricTileView(
            label: network.interfaceName.isEmpty
                ? String(localized: "network")
                : String(localized: "network · \(network.interfaceName)"),
            value: SystemMetrics.speed(network.downloadPerSecond),
            caption: String(localized: "down · up \(SystemMetrics.speed(network.uploadPerSecond))"),
            history: metrics.downloadHistory,
            size: context.tileSize,
            tint: nil,
            details: [
                .init(title: String(localized: "upload now"), value: SystemMetrics.speed(network.uploadPerSecond)),
                .init(
                    title: String(localized: "received this session"),
                    value: SystemMetrics.gigabytes(network.sessionDownload)),
                .init(
                    title: String(localized: "sent this session"),
                    value: SystemMetrics.gigabytes(network.sessionUpload)),
                .init(
                    title: String(localized: "address"),
                    value: network.localAddress.isEmpty ? String(localized: "no network") : network.localAddress),
            ],
            scaleToPeak: true,
            role: .network)
    }
}

// MARK: - Disk

@MainActor @Observable
final class DiskWidget: MetricWidget {
    static let descriptor = WidgetDescriptor(
        id: "disk", name: "Disk", icon: "internaldrive",
        sizes: [.small, .medium, .large], defaultSize: .small)

    let context: WidgetContext

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(2)) { SystemMetrics.shared.refresh() }
    }

    var tile: MetricTileView {
        let disk = metrics.disk
        return MetricTileView(
            label: String(localized: "disk"),
            value: SystemMetrics.gigabytes(disk.free),
            caption: String(localized: "free of \(SystemMetrics.gigabytes(disk.total))"),
            history: metrics.diskHistory,
            size: context.tileSize,
            details: [
                .init(title: String(localized: "used"), value: SystemMetrics.percent(disk.share), share: disk.share),
                .init(title: String(localized: "read"), value: SystemMetrics.speed(disk.readPerSecond)),
                .init(title: String(localized: "write"), value: SystemMetrics.speed(disk.writePerSecond)),
            ],
            scaleToPeak: true,
            role: .disk,
            load: disk.share)
    }
}

// MARK: - Battery

@MainActor @Observable
final class BatteryWidget: MetricWidget {
    static let descriptor = WidgetDescriptor(
        id: "battery", name: "Battery", icon: "battery.100",
        sizes: [.small, .medium, .large], defaultSize: .small)

    let context: WidgetContext
    private var theme: Theme { context.theme }

    init(context: WidgetContext) {
        self.context = context
        context.schedule(every: .seconds(2)) { SystemMetrics.shared.refresh() }
    }

    // Battery icon by level — same as the menu bar: empty, quarter, half, full
    static func icon(for battery: SystemMetrics.Battery) -> String {
        if battery.charging || battery.plugged { return "battery.100.bolt" }
        switch battery.percent {
        case ..<10: return "battery.0"
        case ..<35: return "battery.25"
        case ..<60: return "battery.50"
        case ..<85: return "battery.75"
        default: return "battery.100"
        }
    }

    // A Mac may have no battery at all (mini, Studio) — that's the tile's empty
    // state, not a "—" value with small-print caption
    var body: AnyView {
        guard metrics.battery != nil else {
            return AnyView(TilePlaceholder(String(localized: "No battery"), icon: "battery.100"))
        }
        return AnyView(tile)
    }

    var tile: MetricTileView {
        let battery = metrics.battery
        var details: [MetricTileView.Detail] = []
        // Rectangle shows how many nearby devices there are; large shows the full list
        if !metrics.devices.isEmpty, context.tileSize == .medium {
            let lowest = metrics.devices.first
            details.append(
                .init(
                    title: lowest.map { "\($0.name)" } ?? String(localized: "devices"),
                    value: lowest.map { "\($0.percent)%" } ?? ""))
        }
        if let battery {
            if let cycles = battery.cycles {
                details.append(.init(title: String(localized: "cycles"), value: "\(cycles)"))
            }
            if let health = battery.health {
                details.append(
                    .init(title: String(localized: "capacity"), value: "\(health)%", share: Double(health) / 100))
            }
            if let watts = battery.watts {
                details.append(
                    .init(
                        title: String(localized: "power draw"),
                        value: String(localized: "\(watts.formatted(.number.precision(.fractionLength(1)))) W")))
            }
            if let temperature = battery.temperature {
                details.append(
                    .init(
                        title: String(localized: "temperature"),
                        value: String(
                            localized: "\(temperature.formatted(.number.precision(.fractionLength(1)))) °C")))
            }
        }
        return MetricTileView(
            label: String(localized: "battery"),
            value: battery.map { "\($0.percent)%" } ?? "—",
            caption: battery.map(Self.status) ?? String(localized: "no battery"),
            history: metrics.batteryHistory,
            size: context.tileSize,
            tint: battery.flatMap { $0.percent <= 20 && !$0.plugged ? theme.error.color : nil },
            details: details,
            role: .battery,
            devices: context.tileSize == .large ? metrics.devices : [])
    }

    private static func status(_ battery: SystemMetrics.Battery) -> String {
        if battery.charging {
            if let minutes = battery.minutesToFull {
                let hours = minutes / 60
                return hours > 0
                    ? String(localized: "full in \(hours)h \(minutes % 60)m")
                    : String(localized: "full in \(minutes)m")
            }
            return String(localized: "charging")
        }
        if battery.plugged { return String(localized: "plugged in") }
        if let minutes = battery.minutesLeft {
            let hours = minutes / 60
            return hours > 0
                ? String(localized: "\(hours)h \(minutes % 60)m left")
                : String(localized: "\(minutes)m left")
        }
        return String(localized: "on battery")
    }
}
