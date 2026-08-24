import Foundation
import Testing
@testable import MacGameToolboxCore

private struct NoopWorkflowStep: WorkflowStepExecuting {
    func execute(context: WorkflowStepContext) async throws -> WorkflowStepExecution {
        .completed
    }
}

private actor RecordingCapabilityHandler: PrivilegedCapabilityHandling {
    private(set) var invocations: [CapabilityInvocationEnvelope] = []
    private(set) var recoveries: [CapabilityRecoveryHandle] = []

    func invoke(_ invocation: CapabilityInvocationEnvelope) async throws -> CapabilityResultEnvelope {
        invocations.append(invocation)
        return CapabilityResultEnvelope(
            runID: invocation.runID,
            stepID: invocation.stepID,
            capability: invocation.capability,
            outputPayload: Data("ok".utf8),
            recoveryHandle: CapabilityRecoveryHandle(
                tokenID: UUID(),
                capability: invocation.capability
            )
        )
    }

    func recover(_ handle: CapabilityRecoveryHandle) async throws {
        recoveries.append(handle)
    }
}

private func testContract(
    id: String = "network.isolation",
    version: Int = 1,
    sideEffect: CapabilitySideEffectCategory = .network,
    permissions: Set<CapabilityPermission> = [.privileged, .networkIsolation],
    maxInputBytes: Int = 16
) throws -> CapabilityContract {
    try CapabilityContract(
        id: id,
        version: version,
        inputSchema: CapabilitySchema(id: "network.isolation.input", version: 1),
        outputSchema: CapabilitySchema(id: "network.isolation.output", version: 1),
        permissions: permissions,
        resourceLocks: [CapabilityResourceLock(key: "network", mode: .exclusive)],
        sideEffect: sideEffect,
        recovery: sideEffect == .none ? .none : .idempotent(tokenVersion: 1),
        limits: CapabilityPayloadLimits(maxInputBytes: maxInputBytes, maxOutputBytes: 16),
        lease: sideEffect == .none ? .none : CapabilityLeaseMetadata(
            durationMilliseconds: 10_000,
            renewAfterMilliseconds: 3_000
        )
    )
}

@Test func capabilityContractRejectsInvalidRecoveryMetadata() {
    #expect(throws: CapabilityContractError.invalidRecoverySemantics) {
        try CapabilityContract(
            id: "network.isolation",
            version: 1,
            inputSchema: CapabilitySchema(id: "input", version: 1),
            outputSchema: CapabilitySchema(id: "output", version: 1),
            sideEffect: .network
        )
    }
}

@Test func capabilityContractRejectsInvalidLeaseMetadata() {
    #expect(throws: CapabilityContractError.invalidLeaseMetadata) {
        try CapabilityContract(
            id: "network.isolation",
            version: 1,
            inputSchema: CapabilitySchema(id: "input", version: 1),
            outputSchema: CapabilitySchema(id: "output", version: 1),
            sideEffect: .network,
            recovery: .idempotent(tokenVersion: 1),
            lease: CapabilityLeaseMetadata(durationMilliseconds: 3_000, renewAfterMilliseconds: 3_000)
        )
    }
}

@Test func capabilityInvocationRejectsPayloadOutsideContractLimit() throws {
    let contract = try testContract(maxInputBytes: 2)
    let invocation = CapabilityInvocationEnvelope(
        runID: UUID(),
        stepID: "network",
        capability: contract.reference,
        inputPayload: Data([1, 2, 3])
    )

    #expect(throws: CapabilityContractError.payloadTooLarge(actual: 3, maximum: 2)) {
        try invocation.validate(against: contract)
    }
}

@Test func workflowRegistryIsImmutableAndRejectsUnknownCapabilityVersion() throws {
    let contract = try testContract()
    let registration = WorkflowStepRegistration(
        kind: "network.isolation",
        version: 1,
        capabilities: [contract.reference],
        makeExecutor: { NoopWorkflowStep() }
    )
    let registry = try WorkflowStepRegistry(registrations: [registration], contracts: [contract])

    #expect(registry.contains(WorkflowStepReference(id: "network.isolation", version: 1)))
    #expect(throws: CapabilityContractError.unknownStep(WorkflowStepReference(id: "network.isolation", version: 2))) {
        try registry.registration(for: WorkflowStepReference(id: "network.isolation", version: 2))
    }
    #expect(throws: CapabilityContractError.unknownCapability(CapabilityReference(id: "network.isolation", version: 2))) {
        try registry.contract(for: CapabilityReference(id: "network.isolation", version: 2))
    }
}

@Test func registriesRejectDuplicateRegistrations() throws {
    let contract = try testContract()
    let duplicateContract = try testContract()
    #expect(throws: CapabilityContractError.duplicateRegistration(contract.reference)) {
        try PrivilegedCapabilityRegistry(registrations: [
            PrivilegedCapabilityRegistration(contract: contract, handler: RecordingCapabilityHandler()),
            PrivilegedCapabilityRegistration(contract: duplicateContract, handler: RecordingCapabilityHandler())
        ])
    }

    let registration = WorkflowStepRegistration(
        kind: "network.isolation",
        version: 1,
        makeExecutor: { NoopWorkflowStep() }
    )
    #expect(throws: CapabilityContractError.duplicateStepRegistration(registration.reference)) {
        try WorkflowStepRegistry(registrations: [registration, registration])
    }
}

@Test func privilegedRegistryRevalidatesInvocationAndRequiresRecoveryHandle() async throws {
    let contract = try testContract()
    let handler = RecordingCapabilityHandler()
    let registry = try PrivilegedCapabilityRegistry(registrations: [
        PrivilegedCapabilityRegistration(contract: contract, handler: handler)
    ])
    let invocation = CapabilityInvocationEnvelope(
        runID: UUID(),
        stepID: "network",
        capability: contract.reference,
        inputPayload: Data([1])
    )

    let result = try await registry.invoke(invocation)
    #expect(result.recoveryHandle?.capability == contract.reference)
    try await registry.recover(result.recoveryHandle!)
    #expect((await handler.invocations).count == 1)
    #expect((await handler.recoveries).count == 1)

    let unknownVersion = CapabilityInvocationEnvelope(
        runID: UUID(),
        stepID: "network",
        capability: CapabilityReference(id: contract.id, version: 2),
        inputPayload: Data([1])
    )
    await #expect(throws: CapabilityContractError.unknownCapability(unknownVersion.capability)) {
        try await registry.invoke(unknownVersion)
    }
}

@Test func nonPrivilegedContractCannotEnterHelperRegistry() throws {
    let contract = try testContract(permissions: [.networkIsolation])
    #expect(throws: CapabilityContractError.privilegedCapabilityRequiresPermission(contract.reference)) {
        try PrivilegedCapabilityRegistry(registrations: [
            PrivilegedCapabilityRegistration(contract: contract, handler: RecordingCapabilityHandler())
        ])
    }
}
