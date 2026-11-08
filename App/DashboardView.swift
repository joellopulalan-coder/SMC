import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var monitor: SensorMonitor
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var helper: HelperManager
    /// SwiftUI keeps a closed Window alive; without this flag the charts keep redrawing every 2 s.
    /// (Not @State: that is a macro whose plugin the Command Line Tools don't ship.)
    @StateObject private var window = WindowState()

    var body: some View {
        Group {
            if window.visible { content } else { Color.clear }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(WindowAccessor { window.attach($0) })
        .onReceive(window.$visible) { monitor.dashboardVisible = $0 }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statsRow

                if helper.state != .running {
                    ServiceBanner()
                }

                Panel(tr("Load"), symbol: "cpu") {
                    CoreLoadSection()
                }
                Panel(tr("Activity"), symbol: "list.bullet.rectangle") {
                    ActivitySection()
                }
                Panel(tr("Temperature"), symbol: "thermometer.medium") {
                    TemperatureChart()
                }
                Panel(tr("Fan speed"), symbol: "fan") {
                    FanChart()
                }
                Panel(tr("Power"), symbol: "bolt") {
                    PowerSection()
                }
                Panel(tr("Stress test"), symbol: "flame") {
                    StressSection()
                }
                Panel(tr("Profile"), symbol: "slider.horizontal.3") {
                    ProfileSection()
                }
                Panel(tr("Menu bar"), symbol: "menubar.rectangle") {
                    MenuBarSettings()
                }
                Panel(tr("Background service"), symbol: "gearshape.2") {
                    ServiceSection()
                }
            }
            .padding(24)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatCard(title: "CPU", symbol: "cpu", value: monitor.cpuMax, unit: "°C",
                     detail: tr("average %@", "\(Int(monitor.cpuAvg)) °C"), tint: temperatureColor(monitor.cpuMax))
            StatCard(title: "GPU", symbol: "square.stack.3d.up", value: monitor.gpuMax, unit: "°C",
                     detail: tr("average %@", "\(Int(monitor.gpuAvg)) °C"), tint: temperatureColor(monitor.gpuMax))
            ForEach(monitor.fans) { fan in
                StatCard(title: tr("Fan %@", "\(fan.id + 1)"), symbol: fan.manual ? "fan.fill" : "fan",
                         value: fan.rpm, unit: "rpm",
                         detail: fan.manual ? "SMC Fan · \(Int(fan.fraction * 100))%" : tr("macOS in control"),
                         tint: fan.manual ? .accentColor : .primary)
            }
        }
    }
}

