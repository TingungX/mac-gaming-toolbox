import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

enum GenshinWorkflowStage: Sendable {
    case recovering
    case preflight
    case claimingProcessSession
    case isolatingNetwork
    case configuringMetalHUD
    case launching
    case waitingForRendering
    case restoringNetwork
    case applyingQoS
    case claimingGameMode
    case waitingForExit
    case terminatingResiduals
    case releasingGameMode
}

struct GenshinWorkflowRecovery: Sendable {
    let compensated: [WorkflowRunResult]
    let resumableRunIDs: [WorkflowRunID]
}

struct GenshinWorkflowUpdate: Sendable {
    let stage: GenshinWorkflowStage
    let progress: Double
}

protocol GenshinWorkflowCoordinating: Sendable {
    func exclusiveConflicts(for installation: GameInstallation) async -> [WorkflowResourceConflict]
    func gameModeHolderCount() async -> Int
    func run(
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult
    func resume(
        runID: WorkflowRunID,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult
    func cancel() async
    func cancel(runIDs: [WorkflowRunID]) async
    func recoverIncompleteRuns(
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> GenshinWorkflowRecovery
}

actor GenshinWorkflowCoordinator: GenshinWorkflowCoordinating {
    static let workflowID = "game.hoyo.genshin.cn.launch"
    static let installationID = "game.hoyo.genshin.cn"
    static let stepPreviews: [WorkflowStepPreview] = [
        WorkflowStepPreview(id: "preflight", title: tr("环境预检", "Environment preflight"), detail: tr("检查 CrossOver 与已绑定的游戏配置", "Check CrossOver and the bound game configuration"), icon: "checkmark.shield"),
        WorkflowStepPreview(id: "claim-process-session", title: tr("占用容器", "Claim bottle"), detail: tr("以本机安装绑定为锁，独占这个 CrossOver 容器", "Exclusively claim this CrossOver bottle from the local installation binding"), icon: "lock.fill"),
        WorkflowStepPreview(id: "isolate-network", title: tr("隔离网络", "Isolate network"), detail: tr("短时阻断全机网络，避免启动阶段失败", "Temporarily block global network access during startup"), icon: "network.slash"),
        WorkflowStepPreview(id: "configure-metalhud", title: tr("配置 MetalHUD", "Configure MetalHUD"), detail: tr("按当前偏好准备性能监视器", "Prepare the performance monitor when enabled"), icon: "gauge.with.dots.needle.67percent"),
        WorkflowStepPreview(id: "launch-game", title: tr("启动游戏", "Launch game"), detail: tr("通过已验证的 CrossOver 启动适配器启动", "Launch through the verified CrossOver adapter"), icon: "play.fill"),
        WorkflowStepPreview(id: "await-rendering", title: tr("等待渲染就绪", "Wait for rendering"), detail: tr("检测受限的渲染信号，不使用固定倒计时", "Wait for the bounded rendering signal instead of a fixed delay"), icon: "eye"),
        WorkflowStepPreview(id: "restore-network", title: tr("恢复网络", "Restore network"), detail: tr("通过同一恢复句柄恢复网络连通性", "Restore connectivity through the same recovery handle"), icon: "network"),
        WorkflowStepPreview(id: "apply-qos", title: tr("优化进程", "Optimize processes"), detail: tr("提升已识别的游戏进程优先级", "Boost the identified game process tree"), icon: "bolt.fill"),
        WorkflowStepPreview(id: "claim-game-mode", title: tr("占用 Game Mode", "Claim Game Mode"), detail: tr("由本 run 占用全局 Game Mode；最后释放者才恢复原策略", "This run claims global Game Mode; the last releaser restores the previous policy"), icon: "flag.checkered"),
        WorkflowStepPreview(id: "await-exit", title: tr("跟踪至退出", "Track until exit"), detail: tr("等待原神可执行文件退出，而不是 cxstart 命令行里的名字", "Wait until the Genshin executable itself exits, not a launcher command line"), icon: "eye.circle"),
        WorkflowStepPreview(id: "terminate-residuals", title: tr("结束残留进程", "Terminate residuals"), detail: tr("强制结束挂起的 YuanShen.exe 并清理本容器 Wine 进程", "Force-quit a hung YuanShen.exe and clean up this bottle's Wine processes"), icon: "xmark.circle"),
        WorkflowStepPreview(id: "release-game-mode", title: tr("交还 Game Mode", "Release Game Mode"), detail: tr("释放本 run 的 claim；无其他持有者时恢复自动策略", "Release this run's claim and restore auto when no holders remain"), icon: "flag")
    ]

    private enum StepKind {
        static let preflight = "environment.preflight"
        static let claimProcessSession = "process.session.claim"
        static let isolateNetwork = "network.isolate"
        static let configureMetalHUD = "metalhud.configure"
        static let launch = "game.launch.crossover"
        static let awaitReadiness = "game.awaitReadiness.genshin"
        static let restoreNetwork = "network.restore"
        static let applyQoS = "process.applyQoS"
        static let claimGameMode = "system.gameMode.claim"
        static let awaitExit = "game.awaitExit"
        static let terminateResiduals = "process.terminateClaimed"
        static let releaseGameMode = "system.gameMode.release"
        static let releaseProcessSession = "process.session.release"
    }

    fileprivate struct LeaseInput: Codable, Sendable { let seconds: Int }
    fileprivate struct MetalHUDInput: Codable, Sendable { let enabled: Bool }
    fileprivate struct ReadinessInput: Codable, Sendable { let timeoutSeconds: Int }

    private let runtimeStore: GenshinRuntimeStore
    private let journal: any WorkflowJournal
    private let engine: WorkflowEngine
    private let runsDirectory: URL
    private let capabilityClient: any PrivilegedCapabilityOperating
    private let exclusiveLocks: WorkflowExclusiveLockTable
    private let gameModeClaims: GameModeClaimLedger

    init(
        capabilityClient: any PrivilegedCapabilityOperating,
        privileged: any PrivilegedOperating,
        gamingService: GamingService,
        journal: any WorkflowJournal,
        runsDirectory: URL,
        exclusiveLocks: WorkflowExclusiveLockTable,
        gameModeClaims: GameModeClaimLedger,
        processSignaler: any ProcessSignaling = POSIXProcessSignaler()
    ) throws {
        let runtimeStore = GenshinRuntimeStore()
        let contract = try NetworkIsolationCapability.contract()
        let registry = try WorkflowStepRegistry(
            registrations: [
                WorkflowStepRegistration(kind: StepKind.preflight, version: 1) {
                    GenshinPreflightStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(kind: StepKind.claimProcessSession, version: 1) {
                    GenshinClaimProcessSessionStep(
                        runtimeStore: runtimeStore,
                        exclusiveLocks: exclusiveLocks,
                        gamingService: gamingService,
                        processSignaler: processSignaler
                    )
                },
                WorkflowStepRegistration(
                    kind: StepKind.isolateNetwork,
                    version: 1,
                    capabilities: [contract.reference]
                ) {
                    GenshinNetworkIsolationStep(
                        runtimeStore: runtimeStore,
                        capabilityClient: capabilityClient,
                        exclusiveLocks: exclusiveLocks
                    )
                },
                WorkflowStepRegistration(kind: StepKind.configureMetalHUD, version: 1) {
                    GenshinMetalHUDStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(kind: StepKind.launch, version: 1) {
                    GenshinLaunchStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(kind: StepKind.awaitReadiness, version: 1) {
                    GenshinReadinessStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(
                    kind: StepKind.restoreNetwork,
                    version: 1,
                    capabilities: [contract.reference]
                ) {
                    GenshinNetworkRestoreStep(
                        runtimeStore: runtimeStore,
                        capabilityClient: capabilityClient
                    )
                },
                WorkflowStepRegistration(kind: StepKind.applyQoS, version: 1) {
                    GenshinQoSStep(
                        runtimeStore: runtimeStore,
                        gamingService: gamingService,
                        privileged: privileged
                    )
                },
                WorkflowStepRegistration(kind: StepKind.claimGameMode, version: 1) {
                    GenshinClaimGameModeStep(
                        runtimeStore: runtimeStore,
                        ledger: gameModeClaims
                    )
                },
                WorkflowStepRegistration(kind: StepKind.awaitExit, version: 1) {
                    GenshinAwaitExitStep(
                        runtimeStore: runtimeStore,
                        gamingService: gamingService
                    )
                },
                WorkflowStepRegistration(kind: StepKind.terminateResiduals, version: 1) {
                    GenshinTerminateResidualsStep(
                        runtimeStore: runtimeStore,
                        gamingService: gamingService,
                        processSignaler: processSignaler
                    )
                },
                WorkflowStepRegistration(kind: StepKind.releaseGameMode, version: 1) {
                    GenshinReleaseGameModeStep(ledger: gameModeClaims)
                },
                WorkflowStepRegistration(kind: StepKind.releaseProcessSession, version: 1) {
                    GenshinReleaseProcessSessionStep(
                        runtimeStore: runtimeStore,
                        exclusiveLocks: exclusiveLocks
                    )
                }
            ],
            contracts: [contract]
        )
        self.runtimeStore = runtimeStore
        self.journal = journal
        self.engine = WorkflowEngine(registry: registry, journal: journal)
        self.runsDirectory = runsDirectory
        self.capabilityClient = capabilityClient
        self.exclusiveLocks = exclusiveLocks
        self.gameModeClaims = gameModeClaims
    }

    func exclusiveConflicts(for installation: GameInstallation) async -> [WorkflowResourceConflict] {
        guard case .crossOver(let binding) = installation.launchBinding else { return [] }
        return await exclusiveLocks.conflicts(for: [
            .processSession(bottle: binding.bottleName),
            .networkGlobalIsolation
        ])
    }

    func gameModeHolderCount() async -> Int {
        await gameModeClaims.holderCount()
    }

    func run(
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult {
        try await execute(
            runID: UUID(),
            installation: installation,
            metalHUDEnabled: metalHUDEnabled,
            update: update,
            resumeExisting: false
        )
    }

    func resume(
        runID: WorkflowRunID,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult {
        try await execute(
            runID: runID,
            installation: installation,
            metalHUDEnabled: metalHUDEnabled,
            update: update,
            resumeExisting: true
        )
    }

    func cancel() async {
        _ = await engine.cancelActiveRun()
    }

    func cancel(runIDs: [WorkflowRunID]) async {
        for runID in runIDs {
            _ = await engine.cancel(runID: runID)
        }
    }

    func recoverIncompleteRuns(
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> GenshinWorkflowRecovery {
        await update(GenshinWorkflowUpdate(stage: .recovering, progress: 0))
        let orphanRestored = try await NetworkIsolationRecovery.restoreActive(
            using: capabilityClient
        )
        let runIDs = try await journal.incompleteRunIDs()
        var compensated: [WorkflowRunResult] = []
        var resumable: [WorkflowRunID] = []
        let workflow = try Self.workflow(metalHUDEnabled: false)
        for runID in runIDs {
            let events = try await journal.events(for: runID)
            guard events.first?.workflowID == Self.workflowID else { continue }
            switch WorkflowRecoveryPlanner.action(for: events, workflow: workflow) {
            case .resume:
                resumable.append(runID)
            case .compensate:
                await update(GenshinWorkflowUpdate(stage: .recovering, progress: 0))
                compensated.append(try await engine.recover(workflow, runID: runID))
            }
        }
        if compensated.isEmpty, resumable.isEmpty, orphanRestored {
            compensated.append(WorkflowRunResult(
                runID: UUID(),
                workflowID: Self.workflowID,
                status: .recovered
            ))
        }
        return GenshinWorkflowRecovery(compensated: compensated, resumableRunIDs: resumable)
    }

    private func execute(
        runID: WorkflowRunID,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void,
        resumeExisting: Bool
    ) async throws -> WorkflowRunResult {
        let traceURL = runsDirectory.appendingPathComponent("\(runID.uuidString).cxlog")
        let context = GenshinRunContext(
            installation: installation,
            traceURL: traceURL,
            sidecarURL: Self.sidecarURL(in: runsDirectory, runID: runID),
            update: update
        )
        await runtimeStore.insert(context, for: runID)
        if resumeExisting {
            await restoreSessionClaims(runID: runID, context: context)
        }

        do {
            let workflow = try Self.workflow(metalHUDEnabled: metalHUDEnabled)
            let result = resumeExisting
                ? try await engine.recover(workflow, runID: runID)
                : try await engine.run(workflow, runID: runID)
            await context.cleanup()
            await runtimeStore.remove(runID)
            return result
        } catch {
            await context.cleanup()
            await runtimeStore.remove(runID)
            throw error
        }
    }

    private func restoreSessionClaims(runID: WorkflowRunID, context: GenshinRunContext) async {
        let holder = WorkflowExclusiveLockHolder(
            runID: runID,
            workflowID: Self.workflowID,
            title: tr("原神一键启动", "Genshin One-click Launch")
        )
        if let bottle = try? await context.bottleName() {
            try? await exclusiveLocks.acquire(key: .processSession(bottle: bottle), holder: holder)
        }
        if let sidecar = await context.loadSidecar() {
            await context.restorePreexistingGamePIDs(Set(sidecar.preexistingGamePIDs ?? []))
            await context.restoreClaimedPIDs(Set(sidecar.claimedPIDs))
            if sidecar.gameModeHeld, let baseline = sidecar.gameModeBaseline {
                await gameModeClaims.restoreHolder(runID: runID, baseline: baseline)
            }
        }
    }

    private static func sidecarURL(in directory: URL, runID: WorkflowRunID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).session.json")
    }

    private static func workflow(metalHUDEnabled: Bool) throws -> CompiledWorkflow {
        let encoder = JSONEncoder()
        return CompiledWorkflow(
            id: workflowID,
            revision: 1,
            steps: [
                WorkflowStepDefinition(id: "preflight", kind: StepKind.preflight),
                WorkflowStepDefinition(id: "claim-process-session", kind: StepKind.claimProcessSession),
                WorkflowStepDefinition(
                    id: "isolate-network",
                    kind: StepKind.isolateNetwork,
                    input: try encoder.encode(LeaseInput(seconds: 60))
                ),
                WorkflowStepDefinition(
                    id: "configure-metalhud",
                    kind: StepKind.configureMetalHUD,
                    input: try encoder.encode(MetalHUDInput(enabled: metalHUDEnabled))
                ),
                WorkflowStepDefinition(id: "launch-game", kind: StepKind.launch),
                WorkflowStepDefinition(
                    id: "await-rendering",
                    kind: StepKind.awaitReadiness,
                    input: try encoder.encode(ReadinessInput(timeoutSeconds: 45))
                ),
                WorkflowStepDefinition(id: "restore-network", kind: StepKind.restoreNetwork),
                WorkflowStepDefinition(id: "apply-qos", kind: StepKind.applyQoS),
                WorkflowStepDefinition(id: "claim-game-mode", kind: StepKind.claimGameMode),
                WorkflowStepDefinition(id: "await-exit", kind: StepKind.awaitExit, holding: true),
                WorkflowStepDefinition(id: "terminate-residuals", kind: StepKind.terminateResiduals),
                WorkflowStepDefinition(id: "release-game-mode", kind: StepKind.releaseGameMode),
                WorkflowStepDefinition(id: "release-process-session", kind: StepKind.releaseProcessSession)
            ]
        )
    }
}

private actor GenshinRuntimeStore {
    private var contexts: [WorkflowRunID: GenshinRunContext] = [:]

    func insert(_ context: GenshinRunContext, for runID: WorkflowRunID) {
        contexts[runID] = context
    }

    func context(for runID: WorkflowRunID) throws -> GenshinRunContext {
        guard let context = contexts[runID] else {
            throw GenshinWorkflowCoordinatorError.missingRuntime(runID)
        }
        return context
    }

    func optionalContext(for runID: WorkflowRunID) -> GenshinRunContext? {
        contexts[runID]
    }

    func remove(_ runID: WorkflowRunID) {
        contexts.removeValue(forKey: runID)
    }
}

private struct GenshinSessionSidecar: Codable, Sendable {
    var bottleName: String
    var gameModeBaseline: GameModePolicy?
    var gameModeHeld: Bool
    var claimedPIDs: [Int32]
    var preexistingGamePIDs: [Int32]?
}

private actor GenshinRunContext {
    let installation: GameInstallation
    let traceURL: URL
    let sidecarURL: URL

    private let update: @Sendable (GenshinWorkflowUpdate) async -> Void
    private var launchDescription: CrossOverProcessLaunchDescription?
    private var launchProcess: Process?
    private var traceHandle: FileHandle?
    private var metalHUDEnabled = false
    private var networkHandle: CapabilityRecoveryHandle?
    private var leaseSession: NetworkIsolationLeaseSession?
    private var claimedPIDs: Set<Int32> = []
    private var preexistingGamePIDs: Set<Int32> = []
    private var gameModeBaseline: GameModePolicy?
    private var gameModeHeld = false

    init(
        installation: GameInstallation,
        traceURL: URL,
        sidecarURL: URL,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) {
        self.installation = installation
        self.traceURL = traceURL
        self.sidecarURL = sidecarURL
        self.update = update
    }

    func bottleName() throws -> String {
        try crossOverBinding().bottleName
    }

    func applicationPath() throws -> String {
        try crossOverBinding().applicationPath
    }

    private func crossOverBinding() throws -> CrossOverGameBinding {
        guard case .crossOver(let binding) = installation.launchBinding else {
            throw GenshinWorkflowCoordinatorError.invalidInstallation
        }
        return binding
    }

    func gameProcessNames() -> [String] {
        var names = ["YuanShen.exe"]
        if case .crossOver(let binding) = installation.launchBinding {
            let leaf = BottleProcessSession.executableLeafName(binding.executablePath)
            if !leaf.isEmpty {
                names.append(leaf)
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    func claimedProcessIDs() -> Set<Int32> { claimedPIDs }

    func preexistingGameProcessIDs() -> Set<Int32> { preexistingGamePIDs }

    func restoreClaimedPIDs(_ pids: Set<Int32>) {
        claimedPIDs = pids.filter { $0 > 1 && !preexistingGamePIDs.contains($0) }
    }

    func restorePreexistingGamePIDs(_ pids: Set<Int32>) {
        preexistingGamePIDs = pids.filter { $0 > 1 }
        claimedPIDs.subtract(preexistingGamePIDs)
    }

    func snapshotPreexistingGamePIDs(from processes: [SystemProcess]) {
        preexistingGamePIDs = BottleProcessSession.gameExecutablePIDs(processes, names: gameProcessNames())
        claimedPIDs.subtract(preexistingGamePIDs)
    }

    func claimProcessIDs(_ pids: [Int32]) {
        claimedPIDs.formUnion(pids.filter { $0 > 1 && !preexistingGamePIDs.contains($0) })
    }

    func markGameModeClaimed(baseline: GameModePolicy?) {
        gameModeBaseline = baseline
        gameModeHeld = true
    }

    func loadSidecar() -> GenshinSessionSidecar? {
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return try? JSONDecoder().decode(GenshinSessionSidecar.self, from: data)
    }

    func persistSidecar() {
        guard let bottle = try? bottleName() else { return }
        let sidecar = GenshinSessionSidecar(
            bottleName: bottle,
            gameModeBaseline: gameModeBaseline,
            gameModeHeld: gameModeHeld,
            claimedPIDs: claimedPIDs.sorted(),
            preexistingGamePIDs: preexistingGamePIDs.sorted()
        )
        do {
            try FileManager.default.createDirectory(
                at: sidecarURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: .atomic)
        } catch {
            DiagnosticFileLogger.write("Unable to persist Genshin session sidecar: \(error.localizedDescription)")
        }
    }

    func removeSidecar() {
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    func report(_ stage: GenshinWorkflowStage, progress: Double) async {
        await update(GenshinWorkflowUpdate(stage: stage, progress: progress))
    }

    func prepareLaunch() throws {
        guard installation.id == GenshinWorkflowCoordinator.installationID,
              case .crossOver(let binding) = installation.launchBinding else {
            throw GenshinWorkflowCoordinatorError.invalidInstallation
        }
        let configuration = try CrossOverLaunchConfiguration(
            crossOverAppURL: URL(fileURLWithPath: binding.applicationPath),
            bottle: binding.bottleName,
            executablePath: binding.executablePath,
            workingDirectoryPath: binding.workingDirectoryPath
        )
        let adapter = CrossOverLaunchAdapter(configuration: configuration)
        let description = try adapter.makeProcessLaunchDescription(logFileURL: traceURL)
        guard FileManager.default.fileExists(atPath: configuration.crossOverApp.url.path),
              FileManager.default.isExecutableFile(atPath: description.executableURL.path) else {
            throw GenshinWorkflowCoordinatorError.crossOverUnavailable
        }
        try FileManager.default.createDirectory(
            at: traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if FileManager.default.fileExists(atPath: traceURL.path) {
            try FileManager.default.removeItem(at: traceURL)
        }
        launchDescription = description
    }

    func setMetalHUDEnabled(_ enabled: Bool) {
        metalHUDEnabled = enabled
    }

    func launch() throws {
        guard let launchDescription else {
            throw GenshinWorkflowCoordinatorError.preflightNotCompleted
        }
        let process = Process()
        process.executableURL = launchDescription.executableURL
        process.arguments = launchDescription.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if metalHUDEnabled {
            var environment = ProcessInfo.processInfo.environment
            environment["MTL_HUD_ENABLED"] = "1"
            process.environment = environment
        }
        try process.run()
        launchProcess = process
    }

    func readTraceChunk(maximumBytes: Int) throws -> Data {
        if traceHandle == nil {
            guard FileManager.default.fileExists(atPath: traceURL.path) else { return Data() }
            traceHandle = try FileHandle(forReadingFrom: traceURL)
        }
        return try traceHandle?.read(upToCount: maximumBytes) ?? Data()
    }

    func launchProcessIsRunning() -> Bool {
        launchProcess?.isRunning ?? false
    }

    func setNetworkLease(
        handle: CapabilityRecoveryHandle,
        session: NetworkIsolationLeaseSession
    ) {
        networkHandle = handle
        leaseSession = session
    }

    func networkLeaseFailure() async -> String? {
        await leaseSession?.failureDescription()
    }

    func takeNetworkLease() async -> CapabilityRecoveryHandle? {
        if let leaseSession {
            await leaseSession.stop()
        }
        self.leaseSession = nil
        defer { networkHandle = nil }
        return networkHandle
    }

    func stopLeaseRenewal() async {
        if let leaseSession {
            await leaseSession.stop()
        }
        leaseSession = nil
        networkHandle = nil
    }

    func cleanup() async {
        await stopLeaseRenewal()
        if let traceHandle {
            do {
                try traceHandle.close()
            } catch {
                DiagnosticFileLogger.write("Unable to close Genshin workflow trace: \(error.localizedDescription)")
            }
        }
        traceHandle = nil
        launchProcess = nil
        removeSidecar()
        if FileManager.default.fileExists(atPath: traceURL.path) {
            do {
                try FileManager.default.removeItem(at: traceURL)
            } catch {
                DiagnosticFileLogger.write("Unable to remove Genshin workflow trace: \(error.localizedDescription)")
            }
        }
    }
}

private actor NetworkIsolationLeaseSession {
    private let client: any PrivilegedCapabilityOperating
    private let runID: WorkflowRunID
    private let handle: CapabilityRecoveryHandle
    private var renewalTask: Task<Void, Never>?
    private var failure: String?

    init(
        client: any PrivilegedCapabilityOperating,
        runID: WorkflowRunID,
        handle: CapabilityRecoveryHandle
    ) {
        self.client = client
        self.runID = runID
        self.handle = handle
    }

    func start() {
        guard renewalTask == nil else { return }
        renewalTask = Task { [weak self] in
            await self?.renewalLoop()
        }
    }

    func stop() async {
        let task = renewalTask
        renewalTask = nil
        task?.cancel()
        await task?.value
    }

    func failureDescription() -> String? { failure }

    private func renewalLoop() async {
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(25))
                try Task.checkCancellation()
                let payload = try JSONEncoder().encode(NetworkIsolationInput.renew(
                    leaseSeconds: 60,
                    tokenID: handle.tokenID
                ))
                let invocation = CapabilityInvocationEnvelope(
                    runID: runID,
                    stepID: "network-lease-renewal",
                    capability: NetworkIsolationCapability.reference,
                    inputPayload: payload
                )
                let result: CapabilityResultEnvelope
                do {
                    result = try await client.invoke(invocation)
                } catch ToolboxError.helperTimedOut {
                    result = try await client.invoke(invocation)
                }
                try result.validate(
                    against: NetworkIsolationCapability.contract(),
                    matching: invocation
                )
                guard result.recoveryHandle == handle else {
                    throw GenshinWorkflowCoordinatorError.recoveryHandleChanged
                }
            }
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct GenshinPreflightStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.preflight, progress: 0.05)
        try await runtime.prepareLaunch()
        return .completed
    }
}

private struct GenshinNetworkIsolationStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let capabilityClient: any PrivilegedCapabilityOperating
    let exclusiveLocks: WorkflowExclusiveLockTable

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let input = try JSONDecoder().decode(
            GenshinWorkflowCoordinator.LeaseInput.self,
            from: context.step.input
        )
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.isolatingNetwork, progress: 0.15)
        try await exclusiveLocks.acquire(
            key: .networkGlobalIsolation,
            holder: WorkflowExclusiveLockHolder(
                runID: context.runID,
                workflowID: context.workflowID,
                title: tr("原神一键启动", "Genshin One-click Launch")
            )
        )
        let payload = try JSONEncoder().encode(NetworkIsolationInput.begin(leaseSeconds: input.seconds))
        let invocation = CapabilityInvocationEnvelope(
            runID: context.runID,
            stepID: context.step.id,
            capability: NetworkIsolationCapability.reference,
            inputPayload: payload
        )
        let result: CapabilityResultEnvelope
        do {
            result = try await capabilityClient.invoke(invocation)
        } catch ToolboxError.helperTimedOut {
            // `begin` is idempotent for one run ID. Retrying closes the XPC
            // timeout window in which PF changed state but the App did not
            // receive and journal the recovery handle.
            result = try await capabilityClient.invoke(invocation)
        }
        try result.validate(
            against: NetworkIsolationCapability.contract(),
            matching: invocation
        )
        guard let handle = result.recoveryHandle else {
            throw GenshinWorkflowCoordinatorError.missingRecoveryHandle
        }
        let leaseSession = NetworkIsolationLeaseSession(
            client: capabilityClient,
            runID: context.runID,
            handle: handle
        )
        await runtime.setNetworkLease(handle: handle, session: leaseSession)
        await leaseSession.start()
        return WorkflowStepExecution(recoveryHandle: WorkflowRecoveryHandle(
            tokenID: handle.tokenID,
            capabilityID: handle.capability.id,
            capabilityVersion: handle.capability.version
        ))
    }

    func compensate(
        _ recoveryHandle: WorkflowRecoveryHandle,
        context: WorkflowCompensationContext
    ) async throws {
        if let runtime = await runtimeStore.optionalContext(for: context.runID) {
            await runtime.stopLeaseRenewal()
        }
        await exclusiveLocks.release(key: .networkGlobalIsolation, runID: context.runID)
        try await capabilityClient.recover(try Self.capabilityHandle(from: recoveryHandle))
    }

    func compensateInFlight(context: WorkflowCompensationContext) async throws {
        if let runtime = await runtimeStore.optionalContext(for: context.runID) {
            await runtime.stopLeaseRenewal()
        }
        await exclusiveLocks.release(key: .networkGlobalIsolation, runID: context.runID)
        _ = try await NetworkIsolationRecovery.restoreActive(
            using: capabilityClient,
            runID: context.runID
        )
    }

    private static func capabilityHandle(
        from handle: WorkflowRecoveryHandle
    ) throws -> CapabilityRecoveryHandle {
        let reference = CapabilityReference(
            id: handle.capabilityID,
            version: handle.capabilityVersion
        )
        guard reference == NetworkIsolationCapability.reference else {
            throw GenshinWorkflowCoordinatorError.invalidRecoveryHandle
        }
        return CapabilityRecoveryHandle(tokenID: handle.tokenID, capability: reference)
    }
}

private struct GenshinMetalHUDStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let input = try JSONDecoder().decode(
            GenshinWorkflowCoordinator.MetalHUDInput.self,
            from: context.step.input
        )
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.configuringMetalHUD, progress: 0.25)
        await runtime.setMetalHUDEnabled(input.enabled)
        return .completed
    }
}

private struct GenshinLaunchStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.launching, progress: 0.35)
        try await runtime.launch()
        return .completed
    }
}

private struct GenshinReadinessStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let input = try JSONDecoder().decode(
            GenshinWorkflowCoordinator.ReadinessInput.self,
            from: context.step.input
        )
        guard (5...55).contains(input.timeoutSeconds) else {
            throw GenshinWorkflowCoordinatorError.invalidReadinessTimeout
        }
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.waitingForRendering, progress: 0.5)
        var probe = try GenshinReadinessProbe()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(input.timeoutSeconds))

        while clock.now < deadline {
            try Task.checkCancellation()
            if let leaseFailure = await runtime.networkLeaseFailure() {
                throw GenshinWorkflowCoordinatorError.networkLeaseFailed(leaseFailure)
            }
            let chunk = try await runtime.readTraceChunk(maximumBytes: 64 * 1_024)
            if !chunk.isEmpty {
                switch probe.append(chunk) {
                case .ready:
                    return .completed
                case .failed(let failure):
                    throw GenshinWorkflowCoordinatorError.readinessFailed(failure)
                case .waiting:
                    break
                }
            } else if !(await runtime.launchProcessIsRunning()) {
                switch probe.finish() {
                case .ready:
                    return .completed
                case .failed(let failure):
                    throw GenshinWorkflowCoordinatorError.readinessFailed(failure)
                case .waiting:
                    break
                }
                if let pid = probe.targetPID {
                    switch probe.processDidExit(pid: pid) {
                    case .ready:
                        return .completed
                    case .failed(let failure):
                        throw GenshinWorkflowCoordinatorError.readinessFailed(failure)
                    case .waiting:
                        throw GenshinWorkflowCoordinatorError.readinessFailed(.processExited)
                    }
                } else {
                    throw GenshinWorkflowCoordinatorError.gameExitedBeforeTrace
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        switch probe.finish() {
        case .ready:
            return .completed
        case .failed(let failure):
            throw GenshinWorkflowCoordinatorError.readinessFailed(failure)
        case .waiting:
            break
        }
        _ = probe.timeout()
        throw GenshinWorkflowCoordinatorError.readinessFailed(.timedOut)
    }
}

private struct GenshinNetworkRestoreStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let capabilityClient: any PrivilegedCapabilityOperating

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.restoringNetwork, progress: 0.8)
        guard let handle = await runtime.takeNetworkLease() else {
            throw GenshinWorkflowCoordinatorError.missingRecoveryHandle
        }
        try await capabilityClient.recover(handle)
        return .completed
    }
}

