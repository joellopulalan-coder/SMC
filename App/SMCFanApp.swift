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
    case temperature, fanSpeed, profile, systemPower, batteryPower, batteryPercent

    static let storageKey = "menuBarItems"
    static let defaultRaw = "temperature"
    static let overdrawKey = "overdrawWarning"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: tr("Temperature")
        case .fanSpeed: tr("Fan speed")
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

    var body: some View {
        // .equatable(): only redraw when the text actually changes. Every redraw makes
        // macOS re-render the menu bar item once per display.
        LabelContent(symbol: symbol, text: text)
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if !text.isEmpty {
                Text(verbatim: text).monospacedDigit()
            }
        }
    }
}
