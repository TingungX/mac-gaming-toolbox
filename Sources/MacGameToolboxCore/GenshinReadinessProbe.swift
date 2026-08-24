import Foundation

public enum GenshinReadinessFailure: Equatable, Sendable {
    case processExited
    case mhypBaseAccessViolation
    case traceLimitExceeded
    case timedOut
}

public enum GenshinReadinessState: Equatable, Sendable {
    case waiting
    case ready
    case failed(GenshinReadinessFailure)
}

/// A bounded, per-launch readiness probe for the Genshin render thread.
/// Network isolation and restoration intentionally do not belong here; the
/// workflow engine decides what to do after observing `ready` or `failed`.
public struct GenshinReadinessProbe: Sendable {
    public private(set) var state: GenshinReadinessState = .waiting
    public private(set) var targetPID: Int32?

    private var parser: CrossOverTraceParser

    public init(targetPID: Int32? = nil, limits: CrossOverTraceParser.Limits = .init()) throws {
        self.targetPID = targetPID
        self.parser = try CrossOverTraceParser(targetPID: targetPID, limits: limits)
    }

    /// Consumes a trace chunk and returns the current terminal-or-waiting
    /// state. The caller can feed arbitrary chunk boundaries, including UTF-8
    /// and log-line splits.
    @discardableResult
    public mutating func append(_ chunk: Data) -> GenshinReadinessState {
        transition(parser.append(chunk))
    }

    @discardableResult
    public mutating func append(_ chunk: String) -> GenshinReadinessState {
        transition(parser.append(chunk))
    }

    /// Flushes one final unterminated line when the cxstart log stream closes.
    @discardableResult
    public mutating func finish() -> GenshinReadinessState {
        transition(parser.finish())
    }

    /// Process observation is kept separate from trace parsing because a
    /// crashed Wine process may not emit LdrShutdownProcess before its log
    /// stream disappears.
    @discardableResult
    public mutating func processDidExit(pid: Int32) -> GenshinReadinessState {
        guard pid == targetPID else { return state }
        return transition([.processExited(pid: pid)])
    }

    @discardableResult
    public mutating func timeout() -> GenshinReadinessState {
        guard case .waiting = state else { return state }
        state = .failed(.timedOut)
        return state
    }

    /// Starts a new process instance. This explicit boundary makes a numeric
    /// PID reuse harmless, even when the operating system recycles the PID.
    public mutating func beginNewRun(targetPID: Int32) throws {
        try parser.reset(targetPID: targetPID)
        self.targetPID = targetPID
        state = .waiting
    }

    private mutating func transition(_ events: [CrossOverTraceEvent]) -> GenshinReadinessState {
        for event in events {
            switch event {
            case .genshinProcessStarted(let pid):
                // A new YuanShen launch is a new process instance even when
                // the OS has reused the previous numeric PID. The parser has
                // already reset its module ranges at this boundary.
                targetPID = pid
                state = .waiting
                continue
            default:
                break
            }

            guard case .waiting = state else { return state }
            switch event {
            case .threadNamed(let pid, .unityGfxDeviceWorker) where pid == targetPID:
                state = .ready
            case .mhypBaseAccessViolation(let pid, _, _) where pid == targetPID:
                state = .failed(.mhypBaseAccessViolation)
            case .processExited(let pid) where pid == targetPID:
                state = .failed(.processExited)
            case .lineLimitExceeded, .logLimitExceeded:
                state = .failed(.traceLimitExceeded)
            default:
                break
            }

            if case .waiting = state {
                continue
            }
            // A later process-start boundary can legitimately begin a new
            // attempt in the same cxstart trace, so keep scanning even after
            // an earlier attempt reached a terminal state.
        }
        return state
    }
}
