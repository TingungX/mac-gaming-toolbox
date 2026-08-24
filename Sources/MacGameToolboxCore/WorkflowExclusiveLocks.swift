import Foundation

/// An exclusive lock key owned by a workflow run. Keys may name global
/// machine state (network isolation) or an installation-scoped resource
/// (a CrossOver bottle). This table is not a resource-implementation pool;
/// it only records which run currently holds a key.
public struct WorkflowExclusiveLockKey: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let networkGlobalIsolation = WorkflowExclusiveLockKey(rawValue: "network.globalIsolation")

    public static func processSession(bottle: String) -> WorkflowExclusiveLockKey {
        WorkflowExclusiveLockKey(rawValue: "process.session.crossover.\(bottle)")
    }
}

public struct WorkflowExclusiveLockHolder: Equatable, Sendable {
    public let runID: WorkflowRunID
    public let workflowID: WorkflowID
    public let title: String

    public init(runID: WorkflowRunID, workflowID: WorkflowID, title: String) {
        self.runID = runID
        self.workflowID = workflowID
        self.title = title
    }
}

public struct WorkflowResourceConflict: Equatable, Sendable, Identifiable {
    public var id: String { lockKey.rawValue }
    public let lockKey: WorkflowExclusiveLockKey
    public let holder: WorkflowExclusiveLockHolder

    public init(lockKey: WorkflowExclusiveLockKey, holder: WorkflowExclusiveLockHolder) {
        self.lockKey = lockKey
        self.holder = holder
    }
}

public enum WorkflowExclusiveLockError: Error, Equatable, Sendable, LocalizedError {
    case heldByOther(WorkflowExclusiveLockHolder)

    public var errorDescription: String? {
        switch self {
        case .heldByOther(let holder):
            return "Resource is held by workflow \(holder.workflowID) run \(holder.runID.uuidString)"
        }
    }
}

/// In-process exclusive lock table. Shared claims such as Game Mode do not
/// belong here; only keys that cannot be held by two runs at once.
public actor WorkflowExclusiveLockTable {
    private var holders: [WorkflowExclusiveLockKey: WorkflowExclusiveLockHolder] = [:]

    public init() {}

    public func holder(for key: WorkflowExclusiveLockKey) -> WorkflowExclusiveLockHolder? {
        holders[key]
    }

    public func conflicts(for keys: [WorkflowExclusiveLockKey]) -> [WorkflowResourceConflict] {
        keys.compactMap { key in
            holders[key].map { WorkflowResourceConflict(lockKey: key, holder: $0) }
        }
    }

    public func acquire(key: WorkflowExclusiveLockKey, holder: WorkflowExclusiveLockHolder) throws {
        if let existing = holders[key], existing.runID != holder.runID {
            throw WorkflowExclusiveLockError.heldByOther(existing)
        }
        holders[key] = holder
    }

    public func release(key: WorkflowExclusiveLockKey, runID: WorkflowRunID) {
        guard holders[key]?.runID == runID else { return }
        holders[key] = nil
    }

    public func releaseAll(for runID: WorkflowRunID) {
        holders = holders.filter { $0.value.runID != runID }
    }

    public func heldKeys(for runID: WorkflowRunID) -> [WorkflowExclusiveLockKey] {
        holders.compactMap { $0.value.runID == runID ? $0.key : nil }
    }
}
