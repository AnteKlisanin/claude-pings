import Foundation
import AppKit

struct PortResource: Codable, Identifiable {
    var id: String { port }
    let port: String
    let project: String
    let path: String?
    let started: String?
}

struct DatabaseResource: Codable, Identifiable {
    var id: String { name }
    let name: String
    let project: String
    let port: Int?
}

struct SimulatorResource: Codable, Identifiable {
    var id: String { udid }
    let udid: String
    let name: String
    let project: String
    let deviceType: String?
    let started: String?
}

struct DetectedPort: Identifiable, Equatable {
    var id: Int { port }
    let port: Int
    let pid: Int
    let processName: String
    let workingDirectory: String?
    let projectName: String?
}

struct SharedResources: Codable {
    var ports: [String: PortInfo]
    var databases: [String: DatabaseInfo]
    var redis: [String: RedisInfo]
    var simulators: [String: SimulatorInfo]
    var notes: String?

    struct PortInfo: Codable {
        let project: String
        let path: String?
        let started: String?
    }

    struct DatabaseInfo: Codable {
        let project: String
        let port: Int?
    }

    struct RedisInfo: Codable {
        let project: String
        let port: Int?
    }

    struct SimulatorInfo: Codable {
        let name: String
        let project: String
        let deviceType: String?
        let started: String?
    }

    static var empty: SharedResources {
        SharedResources(ports: [:], databases: [:], redis: [:], simulators: [:], notes: nil)
    }
}

class ResourcesManager: ObservableObject {
    static let shared = ResourcesManager()

    @Published private(set) var resources: SharedResources = .empty
    @Published private(set) var detectedPorts: [DetectedPort] = []
    @Published private(set) var lastUpdated: Date?

    private let fileURL: URL
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var scanTimer: Timer?

    // Common development ports to scan
    private let commonPorts = [
        3000, 3001, 3002, 3003,  // Node.js, React, Next.js
        4000, 4200, 4567,        // Phoenix, Angular, Sinatra
        5000, 5001, 5173, 5174,  // Flask, Vite
        6006,                     // Storybook
        8000, 8001, 8080, 8081, 8888,  // Django, common HTTP
        9000, 9090,              // PHP, various
        19000, 19001, 19002,     // Expo
    ]

    private init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/shared-resources.json")