private struct GenshinQoSStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let gamingService: GamingService
    let privileged: any PrivilegedOperating

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.applyingQoS, progress: 0.9)
        let processes = try await gamingService.runningProcesses()
        let bottle = try await runtime.bottleName()
        let names = await runtime.gameProcessNames()
        let pids = BottleProcessSession.boostablePIDs(
            processes,
            bottle: bottle,
            additionallyClaimed: await runtime.claimedProcessIDs(),
            gameProcessNames: names,
            preexistingGamePIDs: await runtime.preexistingGameProcessIDs()
        )
        guard !pids.isEmpty else {
            throw GenshinWorkflowCoordinatorError.gameProcessNotFound
        }
        await runtime.claimProcessIDs(pids)
        await runtime.persistSidecar()
        try await privileged.perform(.renice(pids))
        return .completed
    }
}

private struct GenshinClaimProcessSessionStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let exclusiveLocks: WorkflowExclusiveLockTable
    let gamingService: GamingService
    let processSignaler: any ProcessSignaling

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.claimingProcessSession, progress: 0.08)
        let bottle = try await runtime.bottleName()
        try await exclusiveLocks.acquire(
            key: .processSession(bottle: bottle),
            holder: WorkflowExclusiveLockHolder(
                runID: context.runID,
                workflowID: context.workflowID,
                title: tr("原神一键启动", "Genshin One-click Launch")
            )
        )
        let processes = (try? await gamingService.runningProcesses()) ?? []
        await runtime.snapshotPreexistingGamePIDs(from: processes)
        await runtime.persistSidecar()
        return WorkflowStepExecution(recoveryHandle: WorkflowRecoveryHandle(
            capabilityID: "process.session"
        ))
    }

    func compensate(
        _ recoveryHandle: WorkflowRecoveryHandle,
        context: WorkflowCompensationContext
    ) async throws {
        try await teardown(context: context)
    }

    func compensateInFlight(context: WorkflowCompensationContext) async throws {
        try await teardown(context: context)
    }

    private func teardown(context: WorkflowCompensationContext) async throws {
        guard let runtime = await runtimeStore.optionalContext(for: context.runID) else {
            return
        }
        let bottle = try await runtime.bottleName()
        let names = await runtime.gameProcessNames()
        CrossOverBottleShutdown.requestWineserverExit(
            applicationPath: try await runtime.applicationPath(),
            bottle: bottle
        )
        let processes = (try? await gamingService.runningProcesses()) ?? []
        let report = await BottleProcessSession.terminate(
            claimedPIDs: await runtime.claimedProcessIDs(),
            processes: processes,
            bottle: bottle,
            signaler: processSignaler,
            gameProcessNames: names,
            preexistingGamePIDs: await runtime.preexistingGameProcessIDs()
        )
        await exclusiveLocks.release(key: .processSession(bottle: bottle), runID: context.runID)
        await exclusiveLocks.release(key: .networkGlobalIsolation, runID: context.runID)
        await runtime.removeSidecar()
        if !report.failures.isEmpty {
            throw GenshinWorkflowCoordinatorError.terminationFailed(report.failures.joined(separator: "; "))
        }
    }
}