/// Tracks whether the dashboard window is really visible (open and not fully covered), and shows
/// the Dock icon only while it is open. Lives in a @StateObject, so it survives SwiftUI view swaps.
private final class WindowState: ObservableObject {
    @Published var visible = true
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.window = window

        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                        queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.visible = false
        })
        refresh()
    }

    private func refresh() {
        guard let window else { return }
        let nowVisible = window.isVisible && (window.isKeyWindow || window.occlusionState.contains(.visible))
        if nowVisible, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if nowVisible != visible { visible = nowVisible }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Hands over the NSWindow that hosts the dashboard.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
        }
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StatCard: View {
    let title: String
    let symbol: String
    let value: Double
    let unit: String
    let detail: String
    let tint: Color
    var text: String? = nil // shown instead of the rounded value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: text ?? "\(Int(value.rounded()))")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(verbatim: unit).font(.callout).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TemperatureChart: View {
    @EnvironmentObject private var monitor: SensorMonitor
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Chart {
            ForEach(monitor.history) { s in
                LineMark(x: .value("Time", s.date), y: .value("°C", s.cpu))
                    .foregroundStyle(by: .value("Sensor", "CPU"))
                LineMark(x: .value("Time", s.date), y: .value("°C", s.gpu))
                    .foregroundStyle(by: .value("Sensor", "GPU"))
            }
            if let t = settings.activeTakeover {
                RuleMark(y: .value("Takeover", t))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text(tr("takeover %@", "\(Int(t)) °C")).font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(["CPU": Color.orange, "GPU": Color.purple])
        .chartYScale(domain: 30...105)
        .chartYAxisLabel("°C")
        .frame(height: 170)
    }
}

private struct FanChart: View {
    @EnvironmentObject private var monitor: SensorMonitor

    private var maxRPM: Double { monitor.fans.map(\.maxRPM).max() ?? 8000 }

    var body: some View {
        Chart(monitor.history) { s in
            AreaMark(x: .value("Time", s.date), y: .value("rpm", s.rpm))
                .foregroundStyle(Color.accentColor.opacity(0.18))
            LineMark(x: .value("Time", s.date), y: .value("rpm", s.rpm))
                .foregroundStyle(Color.accentColor)
        }
        .chartYScale(domain: 0...max(maxRPM, 1000))
        .chartYAxisLabel("rpm")
        .frame(height: 130)
    }
}

private struct CoreLoadSection: View {
    @EnvironmentObject private var monitor: SensorMonitor

    var body: some View {
        let topology = monitor.topology
        VStack(alignment: .leading, spacing: 14) {
            Text(summary(topology)).font(.callout).foregroundStyle(.secondary)

            ForEach(topology.types) { type in
                CoreTypeRow(type: type, loads: monitor.coreLoads, average: monitor.load(of: type))
            }
            if let gpu = monitor.gpuLoad {
                GPULoadRow(load: gpu, cores: topology.gpuCores)
            }

            Chart {
                ForEach(monitor.history) { s in
                    ForEach(topology.types) { type in
                        if s.typeLoads.indices.contains(type.id) {
                            LineMark(x: .value("Time", s.date), y: .value("%", s.typeLoads[type.id] * 100))
                                .foregroundStyle(by: .value("Type", type.title))
                        }
                    }
                    if let gpu = s.gpuLoad {
                        LineMark(x: .value("Time", s.date), y: .value("%", gpu * 100))
                            .foregroundStyle(by: .value("Type", "GPU"))
                    }
                }
            }
            .chartForegroundStyleScale(domain: topology.types.map(\.title) + ["GPU"],
                                       range: topology.types.map(\.color) + [Color.purple])
            .chartYScale(domain: 0...100)
            .chartYAxisLabel("%")
            .frame(height: 120)
        }
    }

    private func summary(_ t: CPUTopology) -> String {
        var parts = [t.chip, tr("%@ CPU cores", "\(t.cpuCount)")]
        if let gpu = t.gpuCores { parts.append(tr("%@-core GPU", "\(gpu)")) }
        return parts.joined(separator: " · ")
    }
}

private struct ActivitySection: View {
    @EnvironmentObject private var monitor: SensorMonitor
    @AppStorage("activitySort") private var sort = "cpu"

    private var rows: [ProcessGroup] {
        let list = monitor.processes
        let sorted: [ProcessGroup]
        switch sort {
        case "energy": sorted = list.sorted { $0.watts > $1.watts }
        case "gpu": sorted = list.sorted { ($0.usingGPU ? 1 : 0, $0.cpu) > ($1.usingGPU ? 1 : 0, $1.cpu) }
        default: sorted = list.sorted { $0.cpu > $1.cpu }
        }
        return Array(sorted.prefix(10))
    }

    var body: some View {
        let rows = rows
        let scale = max(rows.map { sort == "energy" ? $0.watts : $0.cpu }.max() ?? 1, 0.001)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Which apps and processes the load comes from right now."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                EqualSegmentedPicker(selection: $sort, options: [("cpu", "CPU"), ("energy", tr("Power")), ("gpu", "GPU")],
                                     enabled: true)
                    .frame(width: 220)
            }

            if rows.isEmpty {
                Text(tr("Measuring…")).font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text(tr("Name"))
                        Text(verbatim: "")
                        Text(verbatim: "CPU").gridColumnAlignment(.trailing)
                        Text(tr("Power")).gridColumnAlignment(.trailing)
                        Text(verbatim: "GPU").gridColumnAlignment(.center)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(rows) { g in
                        GridRow {
                            HStack(spacing: 8) {
                                Image(nsImage: AppIcons.icon(for: g.bundlePath)).resizable().frame(width: 16, height: 16)
                                Text(g.name).lineLimit(1).truncationMode(.middle)
                                if g.processCount > 1 {
                                    Text(verbatim: "\(g.processCount)").font(.caption2).foregroundStyle(.secondary)
                                        .help(tr("%@ processes", "\(g.processCount)"))
                                }
                            }
                            ShareBar(fraction: (sort == "energy" ? g.watts : g.cpu) / scale)
                                .frame(width: 90)
                            Text(verbatim: formatCPU(g.cpu)).monospacedDigit()
                            Text(formatWatts(g.watts)).monospacedDigit()
                            Group {
                                if g.usingGPU {
                                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.purple)
                                        .help(tr("Sent work to the GPU in the last seconds"))
                                } else {
                                    Text(verbatim: "")
                                }
                            }
                            .gridColumnAlignment(.center)
                        }
                        .font(.callout)
                    }

                    if monitor.otherCPU >= 0.5 {
                        GridRow {
                            HStack(spacing: 8) {
                                Image(systemName: "ellipsis.circle").frame(width: 16, height: 16).foregroundStyle(.secondary)
                                Text(tr("Other system processes")).foregroundStyle(.secondary)
                            }
                            Text(verbatim: "")
                            Text(verbatim: formatCPU(monitor.otherCPU)).monospacedDigit().foregroundStyle(.secondary)
                            Text(verbatim: "–").foregroundStyle(.secondary)
                            Text(verbatim: "")
                        }
                        .font(.callout)
                    }
                }
            }

            Text(tr("CPU: 100%% is one full core (%@ cores in total). Power is the energy macOS attributes to each process. GPU marks apps that sent work to the GPU in the last seconds; macOS doesn't report a reliable GPU percentage per app. Processes of other users and the system can only be read as a total.", "\(monitor.topology.cpuCount)"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatCPU(_ v: Double) -> String {
        v < 10 ? v.formatted(.number.precision(.fractionLength(1))) + "%" : "\(Int(v.rounded()))%"
    }
}

private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.15))
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

