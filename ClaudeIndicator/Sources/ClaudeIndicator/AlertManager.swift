import Foundation
import AppKit

struct Alert: Hashable {
    let id: String
    let pid: pid_t
    let screenID: CGDirectDisplayID
    let timestamp: Date
    let suppressRing: Bool
    let suppressPanel: Bool
    let projectName: String?

    init(pid: pid_t, screenID: CGDirectDisplayID, timestamp: Date = Date(), suppressRing: Bool = false, suppressPanel: Bool = false, projectName: String? = nil) {
        self.id = "\(pid)-\(screenID)-\(timestamp.timeIntervalSince1970)"
        self.pid = pid
        self.screenID = screenID
        self.timestamp = timestamp
        self.suppressRing = suppressRing
        self.suppressPanel = suppressPanel
        self.projectName = projectName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(screenID)
    }

    static func == (lhs: Alert, rhs: Alert) -> Bool {
        lhs.pid == rhs.pid && lhs.screenID == rhs.screenID
    }
}

class AlertManager: ObservableObject {
    static let shared = AlertManager()

    @Published private(set) var alerts: Set<Alert> = []
    private var dismissTimers: [Alert: Timer] = [:]
    private let settings = Settings.shared
    private let stats = StatsManager.shared

    var hasActiveAlerts: Bool {
        !alerts.isEmpty
    }

    func alertCount(for screenID: CGDirectDisplayID) -> Int {
        alerts.filter { $0.screenID == screenID }.count
    }

    /// Count of alerts that should show the ring (not suppressed)
    func ringAlertCount(for screenID: CGDirectDisplayID) -> Int {
        alerts.filter { $0.screenID == screenID && !$0.suppressRing }.count
    }

    func ringThickness(for screenID: CGDirectDisplayID) -> CGFloat {
        let count = ringAlertCount(for: screenID)
        guard count > 0 else { return 0 }
        return CGFloat(settings.ringThickness) + CGFloat(max(0, count - 1)) * CGFloat(settings.thicknessIncrement)
    }

    func addAlert(pid: pid_t, screenID: CGDirectDisplayID, suppressRing: Bool = false, suppressPanel: Bool = false) {
        // Try to get project info from the working directory
        let projectName = resolveProjectName(for: pid)
        let alert = Alert(pid: pid, screenID: screenID, timestamp: Date(), suppressRing: suppressRing, suppressPanel: suppressPanel, projectName: projectName)

        // If alert already exists, just reset its timer
        if let existingAlert = alerts.first(where: { $0.pid == pid && $0.screenID == screenID }) {
            dismissTimers[existingAlert]?.invalidate()
            dismissTimers.removeValue(forKey: existingAlert)
            // Remove old alert and add new one (in case suppressRing changed)
            alerts.remove(existingAlert)
            alerts.insert(alert)
        } else {
            alerts.insert(alert)
            // Record stats for new alerts
            stats.recordAlert(id: alert.id)
            // Play sound for new alerts only (but not if ring is suppressed - user is looking)
            if !suppressRing {
                playAlertSound()
            }
        }

        // Set up auto-dismiss if enabled
        if settings.autoDismissEnabled {
            let timer = Timer.scheduledTimer(withTimeInterval: settings.autoDismissDelay, repeats: false) { [weak self] _ in
                self?.dismissAlert(alert)
            }
            dismissTimers[alert] = timer
        }

        NotificationCenter.default.post(name: .alertsDidChange, object: nil)
    }

    private func playAlertSound() {
        guard settings.soundEnabled else { return }
        NSSound(named: NSSound.Name(settings.soundName))?.play()
    }

    func removeAlert(_ alert: Alert) {
        dismissTimers[alert]?.invalidate()
        dismissTimers.removeValue(forKey: alert)
        alerts.remove(alert)
        NotificationCenter.default.post(name: .alertsDidChange, object: nil)
    }

    /// Called when user clicks an alert to go to the terminal
    func clickAlert(_ alert: Alert) {
        stats.recordClick(id: alert.id)
        removeAlert(alert)
    }

    /// Called when alert is dismissed without clicking
    func dismissAlert(_ alert: Alert) {
        stats.recordDismiss(id: alert.id)
        removeAlert(alert)
    }

    func dismissAlerts(for screenID: CGDirectDisplayID) {
        let screensAlerts = alerts.filter { $0.screenID == screenID }
        for alert in screensAlerts {
            dismissAlert(alert)
        }
    }

    func dismissAllAlerts() {
        for alert in alerts {
            dismissTimers[alert]?.invalidate()
            stats.recordDismiss(id: alert.id)
        }
        dismissTimers.removeAll()
        alerts.removeAll()
        NotificationCenter.default.post(name: .alertsDidChange, object: nil)
    }

    func screenIDs(withAlerts: Bool = true) -> Set<CGDirectDisplayID> {
        Set(alerts.map { $0.screenID })
    }

    /// Screen IDs that have alerts with ring enabled (not suppressed)
    func screenIDsWithRing() -> Set<CGDirectDisplayID> {
        Set(alerts.filter { !$0.suppressRing }.map { $0.screenID })
    }

    /// Alerts that should show the panel (not suppressed)
    var panelAlerts: [Alert] {
        alerts.filter { !$0.suppressPanel }
    }

    var hasPanelAlerts: Bool {
        !panelAlerts.isEmpty
    }
}

extension AlertManager {
    /// Get working directory of a process using lsof
    private func getWorkingDirectory(for pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", "\(pid)", "-Fn", "-a", "-d", "cwd"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Output format: "p<pid>\nn<path>"
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    if line.hasPrefix("n") && line.count > 1 {
                        return String(line.dropFirst())
                    }
                }
            }
        } catch {
            print("Failed to get working directory: \(error)")
        }
        return nil
    }

    /// Resolve project name for a given PID
    private func resolveProjectName(for pid: pid_t) -> String? {
        guard let workingDir = getWorkingDirectory(for: pid) else {
            return nil
        }

        // Try to match to a tracked project
        let projects = ProjectsManager.shared.projects
        if let project = projects.first(where: { workingDir.hasPrefix($0.path) }) {
            return project.displayName
        }

        // If not tracked, derive a name from the path
        return deriveProjectName(from: workingDir)
    }

    private func deriveProjectName(from path: String) -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var displayPath = path
        if displayPath.hasPrefix(homeDir) {
            displayPath = String(displayPath.dropFirst(homeDir.count))
            if displayPath.hasPrefix("/") {
                displayPath = String(displayPath.dropFirst())
            }
        }

        let components = displayPath.split(separator: "/")
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        } else if let last = components.last {
            return String(last)
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

extension Notification.Name {
    static let alertsDidChange = Notification.Name("alertsDidChange")
}
