import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

enum DirectLaunchWorkflowStage: Sendable {
    case recovering
    case preflight
    case claimingProcessSession
    case configuringMetalHUD
    case installingAspectFix
    case launching
    case waitingForProcess
    case applyingQoS
    case claimingGameMode
    case waitingForExit
    case terminatingResiduals
    case releasingGameMode
}

struct DirectLaunchResumableRun: Sendable {
    let runID: WorkflowRunID
    let workflowID: WorkflowID
}

struct DirectLaunchWorkflowRecovery: Sendable {
    let compensated: [WorkflowRunResult]
    let resumable: [DirectLaunchResumableRun]
}

struct DirectLaunchWorkflowUpdate: Sendable {
    let profile: BuiltInGameWorkflow
    let stage: DirectLaunchWorkflowStage
    let progress: Double
}

protocol DirectLaunchWorkflowCoordinating: Sendable {
    func exclusiveConflicts(for installation: GameInstallation) async -> [WorkflowResourceConflict]
    func gameModeHolderCount() async -> Int
    func run(
        profile: BuiltInGameWorkflow,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult
    func resume(
        profile: BuiltInGameWorkflow,
        runID: WorkflowRunID,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult
    func cancel() async
    func cancel(runIDs: [WorkflowRunID]) async
    func recoverIncompleteRuns(
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    ) async throws -> DirectLaunchWorkflowRecovery
}

actor DirectLaunchWorkflowCoordinator: DirectLaunchWorkflowCoordinating {
    private let runtimeStore: DirectLaunchRuntimeStore
    private let journal: any WorkflowJournal
    private let engine: WorkflowEngine
    private let runsDirectory: URL
    private let exclusiveLocks: WorkflowExclusiveLockTable
    private let gameModeClaims: GameModeClaimLedger

    init(
        privileged: any PrivilegedOperating,
        gamingService: GamingService,
        journal: any WorkflowJournal,
        runsDirectory: URL,
        exclusiveLocks: WorkflowExclusiveLockTable,
        gameModeClaims: GameModeClaimLedger,
        processSignaler: any ProcessSignaling = POSIXProcessSignaler()
    ) throws {
        let runtimeStore = DirectLaunchRuntimeStore()
        let registry = try WorkflowStepRegistry(
            registrations: [
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.preflight, version: 1) {
                    DirectLaunchPreflightStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.claimProcessSession, version: 1) {
                    DirectLaunchClaimProcessSessionStep(
                        runtimeStore: runtimeStore,
                        exclusiveLocks: exclusiveLocks,
                        gamingService: gamingService,
                        processSignaler: processSignaler
                    )
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.configureMetalHUD, version: 1) {
                    DirectLaunchMetalHUDStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.installP3RFix, version: 1) {
                    DirectLaunchInstallP3RFixStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.launch, version: 1) {
                    DirectLaunchLaunchStep(runtimeStore: runtimeStore)
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.awaitProcess, version: 1) {
                    DirectLaunchAwaitProcessStep(
                        runtimeStore: runtimeStore,
                        gamingService: gamingService
                    )
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.applyQoS, version: 1) {
                    DirectLaunchQoSStep(
                        runtimeStore: runtimeStore,
                        gamingService: gamingService,
                        privileged: privileged
                    )
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.claimGameMode, version: 1) {
                    DirectLaunchClaimGameModeStep(
                        runtimeStore: runtimeStore,
                        ledger: gameModeClaims
                    )
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.awaitExit, version: 1) {
                    DirectLaunchAwaitExitStep(
                        runtimeStore: runtimeStore,
                        gamingService: gamingService
                    )
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.terminateResiduals, version: 1) {
                    DirectLaunchTerminateResidualsStep(
                        runtimeStore: runtimeStore,
                        gamingService: gamingService,
                        processSignaler: processSignaler
                    )
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.releaseGameMode, version: 1) {
                    DirectLaunchReleaseGameModeStep(ledger: gameModeClaims)
                },
                WorkflowStepRegistration(kind: DirectLaunchWorkflowStepKind.releaseProcessSession, version: 1) {
                    DirectLaunchReleaseProcessSessionStep(
                        runtimeStore: runtimeStore,
                        exclusiveLocks: exclusiveLocks
                    )
                }
            ]
        )
        self.runtimeStore = runtimeStore
        self.journal = journal
        self.engine = WorkflowEngine(registry: registry, journal: journal)
        self.runsDirectory = runsDirectory
        self.exclusiveLocks = exclusiveLocks
        self.gameModeClaims = gameModeClaims
    }

    func exclusiveConflicts(for installation: GameInstallation) async -> [WorkflowResourceConflict] {
        guard case .crossOver(let binding) = installation.launchBinding else { return [] }
        return await exclusiveLocks.conflicts(for: [.processSession(bottle: binding.bottleName)])
    }

    func gameModeHolderCount() async -> Int {
        await gameModeClaims.holderCount()
    }

    func run(
        profile: BuiltInGameWorkflow,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult {
        try await execute(
            profile: profile,
            runID: UUID(),
            installation: installation,
            metalHUDEnabled: metalHUDEnabled,
            update: update,
            resumeExisting: false
        )
    }

    func resume(
        profile: BuiltInGameWorkflow,
        runID: WorkflowRunID,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult {
        try await execute(
            profile: profile,
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
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    ) async throws -> DirectLaunchWorkflowRecovery {
        let runIDs = try await journal.incompleteRunIDs()
        var compensated: [WorkflowRunResult] = []
        var resumable: [DirectLaunchResumableRun] = []

        for runID in runIDs {
            let events = try await journal.events(for: runID)
            guard let workflowID = events.first?.workflowID,
                  let profile = BuiltInDirectLaunchWorkflows.workflow(workflowID: workflowID) else {
                continue
            }
            await update(DirectLaunchWorkflowUpdate(profile: profile, stage: .recovering, progress: 0))
            let workflow = try DirectLaunchWorkflowPlan.compiled(
                workflowID: profile.workflowID,
                metalHUDEnabled: false,
                processWaitTimeoutSeconds: profile.processWaitTimeoutSeconds
            )
            switch WorkflowRecoveryPlanner.action(for: events, workflow: workflow) {
            case .resume:
                resumable.append(DirectLaunchResumableRun(runID: runID, workflowID: workflowID))
            case .compensate:
                compensated.append(try await engine.recover(workflow, runID: runID))
            }
        }
        return DirectLaunchWorkflowRecovery(compensated: compensated, resumable: resumable)
    }

    private func execute(
        profile: BuiltInGameWorkflow,
        runID: WorkflowRunID,
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void,
        resumeExisting: Bool
    ) async throws -> WorkflowRunResult {
        let traceURL = runsDirectory.appendingPathComponent("\(runID.uuidString).cxlog")
        let context = DirectLaunchRunContext(
            profile: profile,
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
            let workflow = try DirectLaunchWorkflowPlan.compiled(
                workflowID: profile.workflowID,
                metalHUDEnabled: metalHUDEnabled,
                processWaitTimeoutSeconds: profile.processWaitTimeoutSeconds
            )
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

    private func restoreSessionClaims(runID: WorkflowRunID, context: DirectLaunchRunContext) async {
        let holder = WorkflowExclusiveLockHolder(
            runID: runID,
            workflowID: context.profile.workflowID,
            title: context.profile.displayName
        )
        if let bottle = try? await context.bottleName() {
            try? await exclusiveLocks.acquire(key: .processSession(bottle: bottle), holder: holder)
        }
        if let sidecar = await context.loadSidecar() {
            await context.restoreClaimedPIDs(Set(sidecar.claimedPIDs))
            if sidecar.gameModeHeld, let baseline = sidecar.gameModeBaseline {
                await gameModeClaims.restoreHolder(runID: runID, baseline: baseline)
            }
        }
    }

    private static func sidecarURL(in directory: URL, runID: WorkflowRunID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).session.json")
    }
}

private actor DirectLaunchRuntimeStore {
    private var contexts: [WorkflowRunID: DirectLaunchRunContext] = [:]

    func insert(_ context: DirectLaunchRunContext, for runID: WorkflowRunID) {
        contexts[runID] = context
    }

    func context(for runID: WorkflowRunID) throws -> DirectLaunchRunContext {
        guard let context = contexts[runID] else {
            throw DirectLaunchWorkflowError.missingRuntime(runID)
        }
        return context
    }

    func optionalContext(for runID: WorkflowRunID) -> DirectLaunchRunContext? {
        contexts[runID]
    }

    func remove(_ runID: WorkflowRunID) {
        contexts.removeValue(forKey: runID)
    }
}

private struct DirectLaunchSessionSidecar: Codable, Sendable {
    var bottleName: String
    var gameModeBaseline: GameModePolicy?
    var gameModeHeld: Bool
    var claimedPIDs: [Int32]
}

private actor DirectLaunchRunContext {
    let profile: BuiltInGameWorkflow
    let installation: GameInstallation
    let traceURL: URL
    let sidecarURL: URL

    private let update: @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    private var launchDescription: CrossOverProcessLaunchDescription?
    private var launchProcess: Process?
    private var metalHUDEnabled = false
    private var claimedPIDs: Set<Int32> = []
    private var gameModeBaseline: GameModePolicy?
    private var gameModeHeld = false

    init(
        profile: BuiltInGameWorkflow,
        installation: GameInstallation,
        traceURL: URL,
        sidecarURL: URL,
        update: @escaping @Sendable (DirectLaunchWorkflowUpdate) async -> Void
    ) {
        self.profile = profile
        self.installation = installation
        self.traceURL = traceURL
        self.sidecarURL = sidecarURL
        self.update = update
    }

    func bottleName() throws -> String {
        guard case .crossOver(let binding) = installation.launchBinding else {
            throw DirectLaunchWorkflowError.invalidInstallation(profile.displayName)
        }
        return binding.bottleName
    }

    func displayName() -> String { profile.displayName }

    func processNames() -> [String] { profile.processNames }

    func claimedProcessIDs() -> Set<Int32> { claimedPIDs }

    func restoreClaimedPIDs(_ pids: Set<Int32>) {
        claimedPIDs = pids
    }

    func claimProcessIDs(_ pids: [Int32]) {
        claimedPIDs.formUnion(pids.filter { $0 > 1 })
    }

    func markGameModeClaimed(baseline: GameModePolicy?) {
        gameModeBaseline = baseline
        gameModeHeld = true
    }

    func loadSidecar() -> DirectLaunchSessionSidecar? {
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return try? JSONDecoder().decode(DirectLaunchSessionSidecar.self, from: data)
    }

    func persistSidecar() {
        guard let bottle = try? bottleName() else { return }
        let sidecar = DirectLaunchSessionSidecar(
            bottleName: bottle,
            gameModeBaseline: gameModeBaseline,
            gameModeHeld: gameModeHeld,
            claimedPIDs: claimedPIDs.sorted()
        )
        do {
            try FileManager.default.createDirectory(
                at: sidecarURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: .atomic)
        } catch {
            DiagnosticFileLogger.write("Unable to persist launch session sidecar: \(error.localizedDescription)")
        }
    }

    func removeSidecar() {
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    func report(_ stage: DirectLaunchWorkflowStage, progress: Double) async {
        await update(DirectLaunchWorkflowUpdate(profile: profile, stage: stage, progress: progress))
    }

    func prepareLaunch() throws {
        guard installation.id == profile.id,
              case .crossOver(let binding) = installation.launchBinding else {
            throw DirectLaunchWorkflowError.invalidInstallation(profile.displayName)
        }
        let configuration = try CrossOverLaunchConfiguration(
            crossOverAppURL: URL(fileURLWithPath: binding.applicationPath),
            bottle: binding.bottleName,
            executablePath: binding.executablePath,
            workingDirectoryPath: binding.workingDirectoryPath
        )
        let adapter = CrossOverLaunchAdapter(configuration: configuration)
        let description = try adapter.makeProcessLaunchDescription(
            logFileURL: traceURL,
            wineDllOverrides: profile.installsP3RFix ? P3RFixRelease.wineDllOverrides : nil
        )
        guard FileManager.default.fileExists(atPath: configuration.crossOverApp.url.path),
              FileManager.default.isExecutableFile(atPath: description.executableURL.path) else {
            throw DirectLaunchWorkflowError.crossOverUnavailable
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

    func installP3RFix() throws {
        guard profile.installsP3RFix else { return }
        guard case .crossOver(let binding) = installation.launchBinding else {
            throw DirectLaunchWorkflowError.invalidInstallation(profile.displayName)
        }
        guard let executableURL = CrossOverGamePathDiscovery.nativeURL(
            forWindowsPath: binding.executablePath,
            inBottle: binding.bottleName
        ) else {
            throw DirectLaunchWorkflowError.aspectFixInstallFailed(
                P3RFixInstallError.destinationEscapedBottle.localizedDescription
            )
        }
        do {
            try P3RFixInstaller.install(
                payload: try BundledP3RFixPayload.load(),
                executableURL: executableURL
            )
        } catch let error as DirectLaunchWorkflowError {
            throw error
        } catch {
            throw DirectLaunchWorkflowError.aspectFixInstallFailed(error.localizedDescription)
        }
    }

    func setMetalHUDEnabled(_ enabled: Bool) {
        metalHUDEnabled = enabled
    }

    func launch() throws {
        guard let launchDescription else {
            throw DirectLaunchWorkflowError.preflightNotCompleted
        }
        let process = Process()
        process.executableURL = launchDescription.executableURL
        process.arguments = launchDescription.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if metalHUDEnabled || !launchDescription.extraEnvironment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in launchDescription.extraEnvironment {
                environment[key] = value
            }
            if metalHUDEnabled {
                environment["MTL_HUD_ENABLED"] = "1"
            }
            process.environment = environment
        }
        try process.run()
        launchProcess = process
    }

    func launchProcessIsRunning() -> Bool {
        launchProcess?.isRunning ?? false
    }

    func cleanup() async {
        launchProcess = nil
        removeSidecar()
        if FileManager.default.fileExists(atPath: traceURL.path) {
            do {
                try FileManager.default.removeItem(at: traceURL)
            } catch {
                DiagnosticFileLogger.write("Unable to remove launch workflow trace: \(error.localizedDescription)")
            }
        }
    }
}

private struct DirectLaunchPreflightStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.preflight, progress: 0.05)
        try await runtime.prepareLaunch()
        return .completed
    }
}

private struct DirectLaunchMetalHUDStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let input = try JSONDecoder().decode(
            DirectLaunchWorkflowPlan.MetalHUDInput.self,
            from: context.step.input
        )
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.configuringMetalHUD, progress: 0.2)
        await runtime.setMetalHUDEnabled(input.enabled)
        return .completed
    }
}

private struct DirectLaunchInstallP3RFixStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.installingAspectFix, progress: 0.28)
        try await runtime.installP3RFix()
        return .completed
    }
}