private struct CoreTypeRow: View {
    let type: CoreType
    let loads: [Double]
    let average: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(type.color).frame(width: 8, height: 8)
                Text(type.title).font(.subheadline.weight(.semibold))
                Text(tr("%@ cores", "\(type.cores.count)")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(Int((average * 100).rounded()))%").font(.subheadline).monospacedDigit()
            }
            // One bar per core; a wider gap separates clusters.
            HStack(spacing: 10) {
                ForEach(type.clusters.indices, id: \.self) { i in
                    HStack(spacing: 3) {
                        ForEach(type.clusters[i], id: \.self) { cpu in
                            CoreBar(load: loads.indices.contains(cpu) ? loads[cpu] : 0, color: type.color)
                                .help("CPU \(cpu) · \(Int(((loads.indices.contains(cpu) ? loads[cpu] : 0) * 100).rounded()))%")
                        }
                    }
                }
            }
        }
    }
}

private struct CoreBar: View {
    let load: Double
    let color: Color
    var height: CGFloat = 40

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15))
            RoundedRectangle(cornerRadius: 3).fill(color)
                .frame(height: max(height * load, load > 0.005 ? 2 : 0))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

private struct GPULoadRow: View {
    let load: Double
    let cores: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color.purple).frame(width: 8, height: 8)
                Text(verbatim: "GPU").font(.subheadline.weight(.semibold))
                if let cores { Text(tr("%@ cores", "\(cores)")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(verbatim: "\(Int((load * 100).rounded()))%").font(.subheadline).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3).fill(Color.purple).frame(width: geo.size.width * load)
                }
            }
            .frame(height: 12)
        }
    }
}

private struct PowerSection: View {
    @EnvironmentObject private var monitor: SensorMonitor

