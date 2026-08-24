import Foundation

public struct WorkflowStepReference: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }
}

/// App-side registration assembled by the Composition Root. `kind` is the
/// stable step type used by a compiled workflow; the workflow's own step ID
/// remains data on `WorkflowStepDefinition`.
public struct WorkflowStepRegistration: Sendable {
    public let reference: WorkflowStepReference
    public let capabilities: [CapabilityReference]
    public let makeExecutor: @Sendable () -> any WorkflowStepExecuting

    public init(
        kind: String,
        version: Int,
        capabilities: [CapabilityReference] = [],
        makeExecutor: @escaping @Sendable () -> any WorkflowStepExecuting
    ) {
        self.reference = WorkflowStepReference(id: kind, version: version)
        self.capabilities = capabilities
        self.makeExecutor = makeExecutor
    }

    public var kind: String { reference.id }
    public var version: Int { reference.version }
}

/// App-side registry. It has no mutating registration API; Composition Root
/// builds it once and passes the value to the workflow engine.
public struct WorkflowStepRegistry: WorkflowStepResolving, Sendable {
    private let registrations: [WorkflowStepReference: WorkflowStepRegistration]
    private let contracts: [CapabilityReference: CapabilityContract]

    public init(
        registrations: [WorkflowStepRegistration],
        contracts: [CapabilityContract] = []
    ) throws {
        let contractIndex = try Self.indexContracts(contracts)
        var registrationIndex = [WorkflowStepReference: WorkflowStepRegistration]()

        for registration in registrations {
            try Self.validateStepReference(registration.reference)
            guard registrationIndex.updateValue(registration, forKey: registration.reference) == nil else {
                throw CapabilityContractError.duplicateStepRegistration(registration.reference)
            }

            for capability in registration.capabilities {
                guard contractIndex[capability] != nil else {
                    throw CapabilityContractError.unknownCapability(capability)
                }
            }
            guard Set(registration.capabilities).count == registration.capabilities.count else {
                throw CapabilityContractError.invalidRegistration(
                    "workflow step declares a capability more than once"
                )
            }
        }

        self.registrations = registrationIndex
        self.contracts = contractIndex
    }

    public init(
        _ registrations: [WorkflowStepRegistration],
        contracts: [CapabilityContract] = []
    ) throws {
        try self.init(registrations: registrations, contracts: contracts)
    }

    public var registeredSteps: [WorkflowStepReference] {
        registrations.keys.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.version < rhs.version : lhs.id < rhs.id
        }
    }

    public func registration(for reference: WorkflowStepReference) throws -> WorkflowStepRegistration {
        guard let registration = registrations[reference] else {
            throw CapabilityContractError.unknownStep(reference)
        }
        return registration
    }

    public func makeExecutor(for reference: WorkflowStepReference) throws -> any WorkflowStepExecuting {
        try registration(for: reference).makeExecutor()
    }

    /// Resolves a compiled workflow step by its registered kind and version;
    /// the instance-specific step ID is intentionally not part of the key.
    public func resolve(step: WorkflowStepDefinition) async throws -> any WorkflowStepExecuting {
        try makeExecutor(for: WorkflowStepReference(id: step.kind, version: step.version))
    }

    public func contract(for reference: CapabilityReference) throws -> CapabilityContract {
        guard let contract = contracts[reference] else {
            throw CapabilityContractError.unknownCapability(reference)
        }
        return contract
    }

    public func contains(_ reference: WorkflowStepReference) -> Bool {
        registrations[reference] != nil
    }

    private static func validateStepReference(_ reference: WorkflowStepReference) throws {
        guard !reference.id.isEmpty else { throw CapabilityContractError.emptyIdentifier }
        guard reference.id == reference.id.trimmingCharacters(in: .whitespacesAndNewlines),
              reference.id.count <= 128,
              reference.id.unicodeScalars.allSatisfy({
                  $0.isASCII &&
                      ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "." || $0 == "-" || $0 == "_")
              }) else {
            throw CapabilityContractError.invalidIdentifier(reference.id)
        }
        guard reference.version > 0 else {
            throw CapabilityContractError.invalidVersion(reference.version)
        }
    }

    fileprivate static func indexContracts(
        _ contracts: [CapabilityContract]
    ) throws -> [CapabilityReference: CapabilityContract] {
        var index = [CapabilityReference: CapabilityContract]()
        for contract in contracts {
            guard index.updateValue(contract, forKey: contract.reference) == nil else {
                throw CapabilityContractError.duplicateRegistration(contract.reference)
            }
        }
        return index
    }
}

public protocol PrivilegedCapabilityHandling: Sendable {
    func invoke(_ invocation: CapabilityInvocationEnvelope) async throws -> CapabilityResultEnvelope
    func recover(_ handle: CapabilityRecoveryHandle) async throws
}

public struct PrivilegedCapabilityRegistration: Sendable {
    public let contract: CapabilityContract
    public let handler: any PrivilegedCapabilityHandling

    public init(
        contract: CapabilityContract,
        handler: any PrivilegedCapabilityHandling
    ) {
        self.contract = contract
        self.handler = handler
    }
}

/// Helper-side registry. The registry owns the immutable contract-to-handler
/// mapping and performs the second validation pass at the privilege boundary.
public struct PrivilegedCapabilityRegistry: Sendable {
    private let registrations: [CapabilityReference: PrivilegedCapabilityRegistration]

    public init(registrations: [PrivilegedCapabilityRegistration]) throws {
        var index = [CapabilityReference: PrivilegedCapabilityRegistration]()
        for registration in registrations {
            guard registration.contract.permissions.contains(.privileged) else {
                throw CapabilityContractError.privilegedCapabilityRequiresPermission(
                    registration.contract.reference
                )
            }
            guard index.updateValue(registration, forKey: registration.contract.reference) == nil else {
                throw CapabilityContractError.duplicateRegistration(registration.contract.reference)
            }
        }
        self.registrations = index
    }

    public init(_ registrations: [PrivilegedCapabilityRegistration]) throws {
        try self.init(registrations: registrations)
    }

    public var registeredCapabilities: [CapabilityReference] {
        registrations.keys.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.version < rhs.version : lhs.id < rhs.id
        }
    }

    public func contract(for reference: CapabilityReference) throws -> CapabilityContract {
        guard let registration = registrations[reference] else {
            throw CapabilityContractError.unknownCapability(reference)
        }
        return registration.contract
    }

    public func handler(for reference: CapabilityReference) throws -> any PrivilegedCapabilityHandling {
        guard let registration = registrations[reference] else {
            throw CapabilityContractError.unknownCapability(reference)
        }
        return registration.handler
    }

    public func invoke(
        _ invocation: CapabilityInvocationEnvelope
    ) async throws -> CapabilityResultEnvelope {
        let registration = try registration(for: invocation.capability)
        try invocation.validate(against: registration.contract)
        let result = try await registration.handler.invoke(invocation)
        try result.validate(against: registration.contract, matching: invocation)
        return result
    }

    public func recover(_ handle: CapabilityRecoveryHandle) async throws {
        let registration = try registration(for: handle.capability)
        try handle.validate(against: registration.contract)
        try await registration.handler.recover(handle)
    }

    public func contains(_ reference: CapabilityReference) -> Bool {
        registrations[reference] != nil
    }

    private func registration(
        for reference: CapabilityReference
    ) throws -> PrivilegedCapabilityRegistration {
        guard let registration = registrations[reference] else {
            throw CapabilityContractError.unknownCapability(reference)
        }
        return registration
    }
}
