import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

enum GenshinWorkflowStage: Sendable {
    case recovering
    case preflight
    case isolatingNetwork
    case configuringMetalHUD
    case launching
    case waitingForRendering
    case restoringNetwork
    case applyingQoS
}

struct GenshinWorkflowUpdate: Sendable {
    let stage: GenshinWorkflowStage
    let progress: Double
}

protocol GenshinWorkflowCoordinating: Sendable {
    func run(
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult
    func cancel() async
    func recoverIncompleteRuns(
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> [WorkflowRunResult]
}

actor GenshinWorkflowCoordinator: GenshinWorkflowCoordinating {
    static let workflowID = "game.hoyo.genshin.cn.launch"
    static let installationID = "game.hoyo.genshin.cn"

    private enum StepKind {
        static let preflight = "environment.preflight"
        static let isolateNetwork = "network.isolate"
        static let configureMetalHUD = "metalhud.configure"
        static let launch = "game.launch.crossover"
        static let awaitReadiness = "game.awaitReadiness.genshin"
        static let restoreNetwork = "network.restore"
        static let applyQoS = "process.applyQoS"
    }

    fileprivate struct LeaseInput: Codable, Sendable { let seconds: Int }
    fileprivate struct MetalHUDInput: Codable, Sendable { let enabled: Bool }
    fileprivate struct ReadinessInput: Codable, Sendable { let timeoutSeconds: Int }

    private let runtimeStore: GenshinRuntimeStore
    private let journal: any WorkflowJournal
    private let engine: WorkflowEngine
    private let runsDirectory: URL

    init(
        capabilityClient: any PrivilegedCapabilityOperating,
        privileged: any PrivilegedOperating,
        gamingService: GamingService,
        journal: any WorkflowJournal,
        runsDirectory: URL
    ) throws {
        let runtimeStore = GenshinRuntimeStore()
        let contract = try NetworkIsolationCapability.contract()
        let registry = try WorkflowStepRegistry(
            registrations: [
                WorkflowStepRegistration(kind: StepKind.preflight, version: 1) {
                    GenshinPreflightStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(
                    kind: StepKind.isolateNetwork,
                    version: 1,
                    capabilities: [contract.reference]
                ) {
                    GenshinNetworkIsolationStep(
                        runtimeStore: runtimeStore,
                        capabilityClient: capabilityClient
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
                }
            ],
            contracts: [contract]
        )
        self.runtimeStore = runtimeStore
        self.journal = journal
        self.engine = WorkflowEngine(registry: registry, journal: journal)
        self.runsDirectory = runsDirectory
    }

    func run(
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult {
        let runID = UUID()
        let traceURL = runsDirectory.appendingPathComponent("\(runID.uuidString).cxlog")
        let context = GenshinRunContext(
            installation: installation,
            traceURL: traceURL,
            update: update
        )
        await runtimeStore.insert(context, for: runID)

        do {
            let result = try await engine.run(
                try Self.workflow(metalHUDEnabled: metalHUDEnabled),
                runID: runID
            )
            await context.cleanup()
            await runtimeStore.remove(runID)
            return result
        } catch {
            await context.cleanup()
            await runtimeStore.remove(runID)
            throw error
        }
    }

    func cancel() async {
        _ = await engine.cancelActiveRun()
    }

    func recoverIncompleteRuns(
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> [WorkflowRunResult] {
        let runIDs = try await journal.incompleteRunIDs()
        var results: [WorkflowRunResult] = []
        for runID in runIDs {
            await update(GenshinWorkflowUpdate(stage: .recovering, progress: 0))
            results.append(try await engine.recover(
                try Self.workflow(metalHUDEnabled: false),
                runID: runID
            ))
        }
        return results
    }

    private static func workflow(metalHUDEnabled: Bool) throws -> CompiledWorkflow {
        let encoder = JSONEncoder()
        return CompiledWorkflow(
            id: workflowID,
            revision: 1,
            steps: [
                WorkflowStepDefinition(id: "preflight", kind: StepKind.preflight),
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
                WorkflowStepDefinition(id: "apply-qos", kind: StepKind.applyQoS)
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

private actor GenshinRunContext {
    let installation: GameInstallation
    let traceURL: URL

    private let update: @Sendable (GenshinWorkflowUpdate) async -> Void
    private var launchDescription: CrossOverProcessLaunchDescription?
    private var launchProcess: Process?
    private var traceHandle: FileHandle?
    private var metalHUDEnabled = false
    private var networkHandle: CapabilityRecoveryHandle?
    private var leaseSession: NetworkIsolationLeaseSession?

    init(
        installation: GameInstallation,
        traceURL: URL,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) {
        self.installation = installation
        self.traceURL = traceURL
        self.update = update
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

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let input = try JSONDecoder().decode(
            GenshinWorkflowCoordinator.LeaseInput.self,
            from: context.step.input
        )
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.isolatingNetwork, progress: 0.15)
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
        try await capabilityClient.recover(try Self.capabilityHandle(from: recoveryHandle))
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
            } else if !(await runtime.launchProcessIsRunning()), probe.targetPID == nil {
                throw GenshinWorkflowCoordinatorError.gameExitedBeforeTrace
            }
            try await Task.sleep(for: .milliseconds(100))
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
        let processes = try await gamingService.wineProcesses(crossOverOnly: true)
        let genshinProcesses = processes.filter {
            $0.command.localizedCaseInsensitiveContains("YuanShen.exe")
        }
        guard !genshinProcesses.isEmpty else {
            throw GenshinWorkflowCoordinatorError.gameProcessNotFound
        }
        try await privileged.perform(.renice(genshinProcesses.map(\.pid)))
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
        }
    }
}
