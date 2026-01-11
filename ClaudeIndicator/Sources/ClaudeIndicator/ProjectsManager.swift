import Foundation
import AppKit

struct ClaudeProject: Identifiable, Codable {
    var id: String { path }
    let path: String
    let name: String
    var firstSeen: Date
    var lastActivity: Date
    var sessionCount: Int
    var status: ProjectStatus
    var notes: String

    enum ProjectStatus: String, Codable, CaseIterable {
        case active = "active"
        case paused = "paused"
        case completed = "completed"

        var displayName: String {
            switch self {
            case .active: return "Active"
            case .paused: return "Paused"
            case .completed: return "Completed"
            }
        }

        var icon: String {
            switch self {
            case .active: return "circle.fill"
            case .paused: return "pause.circle.fill"
            case .completed: return "checkmark.circle.fill"
            }
        }

        var color: String {
            switch self {
            case .active: return "green"
            case .paused: return "orange"
            case .completed: return "gray"
            }
        }
    }
}

class ProjectsManager: ObservableObject {
    static let shared = ProjectsManager()

    @Published private(set) var projects: [ClaudeProject] = []
    @Published private(set) var lastUpdated: Date?

    private let claudeProjectsDir: URL
    private let storageURL: URL
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        claudeProjectsDir = homeDir.appendingPathComponent(".claude/projects")
        storageURL = homeDir.appendingPathComponent(".claude/claude-buddy-projects.json")

        loadProjects()
        startWatching()
    }

    deinit {
        stopWatching()
    }

    // MARK: - Loading & Saving

    func loadProjects() {
        // Load saved project metadata
        var savedProjects: [String: ClaudeProject] = [:]
        if let data = try? Data(contentsOf: storageURL),
           let loaded = try? JSONDecoder().decode([ClaudeProject].self, from: data) {
            for project in loaded {
                savedProjects[project.path] = project
            }
        }

        // Scan Claude projects directory
        var discoveredProjects: [ClaudeProject] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            projects = Array(savedProjects.values).sorted { $0.lastActivity > $1.lastActivity }
            return
        }

        for folderURL in contents {
            guard folderURL.hasDirectoryPath else { continue }

            let folderName = folderURL.lastPathComponent
            let projectPath = decodeProjectPath(folderName)

            // Skip if it's not a real project path
            guard projectPath.hasPrefix("/") else { continue }

            // Get session count and last activity from .jsonl files
            let (sessionCount, lastActivity) = getSessionInfo(for: folderURL)

            if var existingProject = savedProjects[projectPath] {
                // Update existing project with fresh data
                existingProject.sessionCount = sessionCount
                existingProject.lastActivity = max(existingProject.lastActivity, lastActivity)
                discoveredProjects.append(existingProject)
                savedProjects.removeValue(forKey: projectPath)
            } else {
                // New project discovered
                let project = ClaudeProject(
                    path: projectPath,
                    name: URL(fileURLWithPath: projectPath).lastPathComponent,
                    firstSeen: lastActivity,
                    lastActivity: lastActivity,
                    sessionCount: sessionCount,
                    status: .active,
                    notes: ""
                )
                discoveredProjects.append(project)
            }
        }

        // Keep saved projects that weren't found (might be on external drive, etc.)
        for (_, project) in savedProjects {
            discoveredProjects.append(project)
        }

        projects = discoveredProjects.sorted { $0.lastActivity > $1.lastActivity }
        lastUpdated = Date()
        saveProjects()
    }

    private func saveProjects() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(projects)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("Failed to save projects: \(error)")
        }
    }

    // MARK: - Path Decoding

    private func decodeProjectPath(_ folderName: String) -> String {
        // Convert "-Users-ak-Code-project" back to "/Users/ak/Code/project"
        var path = folderName
        // First character dash becomes root slash
        if path.hasPrefix("-") {
            path = "/" + path.dropFirst()
        }
        // Remaining dashes become slashes
        path = path.replacingOccurrences(of: "-", with: "/")
        return path
    }

    private func encodeProjectPath(_ path: String) -> String {
        // Convert "/Users/ak/Code/project" to "-Users-ak-Code-project"
        return path.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Session Info

    private func getSessionInfo(for folderURL: URL) -> (count: Int, lastActivity: Date) {
        var sessionCount = 0
        var lastActivity = Date.distantPast

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return (0, Date())
        }

        for file in files {
            if file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                sessionCount += 1

                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    if modDate > lastActivity {
                        lastActivity = modDate
                    }
                }
            }
        }

        return (sessionCount, lastActivity == Date.distantPast ? Date() : lastActivity)
    }

    // MARK: - File Watching

    private func startWatching() {
        guard FileManager.default.fileExists(atPath: claudeProjectsDir.path) else { return }

        fileDescriptor = open(claudeProjectsDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .link],
            queue: .main
        )

        fileWatcher?.setEventHandler { [weak self] in
            self?.loadProjects()
        }

        fileWatcher?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
            self?.fileDescriptor = -1
        }

        fileWatcher?.resume()
    }

    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    // MARK: - Project Management

    func updateStatus(_ project: ClaudeProject, status: ClaudeProject.ProjectStatus) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].status = status
        saveProjects()
        objectWillChange.send()
    }

    func updateNotes(_ project: ClaudeProject, notes: String) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].notes = notes
        saveProjects()
        objectWillChange.send()
    }

    func openInFinder(_ project: ClaudeProject) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    }

    func openInTerminal(_ project: ClaudeProject) {
        let script = """
            tell application "Terminal"
                activate
                do script "cd '\(project.path)'"
            end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - Computed Properties

    var activeProjects: [ClaudeProject] {
        projects.filter { $0.status == .active }
    }

    var recentProjects: [ClaudeProject] {
        Array(projects.prefix(5))
    }

    var totalSessions: Int {
        projects.reduce(0) { $0 + $1.sessionCount }
    }

    /// Projects not accessed in over 7 days
    var forgottenProjects: [ClaudeProject] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days
        return projects.filter { $0.lastActivity < cutoff && $0.status != .completed }
    }

    /// Projects accessed in the last 7 days
    var activeRecentProjects: [ClaudeProject] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days
        return projects.filter { $0.lastActivity >= cutoff || $0.status == .active }
    }

    func hideProject(_ project: ClaudeProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        saveProjects()
        objectWillChange.send()
    }

    func deleteProjectData(_ project: ClaudeProject) {
        // Remove from our list
        hideProject(project)

        // Optionally delete Claude's session data
        let encodedPath = encodeProjectPath(project.path)
        let projectDataURL = claudeProjectsDir.appendingPathComponent(encodedPath)
        try? FileManager.default.removeItem(at: projectDataURL)
    }
}
