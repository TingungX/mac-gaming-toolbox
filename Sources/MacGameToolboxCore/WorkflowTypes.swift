import Foundation

/// The stable identity of one workflow run.
public typealias WorkflowRunID = UUID

/// The identifiers below are deliberately plain values.  They are persisted in
/// the journal and are also the values a future registry/recipe compiler will
/// exchange with the engine.
public typealias WorkflowID = String
public typealias WorkflowStepID = String

public struct WorkflowStepDefinition: Codable, Equatable, Hashable, Sendable {
    public let id: WorkflowStepID
    public let kind: String
    public let version: Int
    public let input: Data

    public init(id: WorkflowStepID, kind: String, version: Int = 1, input: Data = Data()) {
        self.id = id
        self.kind = kind
        self.version = version
        self.input = input
    }
}

/// A compiled, immutable plan.  The engine intentionally does not know where
/// this plan came from; built-in plans and future validated recipes use the
/// same execution path.
public struct CompiledWorkflow: Codable, Equatable, Sendable {
    public let id: WorkflowID
    public let revision: Int
    public let steps: [WorkflowStepDefinition]

    public init(id: WorkflowID, revision: Int = 1, steps: [WorkflowStepDefinition]) {
        self.id = id
        self.revision = revision
        self.steps = steps
    }
}

public typealias WorkflowPlan = CompiledWorkflow

public struct WorkflowStepContext: Sendable, Equatable {
    public let runID: WorkflowRunID
    public let workflowID: WorkflowID
    public let step: WorkflowStepDefinition

    public init(runID: WorkflowRunID, workflowID: WorkflowID, step: WorkflowStepDefinition) {
        self.runID = runID
        self.workflowID = workflowID
        self.step = step
    }
}

public enum WorkflowCompensationReason: String, Codable, Equatable, Sendable {
    case failure
    case cancellation
    case recovery
}

public struct WorkflowCompensationContext: Sendable, Equatable {
    public let runID: WorkflowRunID
    public let workflowID: WorkflowID
    public let step: WorkflowStepDefinition
    public let reason: WorkflowCompensationReason

    public init(
        runID: WorkflowRunID,
        workflowID: WorkflowID,
        step: WorkflowStepDefinition,
        reason: WorkflowCompensationReason
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.step = step
        self.reason = reason
    }
}

/// An opaque token returned by a side-effecting step.  The engine persists the
/// handle and passes it back to the same executor during compensation; it does
/// not inspect or manufacture root-owned snapshot data.
public struct WorkflowRecoveryHandle: Codable, Equatable, Hashable, Sendable {
    public let tokenID: UUID
    public let capabilityID: String
    public let capabilityVersion: Int

    public init(
        tokenID: UUID = UUID(),
        capabilityID: String,
        capabilityVersion: Int = 1
    ) {
        self.tokenID = tokenID
        self.capabilityID = capabilityID
        self.capabilityVersion = capabilityVersion
    }
}

public struct WorkflowStepExecution: Codable, Equatable, Sendable {
    public let output: Data?
    public let recoveryHandle: WorkflowRecoveryHandle?

    public init(output: Data? = nil, recoveryHandle: WorkflowRecoveryHandle? = nil) {
        self.output = output
        self.recoveryHandle = recoveryHandle
    }

    public static var completed: WorkflowStepExecution { WorkflowStepExecution() }
}

public typealias WorkflowStepResult = WorkflowStepExecution

public struct WorkflowStepExecutionError: Error, LocalizedError, Codable, Equatable, Sendable {
    public let message: String
    public let recoveryHandle: WorkflowRecoveryHandle?

    public init(message: String, recoveryHandle: WorkflowRecoveryHandle? = nil) {
        self.message = message
        self.recoveryHandle = recoveryHandle
    }

    public var errorDescription: String? { message }
}

/// A step is trusted application code registered at the App composition root.
/// Recipes can select a registered step, but cannot provide an implementation.
public protocol WorkflowStepExecuting: Sendable {
    func prepare(context: WorkflowStepContext) async throws
    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution
    func compensate(
        _ recoveryHandle: WorkflowRecoveryHandle,
        context: WorkflowCompensationContext
    ) async throws
    /// Compensates a step that started executing but never journaled a handle.
    /// Side-effecting steps must undo helper-owned state here; default is a no-op.
    func compensateInFlight(context: WorkflowCompensationContext) async throws
}

