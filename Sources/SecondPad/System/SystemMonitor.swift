import AppKit
import Darwin
import IOKit.ps

/// What the Mac health strip and the battery show. Sent once a second.
nonisolated struct SystemStats: Encodable, Equatable, Sendable {
    let type = "stats"
    var cpuPercent: Double = 0
    var topProcess: String?
    var topProcessCPU: Double?
    var ramPercent: Double = 0
    var ramUsedGB: Double = 0
    var ramTotalGB: Double = 0
    var compressedGB: Double = 0
    var swapUsedGB: Double = 0
    var swapTotalGB: Double = 0
    var swapInMBs: Double = 0
    var swapOutMBs: Double = 0
    /// macOS: 1 normal, 2 warning, 4 critical.
    var memoryPressure: Int = 1
    var uptimeDays: Double = 0
    var temperature: Double?
    /// 0 = fan stopped, 1 = at maximum; nil when there is no fan / no SMC.
    var fanLoad: Double?
    var batteryPercent: Int?
    var batteryCharging: Bool?
    /// Sustained peaks (5 s, with hysteresis): the Deep Focus page shows a chip.
    var cpuPeak = false
    var heatPeak = false
    var memoryPeak = false
    // For the detail sheets.
    var coreLoads: [Double] = []
    var performanceCores: Int?
    var topCPU: [ProcessRow] = []
    var topMemory: [ProcessRow] = []
    var sensors: [Sensor] = []
    var fanRPM: Int?
    var fanMaxRPM: Int?
    /// nominal | fair | serious | critical
    var thermalState = "nominal"

    private enum CodingKeys: String, CodingKey {
        case type, cpuPercent, topProcess, topProcessCPU, ramPercent, ramUsedGB, ramTotalGB, compressedGB,
             swapUsedGB, swapTotalGB, swapInMBs, swapOutMBs, memoryPressure, uptimeDays, temperature, fanLoad,
             batteryPercent, batteryCharging, cpuPeak, heatPeak, memoryPeak, coreLoads, performanceCores,
             topCPU, topMemory, sensors, fanRPM, fanMaxRPM, thermalState
    }
}

/// One process in a sheet's list. `bundleId` when it is a running app (its icon is shown).
nonisolated struct ProcessRow: Encodable, Equatable, Sendable {
    let name: String
    var cpu: Double = 0
    var memoryMB: Double = 0
    var bundleId: String?
}

nonisolated struct Sensor: Encodable, Equatable, Sendable {
    let name: String
    let celsius: Double
}

/// A value that must stay past `enter` for `hold` seconds to switch on, and drop below `exit` to
/// switch off again. One noisy second is not a peak. Pure, unit-tested.
nonisolated struct PeakGate: Sendable {
    let enter: Double
    let exit: Double
    var hold: TimeInterval = 5
    private(set) var on = false
    private var since: Date?

    init(enter: Double, exit: Double, hold: TimeInterval = 5) {
        self.enter = enter
        self.exit = exit
        self.hold = hold
    }

    mutating func feed(_ value: Double?, now: Date) -> Bool {
        guard let value else { return on }
        let want = on ? value >= exit : value >= enter
        if want == on { since = nil; return on }
        let start = since ?? now
        since = start
        if now.timeIntervalSince(start) >= hold { on = want; since = nil }
        return on
    }
}

/// Reads CPU, memory, swap, battery, temperature and fan. Public APIs plus the SMC (read only).
final class SystemMonitor {

    nonisolated static let pageSize: Int = {
        var size = 0
        var length = MemoryLayout<Int>.size
        return sysctlbyname("hw.pagesize", &size, &length, nil, 0) == 0 && size > 0 ? size : 16_384
    }()

    private var previousCPU: host_cpu_load_info?
    private var lastSwap: (ins: UInt64, outs: UInt64, at: Date)?
    private let smc = SMCReader()
    private var sensor: SensorReading?
    private var lastSensorRead: Date?
    private var topProcess: (name: String, cpu: Double)?
    private var processes = ProcessTops()
    private var previousCores: [[UInt32]] = []
    private var lastProcessRead: Date?
    private var readingProcesses = false
    private var cpuGate = PeakGate(enter: 85, exit: 70)
    private var heatGate = PeakGate(enter: 95, exit: 90)
    /// Memory: real stalls only — pressure critical, or warning while swapping right now (≥ 5 MB/s).
    private var memoryGate = PeakGate(enter: 1, exit: 1)
    /// Heat is judged on the temperature smoothed over ~10 s, so one spike doesn't light it up.
    private var smoothTemp: Double?
    private var lastPeakFeed: Date?

