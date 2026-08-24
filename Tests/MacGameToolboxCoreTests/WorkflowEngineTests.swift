import Foundation
import Testing
@testable import MacGameToolboxCore

private actor WorkflowEventRecorder {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor WorkflowTestStep: WorkflowStepExecuting {
    let id: String
    let recorder: WorkflowEventRecorder
    let recoveryHandle: WorkflowRecoveryHandle?
    let executionFailure: WorkflowStepExecutionError?
    let compensationFailure: Error?
    let blocksUntilCancelled: Bool

    init(
        id: String,
        recorder: WorkflowEventRecorder = WorkflowEventRecorder(),
        recoveryHandle: WorkflowRecoveryHandle? = nil,
        executionFailure: WorkflowStepExecutionError? = nil,
        compensationFailure: Error? = nil,
        blocksUntilCancelled: Bool = false
    ) {
        self.id = id
        self.recorder = recorder
        self.recoveryHandle = recoveryHandle
        self.executionFailure = executionFailure
        self.compensationFailure = compensationFailure
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func prepare(context: WorkflowStepContext) async throws {
        await recorder.append("\(id).prepare")
    }

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        await recorder.append("\(id).execute")
        if blocksUntilCancelled {
            while true {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        if let executionFailure {
            throw executionFailure
        }
        return WorkflowStepExecution(recoveryHandle: recoveryHandle)
    }

    func compensate(
        _ recoveryHandle: WorkflowRecoveryHandle,
        context: WorkflowCompensationContext
    ) async throws {
        await recorder.append("\(id).compensate.\(context.reason.rawValue)")
        if let compensationFailure {
            throw compensationFailure
        }
    }
}

private struct WorkflowTestError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private func makeWorkflow(
    id: String = "test.workflow",
    stepIDs: [String]
) -> CompiledWorkflow {
    CompiledWorkflow(
        id: id,
        steps: stepIDs.map { WorkflowStepDefinition(id: $0, kind: "test.\($0)") }
    )
}

private func makeEngine(
    steps: [String: any WorkflowStepExecuting],
    journal: InMemoryWorkflowJournal
) -> WorkflowEngine {
    let resolver = ClosureWorkflowStepResolver { definition in
        guard let step = steps[definition.id] else {
            throw WorkflowTestError(message: "missing step \(definition.id)")
        }
        return step
    }
    return WorkflowEngine(resolver: resolver, journal: journal)
}

private func waitForActiveRun(_ engine: WorkflowEngine) async throws -> WorkflowRunID {
    for _ in 0..<100 {
        if let runID = await engine.activeRunID() {
            return runID
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw WorkflowTestError(message: "workflow did not become active")
}

@Test func workflowEngineRunsSequentiallyAndPersistsRecoveryHandle() async throws {
    let journal = InMemoryWorkflowJournal()
    let handle = WorkflowRecoveryHandle(capabilityID: "network.isolation", capabilityVersion: 1)
    let first = WorkflowTestStep(id: "first", recoveryHandle: handle)
    let second = WorkflowTestStep(id: "second")
    let engine = makeEngine(steps: ["first": first, "second": second], journal: journal)
    let runID = UUID()

    let result = try await engine.run(makeWorkflow(stepIDs: ["first", "second"]), runID: runID)

    #expect(result.status == .succeeded)
    #expect(result.completedStepIDs == ["first", "second"])
    #expect(result.compensationFailures.isEmpty)

    let events = try await journal.events(for: runID)
    #expect(events.contains { $0.kind == .stepSucceeded && $0.stepID == "first" && $0.recoveryHandle == handle })
    #expect(events.last?.kind == .runFinished)
    #expect(events.last?.status == .succeeded)
    #expect(try await journal.incompleteRunIDs().isEmpty)

    let firstEvents = await first.recorder.events
    let secondEvents = await second.recorder.events
    #expect(firstEvents == ["first.prepare", "first.execute"])
    #expect(secondEvents == ["second.prepare", "second.execute"])
}

@Test func workflowEngineCompensatesCompletedStepsInReverseOrderAfterFailure() async throws {
    let journal = InMemoryWorkflowJournal()
    let firstRecorder = WorkflowEventRecorder()
    let secondRecorder = WorkflowEventRecorder()
    let first = WorkflowTestStep(
        id: "first",
        recorder: firstRecorder,
        recoveryHandle: WorkflowRecoveryHandle(capabilityID: "first.sideEffect")
    )
    let second = WorkflowTestStep(
        id: "second",
        recorder: secondRecorder,
        recoveryHandle: WorkflowRecoveryHandle(capabilityID: "second.sideEffect")
    )
    let failing = WorkflowTestStep(
        id: "failing",
        executionFailure: WorkflowStepExecutionError(message: "expected failure")
    )
    let engine = makeEngine(
        steps: ["first": first, "second": second, "failing": failing],
        journal: journal
    )
    let runID = UUID()

    let result = try await engine.run(makeWorkflow(stepIDs: ["first", "second", "failing"]), runID: runID)

    #expect(result.status == .failed)
    #expect(result.completedStepIDs == ["first", "second"])
    #expect(result.compensationFailures.isEmpty)
    #expect(await firstRecorder.events == ["first.prepare", "first.execute", "first.compensate.failure"])
    #expect(await secondRecorder.events == ["second.prepare", "second.execute", "second.compensate.failure"])

    let compensationSteps = try await journal.events(for: runID)
        .filter { $0.kind == .compensationStarted }
        .compactMap(\.stepID)
    #expect(compensationSteps == ["second", "first"])
}

@Test func workflowEngineCancellationCompensatesAndReportsCancelled() async throws {
    let journal = InMemoryWorkflowJournal()
    let firstRecorder = WorkflowEventRecorder()
    let first = WorkflowTestStep(
        id: "first",
        recorder: firstRecorder,
        recoveryHandle: WorkflowRecoveryHandle(capabilityID: "first.sideEffect")
    )
    let blocking = WorkflowTestStep(id: "blocking", blocksUntilCancelled: true)
    let engine = makeEngine(steps: ["first": first, "blocking": blocking], journal: journal)
    let task = Task {
        try await engine.run(makeWorkflow(stepIDs: ["first", "blocking"]))
    }

    let runID = try await waitForActiveRun(engine)
    for _ in 0..<100 {
        if await firstRecorder.events.contains("first.execute") { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(await engine.cancel(runID: runID))
    let result = try await task.value

    #expect(result.status == .cancelled)
    #expect(result.compensationFailures.isEmpty)
    #expect(await firstRecorder.events.last == "first.compensate.cancellation")
    let events = try await journal.events(for: runID)
    #expect(events.contains { $0.kind == .runFinished && $0.status == .cancelled })
}

@Test func failedCompensationProducesRecoveryFailedAndContinuesStack() async throws {
    let journal = InMemoryWorkflowJournal()
    let firstRecorder = WorkflowEventRecorder()
    let secondRecorder = WorkflowEventRecorder()
    let first = WorkflowTestStep(
        id: "first",
        recorder: firstRecorder,
        recoveryHandle: WorkflowRecoveryHandle(capabilityID: "first.sideEffect")
    )
    let second = WorkflowTestStep(
        id: "second",
        recorder: secondRecorder,
        recoveryHandle: WorkflowRecoveryHandle(capabilityID: "second.sideEffect"),
        compensationFailure: WorkflowTestError(message: "cannot restore second")
    )
    let failing = WorkflowTestStep(
        id: "failing",
        executionFailure: WorkflowStepExecutionError(message: "expected failure")
    )
    let engine = makeEngine(
        steps: ["first": first, "second": second, "failing": failing],
        journal: journal
    )

    let result = try await engine.run(makeWorkflow(stepIDs: ["first", "second", "failing"]))

    #expect(result.status == .recoveryFailed)
    #expect(result.compensationFailures.count == 1)
    #expect(result.compensationFailures.first?.stepID == "second")
    #expect(await firstRecorder.events.last == "first.compensate.failure")
    #expect(await secondRecorder.events.last == "second.compensate.failure")
}

@Test func workflowJournalTracksIncompleteRunsAndIsCodable() async throws {
    let journal = InMemoryWorkflowJournal()
    let runID = UUID()
    let handle = WorkflowRecoveryHandle(capabilityID: "network.isolation", capabilityVersion: 2)
    let event = WorkflowJournalEvent(
        runID: runID,
        workflowID: "test.workflow",
        kind: .stepSucceeded,
        status: .running,
        stepID: "isolate",
        recoveryHandle: handle
    )

    try await journal.append(event)
    #expect(try await journal.incompleteRunIDs() == [runID])

    let stored = try await journal.events(for: runID).first
    #expect(stored?.sequence == 1)
    #expect(stored?.recoveryHandle == handle)
    let data = try JSONEncoder().encode(stored)
    let decoded = try JSONDecoder().decode(WorkflowJournalEvent?.self, from: data)
    #expect(decoded == stored)

    try await journal.append(WorkflowJournalEvent(
        runID: runID,
        workflowID: "test.workflow",
        kind: .runFinished,
        status: .recovered
    ))
    #expect(try await journal.incompleteRunIDs().isEmpty)
}

@Test func workflowEngineRejectsDuplicateStepIDsBeforeStartingRun() async throws {
    let journal = InMemoryWorkflowJournal()
    let engine = makeEngine(steps: [:], journal: journal)
    let workflow = CompiledWorkflow(
        id: "test.workflow",
        steps: [
            WorkflowStepDefinition(id: "duplicate", kind: "test.one"),
            WorkflowStepDefinition(id: "duplicate", kind: "test.two")
        ]
    )

    do {
        _ = try await engine.run(workflow)
        Issue.record("Duplicate step IDs should be rejected before a run starts")
    } catch let error as WorkflowEngineError {
        #expect(error == .invalidWorkflow("duplicate step id: duplicate"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func workflowEngineRecoversOutstandingJournaledCompensation() async throws {
    let journal = InMemoryWorkflowJournal()
    let runID = UUID()
    let handle = WorkflowRecoveryHandle(capabilityID: "network.globalIsolation")
    try await journal.append(WorkflowJournalEvent(
        runID: runID,
        workflowID: "test.workflow",
        kind: .stepSucceeded,
        status: .running,
        stepID: "isolate",
        recoveryHandle: handle
    ))

    let recorder = WorkflowEventRecorder()
    let isolate = WorkflowTestStep(id: "isolate", recorder: recorder)
    let engine = makeEngine(steps: ["isolate": isolate], journal: journal)
    let result = try await engine.recover(makeWorkflow(stepIDs: ["isolate"]), runID: runID)

    #expect(result.status == .recovered)
    #expect(await recorder.events == ["isolate.compensate.recovery"])
    #expect(try await journal.incompleteRunIDs().isEmpty)
}

@Test func fileWorkflowJournalPersistsIncompleteRunAtomically() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workflow-journal.json")
    let runID = UUID()

    let writer = try FileWorkflowJournal(url: url)
    try await writer.append(WorkflowJournalEvent(
        runID: runID,
        workflowID: "test.workflow",
        kind: .stepSucceeded,
        status: .running,
        stepID: "isolate",
        recoveryHandle: WorkflowRecoveryHandle(capabilityID: "network.globalIsolation")
    ))

    let reader = try FileWorkflowJournal(url: url)
    #expect(await reader.incompleteRunIDs() == [runID])
    #expect(await reader.events(for: runID).count == 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
