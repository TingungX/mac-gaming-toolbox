import Darwin
import Foundation

public protocol ProcessSignaling: Sendable {
    func exists(_ pid: Int32) -> Bool
    /// Returns 0 on success or the `errno` from `kill`.
    func send(_ signal: Int32, to pid: Int32) -> Int32
}

public struct POSIXProcessSignaler: ProcessSignaling {
    public init() {}

    public func exists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    public func send(_ signal: Int32, to pid: Int32) -> Int32 {
        if kill(pid, signal) == 0 { return 0 }
        return errno
    }
}

public struct ProcessTerminationReport: Equatable, Sendable {
    public let requested: [Int32]
    public let remaining: [Int32]
    public let failures: [String]

    public init(requested: [Int32], remaining: [Int32], failures: [String]) {
        self.requested = requested
        self.remaining = remaining
        self.failures = failures
    }
}

/// Bottle-scoped process discovery and termination for a workflow run.
/// The CrossOver GUI itself is never a legal target.
public enum BottleProcessSession {
    public static func matches(_ process: SystemProcess, bottle: String) -> Bool {
        let command = process.command
        if command.contains("/Bottles/\(bottle)") { return true }
        if command.contains("/Bottles/\(bottle)/") { return true }
        let lowered = command.lowercased()
        if lowered.contains("cxstart") && command.contains("--bottle") && command.contains(bottle) {
            return true
        }
        return false
    }

    public static func isProtected(_ process: SystemProcess) -> Bool {
        if process.pid <= 1 { return true }
        let lowered = process.command.lowercased()
        if lowered.contains("macgametoolbox") { return true }
        if lowered.contains("crossover.app/contents/macos/crossover") { return true }
        return false
    }

    public static func isTerminatable(_ process: SystemProcess) -> Bool {
        guard !isProtected(process) else { return false }
        let lowered = process.command.lowercased()
        return lowered.contains("wine")
            || lowered.contains("wineserver")
            || lowered.contains("winedevice")
            || lowered.contains(".exe")
            || lowered.contains("cxstart")
    }

    public static func scopedProcesses(
        _ processes: [SystemProcess],
        bottle: String,
        additionallyClaimed: Set<Int32> = []
    ) -> [SystemProcess] {
        var pids = Set(processes.filter { matches($0, bottle: bottle) && !isProtected($0) }.map(\.pid))
        pids.formUnion(additionallyClaimed.filter { $0 > 1 })
        var added = true
        while added {
            added = false
            for process in processes where pids.contains(process.parentPID) && !pids.contains(process.pid) {
                guard !isProtected(process) else { continue }
                pids.insert(process.pid)
                added = true
            }
        }
        return processes.filter { pids.contains($0.pid) }
    }

    public static func gameStillRunning(
        _ processes: [SystemProcess],
        bottle: String,
        claimedPIDs: Set<Int32>,
        gameProcessNames: [String]
    ) -> Bool {
        let scoped = scopedProcesses(processes, bottle: bottle, additionallyClaimed: claimedPIDs)
        return scoped.contains { process in
            gameProcessNames.contains { name in
                process.command.localizedCaseInsensitiveContains(name)
            }
        }
    }

    public static func terminate(
        claimedPIDs: Set<Int32>,
        processes: [SystemProcess],
        bottle: String,
        signaler: any ProcessSignaling,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        graceNanoseconds: UInt64 = 1_500_000_000
    ) async -> ProcessTerminationReport {
        let targets = scopedProcesses(processes, bottle: bottle, additionallyClaimed: claimedPIDs)
            .filter { isTerminatable($0) && $0.pid != selfPID }
            .map(\.pid)
        let uniqueTargets = Array(Set(targets)).sorted()
        var failures: [String] = []

        for pid in uniqueTargets {
            let code = signaler.send(SIGTERM, to: pid)
            if code != 0 && code != ESRCH {
                failures.append("SIGTERM \(pid) failed with errno \(code)")
            }
        }

        if graceNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: graceNanoseconds)
        }

        var remaining: [Int32] = []
        for pid in uniqueTargets where signaler.exists(pid) {
            let code = signaler.send(SIGKILL, to: pid)
            if code != 0 && code != ESRCH {
                failures.append("SIGKILL \(pid) failed with errno \(code)")
                remaining.append(pid)
            } else if signaler.exists(pid) {
                remaining.append(pid)
            }
        }

        return ProcessTerminationReport(
            requested: uniqueTargets,
            remaining: remaining.sorted(),
            failures: failures
        )
    }
}
