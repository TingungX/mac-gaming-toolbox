import Foundation

/// Shared, run-scoped claims on the machine-wide Game Mode policy.
/// The first acquirer snapshots the previous policy and forces `on`; the last
/// releaser restores that snapshot. This is a simple ledger, not a generic
/// resource pool.
public actor GameModeClaimLedger {
    private let service: GameModeService
    private var baseline: GameModePolicy?
    private var holders: Set<WorkflowRunID> = []

    public init(service: GameModeService) {
        self.service = service
    }

    public func holderCount() -> Int { holders.count }

    public func baselinePolicy() -> GameModePolicy? { baseline }

    public func contains(_ runID: WorkflowRunID) -> Bool {
        holders.contains(runID)
    }

    public func acquire(runID: WorkflowRunID) async throws {
        if holders.contains(runID) { return }
        if holders.isEmpty {
            let status = try await service.status()
            baseline = status.policy
            if status.policy != .on {
                try await service.setPolicy(.on)
            }
        }
        holders.insert(runID)
    }

    public func release(runID: WorkflowRunID) async throws {
        guard holders.remove(runID) != nil else { return }
        guard holders.isEmpty else { return }
        let restore = baseline ?? .automatic
        baseline = nil
        try await service.setPolicy(restore)
    }

    /// Reattaches a holder after App relaunch without changing the current
    /// system policy. `baseline` must be the policy captured before this run
    /// first acquired the claim.
    public func restoreHolder(runID: WorkflowRunID, baseline: GameModePolicy) {
        if holders.isEmpty {
            self.baseline = baseline
        }
        holders.insert(runID)
    }
}
