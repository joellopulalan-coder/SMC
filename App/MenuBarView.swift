import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var monitor: SensorMonitor
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var stress: StressTest
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: "SMC Fan").font(.headline)
                Spacer()
                ServiceDot(state: helper.state)
            }

            HStack(spacing: 8) {
                MiniTemp(title: "CPU", value: monitor.cpuMax)
                MiniTemp(title: "GPU", value: monitor.gpuMax)
            }

            VStack(spacing: 8) {
                ForEach(monitor.fans) { fan in
                    HStack(spacing: 8) {
                        Image(systemName: fan.manual ? "fan.fill" : "fan")
                            .foregroundStyle(fan.manual ? Color.accentColor : .secondary)
                        Text(tr("Fan %@", "\(fan.id + 1)")).font(.callout)
                        ProgressView(value: fan.fraction).progressViewStyle(.linear)
                        Text(verbatim: "\(Int(fan.rpm)) rpm")
                            .font(.callout).monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }

            if stress.running {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill").foregroundStyle(.red)
                    Text(tr("Stress test %@", stress.mode.title)).font(.callout.weight(.semibold))
                    Spacer()
                    Text(verbatim: formatClock(stress.elapsed)
                         + (stress.remaining == nil ? "" : " / " + formatClock(stress.duration.rawValue)))
                        .font(.callout).monospacedDigit()
                    Button(tr("Stop")) { stress.stop() }
                }
                .padding(8)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            PowerRows(power: monitor.power)

            if let d = monitor.overdraw {
                OverdrawNotice(deficit: d, adapterWatts: monitor.power.adapterWatts)
            }

            Divider()

            Text(tr("Profile")).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(FanProfile.allCases) { profile in
                    Button {
                        settings.profile = profile
                    } label: {
                        HStack {
                            Image(systemName: profile.symbol).frame(width: 20)
                            Text(profile.title)
                            Spacer()
                            if settings.profile == profile {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(settings.profile == profile ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            if helper.state != .running {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(helper.state == .notInstalled
                         ? tr("Install the background service to control the fans.")
                         : helper.statusText)
                        .font(.caption)
                }
            }

            Divider()

            HStack {
                Button(tr("Open dashboard")) {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button(tr("Quit")) { NSApp.terminate(nil) }
                    .help(tr("Quits the app. The background service keeps controlling the fans."))
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct MiniTemp: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: "\(Int(value.rounded())) °C")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(temperatureColor(value))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PowerRows: View {
    let power: PowerReading

    private var batteryText: String {
        var s = power.batteryPercent.map { "\($0)%" } ?? "–"
        if let b = power.battery, abs(b) >= 0.5 {
            s += " · " + (b > 0 ? tr("charging %@", formatWatts(b)) : tr("discharging %@", formatWatts(-b)))
        } else if power.externalConnected {
            s += " · " + tr("on adapter")
        }
        return s
    }

    var body: some View {
        VStack(spacing: 6) {
            row("bolt", tr("System"), power.system.map(formatWatts) ?? "–")
            if power.externalConnected {
                row("powerplug", tr("Adapter"),
                    [power.adapterIn.map(formatWatts), power.adapterWatts.map { tr("max %@", "\($0) W") }]
                        .compactMap { $0 }.joined(separator: " · "))
            }
            row(power.charging ? "battery.100percent.bolt" : "battery.75percent", tr("Battery"), batteryText)
        }
        .font(.callout)
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

struct OverdrawNotice: View {
    let deficit: Double
    let adapterWatts: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.trianglebadge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Adapter can't keep up")).font(.callout.weight(.semibold))
                Text(adapterWatts.map { tr("The battery adds %@ on top of the %@ adapter.", formatWatts(deficit), "\($0) W") }
                     ?? tr("The battery adds %@.", formatWatts(deficit)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ServiceDot: View {
    let state: HelperManager.State

    var body: some View {
        Circle()
            .fill(state == .running ? Color.green : state == .notInstalled ? .gray : .orange)
            .frame(width: 8, height: 8)
    }
}
