import Foundation
import Testing
@testable import MacGameToolboxCore

private actor FakeNetworkIsolationClient: PrivilegedCapabilityOperating {
    private(set) var actions: [NetworkIsolationAction] = []
    var restored = true

    func invoke(_ invocation: CapabilityInvocationEnvelope) async throws -> CapabilityResultEnvelope {
        let input = try JSONDecoder().decode(NetworkIsolationInput.self, from: invocation.inputPayload)
        actions.append(input.action)
        let output = try JSONEncoder().encode(
            NetworkIsolationOutput(deadline: Date(), restored: input.action == .restoreActive && restored)
        )
        return CapabilityResultEnvelope(
            runID: invocation.runID,
            stepID: invocation.stepID,
            capability: invocation.capability,
            outputPayload: output,
            recoveryHandle: CapabilityRecoveryHandle(
                tokenID: UUID(),
                capability: invocation.capability
            )
        )
    }

    func recover(_ handle: CapabilityRecoveryHandle) async throws {}
}

private struct IsolationAdapterStep: WorkflowStepExecuting {
    let client: FakeNetworkIsolationClient
    var failAfterBegin = false

    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        let invocation = CapabilityInvocationEnvelope(
            runID: context.runID,
            stepID: context.step.id,
            capability: NetworkIsolationCapability.reference,
            inputPayload: try JSONEncoder().encode(NetworkIsolationInput.begin(leaseSeconds: 60))
        )
        let result = try await client.invoke(invocation)
        try result.validate(
            against: NetworkIsolationCapability.contract(),
            matching: invocation
        )
        guard let handle = result.recoveryHandle else {
            throw WorkflowStepExecutionError(message: "missing handle")
        }
        let workflowHandle = WorkflowRecoveryHandle(
            tokenID: handle.tokenID,
            capabilityID: handle.capability.id,
            capabilityVersion: handle.capability.version
        )
        if failAfterBegin {
            throw WorkflowStepExecutionError(
                message: "post-invoke failure",
                recoveryHandle: workflowHandle
            )
        }
        return WorkflowStepExecution(recoveryHandle: workflowHandle)
    }

    func compensate(
        _ recoveryHandle: WorkflowRecoveryHandle,
        context: WorkflowCompensationContext
    ) async throws {
        _ = recoveryHandle
        _ = try await NetworkIsolationRecovery.restoreActive(
            using: client,
            runID: context.runID
        )
    }

    func compensateInFlight(context: WorkflowCompensationContext) async throws {
        _ = try await NetworkIsolationRecovery.restoreActive(
            using: client,
            runID: context.runID
        )
    }
}

@Test func networkIsolationRecoveryReportsWhetherALeaseWasRestored() async throws {
    let client = FakeNetworkIsolationClient()
    #expect(try await NetworkIsolationRecovery.restoreActive(using: client))
    await client.setRestored(false)
    #expect(try await NetworkIsolationRecovery.restoreActive(using: client) == false)
    #expect(await client.actions == [.restoreActive, .restoreActive])
}

extension FakeNetworkIsolationClient {
    func setRestored(_ value: Bool) { restored = value }
}

@Test func isolationStepFailureAfterBeginCompensatesWithHandle() async throws {
    let journal = InMemoryWorkflowJournal()
    let client = FakeNetworkIsolationClient()
    let step = IsolationAdapterStep(client: client, failAfterBegin: true)
    let engine = WorkflowEngine(
        resolver: ClosureWorkflowStepResolver { _ in step },
        journal: journal
    )
    let result = try await engine.run(
        CompiledWorkflow(
            id: "game.hoyo.genshin.cn.launch",
            steps: [WorkflowStepDefinition(id: "isolate-network", kind: "network.isolate")]
        )
    )

    #expect(result.status == .failed)
    #expect(await client.actions == [.begin, .restoreActive])
}

@Test func isolationCrashBetweenStartAndSuccessRestoresActiveLease() async throws {
    let journal = InMemoryWorkflowJournal()
    let runID = UUID()
    try await journal.append(WorkflowJournalEvent(
        runID: runID,
        workflowID: "game.hoyo.genshin.cn.launch",
        kind: .stepStarted,
        status: .running,
        stepID: "isolate-network"
    ))

    let client = FakeNetworkIsolationClient()
    let step = IsolationAdapterStep(client: client)
    let engine = WorkflowEngine(
        resolver: ClosureWorkflowStepResolver { _ in step },
        journal: journal
    )
    let result = try await engine.recover(
        CompiledWorkflow(
            id: "game.hoyo.genshin.cn.launch",
            steps: [WorkflowStepDefinition(id: "isolate-network", kind: "network.isolate")]
        ),
        runID: runID
    )

    #expect(result.status == .recovered)
    #expect(await client.actions == [.restoreActive])
}
