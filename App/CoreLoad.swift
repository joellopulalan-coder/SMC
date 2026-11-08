import Darwin
import Foundation
import IOKit
import SwiftUI

/// One kind of CPU core, as macOS reports it in `hw.perflevelN` (0 = fastest).
/// M1–M4: Performance + Efficiency. M5: Super + Performance. Ultra chips: the same types, more clusters.
struct CoreType: Identifiable {
    let id: Int             // perflevel index
    let systemName: String  // "Super", "Performance", "Efficiency", … as macOS names it
    let clusters: [[Int]]   // logical CPU ids, grouped per cluster

    var cores: [Int] { clusters.flatMap { $0 } }

    var title: String {
        switch systemName {
        case "Super": tr("Super cores")
        case "Performance": tr("Performance cores")
        case "Efficiency": tr("Efficiency cores")
        default: tr("%@ cores", systemName)
        }
    }

    var color: Color {
        switch systemName {
        case "Super": .pink
        case "Performance": .orange
        case "Efficiency": .green
        default: .gray
        }
    }
}

struct CPUTopology {
    let chip: String
    let types: [CoreType]
    let gpuCores: Int?

    var cpuCount: Int { types.reduce(0) { $0 + $1.cores.count } }

    /// Reads core types from sysctl and maps every logical CPU to one through the device tree.
    static func read() -> CPUTopology {
        let levels = (0..<max(sysctlInt("hw.nperflevels") ?? 1, 1)).map { i in
            (name: sysctlString("hw.perflevel\(i).name") ?? "CPU",
             count: sysctlInt("hw.perflevel\(i).logicalcpu") ?? 0,
             perL2: sysctlInt("hw.perflevel\(i).cpusperl2") ?? 0)
        }
        let cpus = deviceTreeCPUs()

        // Cluster types in the device tree: "P" = fastest, "M" = middle (M5), "E" = efficiency.
        // Ranked fastest first, they line up with the perflevels.
        func rank(_ t: String) -> Int { ["P": 0, "M": 1, "E": 2][t] ?? 3 }
        let deviceTypes = Set(cpus.map(\.type)).sorted { (rank($0), $0) < (rank($1), $1) }
        let matches = deviceTypes.count == levels.count && zip(deviceTypes, levels).allSatisfy { t, level in
            cpus.filter { $0.type == t }.count == level.count
        }

        var types: [CoreType] = []
        if matches {
            for (i, t) in deviceTypes.enumerated() {
                let mine = cpus.filter { $0.type == t }
                let clusters = Dictionary(grouping: mine, by: \.cluster).sorted { $0.key < $1.key }
                    .map { $0.value.map(\.id).sorted() }
                types.append(CoreType(id: i, systemName: levels[i].name, clusters: clusters))
            }
        } else {
            // Fallback: macOS numbers the slowest cores first, so the fastest level gets the highest ids.
            var next = 0
            for (i, level) in levels.enumerated().reversed() {
                let ids = Array(next..<next + level.count)
                next += level.count
                let size = level.perL2 > 0 ? level.perL2 : max(ids.count, 1)
                let clusters = stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
                types.append(CoreType(id: i, systemName: level.name, clusters: clusters))
            }
            types.sort { $0.id < $1.id }
        }
        return CPUTopology(chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
                           types: types, gpuCores: GPULoadReader.coreCount())
    }

    private static func deviceTreeCPUs() -> [(id: Int, cluster: Int, type: String)] {
        let parent = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard parent != 0 else { return [] }
        defer { IOObjectRelease(parent) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [(Int, Int, String)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let id = (property("logical-cpu-id") as? NSNumber)?.intValue,
                  let typeData = property("cluster-type") as? Data,
                  let type = String(data: typeData.prefix { $0 != 0 }, encoding: .ascii) else { continue }
            let cluster = (property("logical-cluster-id") as? NSNumber)?.intValue ?? 0
            result.append((id, cluster, type))
        }
        return result
    }
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

/// Per-core CPU load from the kernel's tick counters: one Mach call per reading.
final class CoreLoadReader {
    private var previous: [[UInt32]] = []

    /// Load per logical CPU (0...1) since the previous call; empty on the first call.
    func read() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * 4) }

        let states = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(count)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
        defer { previous = ticks }
        guard previous.count == ticks.count else { return [] }
        return zip(previous, ticks).map { old, new in
            let delta = (0..<states).map { Double(new[$0] &- old[$0]) } // counters may wrap
            let total = delta.reduce(0, +)
            return total > 0 ? (total - delta[Int(CPU_STATE_IDLE)]) / total : 0
        }
    }
}

/// GPU utilization as reported by the GPU driver (IOAccelerator performance statistics).
final class GPULoadReader {
    private let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// 0...1, or nil when the driver doesn't report it.
    func read() -> Double? {
        guard service != 0,
              let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let pct = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return nil }
        return min(max(pct / 100, 0), 1)
    }

    static func coreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }
}