public extension WorkflowStepExecuting {
    func prepare(context: WorkflowStepContext) async throws {}
    func compensate(
        _ recoveryHandle: WorkflowRecoveryHandle,
        context: WorkflowCompensationContext
    ) async throws {}
    func compensateInFlight(context: WorkflowCompensationContext) async throws {}
}

/// The engine depends on this minimal resolver rather than a concrete global
/// registry.  The App-side immutable WorkflowStepRegistry can conform to this
/// protocol at its composition root.
public protocol WorkflowStepResolving: Sendable {
    func resolve(step: WorkflowStepDefinition) async throws -> any WorkflowStepExecuting
}

public struct ClosureWorkflowStepResolver: WorkflowStepResolving, Sendable {
    private let body: @Sendable (WorkflowStepDefinition) throws -> any WorkflowStepExecuting

    public init(
        _ body: @escaping @Sendable (WorkflowStepDefinition) throws -> any WorkflowStepExecuting
    ) {
        self.body = body
    }

    public func resolve(step: WorkflowStepDefinition) async throws -> any WorkflowStepExecuting {
        try body(step)
    }
}

public enum WorkflowRunStatus: String, Codable, Equatable, Sendable {
    case idle
    case validating
    case preparing
    case running
    case compensating
    case succeeded
    case failed
    case cancelled
    case recoveryRequired
    case recovered
    case recoveryFailed

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .recovered:
            true
        case .idle, .validating, .preparing, .running, .compensating, .recoveryRequired, .recoveryFailed:
            false
        }
    }
}

public struct WorkflowRunSnapshot: Codable, Equatable, Sendable {
    public let runID: WorkflowRunID
    public let workflowID: WorkflowID
    public let startedAt: Date
    public var updatedAt: Date
    public var status: WorkflowRunStatus
    public var currentStepID: WorkflowStepID?
    public var completedStepIDs: [WorkflowStepID]
    public var errorDescription: String?

    public init(
        runID: WorkflowRunID,
        workflowID: WorkflowID,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        status: WorkflowRunStatus = .idle,
        currentStepID: WorkflowStepID? = nil,
        completedStepIDs: [WorkflowStepID] = [],
        errorDescription: String? = nil
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.status = status
        self.currentStepID = currentStepID
        self.completedStepIDs = completedStepIDs
        self.errorDescription = errorDescription
    }
}

public struct WorkflowCompensationFailure: Codable, Equatable, Sendable {
    public let stepID: WorkflowStepID
    public let message: String

    public init(stepID: WorkflowStepID, message: String) {
        self.stepID = stepID
        self.message = message
    }
}

public struct WorkflowRunResult: Codable, Equatable, Sendable {
    public let runID: WorkflowRunID
    public let workflowID: WorkflowID
    public let status: WorkflowRunStatus
    public let completedStepIDs: [WorkflowStepID]
    public let errorDescription: String?
    public let compensationFailures: [WorkflowCompensationFailure]

    public init(
        runID: WorkflowRunID,
        workflowID: WorkflowID,
        status: WorkflowRunStatus,
        completedStepIDs: [WorkflowStepID] = [],
        errorDescription: String? = nil,
        compensationFailures: [WorkflowCompensationFailure] = []
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.status = status
        self.completedStepIDs = completedStepIDs
        self.errorDescription = errorDescription
        self.compensationFailures = compensationFailures
    }

    public var succeeded: Bool { status == .succeeded }
}

public enum WorkflowEngineError: Error, LocalizedError, Equatable, Sendable {
    case runAlreadyActive(WorkflowRunID)
    case invalidWorkflow(String)
    case recoveryUnavailable(WorkflowRunID, String)

    public var errorDescription: String? {
        switch self {
        case .runAlreadyActive(let runID):
            return "A workflow run is already active: \(runID.uuidString)"
        case .invalidWorkflow(let message):
            return "Invalid workflow: \(message)"
        case .recoveryUnavailable(let runID, let message):
            return "Unable to recover workflow \(runID.uuidString): \(message)"
        }
    }
}
