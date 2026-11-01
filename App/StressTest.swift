import Foundation
import Metal

/// GPU load: a Metal compute kernel with long FMA chains, always two command buffers in flight.
final class GPUStress {
    private static let source = """
    #include <metal_stdlib>
    kernel void burn(device float *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
        float a = i * 0.0001f, b = 1.0001f, c = 0.5f, d = 0.25f;
        for (int k = 0; k < 8192; k++) {
            a = metal::fma(a, b, 0.5f);
            b = metal::fma(b, 0.9999f, 0.00001f);
            c = metal::fma(c, 0.9999f, 0.25f);
            d = metal::fma(d, b, 0.125f);
        }
        out[i] = a + b + c + d;
    }
    """
    private static let threads = 1 << 22
    /// 4 FMAs (= 8 flops) per iteration, 8192 iterations per thread.
    static let flopsPerDispatch = Double(threads) * 8192 * 8

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let lock = NSLock()
    private var running = false
    private var completed: UInt64 = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "burn"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let buffer = device.makeBuffer(length: Self.threads * 4, options: .storageModePrivate)
        else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.buffer = buffer
    }

    var dispatches: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    func start() {
        lock.lock()
        running = true
        completed = 0
        lock.unlock()
        enqueue()
        enqueue()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func enqueue() {
        guard let cb = queue.makeCommandBuffer(), let encoder = cb.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: Self.threads, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth * 8, height: 1, depth: 1))
        encoder.endEncoding()
        cb.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.completed += 1
            let again = self.running
            self.lock.unlock()
            if again { self.enqueue() }
        }
        cb.commit()
    }
}

enum StressMode: String, CaseIterable, Identifiable, Codable {
    case cpu, gpu, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .both: tr("CPU + GPU")
        }
    }
    var usesCPU: Bool { self != .gpu }
    var usesGPU: Bool { self != .cpu }
}

enum StressDuration: Int, CaseIterable, Identifiable {
    case oneMinute = 60, threeMinutes = 180, tenMinutes = 600, untilStopped = 0

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .oneMinute: tr("1 min")
        case .threeMinutes: tr("3 min")
        case .tenMinutes: tr("10 min")
        case .untilStopped: tr("Until stopped")
        }
    }
}

struct StressResult: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let mode: StressMode
    let seconds: Int
    let profile: String
    let maxTemp: Double
    let avgPower: Double
    let maxPower: Double
    let maxFanRPM: Double
    let maxDeficit: Double?
    let cpuStart: Double?, cpuEnd: Double? // GFLOPS
    let gpuStart: Double?, gpuEnd: Double?

    /// Performance lost between start and end (thermal throttling), in percent.
    static func drop(_ start: Double?, _ end: Double?) -> Double? {
        guard let start, let end, start > 0 else { return nil }
        return max(0, (start - end) / start * 100)
    }
    var cpuDrop: Double? { Self.drop(cpuStart, cpuEnd) }
    var gpuDrop: Double? { Self.drop(gpuStart, gpuEnd) }
}

/// Runs a stress test, measures the score every second and keeps the latest results.
final class StressTest: ObservableObject {
    private struct Tick {
        let cpu: Double?, gpu: Double?, temp: Double, power: Double?, rpm: Double, deficit: Double?
    }

    @Published var mode: StressMode = .both
    @Published var duration: StressDuration = .threeMinutes
    @Published private(set) var running = false
    @Published private(set) var elapsed = 0
    @Published private(set) var cpuScore: Double?
    @Published private(set) var gpuScore: Double?
    @Published private(set) var results: [StressResult] = []
    @Published private(set) var gpuUnavailable = false

    private static let resultsKey = "stressResults"
    private static let maxResults = 10

    private weak var monitor: SensorMonitor?
    private var profileTitle = ""
    private var gpu: GPUStress?
    private var timer: Timer?
    private var ticks: [Tick] = []
    private var lastCPUBlocks: UInt64 = 0
    private var lastGPUDispatches: UInt64 = 0
    private var lastTick = Date()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.resultsKey),
           let saved = try? JSONDecoder().decode([StressResult].self, from: data) {
            results = saved
        }
    }

    var remaining: Int? {
        duration == .untilStopped ? nil : max(0, duration.rawValue - elapsed)
    }

    func start(monitor: SensorMonitor, profile: String) {
        guard !running else { return }
        self.monitor = monitor
        profileTitle = profile
        ticks = []
        elapsed = 0
        cpuScore = nil
        gpuScore = nil
        lastCPUBlocks = 0
        lastGPUDispatches = 0
        lastTick = Date()

        if mode.usesCPU {
            stress_cpu_start(Int32(ProcessInfo.processInfo.activeProcessorCount))
        }
        if mode.usesGPU {
            gpu = GPUStress() // only load Metal when a test runs
            gpuUnavailable = gpu == nil
            gpu?.start()
        }
        running = true
        monitor.stressRunning = true

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard running else { return }
        timer?.invalidate()
        timer = nil
        stress_cpu_stop()
        gpu?.stop()
        gpu = nil // free buffer and pipeline; the app should stay light between tests
        running = false
        monitor?.stressRunning = false
        saveResult()
    }

    func clearResults() {
        results = []
        UserDefaults.standard.removeObject(forKey: Self.resultsKey)
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        elapsed += 1

        if mode.usesCPU {
            let blocks = stress_cpu_blocks()
            cpuScore = Double(blocks - lastCPUBlocks) * STRESS_CPU_FLOPS_PER_BLOCK / dt / 1e9
            lastCPUBlocks = blocks
        }
        if mode.usesGPU, let gpu {
            let n = gpu.dispatches
            gpuScore = Double(n - lastGPUDispatches) * GPUStress.flopsPerDispatch / dt / 1e9
            lastGPUDispatches = n
        }
        if let m = monitor {
            ticks.append(Tick(cpu: cpuScore, gpu: gpuScore, temp: m.hottest, power: m.power.system,
                              rpm: m.averageRPM, deficit: m.overdraw))
        }
        if let remaining, remaining == 0 { stop() }
    }

    private func saveResult() {
        guard ticks.count >= 10 else { return } // too short to say anything
        // Start: seconds 3–10 (after spin-up); end: the last 20% of the test.
        let begin = Array(ticks[2..<min(10, ticks.count)])
        let end = Array(ticks.suffix(max(5, ticks.count / 5)))
        func avg(_ xs: [Double?]) -> Double? {
            let v = xs.compactMap { $0 }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        let powers = ticks.compactMap(\.power)
        let result = StressResult(
            date: Date(), mode: mode, seconds: elapsed, profile: profileTitle,
            maxTemp: ticks.map(\.temp).max() ?? 0,
            avgPower: powers.isEmpty ? 0 : powers.reduce(0, +) / Double(powers.count),
            maxPower: powers.max() ?? 0,
            maxFanRPM: ticks.map(\.rpm).max() ?? 0,
            maxDeficit: ticks.compactMap(\.deficit).max(),
            cpuStart: avg(begin.map(\.cpu)), cpuEnd: avg(end.map(\.cpu)),
            gpuStart: avg(begin.map(\.gpu)), gpuEnd: avg(end.map(\.gpu)))
        results.insert(result, at: 0)
        if results.count > Self.maxResults { results.removeLast(results.count - Self.maxResults) }
        UserDefaults.standard.set(try? JSONEncoder().encode(results), forKey: Self.resultsKey)
    }
}
