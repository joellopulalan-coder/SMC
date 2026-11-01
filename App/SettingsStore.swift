import Foundation

enum FanProfile: String, CaseIterable, Identifiable, Codable {
    case macOS = "off", balanced, performance, max, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS: "macOS"
        case .balanced: tr("Balanced")
        case .performance: tr("Performance")
        case .max: tr("Maximum")
        case .custom: tr("Custom")
        }
    }

    var subtitle: String {
        switch self {
        case .macOS: tr("Apple controls the fans. Quiet, but the chip is allowed to run hot.")
        case .balanced: tr("Quiet during light work; ramps up from 65 °C, full speed at 85 °C.")
        case .performance: tr("Steps in at 55 °C and cools aggressively. Less throttling, more noise.")
        case .max: tr("Both fans at maximum speed, all the time.")
        case .custom: tr("Your own takeover threshold and curve.")
        }
    }

    var symbol: String {
        switch self {
        case .macOS: "apple.logo"
        case .balanced: "gauge.with.dots.needle.33percent"
        case .performance: "flame"
        case .max: "wind"
        case .custom: "slider.horizontal.3"
        }
    }

    var usesCurve: Bool { self != .macOS && self != .max }
}

struct CurvePoint: Identifiable, Equatable, Codable {
    var id: Int
    var temp: Double
    var pct: Double // 0...100
}

struct Curve: Equatable, Codable {
    var takeover: Double
    var points: [CurvePoint]

    /// Below this temperature the fans go back to macOS (5 °C hysteresis).
    var release: Double { takeover - 5 }

    static func preset(_ profile: FanProfile) -> Curve {
        switch profile {
        case .performance:
            Curve(takeover: 55, points: [.init(id: 0, temp: 55, pct: 40), .init(id: 1, temp: 65, pct: 70), .init(id: 2, temp: 75, pct: 100)])
        default:
            Curve(takeover: 65, points: [.init(id: 0, temp: 65, pct: 30), .init(id: 1, temp: 75, pct: 60), .init(id: 2, temp: 85, pct: 100)])
        }
    }
}

/// Stores the chosen profile and writes the config file that the daemon reads.
final class SettingsStore: ObservableObject {
    static let configPath = "/Library/Application Support/SMCFan/config"

    @Published var profile: FanProfile { didSet { save() } }
    @Published var custom: Curve { didSet { save() } }
    @Published private(set) var writeError: String?

    private let defaults = UserDefaults.standard

    init() {
        profile = defaults.string(forKey: "profile").flatMap(FanProfile.init) ?? .balanced
        custom = defaults.data(forKey: "custom").flatMap { try? JSONDecoder().decode(Curve.self, from: $0) }
            ?? Curve.preset(.balanced)
    }

    var activeCurve: Curve { profile == .custom ? custom : Curve.preset(profile) }

    /// Takeover threshold for the charts; nil when no curve is active.
    var activeTakeover: Double? { profile.usesCurve ? activeCurve.takeover : nil }

    private func save() {
        defaults.set(profile.rawValue, forKey: "profile")
        defaults.set(try? JSONEncoder().encode(custom), forKey: "custom")
        writeConfig()
    }

    /// Writes the active profile in the format described in Daemon/smcfan.c.
    func writeConfig() {
        let curve = activeCurve
        let mode = profile == .macOS ? "off" : profile == .max ? "max" : "curve"
        var lines = [
            "profile=\(profile.rawValue)",
            "mode=\(mode)",
            "takeover=\(Int(curve.takeover))",
            "release=\(Int(curve.release))",
        ]
        lines += curve.points.sorted { $0.temp < $1.temp }.map { "point=\(Int($0.temp)):\(Int($0.pct))" }
        do {
            try (lines.joined(separator: "\n") + "\n").write(toFile: Self.configPath, atomically: true, encoding: .utf8)
            writeError = nil
        } catch {
            writeError = tr("Couldn't save the profile. Is the background service installed?")
        }
    }
}
