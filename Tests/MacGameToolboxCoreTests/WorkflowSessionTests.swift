import Darwin
import Foundation
import Testing
@testable import MacGameToolboxCore

@Test func exclusiveLockTableRejectsADifferentRunAndAllowsTheHolderToReacquire() async throws {
    let table = WorkflowExclusiveLockTable()
    let first = UUID()
    let second = UUID()
    let key = WorkflowExclusiveLockKey.processSession(bottle: "原神（国服）")
    let holder = WorkflowExclusiveLockHolder(runID: first, workflowID: "game.a", title: "A")

    try await table.acquire(key: key, holder: holder)
    try await table.acquire(key: key, holder: holder)

    do {
        try await table.acquire(
            key: key,
            holder: WorkflowExclusiveLockHolder(runID: second, workflowID: "game.b", title: "B")
        )
        Issue.record("A second run should not acquire an exclusive bottle lock")
    } catch let error as WorkflowExclusiveLockError {
        #expect(error == .heldByOther(holder))
    }

    let conflicts = await table.conflicts(for: [key, .networkGlobalIsolation])
    #expect(conflicts.count == 1)
    #expect(conflicts[0].holder.runID == first)

    await table.release(key: key, runID: first)
    #expect(await table.holder(for: key) == nil)
    try await table.acquire(
        key: key,
        holder: WorkflowExclusiveLockHolder(runID: second, workflowID: "game.b", title: "B")
    )
}

@Test func exclusiveLockTableDoesNotConflictAcrossBottles() async throws {
    let table = WorkflowExclusiveLockTable()
    try await table.acquire(
        key: .processSession(bottle: "Genshin"),
        holder: WorkflowExclusiveLockHolder(runID: UUID(), workflowID: "game.a", title: "A")
    )
    try await table.acquire(
        key: .processSession(bottle: "StarRail"),
        holder: WorkflowExclusiveLockHolder(runID: UUID(), workflowID: "game.b", title: "B")
    )
    #expect(await table.conflicts(for: [.networkGlobalIsolation]).isEmpty)
}

actor AdjustableGameModeRunner: CommandRunning {
    var policy = "automatic"
    var enabled = "off"
    private(set) var setCalls: [String] = []

    func run(_ executable: String, arguments: [String]) async throws -> CommandResult {
        if executable == "/usr/bin/xcrun" {
            return CommandResult(
                exitCode: 0,
                standardOutput: Data("/usr/bin/gamepolicyctl\n".utf8),
                standardError: Data()
            )
        }
        if arguments == ["game-mode", "status"] {
            let output = "Game mode is \(enabled). Game mode enablement policy is \(policy).\n"
            return CommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
        if arguments.count == 3, arguments[0] == "game-mode", arguments[1] == "set" {
            setCalls.append(arguments[2])
            switch arguments[2] {
            case "on":
                policy = "currently disabled. Game mode is forced always on"
                enabled = "on"
            case "auto":
                policy = "automatic"
                enabled = "off"
            case "off":
                policy = "currently disabled. Game mode is forced always off"
                enabled = "off"
            default:
                break
            }
        }
        return CommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }
}

@Test func gameModeClaimLedgerRestoresBaselineOnlyWhenTheLastRunReleases() async throws {
    let runner = AdjustableGameModeRunner()
    let ledger = GameModeClaimLedger(service: GameModeService(runner: runner))
    let first = UUID()
    let second = UUID()

    try await ledger.acquire(runID: first)
    #expect(await ledger.holderCount() == 1)
    #expect(await runner.setCalls == ["on"])

    try await ledger.acquire(runID: second)
    #expect(await ledger.holderCount() == 2)
    #expect(await runner.setCalls == ["on"])

    try await ledger.release(runID: first)
    #expect(await ledger.holderCount() == 1)
    #expect(await runner.setCalls == ["on"])

    try await ledger.release(runID: second)
    #expect(await ledger.holderCount() == 0)
    #expect(await runner.setCalls == ["on", "auto"])
}

@Test func bottleProcessSessionScopesToOneBottleAndProtectsCrossOverGUI() {
    let genshin = "原神（国服）"
    let processes = [
        SystemProcess(pid: 1, parentPID: 0, command: "/sbin/launchd"),
        SystemProcess(pid: 10, parentPID: 1, command: "/Applications/CrossOver.app/Contents/MacOS/CrossOver"),
        SystemProcess(pid: 20, parentPID: 10, command: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart --bottle \(genshin) --wait-ready -- /"),
        SystemProcess(pid: 30, parentPID: 20, command: "/Users/me/Library/Application Support/CrossOver/Bottles/\(genshin)/drive_c/windows/system32/wineserver"),
        SystemProcess(pid: 40, parentPID: 1, command: "/Users/me/Library/Application Support/CrossOver/Bottles/\(genshin)/drive_c/Genshin/YuanShen.exe"),
        SystemProcess(pid: 50, parentPID: 1, command: "/Users/me/Library/Application Support/CrossOver/Bottles/OtherGame/wineserver")
    ]

    let scoped = BottleProcessSession.scopedProcesses(processes, bottle: genshin)
    #expect(Set(scoped.map(\.pid)) == [20, 30, 40])
    #expect(BottleProcessSession.isProtected(processes[1]))
    #expect(
        BottleProcessSession.gameStillRunning(
            processes,
            bottle: genshin,
            claimedPIDs: [40],
            gameProcessNames: ["YuanShen.exe"]
        )
    )
    #expect(
        !BottleProcessSession.gameStillRunning(
            processes.filter { $0.pid != 40 },
            bottle: genshin,
            claimedPIDs: [40],
            gameProcessNames: ["YuanShen.exe"]
        )
    )
    #expect(BottleProcessSession.boostablePIDs(processes, bottle: genshin) == [20, 30, 40])
}

