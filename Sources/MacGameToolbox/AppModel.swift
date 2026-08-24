import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var status = TaskStatus()
    @Published var configuration = AppConfiguration()
    @Published var disks: [DiskVolume] = []
    @Published var selectedDiskIDs = Set<String>()
    @Published var diskPaths: [String: String] = [:]
    @Published var metalHUDEnabled = false
    @Published var gameModeEnabled = false
    @Published var gameModeAvailable = false
    @Published var gameModePolicy: GameModePolicy?
    @Published var gameModeUnavailableReason: String?
    @Published var isGameModeBusy = false
    @Published var cacheScan: CacheScan?
    @Published var showingDiskManager = false
    @Published var showingCacheConfirmation = false
    @Published var cacheConfirmationStage = 0
    @Published var showingTutorials = false
    @Published var showingGenshinConfiguration = false
    @Published var isGenshinWorkflowRunning = false
    @Published var showingProcessSelection = false
    @Published var runningProcesses: [SystemProcess] = []
    @Published var selectedProcessIDs = Set<Int32>()

    private let application: any ToolboxApplicationCoordinating
    private let genshinWorkflow: any GenshinWorkflowCoordinating
    private let workflowInitializationError: String?
    private let diagnosticsService = DiagnosticsService()
    private var genshinTask: Task<Void, Never>?
    private var automaticMountTask: Task<Void, Never>?
    private var didLaunch = false

    init(dependencies: AppDependencies) {
        application = dependencies.application
        genshinWorkflow = dependencies.genshinWorkflow
        workflowInitializationError = dependencies.workflowInitializationError
        launch()
    }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        DiagnosticFileLogger.write("App launched, version 3.0.7")
        Task {
            do { configuration = try await application.loadConfiguration() }
            catch { report(error) }
            metalHUDEnabled = await application.metalHUDEnabled()
            do {
                try await application.cleanLegacyHoYoStateIfNeeded()
            } catch {
                DiagnosticFileLogger.write("Legacy HoYo state cleanup failed: \(error.localizedDescription)")
            }
            if let workflowInitializationError {
                report(ToolboxError.commandFailed(tr(
                    "工作流日志无法初始化：\(workflowInitializationError)",
                    "Workflow journal could not be initialized: \(workflowInitializationError)"
                )))
            } else {
                await recoverIncompleteGameWorkflows()
            }
            do {
                let gameMode = try await application.gameModeStatus()
                gameModeAvailable = true
                gameModeUnavailableReason = nil
                gameModePolicy = gameMode.policy
                gameModeEnabled = gameMode.policy == .on
            } catch {
                gameModeAvailable = false
                gameModeEnabled = false
                gameModePolicy = nil
                gameModeUnavailableReason = error.localizedDescription
                DiagnosticFileLogger.write("Game Mode unavailable: \(error.localizedDescription)")
            }
            startAutomaticMountMonitoring()
        }
    }

    func setMetalHUD(_ enabled: Bool) {
        runTask(tr("正在更新 MetalHUD", "Updating MetalHUD")) {
            try await self.application.setMetalHUD(enabled: enabled)
            self.metalHUDEnabled = enabled
            return enabled ? tr("MetalHUD 已开启", "MetalHUD enabled") : tr("MetalHUD 已关闭", "MetalHUD disabled")
        }
    }

    func toggleGameMode() {
        guard gameModeAvailable, !isGameModeBusy else { return }
        isGameModeBusy = true
        if gameModeEnabled {
            runTask(tr("正在恢复 Game Mode 自动策略", "Restoring automatic Game Mode policy")) {
                defer { self.isGameModeBusy = false }
                try await self.application.setGameModePolicy(.automatic)
                self.gameModeEnabled = false
                self.gameModePolicy = .automatic
                return tr("Game Mode 已关闭，已恢复自动策略", "Game Mode disabled; automatic policy restored")
            }
            return
        }

        runTask(tr("正在开启 Game Mode", "Enabling Game Mode")) {
            defer { self.isGameModeBusy = false }
            try await self.application.setGameModePolicy(.on)
            let processCount: Int
            do {
                processCount = try await self.application.prioritizeCrossOverProcesses()
            } catch {
                do {
                    try await self.application.setGameModePolicy(.automatic)
                } catch let rollbackError {
                    throw ToolboxError.commandFailed(tr(
                        "Game Mode 已开启，但恢复自动策略失败：\(rollbackError.localizedDescription)。原始错误：\(error.localizedDescription)",
                        "Game Mode was enabled, but restoring automatic policy failed: \(rollbackError.localizedDescription). Original error: \(error.localizedDescription)"
                    ))
                }
                throw error
            }
            self.gameModeAvailable = true
            self.gameModeEnabled = true
            self.gameModePolicy = .on
            return tr(
                "Game Mode 已开启，已优化 \(processCount) 个进程",
                "Game Mode enabled; optimized \(processCount) process(es)"
            )
        }
    }

    func launchAppWithMetalHUD() {
        let panel = NSOpenPanel()
        panel.title = tr("选择要启用 MetalHUD 的 App", "Choose an app for MetalHUD")
        panel.prompt = tr("启用并打开", "Enable and Open")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }

        launchRecordedAppWithMetalHUD(applicationURL.path)
    }

    func launchRecordedAppWithMetalHUD(_ path: String) {
        let applicationURL = URL(fileURLWithPath: path)
        runTask(tr("正在使用 MetalHUD 启动 App", "Launching app with MetalHUD")) {
            try await self.application.launchWithMetalHUD(applicationPath: applicationURL.path)
            self.rememberMetalHUDApp(applicationURL)
            return tr("已使用 MetalHUD 打开 \(applicationURL.deletingPathExtension().lastPathComponent)", "Opened \(applicationURL.deletingPathExtension().lastPathComponent) with MetalHUD")
        }
    }

    func removeRecentMetalHUDApp(_ app: RecentMetalHUDApp) {
        configuration.recentMetalHUDApps.removeAll { $0.path == app.path }
        saveConfiguration()
    }

    func increaseCrossOverPriority() {
        runTask(tr("正在检测 CrossOver", "Detecting CrossOver")) {
            self.status.phase = .awaitingAuthorization
            let count = try await self.application.prioritizeCrossOverProcesses()
            DiagnosticFileLogger.write("Prioritized CrossOver process count: \(count)")
            return tr("已提高 \(count) 个进程的优先级", "Updated \(count) processes")
        }
    }

    func loadProcessesForManualSelection() {
        showingProcessSelection = true
        runningProcesses = []
        selectedProcessIDs.removeAll()
        Task {
            do { runningProcesses = try await application.runningProcesses() }
            catch { report(error) }
        }
    }

    func increaseSelectedProcessPriority() {
        let identifiers = Array(selectedProcessIDs)
        guard !identifiers.isEmpty else { return }
        showingProcessSelection = false
        runTask(tr("正在提高所选进程优先级", "Increasing selected process priority")) {
            self.status.phase = .awaitingAuthorization
            try await self.application.prioritizeProcesses(identifiers)
            return tr("已提高 \(identifiers.count) 个进程的优先级", "Updated \(identifiers.count) selected process(es)")
        }
    }

    var genshinInstallation: GameInstallation? {
        configuration.gameInstallations.first { $0.id == GenshinWorkflowCoordinator.installationID }
    }

    func startGenshinWorkflow() {
        guard genshinTask == nil else { return }
        guard let installation = genshinInstallation else {
            showingGenshinConfiguration = true
            return
        }

        isGenshinWorkflowRunning = true
        status = TaskStatus(
            phase: .awaitingAuthorization,
            message: tr("正在准备原神启动流程", "Preparing the Genshin launch workflow"),
            progress: 0,
            log: []
        )
        genshinTask = Task { [self] in
            do {
                let result = try await genshinWorkflow.run(
                    installation: installation,
                    metalHUDEnabled: metalHUDEnabled
                ) { update in
                    await self.applyGenshinWorkflowUpdate(update)
                }
                applyGenshinWorkflowResult(result)
            } catch is CancellationError {
                status = TaskStatus(
                    phase: .cancelled,
                    message: tr("已取消", "Cancelled")
                )
            } catch {
                report(error)
            }
            genshinTask = nil
            isGenshinWorkflowRunning = false
        }
    }

    func cancelGenshinWorkflow() {
        Task { await genshinWorkflow.cancel() }
    }

    func saveGenshinInstallation(_ binding: CrossOverGameBinding) {
        do {
            let validated = try CrossOverLaunchConfiguration(
                crossOverAppURL: URL(fileURLWithPath: binding.applicationPath),
                bottle: binding.bottleName,
                executablePath: binding.executablePath,
                workingDirectoryPath: binding.workingDirectoryPath
            )
            guard FileManager.default.fileExists(atPath: validated.crossOverApp.url.path),
                  FileManager.default.isExecutableFile(atPath: validated.crossOverApp.cxstartURL.path) else {
                throw ToolboxError.invalidPath(binding.applicationPath)
            }
            let installation = GameInstallation(
                id: GenshinWorkflowCoordinator.installationID,
                displayName: tr("原神", "Genshin Impact"),
                launchBinding: .crossOver(binding)
            )
            configuration.gameInstallations.removeAll { $0.id == installation.id }
            configuration.gameInstallations.append(installation)
            saveConfiguration()
            showingGenshinConfiguration = false
            status = TaskStatus(
                phase: .succeeded,
                message: tr("原神启动配置已保存", "Genshin launch configuration saved"),
                progress: 1
            )
        } catch {
            report(error)
        }
    }

    func loadDisks() {
        showingDiskManager = true
        Task {
            do {
                disks = try await application.eligibleVolumes()
                for preset in configuration.diskPresets { if let path = preset.mountPath { diskPaths[preset.diskIdentifier] = path } }
            } catch { report(error) }
        }
    }

    func choosePath(for diskID: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("选择", "Choose")
        if panel.runModal() == .OK, let url = panel.url { diskPaths[diskID] = url.path }
    }

    func mountSelectedDisks() {
        let assignments = selectedDiskIDs.compactMap { id -> (String, String)? in
            guard let path = diskPaths[id], !path.isEmpty else { return nil }
            return (id, path)
        }
        guard assignments.count == selectedDiskIDs.count, !assignments.isEmpty else {
            report(ToolboxError.invalidPath(tr("请为每个磁盘选择路径", "Choose a path for every volume")))
            return
        }
        runTask(tr("正在挂载磁盘", "Mounting volumes")) {
            self.status.phase = .awaitingAuthorization
            let results = try await self.application.mount(assignments, creatingDirectories: true)
            let failures = results.compactMap { key, result -> String? in if case .failure = result { return key }; return nil }
            guard failures.isEmpty else { throw ToolboxError.commandFailed(tr("挂载失败并已回滚：\(failures.joined(separator: ", "))", "Mount failed and rolled back: \(failures.joined(separator: ", "))")) }
            self.rememberRestorableMounts(assignments)
            return tr("已成功挂载 \(assignments.count) 个卷", "Mounted \(assignments.count) volume(s)")
        }
    }

    func restoreSelectedDisks() {
        runTask(tr("正在恢复默认挂载", "Restoring default mounts")) {
            try await self.application.restoreDefaultMounts(self.selectedDiskIDs)
            let selectedUUIDs = Set(self.disks.filter { self.selectedDiskIDs.contains($0.id) }.compactMap(\.volumeUUID))
            self.configuration.restorableDiskMounts.removeAll {
                self.selectedDiskIDs.contains($0.diskIdentifier) || ($0.volumeUUID.map(selectedUUIDs.contains) ?? false)
            }
            self.saveConfiguration()
            return tr("已恢复系统默认挂载路径", "Default mounts restored")
        }
    }

    func saveDiskPreset(_ identifier: String) {
        configuration.diskPresets.removeAll { $0.diskIdentifier == identifier }
        configuration.diskPresets.insert(DiskPreset(diskIdentifier: identifier, mountPath: diskPaths[identifier]), at: 0)
        configuration.diskPresets = Array(configuration.diskPresets.prefix(ConfigurationStore.maxPresets))
        saveConfiguration()
    }

    func deleteDiskPreset(_ identifier: String) {
        configuration.diskPresets.removeAll { $0.diskIdentifier == identifier }
        saveConfiguration()
    }

    func setAutomaticallyRestoreMountsOnLaunch(_ enabled: Bool) {
        configuration.automaticallyRestoreMountsOnLaunch = enabled
        saveConfiguration()
        startAutomaticMountMonitoring()
    }

    func restorePreviousMounts() {
        status = TaskStatus(phase: .running, message: tr("正在恢复上次挂载", "Restoring previous mounts"))
        Task {
            do {
                let availableVolumes = try await application.eligibleVolumes()
                disks = availableVolumes
                enrichRestorableMountUUIDs(from: availableVolumes)
                guard !configuration.restorableDiskMounts.isEmpty else {
                    throw ToolboxError.commandFailed(tr("没有可恢复的挂载记录", "No previous mounts to restore"))
                }
                await restoreMounts(from: availableVolumes, manual: true)
            } catch { report(error) }
        }
    }

    func addDefaultPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("添加", "Add")
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        configuration.defaultPaths.removeAll { $0 == path }
        configuration.defaultPaths.insert(path, at: 0)
        configuration.defaultPaths = Array(configuration.defaultPaths.prefix(ConfigurationStore.maxDefaultPaths))
        saveConfiguration()
    }

    func deleteDefaultPath(_ path: String) {
        configuration.defaultPaths.removeAll { $0 == path }
        saveConfiguration()
    }

    func importWallpaper() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = tr("导入壁纸", "Import Wallpaper")
        panel.prompt = tr("导入", "Import")
        guard panel.runModal() == .OK, let source = panel.url else { return }

        runTask(tr("正在导入自定义背景", "Importing custom wallpaper")) {
            let oldPath = self.configuration.customWallpaperPath
            let destination = try await self.application.importWallpaper(from: source, replacing: oldPath)
            self.configuration.customWallpaperPath = destination.path
            self.saveConfiguration()
            DiagnosticFileLogger.write("Custom wallpaper imported: \(destination.path)")
            return tr("已导入自定义背景", "Custom wallpaper imported")
        }
    }

    func resetWallpaper() {
        let oldPath = configuration.customWallpaperPath
        configuration.customWallpaperPath = nil
        saveConfiguration()
        runTask(tr("正在恢复默认背景", "Restoring default wallpaper")) {
            let removed = try await self.application.removeManagedWallpaper(at: oldPath)
            DiagnosticFileLogger.write("Custom wallpaper cleared; removed file: \(removed)")
            return tr("已恢复默认背景", "Default background restored")
        }
    }

    func prepareCacheScan() {
        status = TaskStatus(phase: .running, message: tr("正在扫描缓存", "Scanning caches"))
        Task {
            cacheScan = await application.scanCaches(excludingSensitiveFiles: configuration.excludesSensitiveCacheFiles)
            cacheConfirmationStage = 1
            showingCacheConfirmation = true
            status = TaskStatus()
        }
    }

    func confirmCacheCleaning() {
        if cacheConfirmationStage == 1, !configuration.excludesSensitiveCacheFiles {
            cacheConfirmationStage = 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showingCacheConfirmation = true }
            return
        }
        guard let scan = cacheScan else { return }
        runTask(tr("正在清理缓存", "Cleaning caches")) {
            if !scan.systemTargets.isEmpty { self.status.phase = .awaitingAuthorization }
            try await self.application.clearCaches(scan)
            return tr("缓存清理完成", "Cache cleaning completed")
        }
    }

    func setExcludesSensitiveCacheFiles(_ enabled: Bool) {
        configuration.excludesSensitiveCacheFiles = enabled
        saveConfiguration()
    }

    func toggleSteamDeck() {
        runTask(tr("正在读取设备名称", "Reading hostnames")) {
            let current = try await self.application.currentHostnames()
            self.status.phase = .awaitingAuthorization
            if current.computerName == "steamdeck" {
                guard let backup = self.configuration.hostnameBackup else { throw ToolboxError.commandFailed(tr("找不到原始设备名称备份", "Hostname backup is missing")) }
                try await self.application.restoreHostnames(backup)
                self.configuration.hostnameBackup = nil
                self.saveConfiguration()
                return tr("已恢复原始设备名称", "Original hostnames restored")
            }
            self.configuration.hostnameBackup = current
            self.saveConfiguration()
            try await self.application.enableSteamDeckHostnames()
            return tr("已切换至 SteamDeck 模式", "SteamDeck mode enabled")
        }
    }

    func requestDiagnosticsExport() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = tr("Mac游戏工具箱-诊断-\(Self.diagnosticTimestamp()).txt", "MacGameToolbox-Diagnostics-\(Self.diagnosticTimestamp()).txt")
        panel.title = tr("导出诊断日志", "Export Diagnostics")
        panel.prompt = tr("导出", "Export")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportDiagnostics(to: destination)
    }

    func repairCoreFeatures() {
        runTask(tr("正在修复核心功能", "Repairing core features")) {
            self.status.phase = .awaitingAuthorization
            try await self.application.repairCoreFeatures()
            return tr("核心功能已修复", "Core features repaired")
        }
    }

    func exportDiagnostics(to destination: URL) {
        let currentStatus = status
        let currentConfiguration = configuration
        status = TaskStatus(phase: .running, message: tr("正在收集诊断日志", "Collecting diagnostics"))
        DiagnosticFileLogger.write("Diagnostics export started: \(destination.path)")
        do {
            try (tr("诊断日志正在收集，请稍候…", "Diagnostics collection in progress…") + "\n").write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            report(error)
            return
        }
        Task {
            let helperStatus = await application.helperDiagnosticStatus()
            let diagnosticsText = await diagnosticsService.collect(taskStatus: currentStatus, helperStatus: helperStatus, configuration: currentConfiguration)
            do {
                try diagnosticsText.write(to: destination, atomically: true, encoding: .utf8)
                status = TaskStatus(phase: .succeeded, message: tr("诊断日志已导出：\(destination.path)", "Diagnostics exported: \(destination.path)"))
                DiagnosticFileLogger.write("Diagnostics exported: \(destination.path)")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { report(error) }
        }
    }

    private static func diagnosticTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func startAutomaticMountMonitoring() {
        automaticMountTask?.cancel()
        automaticMountTask = nil
        guard configuration.automaticallyRestoreMountsOnLaunch else { return }
        automaticMountTask = Task { [weak self] in
            await self?.monitorDisksAndRestoreMounts()
        }
    }

    private func monitorDisksAndRestoreMounts() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var nextLogSecond = 0
        while !Task.isCancelled, configuration.automaticallyRestoreMountsOnLaunch {
            do {
                let availableVolumes = try await application.eligibleVolumes()
                disks = availableVolumes
                enrichRestorableMountUUIDs(from: availableVolumes)
                let elapsedSeconds = Int(startedAt.duration(to: clock.now).components.seconds)
                if elapsedSeconds >= nextLogSecond {
                    let identifiers = availableVolumes.map {
                        "\($0.id)[\($0.volumeUUID ?? "no-uuid")]=\($0.mountPoint ?? "unmounted")"
                    }.joined(separator: ", ")
                    DiagnosticFileLogger.write("Automatic disk scan \(elapsedSeconds)s: \(identifiers.isEmpty ? "no eligible volumes" : identifiers)")
                    nextLogSecond = max(10, ((elapsedSeconds / 10) + 1) * 10)
                }
                if elapsedSeconds >= 10 { await restoreMounts(from: availableVolumes) }
            } catch {
                DiagnosticFileLogger.write("Automatic disk refresh failed: \(error.localizedDescription)")
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    private func restoreMounts(from volumes: [DiskVolume], manual: Bool = false) async {
        let assignments = await application.restorationAssignments(
            from: configuration.restorableDiskMounts,
            volumes: volumes
        )
        guard !assignments.isEmpty else {
            if manual {
                report(ToolboxError.commandFailed(tr("没有找到可恢复的磁盘和路径", "No matching volume and path found to restore")))
                return
            }
            if !configuration.restorableDiskMounts.isEmpty {
                DiagnosticFileLogger.write("Automatic mount restore waiting: no matching unmounted target with an existing path")
            }
            return
        }

        status = TaskStatus(phase: .running, message: tr("正在自动恢复上次挂载", "Restoring previous mounts"))
        let results: [String: Result<Void, Error>]
        do {
            results = try await application.mount(assignments, creatingDirectories: false)
        } catch {
            report(error)
            return
        }
        let succeeded = assignments.filter {
            guard case .success? = results[$0.0] else { return false }
            return true
        }
        if succeeded.count == assignments.count {
            rememberRestorableMounts(succeeded)
            status = TaskStatus(phase: .succeeded, message: tr("已自动恢复 \(succeeded.count) 个卷的挂载", "Restored \(succeeded.count) previous mount(s)"), progress: 1)
            DiagnosticFileLogger.write("Automatically restored \(succeeded.count) mount(s)")
        } else {
            report(ToolboxError.commandFailed(tr("自动恢复上次挂载失败", "Failed to restore previous mounts")))
        }
    }

    private func rememberRestorableMounts(_ assignments: [(String, String)]) {
        let identifiers = Set(assignments.map(\.0))
        let presets = assignments.map { identifier, path in
            let volume = disks.first { $0.id == identifier }
            return DiskPreset(diskIdentifier: identifier, volumeUUID: volume?.volumeUUID, mountPath: path)
        }
        let volumeUUIDs = Set(presets.compactMap(\.volumeUUID))
        configuration.restorableDiskMounts.removeAll {
            identifiers.contains($0.diskIdentifier) || ($0.volumeUUID.map(volumeUUIDs.contains) ?? false)
        }
        configuration.restorableDiskMounts.insert(contentsOf: presets, at: 0)
        saveConfiguration()
    }

    private func enrichRestorableMountUUIDs(from volumes: [DiskVolume]) {
        var changed = false
        for index in configuration.restorableDiskMounts.indices where configuration.restorableDiskMounts[index].volumeUUID == nil {
            let identifier = configuration.restorableDiskMounts[index].diskIdentifier
            guard let volumeUUID = volumes.first(where: { $0.id == identifier })?.volumeUUID else { continue }
            configuration.restorableDiskMounts[index].volumeUUID = volumeUUID
            changed = true
            DiagnosticFileLogger.write("Added volume UUID to automatic restore record: \(identifier) -> \(volumeUUID)")
        }
        if changed { saveConfiguration() }
    }

    private func recoverIncompleteGameWorkflows() async {
        do {
            let results = try await genshinWorkflow.recoverIncompleteRuns { [weak self] update in
                await self?.applyGenshinWorkflowUpdate(update)
            }
            guard let failed = results.first(where: { $0.status == .recoveryFailed }) else {
                if !results.isEmpty {
                    status = TaskStatus(
                        phase: .succeeded,
                        message: tr("上次中断的网络状态已恢复", "Recovered network state from the interrupted launch"),
                        progress: 1
                    )
                }
                return
            }
            report(ToolboxError.commandFailed(
                failed.errorDescription ?? tr("上次启动的网络恢复失败", "Failed to recover network state from the previous launch")
            ))
        } catch {
            report(error)
        }
    }

    private func applyGenshinWorkflowUpdate(_ update: GenshinWorkflowUpdate) {
        let message: String
        switch update.stage {
        case .recovering:
            message = tr("正在恢复上次中断的网络状态", "Recovering network state from the previous launch")
        case .preflight:
            message = tr("正在检查 CrossOver 与原神配置", "Checking CrossOver and the Genshin configuration")
        case .isolatingNetwork:
            message = tr("正在短时隔离全机网络", "Temporarily isolating network access")
        case .configuringMetalHUD:
            message = tr("正在配置 MetalHUD", "Configuring MetalHUD")
        case .launching:
            message = tr("正在自动启动原神", "Launching Genshin automatically")
        case .waitingForRendering:
            message = tr("等待原神进入渲染阶段", "Waiting for Genshin to enter the rendering stage")
        case .restoringNetwork:
            message = tr("已通过启动阶段，正在恢复网络", "Startup stage passed; restoring network")
        case .applyingQoS:
            message = tr("正在优化原神进程优先级", "Optimizing Genshin process priority")
        }
        status.phase = update.stage == .isolatingNetwork ? .awaitingAuthorization : .running
        status.message = message
        status.progress = update.progress
        if status.log.last != message {
            status.log.append(message)
        }
    }

    private func applyGenshinWorkflowResult(_ result: WorkflowRunResult) {
        switch result.status {
        case .succeeded:
            status = TaskStatus(
                phase: .succeeded,
                message: tr("原神已启动，网络已恢复并完成进程优化", "Genshin launched; network restored and process optimized"),
                progress: 1,
                log: status.log
            )
        case .cancelled:
            status = TaskStatus(
                phase: .cancelled,
                message: tr("已取消，网络恢复完成", "Cancelled after network restoration"),
                log: status.log
            )
        case .recoveryFailed:
            status = TaskStatus(
                phase: .failed,
                message: result.errorDescription ?? tr("网络恢复失败", "Network recovery failed"),
                log: status.log
            )
        case .failed:
            status = TaskStatus(
                phase: .failed,
                message: result.errorDescription ?? tr("原神启动流程失败", "The Genshin launch workflow failed"),
                log: status.log
            )
        default:
            status = TaskStatus(
                phase: .failed,
                message: tr("原神启动流程以异常状态结束", "The Genshin launch workflow ended in an unexpected state"),
                log: status.log
            )
        }
        DiagnosticFileLogger.write("Genshin workflow finished with status: \(result.status.rawValue)")
    }

    private func saveConfiguration() {
        let value = configuration
        Task {
            do {
                try await application.saveConfiguration(value)
            } catch {
                report(error)
            }
        }
    }

    private func rememberMetalHUDApp(_ applicationURL: URL) {
        let normalizedURL = applicationURL.standardizedFileURL
        let displayName = FileManager.default.displayName(atPath: normalizedURL.path)
        let name = (displayName as NSString).deletingPathExtension
        configuration.recentMetalHUDApps.removeAll { $0.path == normalizedURL.path }
        configuration.recentMetalHUDApps.insert(RecentMetalHUDApp(path: normalizedURL.path, displayName: name), at: 0)
        configuration.recentMetalHUDApps = Array(configuration.recentMetalHUDApps.prefix(ConfigurationStore.maxRecentMetalHUDApps))
        saveConfiguration()
    }

    private func runTask(_ message: String, operation: @escaping @MainActor () async throws -> String) {
        status = TaskStatus(phase: .running, message: message)
        DiagnosticFileLogger.write("Task started: \(message)")
        Task {
            do {
                let result = try await operation()
                status = TaskStatus(phase: .succeeded, message: result, progress: 1)
                DiagnosticFileLogger.write("Task succeeded: \(result)")
            } catch is CancellationError {
                status = TaskStatus(phase: .cancelled, message: tr("已取消", "Cancelled"))
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        status = TaskStatus(phase: error is CancellationError ? .cancelled : .failed, message: error.localizedDescription)
        DiagnosticFileLogger.write("Task failed: \(error.localizedDescription)")
    }
}
