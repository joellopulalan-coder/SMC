import AppKit
import Darwin
import Foundation
import IOKit

/// One row in the activity list: an app (with all its helper processes) or a single process.
struct ProcessGroup: Identifiable, Equatable {
    let id: String          // app bundle path, "exe:<path>" for other programs, or "pid:<n>" when unknown
    let name: String
    let bundlePath: String? // for the icon
    var cpu: Double         // percent of one core, like Activity Monitor (can exceed 100)
    var watts: Double
    var processCount: Int
    var usingGPU: Bool
}

/// Samples CPU time and energy per process. Only processes owned by this user can be read without
/// root (about two thirds on a typical Mac); the rest shows up as "other system processes".
/// Use from one queue only.
final class ProcessSampler {
    private struct Previous { let cpuNs: UInt64; let energyNj: UInt64 }
    private struct Identity { let name: String; let group: String; let bundlePath: String? }

    private var previous: [pid_t: Previous] = [:]
    private var identities: [pid_t: (start: UInt64, identity: Identity)] = [:]
    private var lastGPUSubmit: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Groups sorted by CPU, and the CPU (percent of one core) of all readable processes together.
    /// Empty on the first call, which only records a baseline.
    func sample() -> (groups: [ProcessGroup], readableCPU: Double) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now &- lastTime)
        // After a long pause (dashboard closed) start over instead of averaging over minutes.
        let firstRun = lastTime == 0 || elapsed > 15e9
        lastTime = now
        let gpuActive = activeGPUClients()

        var current: [pid_t: Previous] = [:]
        var groups: [String: ProcessGroup] = [:]
        var readable = 0.0

        for pid in allPIDs() {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0 else { continue }
            let cpuNs = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
            current[pid] = Previous(cpuNs: cpuNs, energyNj: info.ri_energy_nj)
            guard !firstRun, let old = previous[pid], cpuNs >= old.cpuNs else { continue }

            let cpu = Double(cpuNs - old.cpuNs) / elapsed * 100
            let watts = Double(info.ri_energy_nj &- old.energyNj) / elapsed
            readable += cpu
            let id = identity(pid, start: info.ri_proc_start_abstime)
            var group = groups[id.group] ?? ProcessGroup(id: id.group, name: id.name, bundlePath: id.bundlePath,
                                                         cpu: 0, watts: 0, processCount: 0, usingGPU: false)
            group.cpu += cpu
            group.watts += watts
            group.processCount += 1
            group.usingGPU = group.usingGPU || gpuActive.contains(pid)
            groups[id.group] = group
        }
        previous = current
        identities = identities.filter { current[$0.key] != nil } // forget exited processes
        return (groups.values.sorted { $0.cpu > $1.cpu }, readable)
    }

    private func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    /// Name and group of a process, cached per pid (and start time, so a reused pid is looked up again).
    private func identity(_ pid: pid_t, start: UInt64) -> Identity {
        if let cached = identities[pid], cached.start == start { return cached.identity }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let processName = String(cString: nameBuffer).isEmpty ? (path as NSString).lastPathComponent : String(cString: nameBuffer)

        // Group helpers under the outermost app bundle, e.g. all of Google Chrome's helpers.
        let identity: Identity
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.lowerBound]) + ".app"
            let name = FileManager.default.displayName(atPath: bundle).replacingOccurrences(of: ".app", with: "")
            identity = Identity(name: name, group: bundle, bundlePath: bundle)
        } else {
            // Plain processes are grouped per executable, so e.g. several compiler jobs form one row.
            identity = Identity(name: processName.isEmpty ? "pid \(pid)" : processName,
                                group: path.isEmpty ? "pid:\(pid)" : "exe:" + path, bundlePath: nil)
        }
        identities[pid] = (start, identity)
        return identity
    }

    /// Processes that submitted GPU work since the previous sample. The GPU driver keeps a
    /// "last submitted" timestamp per client; its GPU-time counters are not reliable enough for percentages.
    private func activeGPUClients() -> Set<pid_t> {
        let accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accelerator != 0 else { return [] }
        defer { IOObjectRelease(accelerator) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var latest: [pid_t: UInt64] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString,
                                                                kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  creator.hasPrefix("pid "),
                  let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                  let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? [[String: Any]] else { continue }
            let submitted = usage.compactMap { ($0["lastSubmittedTime"] as? NSNumber)?.uint64Value }.max() ?? 0
            latest[pid] = max(latest[pid] ?? 0, submitted)
        }
        defer { lastGPUSubmit = latest }
        return Set(latest.filter { pid, time in (lastGPUSubmit[pid].map { time > $0 } ?? false) }.keys)
    }
}

/// App icons, loaded once per bundle.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundlePath: String?) -> NSImage {
        guard let bundlePath else {
            return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        }
        if let cached = cache[bundlePath] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        cache[bundlePath] = icon
        return icon
    }
}
