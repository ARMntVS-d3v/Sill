import Darwin
import Foundation
import IOKit
import IOKit.ps

// All system calls in one place: sysctl, mach, IORegistry, getifaddrs.
// No access to app state anywhere here — just reading metrics.
enum SystemProbe {
    // MARK: - sysctl

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlNumber(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        var small: UInt32 = 0
        var smallSize = MemoryLayout<UInt32>.size
        guard sysctlbyname(name, &small, &smallSize, nil, 0) == 0 else { return nil }
        return UInt64(small)
    }

    static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    // MARK: - CPU

    /// Cumulative ticks: the kernel doesn't expose instantaneous load, it's derived from the delta between samples
    static func cpuTotals() -> (used: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let used = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        return (used, used + UInt64(info.cpu_ticks.2))
    }

    static func cpuPerCore() -> [(used: UInt64, total: UInt64)] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }

        var result: [(used: UInt64, total: UInt64)] = []
        let states = Int(CPU_STATE_MAX)
        for core in 0..<Int(count) {
            let base = core * states
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let used = user + system + nice
            result.append((used, used + idle))
        }
        return result
    }

    // MARK: - processes

    struct ProcessSample: Sendable {
        var pid: pid_t
        var name: String
        var cpuSeconds: Double
        var memory: UInt64
    }

    // Top processes via libproc: a thousand processes cost under 2ms, so this
    // is cheap enough to do on every sample
    static func processes() -> [ProcessSample] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var result: [ProcessSample] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) where pids[index] > 0 {
            let pid = pids[index]
            var info = rusage_info_current()
            let read = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard read == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            let name = String(cString: buffer)
            guard !name.isEmpty else { continue }
            result.append(
                ProcessSample(
                    pid: pid,
                    name: name,
                    cpuSeconds: Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000,
                    memory: info.ri_resident_size))
        }
        return result
    }

    // MARK: - memory

    static func memoryStats() -> (active: UInt64, wired: UInt64, compressed: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        return (
            UInt64(stats.active_count) * page,
            UInt64(stats.wire_count) * page,
            UInt64(stats.compressor_page_count) * page)
    }

    /// Swap: Activity Monitor shows it separately, and for good reason — once
    /// swap fills up, the machine bogs down even with "free" memory
    static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// Memory pressure as reported by the kernel: 1 = normal, 2 = warning, 4 = critical
    static func memoryPressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return 1 }
        return Int(level)
    }

    // MARK: - GPU

    // GPU load lives in IORegistry on the IOAccelerator class, in the
    // PerformanceStatistics dictionary. There's no public API for it — Stats reads it the same way
    static func gpuStatistics() -> (
        utilization: Double, renderer: Double, tiler: Double, memoryUsed: UInt64, name: String
    ) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return (0, 0, 0, 0, "") }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        var best = (utilization: 0.0, renderer: 0.0, tiler: 0.0, memoryUsed: UInt64(0), name: "")
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            else { continue }

            // Numbers arrive as CFNumber: going through NSNumber handles both integers and fractions
            let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0
            let renderer = (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue ?? 0
            let tiler = (stats["Tiler Utilization %"] as? NSNumber)?.doubleValue ?? 0
            let memory = (stats["In use system memory"] as? NSNumber)?.doubleValue ?? 0
            var name = ""
            if let model = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "model" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) {
                if let data = model as? Data {
                    name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
                } else if let text = model as? String {
                    name = text
                }
                // "Apple M4 Pro" in the GPU label — the word Apple is redundant
                name = name.replacingOccurrences(of: "Apple ", with: "")
            }
            // Pick the most heavily loaded accelerator: Macs can have more than one
            if utilization >= best.utilization {
                best = (utilization / 100, renderer / 100, tiler / 100, UInt64(memory), name)
            }
        }
        return best
    }

    // MARK: - network

    // Counted across every active interface except loopback: Wi-Fi, Ethernet, VPN
    static func networkCounters() -> (
        input: UInt64, output: UInt64, interface: String, address: String
    ) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0, "", "") }
        defer { freeifaddrs(pointer) }

        var input: UInt64 = 0
        var output: UInt64 = 0
        var interface = ""
        var address = ""

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            // Physical interfaces only: VPN tunnels mirror the same traffic, and
            // the total speed would come out double the real figure
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let family = entry.pointee.ifa_addr?.pointee.sa_family

            if family == UInt8(AF_LINK), let data = entry.pointee.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                input += UInt64(stats.ifi_ibytes)
                output += UInt64(stats.ifi_obytes)
            }
            // The address shown is from the first interface with a real IPv4
            if family == UInt8(AF_INET), address.isEmpty, name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    entry.pointee.ifa_addr, socklen_t(entry.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    interface = name
                }
            }
        }
        return (input, output, interface, address)
    }

    // MARK: - disk

    static func diskSpace() -> (total: Int64, free: Int64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return (0, 0) }
        return (
            Int64(values.volumeTotalCapacity ?? 0),
            values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static func volumeName() -> String {
        let url = URL(fileURLWithPath: "/")
        return (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Macintosh HD"
    }

    // Read/write counters for block storage devices
    static func diskCounters() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            else { continue }
            read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }

    // MARK: - device batteries

    /// Battery level for headphones, mouse, and keyboard. There's no public API
    /// for this, so we read the system_profiler report — it returns the same
    /// data the system itself shows. Costs about a quarter second and an
    /// external process, so it's only called once a minute
    static func deviceBatteries() async -> [SystemMetrics.DeviceBattery] {
        let task = Process()
        task.executableURL = URL(filePath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = json["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var result: [SystemMetrics.DeviceBattery] = []
        for section in sections {
            // Battery level only exists for connected devices — disconnected ones show a stale value
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, raw) in entry {
                    guard let info = raw as? [String: Any] else { continue }
                    let kind = (info["device_minorType"] as? String) ?? ""
                    let icon = deviceIcon(for: kind, name: name)

                    // Headphones have three levels: two ears and a case. We show
                    // the lower of the two ears, and the case goes into the
                    // detail caption — that's the order people actually need it in
                    let left = percent(info["device_batteryLevelLeft"])
                    let right = percent(info["device_batteryLevelRight"])
                    let caseLevel = percent(info["device_batteryLevelCase"])
                    let main = percent(info["device_batteryLevelMain"])

                    // Headphones and the case charge separately and drain at
                    // different rates, so these are two entries, not one with a caption
                    if let left, let right {
                        result.append(
                            .init(
                                name: name, icon: icon, percent: min(left, right),
                                detail: left == right ? nil : "\(left)% / \(right)%"))
                        if let caseLevel {
                            result.append(
                                .init(
                                    name: String(localized: "Case"), icon: "airpodspro.chargingcase.wireless",
                                    percent: caseLevel, detail: nil))
                        }
                    } else if let single = main ?? left ?? right {
                        result.append(.init(name: name, icon: icon, percent: single, detail: nil))
                    } else if let caseLevel {
                        result.append(
                            .init(
                                name: String(localized: "\(name) · case"),
                                icon: "airpodspro.chargingcase.wireless",
                                percent: caseLevel, detail: nil))
                    }
                }
            }
        }
        return result.sorted { $0.percent < $1.percent }
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func deviceIcon(for kind: String, name: String) -> String {
        let lower = (kind + " " + name).lowercased()
        if lower.contains("headphone") || lower.contains("airpod") { return "airpods.pro" }
        if lower.contains("mouse") { return "magicmouse" }
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("trackpad") { return "trackpad" }
        if lower.contains("watch") { return "applewatch" }
        if lower.contains("phone") { return "iphone" }
        return "dot.radiowaves.left.and.right"
    }

    // MARK: - battery

    static func batteryDetails() -> SystemMetrics.Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
              let current = info[kIOPSCurrentCapacityKey] as? Int
        else { return nil }

        var battery = SystemMetrics.Battery()
        battery.percent = current
        battery.charging = info[kIOPSIsChargingKey] as? Bool ?? false
        battery.plugged = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let minutes = info[kIOPSTimeToEmptyKey] as? Int
        battery.minutesLeft = (minutes ?? -1) > 0 ? minutes : nil
        let toFull = info[kIOPSTimeToFullChargeKey] as? Int
        battery.minutesToFull = (toFull ?? -1) > 0 ? toFull : nil

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return battery }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        battery.cycles = property("CycleCount") as? Int
        // Health is the ratio of actual capacity to design capacity. The
        // MaxCapacity key doesn't work for this: it's always 100 and means the
        // top of the charge scale, not wear. The system shows its own number
        // (its own calibration); we compute it the way coconutBattery and Stats
        // do — from the nominal capacity
        if let design = property("DesignCapacity") as? Int, design > 0 {
            let full = (property("NominalChargeCapacity") as? Int)
                ?? (property("AppleRawMaxCapacity") as? Int)
            battery.health = full.map { Int((Double($0) / Double(design) * 100).rounded()) }
        }
        if let temperature = property("Temperature") as? Int {
            battery.temperature = Double(temperature) / 100
        }
        // Watts: current in mA and voltage in mV
        if let amperage = property("Amperage") as? Int, let voltage = property("Voltage") as? Int {
            battery.watts = abs(Double(amperage) * Double(voltage)) / 1_000_000
        }
        return battery
    }
}