        loadResources()
        startWatching()
        scanForPorts()  // Initial scan
        startPeriodicScanning()
    }

    deinit {
        stopWatching()
        scanTimer?.invalidate()
    }

    // MARK: - File Operations

    func loadResources() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            resources = .empty
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            resources = try JSONDecoder().decode(SharedResources.self, from: data)
            lastUpdated = Date()
        } catch {
            print("Failed to load shared resources: \(error)")
            resources = .empty
        }

        objectWillChange.send()
    }

    func saveResources() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(resources)
            try data.write(to: fileURL, options: .atomic)
            lastUpdated = Date()
        } catch {
            print("Failed to save shared resources: \(error)")
        }
    }

    // MARK: - File Watching

    private func startWatching() {
        // Ensure file exists
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "{}".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )

        fileWatcher?.setEventHandler { [weak self] in
            self?.loadResources()
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

    // MARK: - Computed Properties

    var ports: [PortResource] {
        resources.ports.map { key, value in
            PortResource(port: key, project: value.project, path: value.path, started: value.started)
        }.sorted { $0.port < $1.port }
    }

    var databases: [DatabaseResource] {
        resources.databases.map { key, value in
            DatabaseResource(name: key, project: value.project, port: value.port)
        }.sorted { $0.name < $1.name }
    }

    var simulators: [SimulatorResource] {
        resources.simulators.map { key, value in
            SimulatorResource(udid: key, name: value.name, project: value.project, deviceType: value.deviceType, started: value.started)
        }.sorted { $0.name < $1.name }
    }

    var totalResourceCount: Int {
        resources.ports.count + resources.databases.count + resources.simulators.count + resources.redis.count
    }

    var activePortsCount: Int { resources.ports.count }
    var activeDatabasesCount: Int { resources.databases.count }
    var activeSimulatorsCount: Int { resources.simulators.count }

    // MARK: - Resource Management

    func addPort(_ port: String, project: String, path: String?) {
        resources.ports[port] = SharedResources.PortInfo(
            project: project,
            path: path,
            started: ISO8601DateFormatter().string(from: Date())
        )
        saveResources()
    }

    func removePort(_ port: String) {
        resources.ports.removeValue(forKey: port)
        saveResources()
    }

    func addSimulator(udid: String, name: String, project: String, deviceType: String?) {
        resources.simulators[udid] = SharedResources.SimulatorInfo(
            name: name,
            project: project,
            deviceType: deviceType,
            started: ISO8601DateFormatter().string(from: Date())
        )
        saveResources()
    }

    func removeSimulator(_ udid: String) {
        resources.simulators.removeValue(forKey: udid)
        saveResources()
    }

    func addDatabase(name: String, project: String, port: Int?) {
        resources.databases[name] = SharedResources.DatabaseInfo(
            project: project,
            port: port
        )
        saveResources()
    }

    func removeDatabase(_ name: String) {
        resources.databases.removeValue(forKey: name)
        saveResources()
    }

    // MARK: - Validation

    func isPortInUse(_ port: String) -> Bool {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "lsof -i :\(port) -t 2>/dev/null"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    func cleanStaleEntries() {
        var modified = false

        // Check ports
        for port in resources.ports.keys {
            if !isPortInUse(port) {
                resources.ports.removeValue(forKey: port)
                modified = true
            }
        }

        // Check simulators (verify they're still booted)
        let bootedSimulators = getBootedSimulators()
        for udid in resources.simulators.keys {
            if !bootedSimulators.contains(udid) {
                resources.simulators.removeValue(forKey: udid)
                modified = true
            }
        }

        if modified {
            saveResources()
        }

        // Also refresh detected ports
        scanForPorts()
    }

    private func getBootedSimulators() -> Set<String> {
        let task = Process()
        task.launchPath = "/usr/bin/xcrun"
        task.arguments = ["simctl", "list", "devices", "-j"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [String: [[String: Any]]] {
                var bootedUDIDs = Set<String>()
                for (_, deviceList) in devices {
                    for device in deviceList {
                        if let state = device["state"] as? String,
                           state == "Booted",
                           let udid = device["udid"] as? String {
                            bootedUDIDs.insert(udid)
                        }
                    }
                }
                return bootedUDIDs
            }
        } catch {
            print("Failed to get booted simulators: \(error)")
        }
        return []
    }

    // MARK: - Summary

    var summaryText: String {
        var parts: [String] = []

        let totalPorts = resources.ports.count + detectedPorts.count
        if totalPorts > 0 {
            parts.append("\(totalPorts) port\(totalPorts == 1 ? "" : "s")")
        }
        if !resources.databases.isEmpty {
            parts.append("\(resources.databases.count) db\(resources.databases.count == 1 ? "" : "s")")
        }
        if !resources.simulators.isEmpty {
            parts.append("\(resources.simulators.count) sim\(resources.simulators.count == 1 ? "" : "s")")
        }

        return parts.isEmpty ? "No active resources" : parts.joined(separator: ", ")
    }

    // MARK: - Auto Port Detection

    private func startPeriodicScanning() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.scanForPorts()
        }
    }

    func scanForPorts() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            var detected: [DetectedPort] = []

            // Scan common ports
            for port in self.commonPorts {
                if let portInfo = self.getPortInfo(port) {
                    // Skip if already in manually registered resources
                    if self.resources.ports[String(port)] == nil {
                        detected.append(portInfo)
                    }
                }
            }

            // Also do a broader scan for listening ports
            let additionalPorts = self.scanListeningPorts()
            for portInfo in additionalPorts {
                if self.resources.ports[String(portInfo.port)] == nil &&
                   !detected.contains(where: { $0.port == portInfo.port }) {
                    detected.append(portInfo)
                }
            }

            // Debug logging to file
            let debugLog = "[\(Date())] Scanned ports, found \(detected.count): \(detected.map { $0.port })\n"
            if let data = debugLog.data(using: .utf8) {
                let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/indicator-debug.log")
                if FileManager.default.fileExists(atPath: logPath.path) {
                    if let handle = try? FileHandle(forWritingTo: logPath) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: logPath)
                }
            }

            DispatchQueue.main.async {
                self.detectedPorts = detected.sorted { $0.port < $1.port }
                self.lastUpdated = Date()
                self.objectWillChange.send()
                print("[ResourcesManager] Updated detectedPorts: \(self.detectedPorts.count)")
            }
        }
    }

    private func getPortInfo(_ port: Int) -> DetectedPort? {
        // Use lsof to get process info for the port
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "lsof -i :\(port) -sTCP:LISTEN -n -P 2>/dev/null | tail -1"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else { return nil }

            // Parse lsof output: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = Int(parts[1]) else { return nil }

            let processName = String(parts[0])
            let workingDir = getWorkingDirectory(for: pid)
            let projectName = deriveProjectName(from: workingDir)

            return DetectedPort(
                port: port,
                pid: pid,
                processName: processName,
                workingDirectory: workingDir,
                projectName: projectName
            )
        } catch {
            return nil
        }
    }

    // System processes to ignore when scanning ports
    private let ignoredProcesses = Set([
        "rapportd", "sharingd", "ControlCe", "ControlCenter",
        "Google", "adb", "mDNSResponder", "httpd", "nginx",
        "Dropbox", "OneDrive", "iCloud", "Finder",
        "com.docke", "docker", "containerd",
        "postgres", "mysqld", "mongod", "redis-server",  // DB servers (tracked separately)
        "replicato", "remotepai"
    ])

    // Ports to ignore (system/common services)
    private let ignoredPorts = Set([
        22, 53, 80, 443, 445, 548, 631, 3306, 5353, 5432, 6379, 27017,
        49152, 49153, 49154, 49155  // Dynamic/ephemeral ports
    ])

    private func scanListeningPorts() -> [DetectedPort] {
        // Scan for all listening TCP ports in the dev range
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "lsof -i -sTCP:LISTEN -n -P 2>/dev/null | grep -E ':(3[0-9]{3}|4[0-9]{3}|5[0-9]{3}|6[0-9]{3}|8[0-9]{3}|9[0-9]{3}|1[0-9]{4})' | awk '{print $2, $1, $9}'"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        var detected: [DetectedPort] = []

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count >= 3,
                      let pid = Int(parts[0]) else { continue }

                let processName = String(parts[1])
                let addressPart = String(parts[2])

                // Skip ignored processes
                if ignoredProcesses.contains(processName) { continue }

                // Extract port from address (e.g., "*:3000" or "127.0.0.1:3000")
                if let colonIndex = addressPart.lastIndex(of: ":"),
                   let port = Int(addressPart[addressPart.index(after: colonIndex)...]) {

                    // Skip ignored ports
                    if ignoredPorts.contains(port) { continue }

                    // Skip high ephemeral ports (typically > 49000)
                    if port > 49000 { continue }

                    // Skip if already detected
                    if detected.contains(where: { $0.port == port }) { continue }

                    let workingDir = getWorkingDirectory(for: pid)
                    let projectName = deriveProjectName(from: workingDir)

                    detected.append(DetectedPort(
                        port: port,
                        pid: pid,
                        processName: processName,
                        workingDirectory: workingDir,
                        projectName: projectName
                    ))
                }
            }
        } catch {
            // Ignore errors
        }

        return detected
    }

    private func getWorkingDirectory(for pid: Int) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-p", "\(pid)", "-Fn", "-a", "-d", "cwd"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.split(separator: "\n") {
                    if line.hasPrefix("n") {
                        return String(line.dropFirst())
                    }
                }
            }
        } catch {
            // Ignore
        }
        return nil
    }

    private func deriveProjectName(from path: String?) -> String? {
        guard let path = path else { return nil }

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
