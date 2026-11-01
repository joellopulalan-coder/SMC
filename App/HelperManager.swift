import AppKit
import ServiceManagement

/// Manages the root daemon (a LaunchDaemon) that drives the fans, and "open at login".
final class HelperManager: ObservableObject {
    enum State { case notInstalled, outdated, stopped, running }

    static let helperPath = "/Library/PrivilegedHelperTools/smcfand"
    static let plistPath = "/Library/LaunchDaemons/local.smcfan.plist"
    static let lockPath = "/var/run/smcfan.lock"

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var lastError: String?

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var statusText: String {
        switch state {
        case .notInstalled: tr("Background service not installed")
        case .outdated: tr("Update available for the background service")
        case .stopped: tr("Background service stopped")
        case .running: tr("Background service running")
        }
    }

    func refresh() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.plistPath), fm.fileExists(atPath: Self.helperPath) else {
            state = .notInstalled
            return
        }
        if let bundled = Bundle.main.path(forResource: "smcfand", ofType: nil),
           !fm.contentsEqual(atPath: bundled, andPath: Self.helperPath) {
            state = .outdated
        } else {
            state = Self.daemonHoldsLock() ? .running : .stopped
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The daemon holds an exclusive flock for as long as it runs.
    private static func daemonHoldsLock() -> Bool {
        let fd = open(lockPath, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    func install() -> Bool {
        guard let script = Bundle.main.path(forResource: "install", ofType: "sh"),
              let daemon = Bundle.main.path(forResource: "smcfand", ofType: nil) else {
            lastError = tr("Installation files are missing from the app.")
            return false
        }
        return runPrivileged([script, daemon, NSUserName()])
    }

    func uninstall() {
        guard let script = Bundle.main.path(forResource: "uninstall", ofType: "sh") else { return }
        _ = runPrivileged([script])
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = tr("Couldn't change open at login: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Runs a script as root through the standard macOS password prompt.
    private func runPrivileged(_ args: [String]) -> Bool {
        let shell = (["/bin/sh"] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        defer { refresh() }
        if let error {
            // -128: the user cancelled the password prompt
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                lastError = error[NSAppleScript.errorMessage] as? String ?? tr("Unknown error")
            }
            return false
        }
        lastError = nil
        return true
    }
}
