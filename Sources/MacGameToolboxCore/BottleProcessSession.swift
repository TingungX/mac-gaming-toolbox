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

public enum ProcessCommResolver {
    /// Live `p_comm` as shown in Activity Monitor. Returns nil when unavailable.
    public static func live(_ pid: Int32) -> String? {
        #if os(macOS)
        var buffer = [CChar](repeating: 0, count: 32)
        let count = proc_name(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
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
    public static func executableLeafName(_ command: String) -> String {
        SystemProcess.inferredComm(from: command)
    }

    public static func matches(_ process: SystemProcess, bottle: String) -> Bool {
        commandContainsBottlePath(process.command, bottle: bottle)
            || commandContainsBottleFlag(process.command, bottle: bottle)
    }

    /// `/Bottles/P3R` must not match `/Bottles/P3R Demo`.
    private static func commandContainsBottlePath(_ command: String, bottle: String) -> Bool {
        let marker = "/Bottles/\(bottle)"
        var search = command.startIndex
        while let range = command.range(of: marker, range: search..<command.endIndex) {
            if range.upperBound == command.endIndex {
                return true
            }
            let next = command[range.upperBound]
            if next == "/" || next == "\\" || next.isWhitespace || next == "\"" {
                return true
            }
            search = command.index(after: range.lowerBound)
        }
        return false
    }

    /// `--bottle P3R` must not match `--bottle P3R Demo`.
    private static func commandContainsBottleFlag(_ command: String, bottle: String) -> Bool {
        guard command.localizedCaseInsensitiveContains("cxstart") else { return false }
        let tokens = command.split { $0.isWhitespace }.map(String.init)
        guard let flagIndex = tokens.firstIndex(of: "--bottle"), flagIndex + 1 < tokens.count else {
            return false
        }
        let name = tokens[(flagIndex + 1)...].prefix { !$0.hasPrefix("-") }.joined(separator: " ")
        return name == bottle
    }

    public static func isProtected(_ process: SystemProcess) -> Bool {
        if process.pid <= 1 { return true }
        let lowered = process.command.lowercased()
        let comm = process.comm.lowercased()
        if lowered.contains("macgametoolbox") || comm.contains("macgametoolbox") { return true }
        if lowered.contains("crossover.app/contents/macos/crossover") { return true }
        if comm == "crossover" && lowered.hasSuffix("/crossover") { return true }
        return false
    }

    public static func isTerminatable(_ process: SystemProcess) -> Bool {
        guard !isProtected(process) else { return false }
        let lowered = process.command.lowercased()
        let comm = process.comm.lowercased()
        return lowered.contains("wine")
            || lowered.contains("wineserver")
            || lowered.contains("winedevice")
            || lowered.contains(".exe")
            || comm.contains(".exe")
            || lowered.contains("cxstart")
            || comm.contains("cxstart")
    }

    /// True only when this Unix process *is* the game executable, not when a
    /// launcher such as `cxstart` merely mentions the name in its arguments.
    public static func matchesGameExecutable(_ process: SystemProcess, names: [String]) -> Bool {
        guard !names.isEmpty, !isProtected(process) else { return false }
        let candidates = [process.comm, executableLeafName(process.command)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.contains { name in
            candidates.contains { candidate in
                candidate.caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    public static func gameExecutablePIDs(_ processes: [SystemProcess], names: [String]) -> Set<Int32> {
        Set(processes.filter { matchesGameExecutable($0, names: names) }.map(\.pid))
    }

    /// Game executables that belong to this run — not a same-named process
    /// that was already alive when the bottle session was claimed.
    ///
    /// P3R and P3R Demo both use `P3R.exe`. A global name match would claim
    /// the already-running bottle before the newly launched process exists.
    public static func thisRunGameProcesses(
        _ processes: [SystemProcess],
        bottle: String,
        claimedPIDs: Set<Int32> = [],
        gameProcessNames: [String],
        preexistingGamePIDs: Set<Int32> = []
    ) -> [SystemProcess] {
        scopedProcesses(
            processes,
            bottle: bottle,
            additionallyClaimed: claimedPIDs,
            gameProcessNames: gameProcessNames,
            preexistingGamePIDs: preexistingGamePIDs
        )
        .filter { process in
            matchesGameExecutable(process, names: gameProcessNames)
                && !preexistingGamePIDs.contains(process.pid)
        }
    }

    public static func scopedProcesses(
        _ processes: [SystemProcess],
        bottle: String,
        additionallyClaimed: Set<Int32> = [],
        gameProcessNames: [String] = [],
        preexistingGamePIDs: Set<Int32> = []
    ) -> [SystemProcess] {
        var pids = Set(processes.filter { matches($0, bottle: bottle) && !isProtected($0) }.map(\.pid))
        pids.formUnion(additionallyClaimed.filter { $0 > 1 && !preexistingGamePIDs.contains($0) })
        for process in processes where matchesGameExecutable(process, names: gameProcessNames) {
            if pids.contains(process.pid) { continue }
            if process.command.contains("/Bottles/") { continue }
            // Detached Wine processes lose the bottle path. Only claim ones that
            // appeared after this run started, so a sibling bottle's P3R.exe is
            // not stolen by P3R Demo (or the reverse).
            if !preexistingGamePIDs.contains(process.pid) {
                pids.insert(process.pid)
            }
        }
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

    /// Wine/cxstart processes owned by this bottle. CrossOver.app itself is
    /// excluded. The helper accepts at most 64 PIDs per renice request.
    public static func boostablePIDs(
        _ processes: [SystemProcess],
        bottle: String,
        additionallyClaimed: Set<Int32> = [],
        gameProcessNames: [String] = [],
        preexistingGamePIDs: Set<Int32> = [],
        limit: Int = 64
    ) -> [Int32] {
        let pids = scopedProcesses(
            processes,
            bottle: bottle,
            additionallyClaimed: additionallyClaimed,
            gameProcessNames: gameProcessNames,
            preexistingGamePIDs: preexistingGamePIDs
        )
        .filter(isTerminatable)
        .map(\.pid)
        return Array(Set(pids)).sorted().prefix(limit).map { $0 }
    }

    public static func gameStillRunning(
        _ processes: [SystemProcess],
        bottle: String,
        claimedPIDs: Set<Int32>,
        gameProcessNames: [String],
        preexistingGamePIDs: Set<Int32> = []
    ) -> Bool {
        // cxstart / wine command lines mention YuanShen.exe as an argument
        // long after the player has quit. Only this run's executable identity
        // counts — a sibling bottle's same-named exe is ignored.
        !thisRunGameProcesses(
            processes,
            bottle: bottle,
            claimedPIDs: claimedPIDs,
            gameProcessNames: gameProcessNames,
            preexistingGamePIDs: preexistingGamePIDs
        ).isEmpty
    }

    public static func terminate(
        claimedPIDs: Set<Int32>,
        processes: [SystemProcess],
        bottle: String,
        signaler: any ProcessSignaling,
        gameProcessNames: [String] = [],
        preexistingGamePIDs: Set<Int32> = [],
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        graceNanoseconds: UInt64 = 1_500_000_000
    ) async -> ProcessTerminationReport {
        let scoped = scopedProcesses(
            processes,
            bottle: bottle,
            additionallyClaimed: claimedPIDs,
            gameProcessNames: gameProcessNames,
            preexistingGamePIDs: preexistingGamePIDs
        )
        .filter { isTerminatable($0) && $0.pid != selfPID }

        let gameTargets = Set(
            scoped.filter { matchesGameExecutable($0, names: gameProcessNames) }.map(\.pid)
        )
        let otherTargets = scoped.map(\.pid).filter { !gameTargets.contains($0) }
        let uniqueTargets = Array(gameTargets.union(otherTargets)).sorted()
        var failures: [String] = []

        // Genshin-on-CrossOver commonly ignores SIGTERM after an in-game quit
        // and must be force-killed, matching Activity Monitor's Force Quit.
        for pid in gameTargets.sorted() {
            appendSignalFailure(
                signaler.send(SIGKILL, to: pid),
                pid: pid,
                signal: "SIGKILL",
                into: &failures
            )
        }

        for pid in otherTargets.sorted() {
            appendSignalFailure(
                signaler.send(SIGTERM, to: pid),
                pid: pid,
                signal: "SIGTERM",
                into: &failures
            )
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

    private static func appendSignalFailure(
        _ code: Int32,
        pid: Int32,
        signal: String,
        into failures: inout [String]
    ) {
        if code != 0 && code != ESRCH {
            failures.append("\(signal) \(pid) failed with errno \(code)")
        }
    }
}