    var body: some View {
        let p = monitor.power
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatCard(title: tr("System"), symbol: "bolt", value: p.system ?? 0, unit: "W",
                         detail: tr("total power draw"), tint: .primary)
                StatCard(title: tr("Adapter"), symbol: "powerplug", value: p.adapterIn ?? 0, unit: "W",
                         detail: p.adapterWatts.map { tr("%@ adapter", "\($0) W") } ?? tr("not connected"),
                         tint: .primary)
                StatCard(title: tr("Battery"), symbol: p.charging ? "battery.100percent.bolt" : "battery.75percent",
                         value: Double(p.batteryPercent ?? 0), unit: "%",
                         detail: batteryDetail(p), tint: .primary)
            }
            if let d = monitor.overdraw {
                OverdrawNotice(deficit: d, adapterWatts: p.adapterWatts)
            }
            Chart(monitor.history) { s in
                AreaMark(x: .value("Time", s.date), y: .value("W", s.power))
                    .foregroundStyle(Color.yellow.opacity(0.18))
                LineMark(x: .value("Time", s.date), y: .value("W", s.power))
                    .foregroundStyle(Color.yellow)
            }
            .chartYAxisLabel("W")
            .frame(height: 110)
        }
    }

    private func batteryDetail(_ p: PowerReading) -> String {
        if let b = p.battery, abs(b) >= 0.5 {
            return b > 0 ? tr("charging at %@", formatWatts(b)) : tr("discharging %@", formatWatts(-b))
        }
        return p.externalConnected ? tr("on adapter, not charging") : tr("on battery")
    }
}

private struct StressSection: View {
    @EnvironmentObject private var monitor: SensorMonitor
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var stress: StressTest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Fully loads the CPU and/or GPU and measures how much performance your Mac loses to heat. Run the same test with different fan profiles to compare them."))
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                EqualSegmentedPicker(selection: $stress.mode,
                                     options: StressMode.allCases.map { ($0, $0.title) },
                                     enabled: !stress.running)
                    .frame(width: 300)

