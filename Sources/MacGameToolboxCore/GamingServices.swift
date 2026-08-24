import Foundation

public enum PrivilegedOperation: Sendable, Equatable {
    case healthCheck
    case addHoYoHosts
    case removeHoYoHosts
    case renice([Int32])
    case clearSystemCaches
    case setHostnames(HostnameBackup)
    case createDirectory(String)
}

public enum GameModePolicy: String, Codable, Equatable, Sendable {
    case automatic = "auto"
    case on
    case off
}

public struct GameModeStatus: Equatable, Sendable {
    public let policy: GameModePolicy
    public let isEnabled: Bool

    public init(policy: GameModePolicy, isEnabled: Bool) {
        self.policy = policy
        self.isEnabled = isEnabled
    }
}

/// Controls the system Game Mode policy through Apple's gamepolicyctl tool.
/// The tool is resolved through xcrun so the app never embeds an Xcode path.
public actor GameModeService {
    private let runner: any CommandRunning
    private var executablePath: String?

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func status() async throws -> GameModeStatus {
        let result = try await runner.run(try await executable(), arguments: ["game-mode", "status"])
        return try Self.parseStatus(result.outputString)
    }

    public func setPolicy(_ policy: GameModePolicy) async throws {
        _ = try await runner.run(try await executable(), arguments: ["game-mode", "set", policy.rawValue])
    }

    public static func parseStatus(_ output: String) throws -> GameModeStatus {
        let normalized = output
            .replacingOccurrences(of: #"\u001B\[[;\d]*m"#, with: "", options: .regularExpression)
            .lowercased()

        let policy: GameModePolicy
        if normalized.contains("forced always on") {
            policy = .on
        } else if normalized.contains("forced always off") {
            policy = .off
        } else if normalized.contains("automatic") || normalized.contains("automatically") {
            policy = .automatic
        } else {
            throw ToolboxError.malformedOutput("Unable to determine Game Mode policy")
        }

        let isEnabled: Bool
        if normalized.contains("game mode is on") {
            isEnabled = true
        } else if normalized.contains("game mode is off") {
            isEnabled = false
        } else {
            throw ToolboxError.malformedOutput("Unable to determine Game Mode state")
        }
        return GameModeStatus(policy: policy, isEnabled: isEnabled)
    }

    private func executable() async throws -> String {
        if let executablePath { return executablePath }
        let result = try await runner.run("/usr/bin/xcrun", arguments: ["--find", "gamepolicyctl"])
        let path = result.outputString
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent == "gamepolicyctl" else {
            throw ToolboxError.malformedOutput("xcrun returned an invalid gamepolicyctl path")
        }
        executablePath = path
        return path
    }
}

public protocol PrivilegedOperating: Sendable {
    func perform(_ operation: PrivilegedOperation) async throws
}

public actor GamingService {
    public static let hoyoDomains = [
        "globaldp-prod-cn01.bhsr.com", "globaldp-prod-os01.starrails.com",
        "dispatchcnglobal.yuanshen.com", "dispatchosglobal.yuanshen.com",
        "globaldp-prod-cn01.juequling.com", "globaldp-prod-cn02.juequling.com",
        "globaldp-prod-os01.zenlesszonezero.com", "globaldp-prod-os02.zenlesszonezero.com"
    ]

    private let runner: any CommandRunning
    private let privileged: any PrivilegedOperating

    public init(runner: any CommandRunning = ProcessCommandRunner(), privileged: any PrivilegedOperating) {
        self.runner = runner
        self.privileged = privileged
    }

    public func metalHUDEnabled() async -> Bool {
        guard let result = try? await runner.run("/bin/launchctl", arguments: ["getenv", "MTL_HUD_ENABLED"]) else { return false }
        return result.outputString == "1"
    }

    public func setMetalHUD(enabled: Bool) async throws {
        let arguments = enabled ? ["setenv", "MTL_HUD_ENABLED", "1"] : ["unsetenv", "MTL_HUD_ENABLED"]
        _ = try await runner.run("/bin/launchctl", arguments: arguments)
    }

    public func launchWithMetalHUD(applicationPath: String) async throws {
        let applicationURL = URL(fileURLWithPath: applicationPath).standardizedFileURL
        guard applicationURL.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            throw ToolboxError.invalidPath(applicationPath)
        }
        _ = try await runner.run(
            "/usr/bin/env",
            arguments: ["MTL_HUD_ENABLED=1", "/usr/bin/open", "-a", applicationURL.path]
        )
    }

    public func wineProcesses(crossOverOnly: Bool = false) async throws -> [(pid: Int32, command: String)] {
        let result = try await runner.run("/bin/ps", arguments: ["-axo", "pid=,ppid=,command="])
        return Self.matchingProcesses(Self.parseProcessTable(result.outputString), crossOverOnly: crossOverOnly)
            .map { ($0.pid, $0.command) }
    }

    public func runningProcesses() async throws -> [SystemProcess] {
        let result = try await runner.run("/bin/ps", arguments: ["-axo", "pid=,ppid=,command="])
        return Self.parseProcessTable(result.outputString)
            .filter { $0.pid > 1 && !$0.command.lowercased().contains("macgametoolbox") }
            .sorted { $0.command.localizedStandardCompare($1.command) == .orderedAscending }
    }

    public func increasePriority(crossOverOnly: Bool = true) async throws -> Int {
        let processes = try await wineProcesses(crossOverOnly: crossOverOnly)
        guard !processes.isEmpty else { throw ToolboxError.commandFailed(coreText("未检测到 Wine 进程", "No Wine process found")) }
        try await privileged.perform(.renice(processes.map(\.pid)))
        return processes.count
    }

    public func beginHoYoLaunch() async throws {
        try await privileged.perform(.addHoYoHosts)
    }

    public func finishHoYoLaunch() async throws {
        try await privileged.perform(.removeHoYoHosts)
    }

    public func cleanStaleHoYoEntries() async {
        try? await privileged.perform(.removeHoYoHosts)
    }

    public static func parseProcessTable(_ text: String) -> [SystemProcess] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int32(fields[0]), let parentPID = Int32(fields[1]) else { return nil }
            return SystemProcess(pid: pid, parentPID: parentPID, command: String(fields[2]))
        }
    }

    public static func matchingProcesses(_ processes: [SystemProcess], crossOverOnly: Bool) -> [SystemProcess] {
        let roots = Set(processes.filter {
            let value = $0.command.lowercased()
            return value.contains("crossover.app/contents/macos/crossover") || value.hasSuffix("/crossover")
        }.map(\.pid))
        var descendants = roots
        var addedDescendant = true
        while addedDescendant {
            addedDescendant = false
            for process in processes where descendants.contains(process.parentPID) && !descendants.contains(process.pid) {
                descendants.insert(process.pid)
                addedDescendant = true
            }
        }
        return processes.filter { process in
            let value = process.command.lowercased()
            guard !value.contains("macgametoolbox") else { return false }
            let isWine = value.contains("wine") || value.contains("wineserver") || value.contains("winedevice")
            if !crossOverOnly { return isWine }
            // Wine services commonly detach from CrossOver and are re-parented to
            // launchd. If the CrossOver root has exited, retain Wine detection.
            return roots.isEmpty ? isWine : descendants.contains(process.pid) || (value.contains("crossover") && isWine)
        }
    }
}

public actor HostnameService {
    private let runner: any CommandRunning
    private let privileged: any PrivilegedOperating

    public init(runner: any CommandRunning = ProcessCommandRunner(), privileged: any PrivilegedOperating) {
        self.runner = runner
        self.privileged = privileged
    }

    public func current() async throws -> HostnameBackup {
        let computer = try await read("ComputerName")
        let local = (try? await read("LocalHostName")) ?? Self.slug(computer)
        let host = (try? await read("HostName")) ?? local
        return HostnameBackup(computerName: computer, hostName: host, localHostName: local)
    }

    public func setSteamDeck() async throws {
        try await privileged.perform(.setHostnames(HostnameBackup(computerName: "steamdeck", hostName: "steamdeck", localHostName: "steamdeck")))
    }

    public func restore(_ backup: HostnameBackup) async throws {
        try await privileged.perform(.setHostnames(backup))
    }

    private func read(_ key: String) async throws -> String {
        try await runner.run("/usr/sbin/scutil", arguments: ["--get", key]).outputString
    }

    private static func slug(_ value: String) -> String {
        let mapped = value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }
}