private struct GenshinClaimGameModeStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let ledger: GameModeClaimLedger

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.claimingGameMode, progress: 0.92)
        do {
            try await ledger.acquire(runID: context.runID)
            await runtime.markGameModeClaimed(baseline: await ledger.baselinePolicy())
            await runtime.persistSidecar()
            return WorkflowStepExecution(recoveryHandle: WorkflowRecoveryHandle(
                capabilityID: "system.gameMode"
            ))
        } catch {
            DiagnosticFileLogger.write("Game Mode claim skipped: \(error.localizedDescription)")
            return .completed
        }
    }

    func compensate(
        _ recoveryHandle: WorkflowRecoveryHandle,
        context: WorkflowCompensationContext
    ) async throws {
        try await ledger.release(runID: context.runID)
    }
}

private struct GenshinAwaitExitStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let gamingService: GamingService

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.waitingForExit, progress: 0.94)
        let bottle = try await runtime.bottleName()
        let names = await runtime.gameProcessNames()
        while true {
            try Task.checkCancellation()
            let processes = try await gamingService.runningProcesses()
            let scoped = BottleProcessSession.scopedProcesses(
                processes,
                bottle: bottle,
                additionallyClaimed: await runtime.claimedProcessIDs(),
                gameProcessNames: names,
                preexistingGamePIDs: await runtime.preexistingGameProcessIDs()
            )
            await runtime.claimProcessIDs(scoped.map(\.pid))
            await runtime.persistSidecar()
            let stillRunning = BottleProcessSession.gameStillRunning(
                processes,
                bottle: bottle,
                claimedPIDs: await runtime.claimedProcessIDs(),
                gameProcessNames: names,
                preexistingGamePIDs: await runtime.preexistingGameProcessIDs()
            )
            if !stillRunning { return .completed }
            try await Task.sleep(for: .seconds(1))
        }
    }
}

private struct GenshinTerminateResidualsStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let gamingService: GamingService
    let processSignaler: any ProcessSignaling

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.terminatingResiduals, progress: 0.97)
        let bottle = try await runtime.bottleName()
        let names = await runtime.gameProcessNames()
        CrossOverBottleShutdown.requestWineserverExit(
            applicationPath: try await runtime.applicationPath(),
            bottle: bottle
        )
        let processes = try await gamingService.runningProcesses()
        let report = await BottleProcessSession.terminate(
            claimedPIDs: await runtime.claimedProcessIDs(),
            processes: processes,
            bottle: bottle,
            signaler: processSignaler,
            gameProcessNames: names,
            preexistingGamePIDs: await runtime.preexistingGameProcessIDs()
        )
        if !report.failures.isEmpty {
            throw GenshinWorkflowCoordinatorError.terminationFailed(report.failures.joined(separator: "; "))
        }
        return .completed
    }
}

private struct GenshinReleaseGameModeStep: WorkflowStepExecuting {
    let ledger: GameModeClaimLedger

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        try await ledger.release(runID: context.runID)
        return .completed
    }
}

private struct GenshinReleaseProcessSessionStep: WorkflowStepExecuting {
    let runtimeStore: GenshinRuntimeStore
    let exclusiveLocks: WorkflowExclusiveLockTable

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        let bottle = try await runtime.bottleName()
        await exclusiveLocks.release(key: .processSession(bottle: bottle), runID: context.runID)
        await exclusiveLocks.release(key: .networkGlobalIsolation, runID: context.runID)
        await runtime.removeSidecar()
        return .completed
    }
}

