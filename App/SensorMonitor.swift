import Foundation

struct FanReading: Identifiable, Equatable {
    let id: Int
    var rpm: Double
    var target: Double
    var minRPM: Double
    var maxRPM: Double
    var manual: Bool

    var fraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

struct PowerReading: Equatable {
    var system: Double?     // W, total system power (SMC PSTR)
    var adapterIn: Double?  // W, power coming in from the adapter (SMC PDTR)
    var battery: Double?    // W, + charging / − discharging
    var batteryPercent: Int?
    var charging = false
    var externalConnected = false
    var adapterWatts: Int?

    /// W the battery adds while the adapter is connected: the Mac draws more than the adapter delivers.
    var deficit: Double? {
        guard externalConnected, let b = battery, b <= -1 else { return nil }
        // The battery sometimes also helps out at low load (e.g. right after a spike, or around the
        // charge limit); only call it a shortfall when the system really asks for more than the adapter gives.
        guard let s = system, let a = adapterIn else { return -b }
        if s <= a { return nil }
        // The battery current lags a few seconds behind; system − adapter does not.
        return max(-b, s - a)
    }
}

struct Sample: Identifiable {
    let id: Int
    let date: Date
    let cpu: Double
    let gpu: Double
    let rpm: Double
    let power: Double
    let typeLoads: [Double] // average load per core type, same order as CPUTopology.types
    let gpuLoad: Double?
}

/// Reads only the few battery values we need, not the whole IORegistry dictionary.
final class BatteryReader {
    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    private func number(_ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
    }

    func read(into p: inout PowerReading) {
        guard service != 0 else { return }
        if let mv = number("Voltage")?.doubleValue, let ma = number("InstantAmperage")?.int64Value {
            p.battery = mv * Double(ma) / 1_000_000
        }
        p.batteryPercent = number("CurrentCapacity")?.intValue
        p.charging = number("IsCharging")?.boolValue ?? false
        p.externalConnected = number("ExternalConnected")?.boolValue ?? false
        let adapter = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        p.adapterWatts = p.externalConnected ? (adapter?["Watts"] as? NSNumber)?.intValue : nil
    }
}

/// Reads the SMC (no root needed). Only use it from one queue.
final class SMCReader {
    private(set) var cpuKeys: [String] = []
    private(set) var gpuKeys: [String] = []
    private(set) var fanCount = 0
    /// "md" on M5-generation Macs, "Md" on earlier Apple Silicon.
    private var modeSuffix = "md"
    let available: Bool

    init() {
        available = smc_open() == KERN_SUCCESS
        guard available else { return }
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<smc_key_count() {
            guard smc_key_at(i, &buf) else { continue }
            let key = String(cString: buf)
            guard key.hasPrefix("T"), let t = read(key), (10...130).contains(t) else { continue }
            if key.hasPrefix("Tp") { cpuKeys.append(key) }
            if key.hasPrefix("Tg") { gpuKeys.append(key) }
        }
        fanCount = Int(read("FNum") ?? 0)
        if read("F0md") == nil, read("F0Md") != nil { modeSuffix = "Md" }
    }

    func read(_ key: String) -> Double? {
        var v = 0.0
        return smc_read_double(key, &v) ? v : nil
    }

    func group(_ keys: [String]) -> (avg: Double, max: Double) {
        let vals = keys.compactMap(read).filter { (10...130).contains($0) }
        guard let hi = vals.max() else { return (0, 0) }
        return (vals.reduce(0, +) / Double(vals.count), hi)
    }

    func power(_ battery: BatteryReader) -> PowerReading {
        var p = PowerReading(system: read("PSTR"), adapterIn: read("PDTR"))
        battery.read(into: &p)
        if !p.externalConnected { p.adapterIn = nil }
        return p
    }

    func fans() -> [FanReading] {
        (0..<fanCount).map { i in
            FanReading(id: i,
                       rpm: read("F\(i)Ac") ?? 0,
                       target: read("F\(i)Tg") ?? 0,
                       minRPM: read("F\(i)Mn") ?? 0,
                       maxRPM: read("F\(i)Mx") ?? 0,
                       manual: (read("F\(i)\(modeSuffix)") ?? 0) != 0)
        }
    }
}

final class SensorMonitor: ObservableObject {
    static let historyLength = 150 // 5 minutes at one sample per 2 s (dashboard open)