@Test func gameStillRunningUsesExecutableIdentityNotLauncherArguments() {
    let genshin = "原神（国服）"
    let launcher = SystemProcess(
        pid: 20,
        parentPID: 10,
        command: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart --bottle \(genshin) -- Y:\\Games\\Genshin Impact Game\\YuanShen.exe"
    )
    let hungGame = SystemProcess(
        pid: 99,
        parentPID: 1,
        command: #"C:\Genshin Impact Game\YuanShen.exe"#,
        comm: "YuanShen.exe"
    )
    let winePreloader = SystemProcess(
        pid: 80,
        parentPID: 1,
        command: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64-preloader",
        comm: "YuanShen.exe"
    )

    #expect(BottleProcessSession.matchesGameExecutable(hungGame, names: ["YuanShen.exe"]))
    #expect(BottleProcessSession.matchesGameExecutable(winePreloader, names: ["YuanShen.exe"]))
    #expect(!BottleProcessSession.matchesGameExecutable(launcher, names: ["YuanShen.exe"]))

    #expect(
        !BottleProcessSession.gameStillRunning(
            [launcher],
            bottle: genshin,
            claimedPIDs: [20],
            gameProcessNames: ["YuanShen.exe"]
        )
    )
    #expect(
        BottleProcessSession.gameStillRunning(
            [launcher, hungGame],
            bottle: genshin,
            claimedPIDs: [20],
            gameProcessNames: ["YuanShen.exe"]
        )
    )
}

@Test func terminateForceKillsDetachedGameExecutableWithoutBottlePath() async {
    let genshin = "原神（国服）"
    let processes = [
        SystemProcess(pid: 10, parentPID: 1, command: "/Applications/CrossOver.app/Contents/MacOS/CrossOver"),
        SystemProcess(
            pid: 20,
            parentPID: 10,
            command: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart --bottle \(genshin) -- Y:\\Games\\YuanShen.exe"
        ),
        SystemProcess(
            pid: 99,
            parentPID: 1,
            command: #"C:\Genshin Impact Game\YuanShen.exe"#,
            comm: "YuanShen.exe"
        )
    ]
    let signaler = RecordingProcessSignaler(alive: [10, 20, 99])
    let report = await BottleProcessSession.terminate(
        claimedPIDs: [],
        processes: processes,
        bottle: genshin,
        signaler: signaler,
        gameProcessNames: ["YuanShen.exe"],
        selfPID: 7,
        graceNanoseconds: 0
    )

    #expect(Set(report.requested) == [20, 99])
    #expect(report.remaining.isEmpty)
    #expect(report.failures.isEmpty)
    #expect(signaler.signals.contains(where: { $0.0 == SIGKILL && $0.1 == 99 }))
    #expect(!signaler.signals.contains(where: { $0.1 == 10 }))
    let firstGameSignal = signaler.signals.first { $0.1 == 99 }
    #expect(firstGameSignal?.0 == SIGKILL)
}

