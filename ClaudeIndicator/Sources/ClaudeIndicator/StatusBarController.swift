import AppKit
import SwiftUI

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let alertManager = AlertManager.shared
    private let settings = Settings.shared
    private let stats = StatsManager.shared
    private let resources = ResourcesManager.shared
    private let projects = ProjectsManager.shared

    // Menu items that need updating
    private var ringToggleItem: NSMenuItem!
    private var panelToggleItem: NSMenuItem!
    private var soundToggleItem: NSMenuItem!
    private var blinkToggleItem: NSMenuItem!
    private var dismissItem: NSMenuItem!

    // Stats menu items
    private var statsTodayItem: NSMenuItem!
    private var statsWeekItem: NSMenuItem!
    private var statsStreakItem: NSMenuItem!

    // Resources menu items
    private var resourcesHeaderItem: NSMenuItem!
    private var resourcesSubmenu: NSMenu!

    // Projects menu items
    private var projectsHeaderItem: NSMenuItem!
    private var projectsSubmenu: NSMenu!

    var onSettingsClicked: (() -> Void)?

    override init() {
        super.init()
        setupStatusItem()
        setupMenu()

        // Listen for alert changes to update icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(alertsDidChange),
            name: .alertsDidChange,
            object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateIcon()
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self

        // Stats section (will be updated when menu opens)
        statsTodayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statsTodayItem.isEnabled = false
        menu.addItem(statsTodayItem)

        statsWeekItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statsWeekItem.isEnabled = false
        menu.addItem(statsWeekItem)

        statsStreakItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statsStreakItem.isEnabled = false
        menu.addItem(statsStreakItem)

        menu.addItem(NSMenuItem.separator())

        // Projects section
        projectsHeaderItem = NSMenuItem(title: "Projects", action: nil, keyEquivalent: "")
        projectsHeaderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        projectsSubmenu = NSMenu()
        projectsHeaderItem.submenu = projectsSubmenu
        menu.addItem(projectsHeaderItem)

        // Resources section
        resourcesHeaderItem = NSMenuItem(title: "Resources", action: nil, keyEquivalent: "")
        resourcesHeaderItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        resourcesSubmenu = NSMenu()
        resourcesHeaderItem.submenu = resourcesSubmenu
        menu.addItem(resourcesHeaderItem)

        menu.addItem(NSMenuItem.separator())

        // Dismiss pings
        dismissItem = NSMenuItem(title: "Dismiss All", action: #selector(dismissAlerts), keyEquivalent: "d")
        dismissItem.keyEquivalentModifierMask = [.command, .shift]
        dismissItem.target = self
        menu.addItem(dismissItem)

        menu.addItem(NSMenuItem.separator())

        // Quick toggles
        ringToggleItem = NSMenuItem(title: "Screen Ring", action: #selector(toggleRing), keyEquivalent: "")
        ringToggleItem.target = self
        menu.addItem(ringToggleItem)

        panelToggleItem = NSMenuItem(title: "Ping Panel", action: #selector(togglePanel), keyEquivalent: "")
        panelToggleItem.target = self
        menu.addItem(panelToggleItem)

        soundToggleItem = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        soundToggleItem.target = self
        menu.addItem(soundToggleItem)

        blinkToggleItem = NSMenuItem(title: "Blinking", action: #selector(toggleBlink), keyEquivalent: "")
        blinkToggleItem.target = self
        menu.addItem(blinkToggleItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Claude Buddy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateToggleStates()
        updateStatsDisplay()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateStatsDisplay()
        updateProjectsDisplay()
        updateResourcesDisplay()
    }

    private func updateStatsDisplay() {
        let today = stats.todayStats
        let todayAlerts = today?.alertCount ?? 0

        // Today stats with icon
        statsTodayItem.title = "Today: \(todayAlerts) pings"
        statsTodayItem.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)

        // Week stats
        let weekAlerts = stats.thisWeekAlerts
        statsWeekItem.title = "This week: \(weekAlerts) pings"
        statsWeekItem.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)

        // Streak
        let streak = stats.streakDays
        if streak > 0 {
            statsStreakItem.title = "Streak: \(streak) day\(streak == 1 ? "" : "s")"
            statsStreakItem.image = NSImage(systemSymbolName: "flame", accessibilityDescription: nil)
            statsStreakItem.isHidden = false
        } else {
            statsStreakItem.isHidden = true
        }
    }

    private func updateProjectsDisplay() {
        projectsSubmenu.removeAllItems()

        let recentProjects = projects.recentProjects

        if recentProjects.isEmpty {
            projectsHeaderItem.title = "Projects"
            let emptyItem = NSMenuItem(title: "No projects yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            projectsSubmenu.addItem(emptyItem)
            return
        }

        projectsHeaderItem.title = "Projects (\(projects.projects.count))"

        // Recent projects
        let recentHeader = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentHeader.isEnabled = false
        projectsSubmenu.addItem(recentHeader)

        for project in recentProjects {
            let item = NSMenuItem(title: "  \(project.displayName)", action: #selector(openProjectInTerminal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project
            item.image = statusIcon(for: project.status)
            projectsSubmenu.addItem(item)
        }

        // Forgotten projects count
        let forgottenCount = projects.forgottenProjects.count
        if forgottenCount > 0 {
            projectsSubmenu.addItem(NSMenuItem.separator())
            let forgottenItem = NSMenuItem(title: "\(forgottenCount) forgotten project\(forgottenCount == 1 ? "" : "s")", action: nil, keyEquivalent: "")
            forgottenItem.isEnabled = false
            forgottenItem.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
            projectsSubmenu.addItem(forgottenItem)
        }
    }

    private func statusIcon(for status: ClaudeProject.ProjectStatus) -> NSImage? {
        let name: String
        switch status {
        case .active: name = "circle.fill"
        case .paused: name = "pause.circle.fill"
        case .completed: name = "checkmark.circle.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    }

    @objc private func openProjectInTerminal(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ClaudeProject else { return }
        projects.openInTerminal(project)
    }

    private func updateResourcesDisplay() {
        resources.loadResources()
        resourcesSubmenu.removeAllItems()

        let totalCount = resources.totalResourceCount

        if totalCount == 0 {
            resourcesHeaderItem.title = "Resources"
            let emptyItem = NSMenuItem(title: "No active resources", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            resourcesSubmenu.addItem(emptyItem)
            return
        }

        resourcesHeaderItem.title = "Resources (\(totalCount))"

        // Ports section
        if !resources.ports.isEmpty {
            let portsHeader = NSMenuItem(title: "Ports", action: nil, keyEquivalent: "")
            portsHeader.isEnabled = false
            portsHeader.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            resourcesSubmenu.addItem(portsHeader)

            for port in resources.ports {
                let isActive = resources.isPortInUse(port.port)
                let item = NSMenuItem(title: "  :\(port.port) — \(port.project)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                if isActive {
                    item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
                    item.image?.isTemplate = false
                }
                resourcesSubmenu.addItem(item)
            }
        }

        // Databases section
        if !resources.databases.isEmpty {
            if !resources.ports.isEmpty {
                resourcesSubmenu.addItem(NSMenuItem.separator())
            }

            let dbHeader = NSMenuItem(title: "Databases", action: nil, keyEquivalent: "")
            dbHeader.isEnabled = false
            dbHeader.image = NSImage(systemSymbolName: "cylinder", accessibilityDescription: nil)
            resourcesSubmenu.addItem(dbHeader)

            for db in resources.databases {
                var title = "  \(db.name) — \(db.project)"
                if let port = db.port {
                    title += " (:\(port))"
                }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                resourcesSubmenu.addItem(item)
            }
        }

        // Simulators section
        if !resources.simulators.isEmpty {
            if !resources.ports.isEmpty || !resources.databases.isEmpty {
                resourcesSubmenu.addItem(NSMenuItem.separator())
            }

            let simHeader = NSMenuItem(title: "Simulators", action: nil, keyEquivalent: "")
            simHeader.isEnabled = false
            simHeader.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
            resourcesSubmenu.addItem(simHeader)

            for sim in resources.simulators {
                let item = NSMenuItem(title: "  \(sim.name) — \(sim.project)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
                resourcesSubmenu.addItem(item)
            }
        }

        // Clean action
        resourcesSubmenu.addItem(NSMenuItem.separator())
        let cleanItem = NSMenuItem(title: "Clean Stale Entries", action: #selector(cleanResources), keyEquivalent: "")
        cleanItem.target = self
        resourcesSubmenu.addItem(cleanItem)
    }

    @objc private func cleanResources() {
        resources.cleanStaleEntries()
    }

    private func updateToggleStates() {
        ringToggleItem.state = settings.ringEnabled ? .on : .off
        panelToggleItem.state = settings.alertPanelEnabled ? .on : .off
        soundToggleItem.state = settings.soundEnabled ? .on : .off
        blinkToggleItem.state = settings.blinkingEnabled ? .on : .off
    }

    @objc private func toggleRing() {
        settings.ringEnabled.toggle()
        updateToggleStates()
        NotificationCenter.default.post(name: .alertsDidChange, object: nil)
    }

    @objc private func togglePanel() {
        settings.alertPanelEnabled.toggle()
        updateToggleStates()
        NotificationCenter.default.post(name: .alertsDidChange, object: nil)
    }

    @objc private func toggleSound() {
        settings.soundEnabled.toggle()
        updateToggleStates()
    }

    @objc private func toggleBlink() {
        settings.blinkingEnabled.toggle()
        updateToggleStates()
        NotificationCenter.default.post(name: .alertsDidChange, object: nil)
    }

    @objc private func statusItemClicked(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: show menu
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left-click: dismiss alerts if active, otherwise show menu
            if alertManager.hasActiveAlerts {
                dismissAlerts()
            } else {
                statusItem.menu = menu
                statusItem.button?.performClick(nil)
                statusItem.menu = nil
            }
        }
    }

    @objc private func dismissAlerts() {
        alertManager.dismissAllAlerts()
    }

    @objc private func openSettings() {
        onSettingsClicked?()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func alertsDidChange() {
        updateIcon()
        updateMenuState()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let alertCount = alertManager.alerts.count

        if alertCount > 0 {
            // Show Siri gradient circle with count in center when alerts are active
            let image = createAlertIcon(count: alertCount)
            button.image = image
            button.title = ""
            button.toolTip = alertCount == 1 ? "Claude Buddy — 1 ping" : "Claude Buddy — \(alertCount) pings"
        } else {
            // Show monochrome circle when idle
            if let image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Claude Buddy") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = image.withSymbolConfiguration(config)
            }
            button.toolTip = "Claude Buddy — Watching"
        }
    }

    private func createAlertIcon(count: Int) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { [self] rect in
            let circleRect = NSRect(x: 3, y: 2, width: 14, height: 14)
            let center = NSPoint(x: circleRect.midX, y: circleRect.midY)
            let radius = circleRect.width / 2

            // Draw Siri gradient filled circle
            let segmentCount = siriColors.count
            for i in 0..<segmentCount {
                let startAngle = CGFloat(i) / CGFloat(segmentCount) * 360 - 90
                let endAngle = CGFloat(i + 1) / CGFloat(segmentCount) * 360 - 90

                let path = NSBezierPath()
                path.move(to: center)
                path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                path.close()

                siriColors[i].setFill()
                path.fill()
            }

            // Draw count in center
            let countStr = count > 9 ? "9+" : "\(count)"
            let font = NSFont.systemFont(ofSize: 9, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = countStr.size(withAttributes: attributes)
            let textRect = NSRect(
                x: center.x - textSize.width / 2,
                y: center.y - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            countStr.draw(in: textRect, withAttributes: attributes)

            return true
        }
        image.isTemplate = false
        return image
    }

    // Siri-style colors
    private let siriColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.18, blue: 0.57, alpha: 1.0),   // Pink
        NSColor(red: 0.61, green: 0.35, blue: 0.71, alpha: 1.0),  // Purple
        NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),    // Blue
        NSColor(red: 0.35, green: 0.78, blue: 0.98, alpha: 1.0),  // Cyan
        NSColor(red: 0.2, green: 0.78, blue: 0.65, alpha: 1.0),   // Teal
        NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1.0),    // Orange
        NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),   // Red
    ]

    private func updateMenuState() {
        dismissItem.isEnabled = alertManager.hasActiveAlerts
        updateToggleStates()
    }
}