    struct Snapshot {
        var cpuAvg = 0.0, cpuMax = 0.0, gpuAvg = 0.0, gpuMax = 0.0
        var fans: [FanReading] = []
        var power = PowerReading()
        /// Shortfall (W) once it occurs in two readings in a row; avoids flicker on short spikes.
        var overdraw: Double?
        var coreLoads: [Double] = [] // per logical CPU, 0...1
        var gpuLoad: Double?
    }

    // One published value per reading, so views redraw only once per round.
    @Published private(set) var ready = false
    @Published private(set) var current = Snapshot()
    @Published private(set) var history: [Sample] = []
    @Published private(set) var topology = CPUTopology(chip: "", types: [], gpuCores: nil)

    var cpuAvg: Double { current.cpuAvg }
    var cpuMax: Double { current.cpuMax }
    var gpuAvg: Double { current.gpuAvg }
    var gpuMax: Double { current.gpuMax }
    var fans: [FanReading] { current.fans }
    var power: PowerReading { current.power }
    var overdraw: Double? { current.overdraw }
    var hottest: Double { max(cpuMax, gpuMax) }
    var anyManual: Bool { fans.contains { $0.manual } }
    var averageRPM: Double { fans.isEmpty ? 0 : fans.map(\.rpm).reduce(0, +) / Double(fans.count) }
    var coreLoads: [Double] { current.coreLoads }
    var gpuLoad: Double? { current.gpuLoad }
    /// Average load of all CPU cores, 0...1.
    var cpuLoad: Double { coreLoads.isEmpty ? 0 : coreLoads.reduce(0, +) / Double(coreLoads.count) }

    /// Average load of one core type, 0...1.
    func load(of type: CoreType) -> Double {
        let loads = type.cores.compactMap { coreLoads.indices.contains($0) ? coreLoads[$0] : nil }
        return loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
    }

    private let queue = DispatchQueue(label: "smc.reader", qos: .utility)
    private var reader: SMCReader?
    private var battery: BatteryReader?
    private let coreReader = CoreLoadReader()
    private let gpuReader = GPULoadReader()
    private var timer: Timer?
    private var seq = 0
    private var overdrawStreak = 0 // >0: readings with a shortfall in a row, <0: without

    init() {
        queue.async { [weak self] in
            let reader = SMCReader()
            let battery = BatteryReader()
            let topology = CPUTopology.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reader = reader
                self.battery = battery
                self.topology = topology
                self.ready = reader.available
                self.poll()
                self.schedule()
            }
        }
    }

    /// Read every 2 s while the dashboard is open or a stress test runs, otherwise every 5 s.
    var dashboardVisible = false {
        didSet { if dashboardVisible != oldValue { schedule() } }
    }
    var stressRunning = false {
        didSet { if stressRunning != oldValue { schedule() } }
    }
    private var fast: Bool { dashboardVisible || stressRunning }

    private func schedule() {
        guard reader != nil else { return }
        timer?.invalidate()
        let interval: TimeInterval = fast ? 2 : 5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = interval / 4 // lets macOS coalesce wake-ups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if fast { poll() }
    }

    private func poll() {
        guard let reader, let battery, reader.available else { return }
        let coreReader = coreReader, gpuReader = gpuReader
        queue.async {
            let cpu = reader.group(reader.cpuKeys)
            let gpu = reader.group(reader.gpuKeys)
            var snap = Snapshot(cpuAvg: cpu.avg, cpuMax: cpu.max, gpuAvg: gpu.avg, gpuMax: gpu.max,
                                fans: reader.fans(), power: reader.power(battery),
                                coreLoads: coreReader.read(), gpuLoad: gpuReader.read())
            DispatchQueue.main.async {
                let deficit = snap.power.deficit
                if deficit != nil {
                    self.overdrawStreak = max(self.overdrawStreak, 0) + 1
                } else {
                    self.overdrawStreak = min(self.overdrawStreak, 0) - 1
                }
                let wasActive = self.current.overdraw != nil
                let active = self.overdrawStreak >= 2 || (wasActive && self.overdrawStreak > -2)
                snap.overdraw = active ? (deficit ?? self.current.overdraw) : nil
                self.current = snap
                self.seq += 1
                self.history.append(Sample(id: self.seq, date: Date(), cpu: cpu.max, gpu: gpu.max,
                                           rpm: self.averageRPM, power: snap.power.system ?? 0,
                                           typeLoads: self.topology.types.map(self.load(of:)),
                                           gpuLoad: snap.gpuLoad))
                if self.history.count > Self.historyLength {
                    self.history.removeFirst(self.history.count - Self.historyLength)
                }
            }
        }
    }
}
