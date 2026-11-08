import SwiftUI

@main
struct SMCFanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = SensorMonitor()
    @StateObject private var settings = SettingsStore()
    @StateObject private var helper = HelperManager()
    @StateObject private var stress = StressTest()

    var body: some Scene {
        Window("SMC Fan", id: "dashboard") {
            DashboardView()
                .environmentObject(monitor)
                .environmentObject(settings)
                .environmentObject(helper)
                .environmentObject(stress)
        }
        .defaultSize(width: 780, height: 760)
        .defaultLaunchBehavior(.suppressed) // the menu bar label opens it, except at login

        MenuBarExtra {
            MenuBarView()
                .environmentObject(monitor)
                .environmentObject(settings)
                .environmentObject(helper)
                .environmentObject(stress)
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
                .environmentObject(settings)
                .environmentObject(stress)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu bar label, which always exists; opens the dashboard.
    static var openDashboard: (() -> Void)?
    /// At login, start in the menu bar only; when opened by hand, also show the dashboard.
    static var openDashboardOnLaunch = true

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Self.openDashboardOnLaunch = !loginItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openDashboard?() }
        return true
    }
}

enum MenuBarItem: String, CaseIterable, Identifiable {
    case temperature, fanSpeed, cpuLoad, gpuLoad, cpuGraph, gpuGraph, profile, systemPower, batteryPower, batteryPercent

    static let storageKey = "menuBarItems"
    static let defaultRaw = "temperature"
    static let overdrawKey = "overdrawWarning"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: tr("Temperature")
        case .fanSpeed: tr("Fan speed")
        case .cpuLoad: tr("CPU load")
        case .gpuLoad: tr("GPU load")
        case .cpuGraph: tr("CPU graph")
        case .gpuGraph: tr("GPU graph")
        case .profile: tr("Profile (as icon)")
        case .systemPower: tr("Power draw")
        case .batteryPower: tr("Charging / discharging")
        case .batteryPercent: tr("Battery percentage")
        }
    }

    var example: String {
        switch self {
        case .temperature: "64°"
        case .fanSpeed: formatRPM(2400)
        case .cpuLoad: "CPU 23%"
        case .gpuLoad: "GPU 41%"
        case .cpuGraph, .gpuGraph: tr("mini chart of the last minute or so")
        case .profile: tr("replaces the fan icon")
        case .systemPower: "19 W"
        case .batteryPower: tr("+12 W, −8 W or AC")
        case .batteryPercent: "80%"
        }
    }

    static func parse(_ raw: String) -> Set<MenuBarItem> {
        Set(raw.split(separator: ",").compactMap { MenuBarItem(rawValue: String($0)) })
    }

    static func serialize(_ items: Set<MenuBarItem>) -> String {
        allCases.filter(items.contains).map(\.rawValue).joined(separator: ",")
    }
}

func formatWatts(_ w: Double) -> String {
    w < 10 ? w.formatted(.number.precision(.fractionLength(1))) + " W" : "\(Int(w.rounded())) W"
}

/// (value, unit), e.g. ("14.2", "TFLOPS") or ("445", "GFLOPS").
func formatFlops(_ gflops: Double) -> (String, String) {
    gflops >= 1000
        ? ((gflops / 1000).formatted(.number.precision(.fractionLength(1))), "TFLOPS")
        : ("\(Int(gflops.rounded()))", "GFLOPS")
}