@Test func crossOverBottleShutdownTargetsTheBoundPrefix() {
    var invoked: (URL, URL)?
    CrossOverBottleShutdown.requestWineserverExit(
        applicationPath: "/Applications/CrossOver.app",
        bottle: "原神（国服）",
        fileManager: .default,
        homeURL: URL(fileURLWithPath: "/Users/test"),
        run: { wineserver, prefix in invoked = (wineserver, prefix) }
    )
    #expect(invoked == nil)

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let wineserver = root.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wineserver")
    try? fileManager.createDirectory(at: wineserver.deletingLastPathComponent(), withIntermediateDirectories: true)
    fileManager.createFile(atPath: wineserver.path, contents: Data())
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserver.path)
    defer { try? fileManager.removeItem(at: root) }

    CrossOverBottleShutdown.requestWineserverExit(
        applicationPath: root.path,
        bottle: "原神（国服）",
        fileManager: fileManager,
        homeURL: URL(fileURLWithPath: "/Users/test"),
        run: { wineserverURL, prefix in invoked = (wineserverURL, prefix) }
    )
    #expect(invoked?.0 == wineserver)
    #expect(
        invoked?.1 == URL(fileURLWithPath: "/Users/test/Library/Application Support/CrossOver/Bottles/原神（国服）", isDirectory: true)
    )
}

private final class RecordingProcessSignaler: ProcessSignaling, @unchecked Sendable {
    var alive: Set<Int32>
    private(set) var signals: [(Int32, Int32)] = []

    init(alive: Set<Int32>) {
        self.alive = alive
    }

    func exists(_ pid: Int32) -> Bool {
        alive.contains(pid)
    }

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        signals.append((signal, pid))
        if signal == SIGKILL {
            alive.remove(pid)
        }
        return 0
    }
}

@Test func claimedProcessTerminatorSignalsOnlyScopedWineProcesses() async {
    let genshin = "Genshin"
    let processes = [
        SystemProcess(pid: 10, parentPID: 1, command: "/Applications/CrossOver.app/Contents/MacOS/CrossOver"),
        SystemProcess(pid: 30, parentPID: 1, command: "/Users/me/Library/Application Support/CrossOver/Bottles/\(genshin)/wineserver"),
        SystemProcess(pid: 40, parentPID: 1, command: "/Users/me/Library/Application Support/CrossOver/Bottles/\(genshin)/YuanShen.exe"),
        SystemProcess(pid: 50, parentPID: 1, command: "/Users/me/Library/Application Support/CrossOver/Bottles/Other/wineserver")
    ]
    let signaler = RecordingProcessSignaler(alive: [10, 30, 40, 50])
    let report = await BottleProcessSession.terminate(
        claimedPIDs: [40],
        processes: processes,
        bottle: genshin,
        signaler: signaler,
        selfPID: 99,
        graceNanoseconds: 0
    )

    #expect(Set(report.requested) == [30, 40])
    #expect(report.remaining.isEmpty)
    #expect(report.failures.isEmpty)
    #expect(!signaler.signals.contains(where: { $0.1 == 10 || $0.1 == 50 }))
}

@Test func recoveryPlannerResumesHoldingStepsAndCompensatesLaunchCrashes() {
    let workflow = CompiledWorkflow(
        id: "test.workflow",
        steps: [
            WorkflowStepDefinition(id: "launch", kind: "game.launch"),
            WorkflowStepDefinition(id: "await-exit", kind: "game.awaitExit", holding: true)
        ]
    )
    let runID = UUID()

    let launchCrash = [
        WorkflowJournalEvent(
            runID: runID,
            workflowID: "test.workflow",
            kind: .stepStarted,
            status: .running,
            stepID: "launch"
        )
    ]
    #expect(WorkflowRecoveryPlanner.action(for: launchCrash, workflow: workflow) == .compensate)

    let holdingCrash = [
        WorkflowJournalEvent(
            runID: runID,
            workflowID: "test.workflow",
            kind: .stepSucceeded,
            status: .running,
            stepID: "launch"
        ),
        WorkflowJournalEvent(
            runID: runID,
            workflowID: "test.workflow",
            kind: .stepStarted,
            status: .running,
            stepID: "await-exit"
        )
    ]
    #expect(WorkflowRecoveryPlanner.action(for: holdingCrash, workflow: workflow) == .resume(fromStepID: "await-exit"))
}