private enum GenshinWorkflowCoordinatorError: Error, LocalizedError {
    case missingRuntime(WorkflowRunID)
    case invalidInstallation
    case crossOverUnavailable
    case preflightNotCompleted
    case missingRecoveryHandle
    case invalidRecoveryHandle
    case recoveryHandleChanged
    case invalidReadinessTimeout
    case readinessFailed(GenshinReadinessFailure)
    case gameExitedBeforeTrace
    case networkLeaseFailed(String)
    case gameProcessNotFound
    case terminationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            tr("找不到本次启动的运行状态", "The launch runtime is unavailable")
        case .invalidInstallation:
            tr("原神安装绑定无效，请重新配置", "The Genshin installation binding is invalid")
        case .crossOverUnavailable:
            tr("找不到可用的 CrossOver 或 cxstart", "CrossOver or cxstart is unavailable")
        case .preflightNotCompleted:
            tr("启动预检尚未完成", "Launch preflight has not completed")
        case .missingRecoveryHandle:
            tr("网络恢复令牌缺失", "The network recovery handle is missing")
        case .invalidRecoveryHandle:
            tr("网络恢复令牌与能力不匹配", "The network recovery handle does not match the capability")
        case .recoveryHandleChanged:
            tr("网络租约续期返回了不同的恢复令牌", "Network lease renewal returned a different recovery handle")
        case .invalidReadinessTimeout:
            tr("渲染检测超时时间无效", "The readiness timeout is invalid")
        case .readinessFailed(let failure):
            switch failure {
            case .processExited:
                tr("原神在进入渲染阶段前退出", "Genshin exited before rendering started")
            case .mhypBaseAccessViolation:
                tr("检测到反作弊启动阶段失败", "The anti-cheat startup stage failed")
            case .traceLimitExceeded:
                tr("CrossOver 启动日志超过安全限制", "The CrossOver launch trace exceeded its safety limit")
            case .timedOut:
                tr("等待原神开始渲染超时", "Timed out waiting for Genshin to start rendering")
            }
        case .gameExitedBeforeTrace:
            tr("CrossOver 在识别到原神进程前退出", "CrossOver exited before the Genshin process was identified")
        case .networkLeaseFailed(let message):
            tr("网络隔离租约续期失败：\(message)", "Network isolation lease renewal failed: \(message)")
        case .gameProcessNotFound:
            tr("渲染开始后未找到原神 Wine 进程", "No Genshin Wine process was found after rendering started")
        case .terminationFailed(let message):
            tr("结束残留进程失败：\(message)", "Failed to terminate residual processes: \(message)")
        }
    }
}