func formatClock(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

func formatRPM(_ rpm: Double) -> String {
    rpm < 1000 ? "\(Int(rpm)) rpm" : (rpm / 1000).formatted(.number.precision(.fractionLength(1))) + "k rpm"
}

/// "+12 W" while charging, "−8 W" while discharging, "AC" on the adapter without charging.
func formatBatteryFlow(_ p: PowerReading) -> String? {
    if let b = p.battery, abs(b) >= 0.5 {
        return (b > 0 ? "+" : "−") + formatWatts(abs(b))
    }
    return p.externalConnected ? "AC" : nil
}

func temperatureColor(_ t: Double) -> Color {
    t < 60 ? .green : t < 80 ? .orange : .red
}

struct MenuBarLabel: View {
    @EnvironmentObject private var monitor: SensorMonitor
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var stress: StressTest
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarItem.storageKey) private var itemsRaw = MenuBarItem.defaultRaw
    @AppStorage(MenuBarItem.overdrawKey) private var overdrawWarning = true

    private var overdraw: Double? { overdrawWarning ? monitor.overdraw : nil }

    private var text: String {
        guard monitor.ready else { return "–" }
        let items = MenuBarItem.parse(itemsRaw)
        let p = monitor.power
        var parts: [String] = []
        // Shortfall first, unless charging/discharging already shows it.
        if let d = overdraw, !items.contains(.batteryPower) { parts.append("−" + formatWatts(d)) }
        if items.contains(.temperature) { parts.append("\(Int(monitor.hottest.rounded()))°") }
        if items.contains(.fanSpeed) { parts.append(formatRPM(monitor.averageRPM)) }
        if items.contains(.cpuLoad) { parts.append("CPU \(Int((monitor.cpuLoad * 100).rounded()))%") }
        if items.contains(.gpuLoad), let g = monitor.gpuLoad { parts.append("GPU \(Int((g * 100).rounded()))%") }
        if items.contains(.systemPower), let w = p.system { parts.append(formatWatts(w)) }
        if items.contains(.batteryPower), let flow = formatBatteryFlow(p) { parts.append(flow) }
        if items.contains(.batteryPercent), let pct = p.batteryPercent { parts.append("\(pct)%") }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        if overdraw != nil { return "bolt.trianglebadge.exclamationmark" }
        if stress.running { return "flame.fill" }
        if MenuBarItem.parse(itemsRaw).contains(.profile) { return settings.profile.symbol }
        return monitor.anyManual ? "fan.fill" : "fan"
    }

    /// Bar heights (0...14) for each enabled graph: the last 16 readings, oldest first.
    private var graphs: [[UInt8]] {
        let items = MenuBarItem.parse(itemsRaw)
        let recent = monitor.history.suffix(MenuBarIcon.bars)
        func bars(_ values: [Double]) -> [UInt8] {
            Array(repeating: 0, count: MenuBarIcon.bars - values.count)
                + values.map { UInt8((min(max($0, 0), 1) * 14).rounded()) }
        }
        var result: [[UInt8]] = []
        if items.contains(.cpuGraph) { result.append(bars(recent.map(\.cpuLoad))) }
        if items.contains(.gpuGraph) { result.append(bars(recent.map { $0.gpuLoad ?? 0 })) }
        return result
    }

    var body: some View {
        // .equatable(): only redraw when the text or graphs actually change. Every redraw makes
        // macOS re-render the menu bar item once per display.
        LabelContent(symbol: symbol, text: text, graphs: graphs)
            .equatable()
            .onAppear {
                AppDelegate.openDashboard = {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if AppDelegate.openDashboardOnLaunch {
                    AppDelegate.openDashboardOnLaunch = false
                    AppDelegate.openDashboard?()
                }
            }
    }
}

private struct LabelContent: View, Equatable {
    let symbol: String
    let text: String
    let graphs: [[UInt8]]

    var body: some View {
        HStack(spacing: 3) {
            // One image with the icon and any graphs: a menu bar label renders an Image and a Text reliably.
            if graphs.isEmpty {
                Image(systemName: symbol)
            } else {
                Image(nsImage: MenuBarIcon.image(symbol: symbol, graphs: graphs))
            }
            if !text.isEmpty {
                Text(verbatim: text).monospacedDigit()
            }
        }
    }
}

/// Draws the menu bar icon with sparkline bar graphs next to it, as a template image
/// so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    static let bars = 16
    private static let barWidth: CGFloat = 1.5
    private static let barStep: CGFloat = 2
    private static let height: CGFloat = 16

    static func image(symbol: String, graphs: [[UInt8]]) -> NSImage {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let iconWidth = icon?.size.width ?? 0
        let graphWidth = CGFloat(bars) * barStep
        let width = iconWidth + CGFloat(graphs.count) * (4 + graphWidth)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            }
            var x = iconWidth + 4
            for graph in graphs {
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSRect(x: x, y: 1, width: graphWidth - (barStep - barWidth), height: 0.5).fill() // baseline
                NSColor.black.setFill()
                for (i, value) in graph.enumerated() where value > 0 {
                    NSRect(x: x + CGFloat(i) * barStep, y: 1, width: barWidth, height: CGFloat(value)).fill()
                }
                x += graphWidth + 4
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
