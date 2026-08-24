import Foundation

public actor WorkflowEngine {
    private let resolver: any WorkflowStepResolving
    private let journal: any WorkflowJournal

    private var activeTasks: [WorkflowRunID: Task<WorkflowRunResult, Never>] = [:]
    private var snapshots: [WorkflowRunID: WorkflowRunSnapshot] = [:]

    private struct CompensationEntry: Sendable {
        let definition: WorkflowStepDefinition
        let executor: any WorkflowStepExecuting
        let recoveryHandle: WorkflowRecoveryHandle?
    }

    private struct StepFailure: Error, Sendable {
        let stepID: WorkflowStepID?
        let message: String
        let recoveryHandle: WorkflowRecoveryHandle?
        let wasCancellation: Bool
    }

    public init(resolver: any WorkflowStepResolving, journal: any WorkflowJournal = InMemoryWorkflowJournal()) {
        self.resolver = resolver
        self.journal = journal
    }

    public init(registry: any WorkflowStepResolving, journal: any WorkflowJournal = InMemoryWorkflowJournal()) {
        self.init(resolver: registry, journal: journal)
    }

    public func activeRunIDs() -> Set<WorkflowRunID> { Set(activeTasks.keys) }

    public func activeRunID() -> WorkflowRunID? {
        activeTasks.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    public func snapshot(for runID: WorkflowRunID) -> WorkflowRunSnapshot? {
        snapshots[runID]
    }

    /// Cancels one run. Cancellation is cooperative; once requested,
    /// the engine still runs the reverse compensation stack before returning.
    @discardableResult
    public func cancel(runID: WorkflowRunID) -> Bool {
        guard let task = activeTasks[runID] else { return false }
        task.cancel()
        return true
    }

    @discardableResult
    public func cancelActiveRun() -> Bool {
        let identifiers = Array(activeTasks.keys)
        guard !identifiers.isEmpty else { return false }
        for runID in identifiers {
            activeTasks[runID]?.cancel()
        }
        return true
    }

    public func run(_ workflow: CompiledWorkflow, runID: WorkflowRunID = UUID()) async throws -> WorkflowRunResult {
        try Self.validate(workflow)
        snapshots[runID] = WorkflowRunSnapshot(runID: runID, workflowID: workflow.id)
        return try await track(runID: runID) {
            await self.execute(workflow: workflow, runID: runID)
        }
    }

    public func start(_ workflow: CompiledWorkflow, runID: WorkflowRunID = UUID()) async throws -> WorkflowRunResult {
        try await run(workflow, runID: runID)
    }

    /// Reconstructs an incomplete run from a durable journal. Holding steps
    /// resume; every other incomplete run compensates in reverse order.
    public func recover(
        _ workflow: CompiledWorkflow,
        runID: WorkflowRunID
    ) async throws -> WorkflowRunResult {
        try Self.validate(workflow)
        let events = try await journal.events(for: runID)
        guard !events.isEmpty else {
            throw WorkflowEngineError.recoveryUnavailable(runID, "journal has no events for this run")
        }
        guard events.allSatisfy({ $0.workflowID == workflow.id }) else {
            throw WorkflowEngineError.recoveryUnavailable(runID, "workflow identity does not match the journal")
        }

        return try await track(runID: runID) {
            switch WorkflowRecoveryPlanner.action(for: events, workflow: workflow) {
            case .resume(let stepID):
                await self.executeResume(
                    workflow: workflow,
                    runID: runID,
                    events: events,
                    fromStepID: stepID
                )
            case .compensate:
                await self.executeRecovery(workflow: workflow, runID: runID, events: events)
            }
        }
    }

    private func track(
        runID: WorkflowRunID,
        operation: @escaping @Sendable () async -> WorkflowRunResult
    ) async throws -> WorkflowRunResult {
        guard activeTasks[runID] == nil else {
            throw WorkflowEngineError.runAlreadyActive(runID)
        }

        let task = Task {
            await operation()
        }
        activeTasks[runID] = task
        if Task.isCancelled {
            task.cancel()
        }

        let result = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })

        activeTasks[runID] = nil
        return result
    }

    private static func validate(_ workflow: CompiledWorkflow) throws {
        guard !workflow.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowEngineError.invalidWorkflow("workflow id is empty")
        }
        guard workflow.revision > 0 else {
            throw WorkflowEngineError.invalidWorkflow("revision must be positive")
        }

        var seen = Set<WorkflowStepID>()
        for step in workflow.steps {
            guard !step.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowEngineError.invalidWorkflow("step id is empty")
            }
            guard seen.insert(step.id).inserted else {
                throw WorkflowEngineError.invalidWorkflow("duplicate step id: \(step.id)")
            }
            guard !step.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowEngineError.invalidWorkflow("step \(step.id) has an empty kind")
            }
            guard step.version > 0 else {
                throw WorkflowEngineError.invalidWorkflow("step \(step.id) has an invalid version")
            }
        }
    }

    private func execute(workflow: CompiledWorkflow, runID: WorkflowRunID) async -> WorkflowRunResult {
        var snapshot = snapshots[runID] ?? WorkflowRunSnapshot(runID: runID, workflowID: workflow.id)
        let compensationStack: [CompensationEntry] = []
        var failureDescription: String?
        var wasCancelled = false

        do {
            snapshot = try await record(
                snapshot,
                kind: .runStarted,
                status: .validating
            )

            var resolved: [(WorkflowStepDefinition, any WorkflowStepExecuting)] = []
            for step in workflow.steps {
                try Task.checkCancellation()
                do {
                    let executor = try await resolver.resolve(step: step)
                    resolved.append((step, executor))
                } catch {
                    throw StepFailure(
                        stepID: step.id,
                        message: "Unable to resolve step \(step.id): \(Self.describe(error))",
                        recoveryHandle: nil,
                        wasCancellation: error is CancellationError || Task.isCancelled
                    )
                }
            }

            snapshot = try await record(
                snapshot,
                kind: .stateChanged,
                status: .preparing
            )

            return await performSteps(
                resolved: resolved,
                workflow: workflow,
                runID: runID,
                snapshot: snapshot,
                startIndex: 0,
                compensationStack: [],
                completedStepIDs: []
            )
        } catch is CancellationError {
            wasCancelled = true
        } catch let stepFailure as StepFailure {
            wasCancelled = stepFailure.wasCancellation
            failureDescription = stepFailure.message
        } catch {
            wasCancelled = Task.isCancelled
            failureDescription = Self.describe(error)
        }

        var compensationFailures: [WorkflowCompensationFailure] = []
        do {
            snapshot = try await record(
                snapshot,
                kind: .stateChanged,
                status: .compensating
            )
        } catch let journalError {
            compensationFailures.append(
                WorkflowCompensationFailure(stepID: "__journal__", message: Self.describe(journalError))
            )
        }

        compensationFailures.append(contentsOf: await compensate(
            stack: compensationStack,
            runID: runID,
            workflowID: workflow.id,
            reason: wasCancelled ? .cancellation : .failure
        ))

        let requestedStatus: WorkflowRunStatus
        if !compensationFailures.isEmpty {
            requestedStatus = .recoveryFailed
        } else if wasCancelled {
            requestedStatus = .cancelled
        } else {
            requestedStatus = .failed
        }

        let combinedError: String? = {
            let compensationText = compensationFailures.map(\.message).joined(separator: "; ")
            switch (failureDescription, compensationText.isEmpty) {
            case (nil, true): return nil
            case (let description?, true): return description
            case (nil, false): return "Compensation failed: \(compensationText)"
            case (let description?, false): return "\(description); compensation failed: \(compensationText)"
            }
        }()

        snapshot.errorDescription = combinedError
        var finalStatus = requestedStatus
        do {
            snapshot = try await record(
                snapshot,
                kind: .runFinished,
                status: requestedStatus,
                errorDescription: combinedError
            )
        } catch let journalError {
            compensationFailures.append(
                WorkflowCompensationFailure(stepID: "__journal__", message: Self.describe(journalError))
            )
            finalStatus = .recoveryFailed
            let journalMessage = "Final journal failed: \(Self.describe(journalError))"
            snapshot.errorDescription = combinedError.map { "\($0); \(journalMessage)" } ?? journalMessage
        }

        // `record` updates the published snapshot before attempting the
        // append. If the terminal append itself failed, publish the stronger
        // recovery-failed state so callers cannot observe a successful
        // terminal status that was never durably recorded.
        if snapshot.status != finalStatus {
            snapshot.status = finalStatus
            snapshot.updatedAt = Date()
            snapshots[runID] = snapshot
        }

        return WorkflowRunResult(
            runID: runID,
            workflowID: workflow.id,
            status: finalStatus,
            completedStepIDs: snapshot.completedStepIDs,
            errorDescription: snapshot.errorDescription,
            compensationFailures: compensationFailures
        )
    }

    private func executeResume(
        workflow: CompiledWorkflow,
        runID: WorkflowRunID,
        events: [WorkflowJournalEvent],
        fromStepID: WorkflowStepID
    ) async -> WorkflowRunResult {
        guard let startIndex = workflow.steps.firstIndex(where: { $0.id == fromStepID }) else {
            return await executeRecovery(workflow: workflow, runID: runID, events: events)
        }

        var resolved: [(WorkflowStepDefinition, any WorkflowStepExecuting)] = []
        var resolveFailures: [WorkflowCompensationFailure] = []
        for step in workflow.steps {
            do {
                resolved.append((step, try await resolver.resolve(step: step)))
            } catch {
                resolveFailures.append(WorkflowCompensationFailure(
                    stepID: step.id,
                    message: "Unable to resolve recovery step: \(Self.describe(error))"
                ))
            }
        }
        if !resolveFailures.isEmpty {
            return await executeRecovery(workflow: workflow, runID: runID, events: events)
        }

        let executorByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.0.id, $0.1) })
        var compensationStack: [CompensationEntry] = []
        for event in events where event.kind == .stepSucceeded {
            guard let stepID = event.stepID,
                  let definition = workflow.steps.first(where: { $0.id == stepID }),
                  let executor = executorByID[stepID],
                  let handle = event.recoveryHandle else { continue }
            compensationStack.removeAll { $0.recoveryHandle?.tokenID == handle.tokenID }
            compensationStack.append(CompensationEntry(
                definition: definition,
                executor: executor,
                recoveryHandle: handle
            ))
        }

        let completedStepIDs = Array(workflow.steps.prefix(startIndex).map(\.id))
        let snapshot = WorkflowRunSnapshot(
            runID: runID,
            workflowID: workflow.id,
            status: .running,
            currentStepID: fromStepID,
            completedStepIDs: completedStepIDs
        )
        snapshots[runID] = snapshot
        return await performSteps(
            resolved: resolved,
            workflow: workflow,
            runID: runID,
            snapshot: snapshot,
            startIndex: startIndex,
            compensationStack: compensationStack,
            completedStepIDs: completedStepIDs
        )
    }

    private func performSteps(
        resolved: [(WorkflowStepDefinition, any WorkflowStepExecuting)],
        workflow: CompiledWorkflow,
        runID: WorkflowRunID,
        snapshot initialSnapshot: WorkflowRunSnapshot,
        startIndex: Int,
        compensationStack initialStack: [CompensationEntry],
        completedStepIDs: [WorkflowStepID]
    ) async -> WorkflowRunResult {
        var snapshot = initialSnapshot
        snapshot.completedStepIDs = completedStepIDs
        var compensationStack = initialStack
        var failureDescription: String?
        var wasCancelled = false

        do {
            for index in startIndex..<resolved.count {
                let (definition, executor) = resolved[index]
                try Task.checkCancellation()
                let context = WorkflowStepContext(runID: runID, workflowID: workflow.id, step: definition)

                snapshot = try await record(
                    snapshot,
                    kind: .stepPreparing,
                    status: .preparing,
                    stepID: definition.id
                )

                do {
                    try await executor.prepare(context: context)
                } catch {
                    let cancelled = error is CancellationError || Task.isCancelled
                    do {
                        snapshot = try await record(
                            snapshot,
                            kind: .stepFailed,
                            status: .preparing,
                            stepID: definition.id,
                            errorDescription: Self.describe(error)
                        )
                    } catch let journalError {
                        throw StepFailure(
                            stepID: definition.id,
                            message: "Step preparation failed: \(Self.describe(error)); journal failed: \(Self.describe(journalError))",
                            recoveryHandle: nil,
                            wasCancellation: cancelled
                        )
                    }
                    if cancelled { throw CancellationError() }
                    throw StepFailure(
                        stepID: definition.id,
                        message: "Step preparation failed: \(Self.describe(error))",
                        recoveryHandle: nil,
                        wasCancellation: false
                    )
                }

                snapshot = try await record(
                    snapshot,
                    kind: .stepPrepared,
                    status: .preparing,
                    stepID: definition.id
                )

                try Task.checkCancellation()
                snapshot = try await record(
                    snapshot,
                    kind: .stepStarted,
                    status: .running,
                    stepID: definition.id
                )

                let outcome: WorkflowStepExecution
                do {
                    outcome = try await executor.execute(context: context)
                } catch {
                    let stepError = error as? WorkflowStepExecutionError
                    let handle = stepError?.recoveryHandle
                    compensationStack.append(
                        CompensationEntry(definition: definition, executor: executor, recoveryHandle: handle)
                    )
                    let cancelled = error is CancellationError || Task.isCancelled
                    do {
                        snapshot = try await record(
                            snapshot,
                            kind: .stepFailed,
                            status: .running,
                            stepID: definition.id,
                            recoveryHandle: handle,
                            errorDescription: Self.describe(error)
                        )
                    } catch let journalError {
                        throw StepFailure(
                            stepID: definition.id,
                            message: "Step execution failed: \(Self.describe(error)); journal failed: \(Self.describe(journalError))",
                            recoveryHandle: handle,
                            wasCancellation: cancelled
                        )
                    }
                    if cancelled { throw CancellationError() }
                    throw StepFailure(
                        stepID: definition.id,
                        message: "Step execution failed: \(Self.describe(error))",
                        recoveryHandle: handle,
                        wasCancellation: false
                    )
                }

                if let handle = outcome.recoveryHandle {
                    compensationStack.append(
                        CompensationEntry(definition: definition, executor: executor, recoveryHandle: handle)
                    )
                }
                snapshot.completedStepIDs.append(definition.id)
                snapshot = try await record(
                    snapshot,
                    kind: .stepSucceeded,
                    status: .running,
                    stepID: definition.id,
                    recoveryHandle: outcome.recoveryHandle
                )
            }

            snapshot = try await record(
                snapshot,
                kind: .runFinished,
                status: .succeeded
            )
            return WorkflowRunResult(
                runID: runID,
                workflowID: workflow.id,
                status: .succeeded,
                completedStepIDs: snapshot.completedStepIDs
            )
        } catch is CancellationError {
            wasCancelled = true
        } catch let stepFailure as StepFailure {
            wasCancelled = stepFailure.wasCancellation
            failureDescription = stepFailure.message
        } catch {
            wasCancelled = Task.isCancelled
            failureDescription = Self.describe(error)
        }

        var compensationFailures: [WorkflowCompensationFailure] = []
        do {
            snapshot = try await record(
                snapshot,
                kind: .stateChanged,
                status: .compensating
            )
        } catch let journalError {
            compensationFailures.append(
                WorkflowCompensationFailure(stepID: "__journal__", message: Self.describe(journalError))
            )
        }

        compensationFailures.append(contentsOf: await compensate(
            stack: compensationStack,
            runID: runID,
            workflowID: workflow.id,
            reason: wasCancelled ? .cancellation : .failure
        ))

        let requestedStatus: WorkflowRunStatus
        if !compensationFailures.isEmpty {
            requestedStatus = .recoveryFailed
        } else if wasCancelled {
            requestedStatus = .cancelled
        } else {
            requestedStatus = .failed
        }

        let combinedError: String? = {
            let compensationText = compensationFailures.map(\.message).joined(separator: "; ")
            switch (failureDescription, compensationText.isEmpty) {
            case (nil, true): return nil
            case (let description?, true): return description
            case (nil, false): return "Compensation failed: \(compensationText)"
            case (let description?, false): return "\(description); compensation failed: \(compensationText)"
            }
        }()

        snapshot.errorDescription = combinedError
        var finalStatus = requestedStatus
        do {
            snapshot = try await record(
                snapshot,
                kind: .runFinished,
                status: requestedStatus,
                errorDescription: combinedError
            )
        } catch let journalError {
            compensationFailures.append(
                WorkflowCompensationFailure(stepID: "__journal__", message: Self.describe(journalError))
            )
            finalStatus = .recoveryFailed
            let journalMessage = "Final journal failed: \(Self.describe(journalError))"
            snapshot.errorDescription = combinedError.map { "\($0); \(journalMessage)" } ?? journalMessage
        }

        if snapshot.status != finalStatus {
            snapshot.status = finalStatus
            snapshot.updatedAt = Date()
            snapshots[runID] = snapshot
        }

        return WorkflowRunResult(
            runID: runID,
            workflowID: workflow.id,
            status: finalStatus,
            completedStepIDs: snapshot.completedStepIDs,
            errorDescription: snapshot.errorDescription,
            compensationFailures: compensationFailures
        )
    }

    private func executeRecovery(
        workflow: CompiledWorkflow,
        runID: WorkflowRunID,
        events: [WorkflowJournalEvent]
    ) async -> WorkflowRunResult {
        let definitionByID = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
        let completedStepIDs = events
            .filter { $0.kind == .stepSucceeded }
            .compactMap(\.stepID)

        var outstanding: [(stepID: WorkflowStepID, handle: WorkflowRecoveryHandle?)] = []
        for event in events {
            switch event.kind {
            case .stepStarted:
                guard let stepID = event.stepID else { continue }
                outstanding.removeAll { $0.stepID == stepID && $0.handle == nil }
                outstanding.append((stepID, nil))
            case .stepSucceeded, .stepFailed:
                guard let stepID = event.stepID else { continue }
                outstanding.removeAll { $0.stepID == stepID && $0.handle == nil }
                if let handle = event.recoveryHandle {
                    outstanding.removeAll { $0.handle?.tokenID == handle.tokenID }
                    outstanding.append((stepID, handle))
                } else if event.kind == .stepFailed {
                    outstanding.append((stepID, nil))
                }
            case .compensationSucceeded:
                if let handle = event.recoveryHandle {
                    outstanding.removeAll { $0.handle?.tokenID == handle.tokenID }
                }
                if let stepID = event.stepID {
                    outstanding.removeAll { $0.stepID == stepID && $0.handle == nil }
                }
            default:
                continue
            }
        }

        var stack: [CompensationEntry] = []
        var failures: [WorkflowCompensationFailure] = []
        for entry in outstanding {
            guard let definition = definitionByID[entry.stepID] else {
                failures.append(WorkflowCompensationFailure(
                    stepID: entry.stepID,
                    message: "Recorded step is absent from the recovery workflow"
                ))
                continue
            }
            do {
                let executor = try await resolver.resolve(step: definition)
                stack.append(CompensationEntry(
                    definition: definition,
                    executor: executor,
                    recoveryHandle: entry.handle
                ))
            } catch {
                failures.append(WorkflowCompensationFailure(
                    stepID: entry.stepID,
                    message: "Unable to resolve recovery step: \(Self.describe(error))"
                ))
            }
        }

        var snapshot = WorkflowRunSnapshot(
            runID: runID,
            workflowID: workflow.id,
            status: .recoveryRequired,
            completedStepIDs: completedStepIDs
        )
        snapshots[runID] = snapshot
        do {
            snapshot = try await record(snapshot, kind: .stateChanged, status: .recoveryRequired)
            snapshot = try await record(snapshot, kind: .stateChanged, status: .compensating)
        } catch {
            failures.append(WorkflowCompensationFailure(
                stepID: "__journal__",
                message: Self.describe(error)
            ))
        }

        failures.append(contentsOf: await compensate(
            stack: stack,
            runID: runID,
            workflowID: workflow.id,
            reason: .recovery
        ))

        let requestedStatus: WorkflowRunStatus = failures.isEmpty ? .recovered : .recoveryFailed
        var finalStatus = requestedStatus
        let failureDescription = failures.isEmpty
            ? nil
            : failures.map { "\($0.stepID): \($0.message)" }.joined(separator: "; ")
        do {
            snapshot = try await record(
                snapshot,
                kind: .runFinished,
                status: requestedStatus,
                errorDescription: failureDescription
            )
        } catch {
            failures.append(WorkflowCompensationFailure(
                stepID: "__journal__",
                message: Self.describe(error)
            ))
            finalStatus = .recoveryFailed
            snapshot.status = .recoveryFailed
            snapshot.errorDescription = failures.map { "\($0.stepID): \($0.message)" }.joined(separator: "; ")
            snapshots[runID] = snapshot
        }

        return WorkflowRunResult(
            runID: runID,
            workflowID: workflow.id,
            status: finalStatus,
            completedStepIDs: completedStepIDs,
            errorDescription: snapshot.errorDescription,
            compensationFailures: failures
        )
    }

    private func record(
        _ snapshot: WorkflowRunSnapshot,
        kind: WorkflowJournalEventKind,
        status: WorkflowRunStatus,
        stepID: WorkflowStepID? = nil,
        recoveryHandle: WorkflowRecoveryHandle? = nil,
        errorDescription: String? = nil
    ) async throws -> WorkflowRunSnapshot {
        var next = snapshot
        next.status = status
        next.currentStepID = stepID
        next.errorDescription = errorDescription ?? snapshot.errorDescription
        next.updatedAt = Date()
        snapshots[next.runID] = next
        let event = WorkflowJournalEvent(
            runID: next.runID,
            workflowID: next.workflowID,
            kind: kind,
            status: status,
            stepID: stepID,
            recoveryHandle: recoveryHandle,
            errorDescription: errorDescription
        )
        try await journal.append(event)
        return next
    }

    private func compensate(
        stack: [CompensationEntry],
        runID: WorkflowRunID,
        workflowID: WorkflowID,
        reason: WorkflowCompensationReason
    ) async -> [WorkflowCompensationFailure] {
        var failures: [WorkflowCompensationFailure] = []
        for entry in stack.reversed() {
            let context = WorkflowCompensationContext(
                runID: runID,
                workflowID: workflowID,
                step: entry.definition,
                reason: reason
            )

            do {
                try await journal.append(WorkflowJournalEvent(
                    runID: runID,
                    workflowID: workflowID,
                    kind: .compensationStarted,
                    status: .compensating,
                    stepID: entry.definition.id,
                    recoveryHandle: entry.recoveryHandle
                ))
            } catch let error {
                failures.append(
                    WorkflowCompensationFailure(stepID: entry.definition.id, message: "Journal compensation start failed: \(Self.describe(error))")
                )
            }

            var compensationError: Error?
            do {
                if let handle = entry.recoveryHandle {
                    try await entry.executor.compensate(handle, context: context)
                } else {
                    try await entry.executor.compensateInFlight(context: context)
                }
            } catch let error {
                compensationError = error
                failures.append(
                    WorkflowCompensationFailure(stepID: entry.definition.id, message: Self.describe(error))
                )
            }

            let kind: WorkflowJournalEventKind = compensationError == nil ? .compensationSucceeded : .compensationFailed
            do {
                try await journal.append(WorkflowJournalEvent(
                    runID: runID,
                    workflowID: workflowID,
                    kind: kind,
                    status: .compensating,
                    stepID: entry.definition.id,
                    recoveryHandle: entry.recoveryHandle,
                    errorDescription: compensationError.map(Self.describe)
                ))
            } catch let error {
                failures.append(
                    WorkflowCompensationFailure(stepID: entry.definition.id, message: "Journal compensation result failed: \(Self.describe(error))")
                )
            }
        }
        return failures
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
