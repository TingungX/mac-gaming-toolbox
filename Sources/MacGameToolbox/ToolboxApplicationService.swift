import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

/// Application-use-case boundary consumed by AppModel. Concrete system
/// services are assembled once at the composition root and remain hidden from
/// presentation state.
protocol ToolboxApplicationCoordinating: Sendable {
    func loadConfiguration() async throws -> AppConfiguration
    func saveConfiguration(_ configuration: AppConfiguration) async throws
    func metalHUDEnabled() async -> Bool
    func setMetalHUD(enabled: Bool) async throws
    func gameModeStatus() async throws -> GameModeStatus
    func setGameModePolicy(_ policy: GameModePolicy) async throws
    func launchWithMetalHUD(applicationPath: String) async throws
    func cleanLegacyHoYoStateIfNeeded() async throws
    func prioritizeCrossOverProcesses() async throws -> Int
    func runningProcesses() async throws -> [SystemProcess]
    func prioritizeProcesses(_ processIDs: [Int32]) async throws
    func eligibleVolumes() async throws -> [DiskVolume]
    func mount(_ assignments: [(String, String)], creatingDirectories: Bool) async throws -> [String: Result<Void, Error>]
    func restoreDefaultMounts(_ identifiers: Set<String>) async throws
    func restorationAssignments(from presets: [DiskPreset], volumes: [DiskVolume]) async -> [(String, String)]
    func importWallpaper(from source: URL, replacing oldPath: String?) async throws -> URL
    func removeManagedWallpaper(at path: String?) async throws -> Bool
    func scanCaches(excludingSensitiveFiles: Bool) async -> CacheScan
    func clearCaches(_ scan: CacheScan) async throws
    func currentHostnames() async throws -> HostnameBackup
    func restoreHostnames(_ backup: HostnameBackup) async throws
    func enableSteamDeckHostnames() async throws
    func helperDiagnosticStatus() async -> String
    func repairCoreFeatures() async throws
}

actor ToolboxApplicationService: ToolboxApplicationCoordinating {
    private let privileged: PrivilegedHelperClient
    private let configurationStore: ConfigurationStore
    private let diskService: DiskService
    private let gamingService: GamingService
    private let gameModeService: GameModeService
    private let hostnameService: HostnameService
    private let cacheService: CacheService
    private let wallpaperService: WallpaperService

    init(
        privileged: PrivilegedHelperClient,
        configurationStore: ConfigurationStore,
        diskService: DiskService,
        gamingService: GamingService,
        gameModeService: GameModeService,
        hostnameService: HostnameService,
        cacheService: CacheService
    ) {
        self.privileged = privileged
        self.configurationStore = configurationStore
        self.diskService = diskService
        self.gamingService = gamingService
        self.gameModeService = gameModeService
        self.hostnameService = hostnameService
        self.cacheService = cacheService
        self.wallpaperService = WallpaperService()
    }

    func loadConfiguration() async throws -> AppConfiguration {
        try await configurationStore.load()
    }

    func saveConfiguration(_ configuration: AppConfiguration) async throws {
        try await configurationStore.save(configuration)
    }

    func metalHUDEnabled() async -> Bool {
        await gamingService.metalHUDEnabled()
    }

    func setMetalHUD(enabled: Bool) async throws {
        try await gamingService.setMetalHUD(enabled: enabled)
    }

    func gameModeStatus() async throws -> GameModeStatus {
        try await gameModeService.status()
    }

    func setGameModePolicy(_ policy: GameModePolicy) async throws {
        try await gameModeService.setPolicy(policy)
    }

    func launchWithMetalHUD(applicationPath: String) async throws {
        try await gamingService.launchWithMetalHUD(applicationPath: applicationPath)
    }

    func cleanLegacyHoYoStateIfNeeded() async throws {
        let hosts = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
        guard hosts.contains("# BEGIN MAC GAME TOOLBOX HOYO") else { return }
        try await privileged.perform(.removeHoYoHosts)
    }

    func prioritizeCrossOverProcesses() async throws -> Int {
        let processes = try await gamingService.wineProcesses(crossOverOnly: true)
        guard !processes.isEmpty else {
            throw ToolboxError.commandFailed(tr(
                "未检测到 CrossOver 或 Wine 进程",
                "No CrossOver or Wine process found"
            ))
        }
        try await privileged.perform(.renice(processes.map(\.pid)))
        return processes.count
    }

    func runningProcesses() async throws -> [SystemProcess] {
        try await gamingService.runningProcesses()
    }

    func prioritizeProcesses(_ processIDs: [Int32]) async throws {
        try await privileged.perform(.renice(processIDs))
    }

    func eligibleVolumes() async throws -> [DiskVolume] {
        try await diskService.listEligibleVolumes()
    }

    func mount(
        _ assignments: [(String, String)],
        creatingDirectories: Bool
    ) async throws -> [String: Result<Void, Error>] {
        if creatingDirectories {
            for (_, path) in assignments where !FileManager.default.fileExists(atPath: path) {
                try await privileged.perform(.createDirectory(path))
            }
        }
        return await diskService.mountBatch(assignments)
    }

    func restoreDefaultMounts(_ identifiers: Set<String>) async throws {
        for identifier in identifiers {
            try await diskService.restoreDefaultMount(identifier)
        }
    }

    func restorationAssignments(
        from presets: [DiskPreset],
        volumes: [DiskVolume]
    ) -> [(String, String)] {
        presets.compactMap { preset in
            guard let path = preset.mountPath,
                  let volume = DiskService.matchingVolume(for: preset, in: volumes),
                  volume.mountPoint != path,
                  FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            return (volume.id, path)
        }
    }

    func importWallpaper(from source: URL, replacing oldPath: String?) throws -> URL {
        try wallpaperService.importWallpaper(from: source, replacing: oldPath)
    }

    func removeManagedWallpaper(at path: String?) throws -> Bool {
        try wallpaperService.removeManagedWallpaper(at: path)
    }

    func scanCaches(excludingSensitiveFiles: Bool) async -> CacheScan {
        await cacheService.scan(excludingSensitiveFiles: excludingSensitiveFiles)
    }

    func clearCaches(_ scan: CacheScan) async throws {
        try await cacheService.clear(scan)
    }

    func currentHostnames() async throws -> HostnameBackup {
        try await hostnameService.current()
    }

    func restoreHostnames(_ backup: HostnameBackup) async throws {
        try await hostnameService.restore(backup)
    }

    func enableSteamDeckHostnames() async throws {
        try await hostnameService.setSteamDeck()
    }

    func helperDiagnosticStatus() -> String {
        privileged.diagnosticStatus()
    }

    func repairCoreFeatures() async throws {
        let shellScript = """
        if /bin/launchctl print system/com.iven.macgametoolbox.helper.v8 >/dev/null 2>&1; then
            /bin/launchctl bootout system/com.iven.macgametoolbox.helper.v8
        fi
        /bin/launchctl enable system/com.iven.macgametoolbox.helper.v8
        /bin/launchctl bootstrap system /Library/LaunchDaemons/com.iven.macgametoolbox.helper.v8.plist
        """
        let appleScript = """
        on run argv
            do shell script item 1 of argv with administrator privileges
        end run
        """

        let result: (Int32, String, String) = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript, "--", shellScript]
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, output, error)
        }.value

        guard result.0 == 0 else {
            if result.2.contains("(-128)") { throw ToolboxError.authorizationCancelled }
            let message = result.2.isEmpty ? result.1 : result.2
            throw ToolboxError.commandFailed(
                message.isEmpty ? tr("核心功能修复失败", "Core feature repair failed") : message
            )
        }
    }
}