    func sample(now: Date = Date()) -> SystemStats {
        var s = SystemStats()
        s.cpuPercent = cpu()
        let memory = Self.memory()
        s.ramPercent = memory.percent
        s.ramUsedGB = memory.usedGB
        s.ramTotalGB = memory.totalGB
        s.compressedGB = memory.compressedGB
        let swap = Self.swapUsage()
        s.swapUsedGB = swap.used
        s.swapTotalGB = swap.total
        let io = swapActivity(stats: memory.stats, now: now)
        s.swapInMBs = io.ins
        s.swapOutMBs = io.outs
        s.memoryPressure = Self.memoryPressure()
        s.uptimeDays = Self.uptimeDays()
        let battery = Self.battery()
        s.batteryPercent = battery.percent
        s.batteryCharging = battery.charging

        if lastSensorRead.map({ now.timeIntervalSince($0) >= 3 }) ?? true, let smc {
            sensor = smc.read()
            lastSensorRead = now
        }
        s.temperature = sensor?.temperature
        s.fanLoad = sensor?.fanLoad
        s.fanRPM = sensor?.fanRPM
        s.fanMaxRPM = sensor?.fanMaxRPM
        s.sensors = Self.sensorRows(sensor?.sensors ?? [])
        s.thermalState = Self.thermalName(ProcessInfo.processInfo.thermalState)
        s.coreLoads = coreLoads()
        s.performanceCores = Self.performanceCores

        refreshTopProcess(now: now)
        s.topProcess = topProcess?.name
        s.topProcessCPU = topProcess?.cpu
        s.topCPU = processes.cpu
        s.topMemory = processes.memory

        s.cpuPeak = cpuGate.feed(s.cpuPercent, now: now)
        smoothTemp = Self.smooth(smoothTemp, s.temperature, dt: lastPeakFeed.map { now.timeIntervalSince($0) } ?? 10)
        lastPeakFeed = now
        s.heatPeak = heatGate.feed(smoothTemp, now: now)
        s.memoryPeak = memoryGate.feed(Self.memoryStall(pressure: s.memoryPressure, swapMBs: s.swapInMBs + s.swapOutMBs) ? 1 : 0, now: now)
        return s
    }

    /// Exponential smoothing with a 10 s time constant (depends on time, not on sample count).
    nonisolated static func smooth(_ previous: Double?, _ value: Double?, dt: TimeInterval) -> Double? {
        guard let value else { return previous }
        guard let previous else { return value }
        return previous + (1 - exp(-max(0, dt) / 10)) * (value - previous)
    }

    nonisolated static func memoryStall(pressure: Int, swapMBs: Double) -> Bool {
        pressure >= 4 || (pressure >= 2 && swapMBs >= 5)
    }

    // MARK: - CPU

    private func cpu() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var load = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        defer { previousCPU = load }
        guard let prev = previousCPU else { return 0 }
        let user = Double(load.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        return total > 0 ? min(100, max(0, (user + system + nice) / total * 100)) : 0
    }