private struct DirectLaunchLaunchStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.launching, progress: 0.35)
        try await runtime.launch()
        return .completed
    }
}

private struct DirectLaunchAwaitProcessStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore
    let gamingService: GamingService

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let input = try JSONDecoder().decode(
            DirectLaunchWorkflowPlan.ProcessWaitInput.self,
            from: context.step.input
        )
        guard (10...180).contains(input.timeoutSeconds) else {
            throw DirectLaunchWorkflowError.invalidProcessWaitTimeout
        }
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.waitingForProcess, progress: 0.55)
        let bottle = try await runtime.bottleName()
        let names = await runtime.processNames()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(input.timeoutSeconds))

        while clock.now < deadline {
            try Task.checkCancellation()
            let processes = try await gamingService.runningProcesses()
            let scoped = BottleProcessSession.scopedProcesses(
                processes,
                bottle: bottle,
                additionallyClaimed: await runtime.claimedProcessIDs()
            )
            let matched = scoped.filter { process in
                names.contains { process.command.localizedCaseInsensitiveContains($0) }
            }
            if !matched.isEmpty {
                await runtime.claimProcessIDs(matched.map(\.pid))
                await runtime.persistSidecar()
                return .completed
            }
            if !(await runtime.launchProcessIsRunning()) {
                throw DirectLaunchWorkflowError.gameExitedBeforeProcess(await runtime.displayName())
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DirectLaunchWorkflowError.processWaitTimedOut(await runtime.displayName())
    }
}

