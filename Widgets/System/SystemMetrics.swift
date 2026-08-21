import Darwin
import Foundation
import IOKit
import IOKit.ps

// One collector for every system widget: CPU, GPU, memory, network, disk,
// battery. Sampling is shared — six tiles on a board shouldn't poll the kernel
// six times. History covers one minute; it drives the live graphs in the tiles.
@MainActor @Observable
final class SystemMetrics {
    static let shared = SystemMetrics()

    static let historyLength = 60

    struct Cpu: Sendable {
        var load: Double = 0
        var perCore: [Double] = []
        var performanceCores = 0
        var efficiencyCores = 0
        var chip = ""
    }

    struct Memory: Sendable {
        var total: UInt64 = 0
        var used: UInt64 = 0
        var active: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        /// 1 = normal, 2 = warning, 4 = critical (as reported by the kernel)
        var pressureLevel = 1
        var share: Double { total > 0 ? Double(used) / Double(total) : 0 }
        var swapShare: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }

        var pressureText: String {
            switch pressureLevel {
            case 4: String(localized: "critical")
            case 2: String(localized: "elevated")
            default: String(localized: "normal")
            }
        }
    }

    // A top-list row: name, CPU share, and memory
    struct ProcessUsage: Sendable, Identifiable {
        var pid: pid_t
        var name: String
        var cpuShare: Double
        var memory: UInt64
        var id: pid_t { pid }
    }

    struct Gpu: Sendable {
        var utilization: Double = 0
        var renderer: Double = 0
        var tiler: Double = 0
        var memoryUsed: UInt64 = 0
        var name = ""
    }

    struct Network: Sendable {
        var downloadPerSecond: Double = 0
        var uploadPerSecond: Double = 0
        var sessionDownload: UInt64 = 0
        var sessionUpload: UInt64 = 0
        var interfaceName = ""
        var localAddress = ""
    }

    struct Disk: Sendable {
        var total: Int64 = 0
        var free: Int64 = 0
        var readPerSecond: Double = 0
        var writePerSecond: Double = 0
        var name = ""
        var share: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
    }

    // Battery level for headphones, mouse, keyboard. Separate from the Mac's
    // own battery: the data source is different
    struct DeviceBattery: Sendable, Identifiable, Equatable {
        var name: String
        var icon: String
        var percent: Int
        var detail: String?
        var id: String { name }
    }

    struct Battery: Sendable {
        var percent: Int = 0
        var charging = false
        var plugged = false
        var cycles: Int?
        var health: Int?
        var minutesLeft: Int?
        var minutesToFull: Int?
        var watts: Double?
        var temperature: Double?
    }

    private(set) var cpu = Cpu()
    private(set) var memory = Memory()
    private(set) var gpu = Gpu()
    private(set) var network = Network()
    private(set) var disk = Disk()
    private(set) var battery: Battery?
    private(set) var devices: [DeviceBattery] = []
    private(set) var topByCpu: [ProcessUsage] = []
    private(set) var topByMemory: [ProcessUsage] = []
    private(set) var uptime: TimeInterval = 0
    private(set) var osVersion = ""
    private(set) var model = ""

    // Graph histories: a 0...1 share, except network and disk, which use bytes/sec
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []
    private(set) var diskHistory: [Double] = []
    private(set) var batteryHistory: [Double] = []

    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var cpuTicks: (used: UInt64, total: UInt64)?
    @ObservationIgnored private var coreTicks: [(used: UInt64, total: UInt64)] = []
    @ObservationIgnored private var netCounters: (input: UInt64, output: UInt64)?
    @ObservationIgnored private var netBase: (input: UInt64, output: UInt64)?
    @ObservationIgnored private var diskCounters: (read: UInt64, written: UInt64)?
    @ObservationIgnored private var processTimes: [pid_t: Double] = [:]
    // Polling devices costs a quarter second and an external process, so once a minute
    @ObservationIgnored private var devicesUpdated: Date?
    @ObservationIgnored private var devicesTask: Task<Void, Never>?

    private init() {}

    /// Sample. Widgets call this from their own tick — redundant calls are dropped
    func refresh() {
        let now = Date()
        if let lastTick, now.timeIntervalSince(lastTick) < 0.8 { return }
        let interval = lastTick.map { now.timeIntervalSince($0) } ?? 1
        // The panel was closed, so there were no samples, and yesterday's value
        // can't be stitched to today's into one continuous curve: the graph is
        // labeled "last minute". A gap over five seconds means the whole history is stale
        if let lastTick, now.timeIntervalSince(lastTick) > 5 { clearHistory() }
        lastTick = now

        readCpu()
        readMemory()
        readGpu()
        readNetwork(interval: interval)
        readDisk(interval: interval)
        readProcesses(interval: interval)
        battery = SystemProbe.batteryDetails()
        uptime = SystemProbe.uptime()
        model = SystemProbe.sysctlString("hw.model") ?? ""
        let version = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "macOS \(version.majorVersion).\(version.minorVersion)"

        refreshDevicesIfNeeded()

        push(&cpuHistory, cpu.load)
        push(&memoryHistory, memory.share)
        push(&gpuHistory, gpu.utilization)
        push(&downloadHistory, network.downloadPerSecond)
        push(&uploadHistory, network.uploadPerSecond)
        push(&diskHistory, disk.readPerSecond + disk.writePerSecond)
        push(&batteryHistory, Double(battery?.percent ?? 0) / 100)
    }

    private func refreshDevicesIfNeeded() {
        if let devicesUpdated, Date().timeIntervalSince(devicesUpdated) < 60 { return }
        guard devicesTask == nil else { return }
        devicesUpdated = Date()
        devicesTask = Task { [weak self] in
            let found = await SystemProbe.deviceBatteries()
            // The task reference is cleared either way: otherwise, if the
            // collector went away, device battery levels would never be polled again
            guard let self else { return }
            devicesTask = nil
            devices = found
        }
    }

    /// History no longer describes the last minute — start it over
    private func clearHistory() {
        cpuHistory.removeAll()
        memoryHistory.removeAll()
        gpuHistory.removeAll()
        downloadHistory.removeAll()
        uploadHistory.removeAll()
        diskHistory.removeAll()
        batteryHistory.removeAll()
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    // MARK: - CPU

    private func readCpu() {
        var next = cpu
        next.chip = SystemProbe.sysctlString("machdep.cpu.brand_string")?
            .replacingOccurrences(of: "Apple ", with: "") ?? ""
        next.performanceCores = Int(SystemProbe.sysctlNumber("hw.perflevel0.physicalcpu") ?? 0)
        next.efficiencyCores = Int(SystemProbe.sysctlNumber("hw.perflevel1.physicalcpu") ?? 0)

        if let total = SystemProbe.cpuTotals() {
            if let previous = cpuTicks, total.total > previous.total {
                next.load = Double(total.used - previous.used) / Double(total.total - previous.total)
            }
            cpuTicks = total
        }

        let cores = SystemProbe.cpuPerCore()
        if !cores.isEmpty {
            if coreTicks.count == cores.count {
                next.perCore = zip(cores, coreTicks).map { current, previous in
                    let deltaTotal = current.total > previous.total ? current.total - previous.total : 0
                    guard deltaTotal > 0 else { return 0 }
                    return Double(current.used - previous.used) / Double(deltaTotal)
                }
            } else {
                next.perCore = Array(repeating: 0, count: cores.count)
            }
            coreTicks = cores
        }
        cpu = next
    }

    // MARK: - memory

    private func readMemory() {
        var next = Memory()
        next.total = SystemProbe.sysctlNumber("hw.memsize") ?? 0
        let stats = SystemProbe.memoryStats()
        next.active = stats.active
        next.wired = stats.wired
        next.compressed = stats.compressed
        next.used = stats.active + stats.wired + stats.compressed
        let swap = SystemProbe.swapUsage()
        next.swapUsed = swap.used
        next.swapTotal = swap.total
        next.pressureLevel = SystemProbe.memoryPressure()
        memory = next
    }

    // CPU share is computed the same way Activity Monitor does: 100% is one core,
    // so a heavy process honestly shows 300% rather than a vague 25% of the total
    private func readProcesses(interval: TimeInterval) {
        let samples = SystemProbe.processes()
        guard !samples.isEmpty else { return }

        var usage: [ProcessUsage] = []
        usage.reserveCapacity(samples.count)
        var times: [pid_t: Double] = [:]
        times.reserveCapacity(samples.count)

        for sample in samples {
            times[sample.pid] = sample.cpuSeconds
            let previous = processTimes[sample.pid]
            let share = previous.map { max(sample.cpuSeconds - $0, 0) / max(interval, 0.1) } ?? 0
            usage.append(
                ProcessUsage(
                    pid: sample.pid, name: sample.name, cpuShare: share, memory: sample.memory))
        }
        processTimes = times

        topByCpu = Array(usage.sorted { $0.cpuShare > $1.cpuShare }.prefix(5))
        topByMemory = Array(usage.sorted { $0.memory > $1.memory }.prefix(5))
    }

    // MARK: - GPU

    private func readGpu() {
        var next = Gpu()
        let stats = SystemProbe.gpuStatistics()
        next.utilization = stats.utilization
        next.renderer = stats.renderer
        next.tiler = stats.tiler
        next.memoryUsed = stats.memoryUsed
        next.name = stats.name
        gpu = next
    }

    // MARK: - network

    private func readNetwork(interval: TimeInterval) {
        let counters = SystemProbe.networkCounters()
        var next = Network()
        next.interfaceName = counters.interface
        next.localAddress = counters.address

        if let previous = netCounters, interval > 0 {
            let down = counters.input >= previous.input ? counters.input - previous.input : 0
            let up = counters.output >= previous.output ? counters.output - previous.output : 0
            next.downloadPerSecond = Double(down) / interval
            next.uploadPerSecond = Double(up) / interval
        }
        if netBase == nil { netBase = (counters.input, counters.output) }
        if let base = netBase {
            next.sessionDownload = counters.input >= base.input ? counters.input - base.input : 0
            next.sessionUpload = counters.output >= base.output ? counters.output - base.output : 0
        }
        netCounters = (counters.input, counters.output)
        network = next
    }

    // MARK: - disk

    private func readDisk(interval: TimeInterval) {
        var next = Disk()
        let space = SystemProbe.diskSpace()
        next.total = space.total
        next.free = space.free
        next.name = SystemProbe.volumeName()

        let io = SystemProbe.diskCounters()
        if let previous = diskCounters, interval > 0 {
            let read = io.read >= previous.read ? io.read - previous.read : 0
            let written = io.written >= previous.written ? io.written - previous.written : 0
            next.readPerSecond = Double(read) / interval
            next.writePerSecond = Double(written) / interval
        }
        diskCounters = io
        disk = next
    }

    // MARK: - formatting

    /// "1.2 MB/s", "860 KB/s" — speed always carries a unit, zero renders as a dash
    nonisolated static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1024 else { return String(localized: "—") }
        return bytes(bytesPerSecond) + String(localized: "/s")
    }

    nonisolated static func bytes(_ value: Double) -> String {
        let units = [
            String(localized: "B"), String(localized: "KB"), String(localized: "MB"),
            String(localized: "GB"), String(localized: "TB"),
        ]
        var size = value
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        let digits = size < 10 && unit > 1 ? 1 : 0
        return size.formatted(.number.precision(.fractionLength(digits))) + " " + units[unit]
    }

    nonisolated static func gigabytes(_ value: some BinaryInteger) -> String {
        bytes(Double(value))
    }

    nonisolated static func percent(_ share: Double) -> String {
        let value = share * 100
        // Below ten percent a whole number lies: half a percent and three
        // percent would both round to the same zero
        let digits = value < 10 && value > 0 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits))) + "%"
    }

    nonisolated static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return String(localized: "\(days)d \(hours)h") }
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m") }
        return String(localized: "\(minutes)m")
    }
}