    /// Load of each core since the last sample, 0…100.
    private func coreLoads() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for core in 0..<Int(count) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[core * states + $0]) })
        }
        defer { previousCores = ticks }
        guard previousCores.count == ticks.count else { return Array(repeating: 0, count: ticks.count) }
        return zip(ticks, previousCores).map { now, before in
            let d = (0..<states).map { Double(now[$0] &- before[$0]) }
            let total = d.reduce(0, +)
            let idle = d[Int(CPU_STATE_IDLE)]
            return total > 0 ? min(100, max(0, (total - idle) / total * 100)) : 0
        }
    }

    nonisolated static let performanceCores: Int? = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : nil
    }()

    nonisolated static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }

    /// SMC keys → plain names: "TCMz" is the chip's hottest point; the rest are CPU sensors.
    nonisolated static func sensorRows(_ readings: [(key: String, celsius: Double)]) -> [Sensor] {
        var n = 0
        return readings.map { reading in
            if reading.key == "TCMz" { return Sensor(name: "Chip (hottest point)", celsius: reading.celsius) }
            n += 1
            return Sensor(name: "CPU sensor \(n)", celsius: reading.celsius)
        }
    }

    // MARK: - Memory and swap

    private static func memory() -> (percent: Double, usedGB: Double, totalGB: Double, compressedGB: Double,
                                     stats: vm_statistics64_data_t?) {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let gb = 1_073_741_824.0
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, total / gb, 0, nil) }
        let page = Double(SystemMonitor.pageSize)
        // Close to Activity Monitor's "Memory Used": app (active) + wired + compressed.
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let compressed = Double(stats.compressor_page_count) * page
        let percent = total > 0 ? min(100, max(0, used / total * 100)) : 0
        return (percent, used / gb, total / gb, compressed / gb, stats)
    }

    private static func swapUsage() -> (used: Double, total: Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(usage.xsu_used) / 1_073_741_824, Double(usage.xsu_total) / 1_073_741_824)
    }

    /// MB/s written to and read from swap since the last sample.
    private func swapActivity(stats: vm_statistics64_data_t?, now: Date) -> (ins: Double, outs: Double) {
        guard let stats else { return (0, 0) }
        defer { lastSwap = (stats.swapins, stats.swapouts, now) }
        guard let last = lastSwap else { return (0, 0) }
        let seconds = max(0.5, now.timeIntervalSince(last.at))
        let page = Double(SystemMonitor.pageSize) / 1_048_576
        return (max(0, Double(stats.swapins &- last.ins) * page / seconds),
                max(0, Double(stats.swapouts &- last.outs) * page / seconds))
    }

    private static func memoryPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return Int(level)
    }

    private static func uptimeDays() -> Double {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return (Date().timeIntervalSince1970 - Double(boot.tv_sec)) / 86_400
    }

    // MARK: - Battery

    private static func battery() -> (percent: Int?, charging: Bool?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil) }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let percent = info[kIOPSCurrentCapacityKey] as? Int
            let charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (percent, charging)
        }
        return (nil, nil)
    }

    // MARK: - Processes (`ps` every 4 s, off the main thread)

    struct ProcessTops: Equatable {
        var cpu: [ProcessRow] = []
        var memory: [ProcessRow] = []
    }

    private func refreshTopProcess(now: Date) {
        guard !readingProcesses, lastProcessRead.map({ now.timeIntervalSince($0) >= 4 }) ?? true else { return }
        readingProcesses = true
        lastProcessRead = now
        Task.detached(priority: .utility) {
            let output = Self.readPS()
            await MainActor.run {
                defer { self.readingProcesses = false }
                guard let output else { return }
                var tops = Self.parseProcesses(output, cores: ProcessInfo.processInfo.activeProcessorCount)
                // Running apps get their bundle id, so the tablet can show the real icon.
                let apps = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
                    guard let id = app.bundleIdentifier, let exe = app.executableURL?.lastPathComponent else { return nil }
                    return (exe, id)
                }, uniquingKeysWith: { first, _ in first })
                for i in tops.cpu.indices { tops.cpu[i].bundleId = apps[tops.cpu[i].name] }
                for i in tops.memory.indices { tops.memory[i].bundleId = apps[tops.memory[i].name] }
                self.processes = tops
                if let first = tops.cpu.first { self.topProcess = (first.name, first.cpu) }
            }
        }
    }

    nonisolated private static func readPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pcpu,rss,comm", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `ps -Aceo pcpu,rss,comm -r` → the 6 busiest processes and the 6 biggest by memory (helpers of
    /// one app with the same name are added up). Pure, unit-tested.
    /// `ps` gives a process's CPU per core (380 % = 3.8 cores); it is divided by the core count so it
    /// reads on the same 0…100 % scale as the Mac's own CPU number.
    nonisolated static func parseProcesses(_ output: String, cores: Int = 1) -> ProcessTops {
        var cpu: [ProcessRow] = []
        var memory: [String: Double] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let load = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
                  let rss = Double(parts[1]) else { continue }
            let raw = parts[2].trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty, !raw.contains("M-") else { continue }
            let name = raw.count > 38 ? String(raw.prefix(38)) + "…" : raw
            if cpu.count < 6 { cpu.append(ProcessRow(name: name, cpu: load / Double(max(1, cores)))) }
            memory[name, default: 0] += rss / 1024
        }
        let mem = memory.sorted { $0.value > $1.value }.prefix(6).map { ProcessRow(name: $0.key, memoryMB: $0.value) }
        return ProcessTops(cpu: cpu, memory: Array(mem))
    }
}