                Picker(tr("Duration"), selection: $stress.duration) {
                    ForEach(StressDuration.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(stress.running)

                Spacer()

                if stress.running {
                    Button {
                        stress.stop()
                    } label: {
                        Label(tr("Stop"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        stress.start(monitor: monitor, profile: settings.profile.title)
                    } label: {
                        Label(tr("Start test"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if stress.running {
                live
            }
            if stress.gpuUnavailable {
                Label(tr("GPU test unavailable (Metal couldn't start)."), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !stress.results.isEmpty {
                StressResults()
            }
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let remaining = stress.remaining {
                ProgressView(value: Double(stress.elapsed), total: Double(stress.duration.rawValue)) {
                    Text(tr("%@ — %@ left", formatClock(stress.elapsed), formatClock(remaining)))
                        .font(.caption).monospacedDigit()
                }
            } else {
                Text(tr("Running for %@", formatClock(stress.elapsed))).font(.caption).monospacedDigit()
            }
            HStack(spacing: 12) {
                if stress.mode.usesCPU {
                    let f = formatFlops(stress.cpuScore ?? 0)
                    StatCard(title: tr("CPU score"), symbol: "cpu", value: 0, unit: f.1,
                             detail: tr("%@ cores at full load", "\(ProcessInfo.processInfo.activeProcessorCount)"),
                             tint: .accentColor, text: f.0)
                }
                if stress.mode.usesGPU {
                    let f = formatFlops(stress.gpuScore ?? 0)
                    StatCard(title: tr("GPU score"), symbol: "square.stack.3d.up", value: 0, unit: f.1,
                             detail: "Metal compute", tint: .accentColor, text: f.0)
                }
                StatCard(title: tr("Hottest sensor"), symbol: "thermometer.high", value: monitor.hottest, unit: "°C",
                         detail: tr("fans %@", formatRPM(monitor.averageRPM)), tint: temperatureColor(monitor.hottest))
                StatCard(title: tr("Power draw"), symbol: "bolt", value: monitor.power.system ?? 0, unit: "W",
                         detail: monitor.overdraw.map { tr("battery adds %@", formatWatts($0)) }
                             ?? tr("adapter keeps up"),
                         tint: monitor.overdraw == nil ? .primary : .orange)
            }
        }
    }
}

/// A native segmented control whose segments always have equal widths.
/// SwiftUI's segmented Picker switches between proportional and equal widths when its state
/// changes (e.g. when disabled), so it jumped out of its frame while a stress test ran.
private struct EqualSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [(Value, String)]
    let enabled: Bool

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(\.1), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (i, option) in options.enumerated() where control.label(forSegment: i) != option.1 {
            control.setLabel(option.1, forSegment: i)
        }
        control.selectedSegment = options.firstIndex { $0.0 == selection } ?? -1
        control.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: EqualSegmentedPicker

        init(_ parent: EqualSegmentedPicker) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment].0
        }
    }
}

private struct StressResults: View {
    @EnvironmentObject private var stress: StressTest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Results")).font(.subheadline.weight(.semibold))
                Spacer()
                Button(tr("Clear")) { stress.clearResults() }
                    .buttonStyle(.link)
                    .disabled(stress.running)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach([tr("When"), tr("Test"), tr("Profile"), tr("Max"), tr("Avg."), "CPU", "GPU", tr("Shortfall")],
                            id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(stress.results) { r in
                    GridRow {
                        Text(r.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        Text(verbatim: "\(r.mode.title) · \(formatClock(r.seconds))")
                        Text(r.profile)
                        Text(verbatim: "\(Int(r.maxTemp)) °C").foregroundStyle(temperatureColor(r.maxTemp))
                        Text(formatWatts(r.avgPower))
                        score(r.cpuStart, r.cpuDrop)
                        score(r.gpuStart, r.gpuDrop)
                        Text(r.maxDeficit.map { "−" + formatWatts($0) } ?? "–")
                            .foregroundStyle(r.maxDeficit == nil ? Color.secondary : .orange)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
            Text(tr("Score = average over the first seconds. The percentage is how much lower the score was at the end (thermal throttling)."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func score(_ start: Double?, _ drop: Double?) -> some View {
        if let start {
            let f = formatFlops(start)
            HStack(spacing: 4) {
                Text(verbatim: "\(f.0) \(f.1)")
                if let drop {
                    Text(verbatim: drop < 1 ? "±0%" : "−\(Int(drop.rounded()))%")
                        .foregroundStyle(drop >= 5 ? Color.orange : .secondary)
                }
            }
        } else {
            Text(verbatim: "–").foregroundStyle(.secondary)
        }
    }
}

private struct MenuBarSettings: View {
    @AppStorage(MenuBarItem.storageKey) private var itemsRaw = MenuBarItem.defaultRaw
    @AppStorage(MenuBarItem.overdrawKey) private var overdrawWarning = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Choose what appears next to the icon in the menu bar."))
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(isOn: binding(for: item)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                            Text(item.example).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Divider()
            Toggle(isOn: $overdrawWarning) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Warn when the adapter can't keep up"))
                    Text(tr("Warning icon plus the shortfall, e.g. −8 W, as soon as the battery helps out while plugged in"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private func binding(for item: MenuBarItem) -> Binding<Bool> {
        Binding(
            get: { MenuBarItem.parse(itemsRaw).contains(item) },
            set: { on in
                var items = MenuBarItem.parse(itemsRaw)
                if on { items.insert(item) } else { items.remove(item) }
                itemsRaw = MenuBarItem.serialize(items)
            }
        )
    }
}

private struct ProfileSection: View {
    @EnvironmentObject private var monitor: SensorMonitor
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var helper: HelperManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(tr("Profile"), selection: $settings.profile) {
                ForEach(FanProfile.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(settings.profile.subtitle).font(.callout).foregroundStyle(.secondary)

            CurveChart(profile: settings.profile, curve: settings.activeCurve, current: monitor.hottest)

            if settings.profile == .custom {
                CurveEditor(curve: $settings.custom)
            }

            if let error = settings.writeError, helper.state != .notInstalled {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct CurveChart: View {
    let profile: FanProfile
    let curve: Curve
    let current: Double

    private var points: [CurvePoint] { curve.points.sorted { $0.temp < $1.temp } }

    var body: some View {
        Chart {
            if profile == .max {
                RuleMark(y: .value("%", 100)).foregroundStyle(Color.accentColor)
            } else if profile.usesCurve {
                ForEach(points) { p in
                    LineMark(x: .value("°C", p.temp), y: .value("%", p.pct), series: .value("Part", "curve"))
                    PointMark(x: .value("°C", p.temp), y: .value("%", p.pct))
                }
                .foregroundStyle(Color.accentColor)
                // Ramp-down while cooling: from the first point back to minimum speed at the release threshold.
                if let first = points.first, first.temp > curve.release {
                    LineMark(x: .value("°C", curve.release), y: .value("%", 0), series: .value("Part", "ramp"))
                        .foregroundStyle(Color.accentColor.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    LineMark(x: .value("°C", first.temp), y: .value("%", first.pct), series: .value("Part", "ramp"))
                        .foregroundStyle(Color.accentColor.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }
                RuleMark(x: .value("Takeover", curve.takeover))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            RuleMark(x: .value("Now", min(max(current, 40), 100)))
                .foregroundStyle(temperatureColor(current))
                .annotation(position: .top) {
                    Text(tr("now %@", "\(Int(current)) °C")).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: 40...100)
        .chartYScale(domain: 0...100)
        .chartXAxisLabel(tr("temperature (°C)"))
        .chartYAxisLabel(tr("fan %"))
        .overlay {
            if profile == .macOS {
                Text(tr("macOS controls the fans")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(height: 150)
    }
}

private struct CurveEditor: View {
    @Binding var curve: Curve

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(tr("Take over from"))
                Slider(value: $curve.takeover, in: 45...85, step: 1)
                Text(verbatim: "\(Int(curve.takeover)) °C").monospacedDigit().frame(width: 52, alignment: .trailing)
                Text(tr("back to macOS below %@", "\(Int(curve.release)) °C"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($curve.points) { $point in
                GridRow {
                    Text(tr("Point %@", "\(point.id + 1)"))
                    Slider(value: $point.temp, in: 45...100, step: 1)
                    Text(verbatim: "\(Int(point.temp)) °C").monospacedDigit().frame(width: 52, alignment: .trailing)
                    HStack {
                        Slider(value: $point.pct, in: 0...100, step: 5)
                        Text(verbatim: "\(Int(point.pct))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .font(.callout)
    }
}

private struct ServiceBanner: View {
    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(helper.statusText).font(.headline)
                Text(helper.state == .outdated
                     ? tr("The service is still running, but this app has a newer version. Updating asks for your password.")
                     : tr("Without the background service, SMC Fan can only watch, not control the fans."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if helper.state == .notInstalled || helper.state == .outdated {
                Button(helper.state == .outdated ? tr("Update") : tr("Install")) {
                    if helper.install() { settings.writeConfig() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ServiceSection: View {
    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ServiceDot(state: helper.state)
                Text(helper.statusText)
                Spacer()
                switch helper.state {
                case .notInstalled:
                    Button(tr("Install")) { if helper.install() { settings.writeConfig() } }
                case .outdated:
                    Button(tr("Update")) { if helper.install() { settings.writeConfig() } }
                    Button(tr("Remove")) { helper.uninstall() }
                case .stopped, .running:
                    Button(tr("Restart")) { if helper.install() { settings.writeConfig() } }
                    Button(tr("Remove")) { helper.uninstall() }
                }
            }
            Text(tr("The service runs as root in the background, also when this app is closed, and starts automatically at boot. When it stops or is removed, the fans go back to macOS."))
                .font(.caption).foregroundStyle(.secondary)

            Toggle(tr("Open SMC Fan at login"), isOn: Binding(
                get: { helper.launchAtLogin },
                set: { helper.setLaunchAtLogin($0) }
            ))

            if let error = helper.lastError {
                Label(error, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
        }
    }
}