private struct DirectLaunchQoSStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore
    let gamingService: GamingService
    let privileged: any PrivilegedOperating

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.applyingQoS, progress: 0.75)
        let bottle = try await runtime.bottleName()
        let processes = try await gamingService.runningProcesses()
        let pids = BottleProcessSession.boostablePIDs(
            processes,
            bottle: bottle,
            additionallyClaimed: await runtime.claimedProcessIDs()
        )
        guard !pids.isEmpty else {
            throw DirectLaunchWorkflowError.gameProcessNotFound(await runtime.displayName())
        }
        await runtime.claimProcessIDs(pids)
        await runtime.persistSidecar()
        try await privileged.perform(.renice(pids))
        return .completed
    }
}

private struct DirectLaunchClaimProcessSessionStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore
    let exclusiveLocks: WorkflowExclusiveLockTable
    let gamingService: GamingService
    let processSignaler: any ProcessSignaling

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.claimingProcessSession, progress: 0.1)
        let bottle = try await runtime.bottleName()
        try await exclusiveLocks.acquire(
            key: .processSession(bottle: bottle),
            holder: WorkflowExclusiveLockHolder(
                runID: context.runID,
                workflowID: context.workflowID,
                title: await runtime.displayName()
            )
        )
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
        let processes = (try? await gamingService.runningProcesses()) ?? []
        let report = await BottleProcessSession.terminate(
            claimedPIDs: await runtime.claimedProcessIDs(),
            processes: processes,
            bottle: bottle,
            signaler: processSignaler
        )
        await exclusiveLocks.release(key: .processSession(bottle: bottle), runID: context.runID)
        await runtime.removeSidecar()
        if !report.failures.isEmpty {
            throw DirectLaunchWorkflowError.terminationFailed(report.failures.joined(separator: "; "))
        }
    }
}

private struct DirectLaunchClaimGameModeStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore
    let ledger: GameModeClaimLedger

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.claimingGameMode, progress: 0.85)
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

private struct DirectLaunchAwaitExitStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore
    let gamingService: GamingService

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.waitingForExit, progress: 0.9)
        let bottle = try await runtime.bottleName()
        let names = await runtime.processNames()
        while true {
            try Task.checkCancellation()
            let processes = try await gamingService.runningProcesses()
            let scoped = BottleProcessSession.scopedProcesses(
                processes,
                bottle: bottle,
                additionallyClaimed: await runtime.claimedProcessIDs()
            )
            await runtime.claimProcessIDs(scoped.map(\.pid))
            await runtime.persistSidecar()
            let stillRunning = BottleProcessSession.gameStillRunning(
                processes,
                bottle: bottle,
                claimedPIDs: await runtime.claimedProcessIDs(),
                gameProcessNames: names
            )
            if !stillRunning { return .completed }
            try await Task.sleep(for: .seconds(1))
        }
    }
}

private struct DirectLaunchTerminateResidualsStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore
    let gamingService: GamingService
    let processSignaler: any ProcessSignaling

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        await runtime.report(.terminatingResiduals, progress: 0.96)
        let bottle = try await runtime.bottleName()
        let processes = try await gamingService.runningProcesses()
        let report = await BottleProcessSession.terminate(
            claimedPIDs: await runtime.claimedProcessIDs(),
            processes: processes,
            bottle: bottle,
            signaler: processSignaler
        )
        if !report.failures.isEmpty {
            throw DirectLaunchWorkflowError.terminationFailed(report.failures.joined(separator: "; "))
        }
        return .completed
    }
}

private struct DirectLaunchReleaseGameModeStep: WorkflowStepExecuting {
    let ledger: GameModeClaimLedger

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        try await ledger.release(runID: context.runID)
        return .completed
    }
}

private struct DirectLaunchReleaseProcessSessionStep: WorkflowStepExecuting {
    let runtimeStore: DirectLaunchRuntimeStore
    let exclusiveLocks: WorkflowExclusiveLockTable

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let runtime = try await runtimeStore.context(for: context.runID)
        let bottle = try await runtime.bottleName()
        await exclusiveLocks.release(key: .processSession(bottle: bottle), runID: context.runID)
        await runtime.removeSidecar()
        return .completed
    }
}

enum DirectLaunchWorkflowError: Error, LocalizedError {
    case missingRuntime(WorkflowRunID)
    case invalidInstallation(String)
    case crossOverUnavailable
    case preflightNotCompleted
    case invalidProcessWaitTimeout
    case gameExitedBeforeProcess(String)
    case processWaitTimedOut(String)
    case gameProcessNotFound(String)
    case terminationFailed(String)
    case aspectFixPayloadMissing
    case aspectFixInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            tr("找不到本次启动的运行状态", "The launch runtime is unavailable")
        case .invalidInstallation(let name):
            tr("\(name) 安装绑定无效，请重新配置", "The \(name) installation binding is invalid")
        case .crossOverUnavailable:
            tr("找不到可用的 CrossOver 或 cxstart", "CrossOver or cxstart is unavailable")
        case .preflightNotCompleted:
            tr("启动预检尚未完成", "Launch preflight has not completed")
        case .invalidProcessWaitTimeout:
            tr("等待游戏进程的超时时间无效", "The process wait timeout is invalid")
        case .gameExitedBeforeProcess(let name):
            tr("CrossOver 在识别到 \(name) 进程前退出", "CrossOver exited before the \(name) process was identified")
        case .processWaitTimedOut(let name):
            tr("等待 \(name) 进程出现超时", "Timed out waiting for the \(name) process")
        case .gameProcessNotFound(let name):
            tr("启动后未找到 \(name) Wine 进程", "No \(name) Wine process was found after launch")
        case .terminationFailed(let message):
            tr("结束残留进程失败：\(message)", "Failed to terminate residual processes: \(message)")
        case .aspectFixPayloadMissing:
            tr("找不到内置的 P3R 去黑边补丁", "The bundled P3R aspect-ratio fix is missing")
        case .aspectFixInstallFailed(let message):
            tr("安装 P3R 去黑边补丁失败：\(message)", "Failed to install the P3R aspect-ratio fix: \(message)")
        }
    }
}
