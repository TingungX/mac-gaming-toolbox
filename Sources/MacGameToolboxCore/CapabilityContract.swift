import Foundation

/// A stable, versioned reference to a capability.
public struct CapabilityReference: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }
}

/// The schema identity carried by a capability contract. The bytes themselves
/// remain opaque to the shared core; the trusted handler performs typed decode.
public struct CapabilitySchema: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }
}

public struct CapabilityPayloadLimits: Codable, Equatable, Hashable, Sendable {
    public static let defaultInputBytes = 64 * 1024
    public static let defaultOutputBytes = 64 * 1024
    public static let maximumBytes = 16 * 1024 * 1024

    public let maxInputBytes: Int
    public let maxOutputBytes: Int

    public init(
        maxInputBytes: Int = CapabilityPayloadLimits.defaultInputBytes,
        maxOutputBytes: Int = CapabilityPayloadLimits.defaultOutputBytes
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
    }
}

/// Optional lease metadata for capabilities whose side effect must expire or
/// be renewed. Durations are integers so the envelope remains deterministic
/// across the App/helper boundary.
public struct CapabilityLeaseMetadata: Codable, Equatable, Hashable, Sendable {
    public static let none = CapabilityLeaseMetadata()
    public static let maximumDurationMilliseconds = 24 * 60 * 60 * 1_000

    public let durationMilliseconds: Int?
    public let renewAfterMilliseconds: Int?

    public init(
        durationMilliseconds: Int? = nil,
        renewAfterMilliseconds: Int? = nil
    ) {
        self.durationMilliseconds = durationMilliseconds
        self.renewAfterMilliseconds = renewAfterMilliseconds
    }

    public var isLeased: Bool {
        durationMilliseconds != nil
    }
}

public enum CapabilityPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case user
    case privileged
    case networkIsolation
    case hosts
    case qualityOfService
    case disk
    case hostname
    case processObservation
}

public enum CapabilityResourceLockMode: String, Codable, Hashable, Sendable {
    case shared
    case exclusive
}

public struct CapabilityResourceLock: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let mode: CapabilityResourceLockMode

    public init(key: String, mode: CapabilityResourceLockMode = .exclusive) {
        self.key = key
        self.mode = mode
    }
}

public enum CapabilitySideEffectCategory: String, Codable, Hashable, Sendable {
    case none
    case network
    case hosts
    case qualityOfService
    case disk
    case hostname
    case process
    case system
}

public enum CapabilityRollbackSemantics: String, Codable, Hashable, Sendable {
    case none
    case idempotent
}

public struct CapabilityRecoverySemantics: Codable, Equatable, Hashable, Sendable {
    public let tokenVersion: Int?
    public let rollback: CapabilityRollbackSemantics

    public init(tokenVersion: Int? = nil, rollback: CapabilityRollbackSemantics = .none) {
        self.tokenVersion = tokenVersion
        self.rollback = rollback
    }

    public static let none = CapabilityRecoverySemantics()

    public static func idempotent(tokenVersion: Int = 1) -> Self {
        CapabilityRecoverySemantics(tokenVersion: tokenVersion, rollback: .idempotent)
    }

    public var requiresRecoveryHandle: Bool {
        tokenVersion != nil
    }
}

public enum CapabilityContractError: Error, Equatable, Sendable {
    case emptyIdentifier
    case invalidIdentifier(String)
    case invalidVersion(Int)
    case invalidSchemaVersion(Int)
    case invalidPayloadLimit(String, Int)
    case invalidResourceLock(String)
    case invalidLeaseMetadata
    case invalidRecoverySemantics
    case privilegedCapabilityRequiresPermission(CapabilityReference)
    case duplicateRegistration(CapabilityReference)
    case duplicateStepRegistration(WorkflowStepReference)
    case invalidRegistration(String)
    case unknownCapability(CapabilityReference)
    case unknownStep(WorkflowStepReference)
    case invalidInvocation(String)
    case payloadTooLarge(actual: Int, maximum: Int)
    case invocationContractMismatch(expected: CapabilityReference, actual: CapabilityReference)
    case resultIdentityMismatch
    case missingRecoveryHandle(CapabilityReference)
    case unexpectedRecoveryHandle(CapabilityReference)
    case recoveryHandleMismatch(CapabilityReference)
}

/// The cross-process contract shared by the App and the privileged helper.
public struct CapabilityContract: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let inputSchema: CapabilitySchema
    public let outputSchema: CapabilitySchema
    public let permissions: Set<CapabilityPermission>
    public let resourceLocks: [CapabilityResourceLock]
    public let sideEffect: CapabilitySideEffectCategory
    public let recovery: CapabilityRecoverySemantics
    public let limits: CapabilityPayloadLimits
    public let lease: CapabilityLeaseMetadata

    public init(
        id: String,
        version: Int,
        inputSchema: CapabilitySchema,
        outputSchema: CapabilitySchema,
        permissions: Set<CapabilityPermission> = [],
        resourceLocks: [CapabilityResourceLock] = [],
        sideEffect: CapabilitySideEffectCategory = .none,
        recovery: CapabilityRecoverySemantics = .none,
        limits: CapabilityPayloadLimits = CapabilityPayloadLimits(),
        lease: CapabilityLeaseMetadata = .none
    ) throws {
        try Self.validateIdentifier(id)
        guard version > 0 else { throw CapabilityContractError.invalidVersion(version) }
        try Self.validateSchema(inputSchema)
        try Self.validateSchema(outputSchema)
        try Self.validateLimits(limits)

        var lockKeys = Set<String>()
        for lock in resourceLocks {
            guard Self.isValidIdentifier(lock.key), lockKeys.insert(lock.key).inserted else {
                throw CapabilityContractError.invalidResourceLock(lock.key)
            }
        }

        try Self.validateLease(lease, sideEffect: sideEffect)

        if sideEffect == .none {
            guard recovery == .none else { throw CapabilityContractError.invalidRecoverySemantics }
        } else {
            guard recovery.requiresRecoveryHandle,
                  recovery.rollback == .idempotent,
                  let tokenVersion = recovery.tokenVersion,
                  tokenVersion > 0 else {
                throw CapabilityContractError.invalidRecoverySemantics
            }
        }

        self.id = id
        self.version = version
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.permissions = permissions
        self.resourceLocks = resourceLocks
        self.sideEffect = sideEffect
        self.recovery = recovery
        self.limits = limits
        self.lease = lease
    }

    public var reference: CapabilityReference {
        CapabilityReference(id: id, version: version)
    }

    public var requiresRecoveryHandle: Bool {
        sideEffect != .none
    }

    private static func validateSchema(_ schema: CapabilitySchema) throws {
        try validateIdentifier(schema.id)
        guard schema.version > 0 else {
            throw CapabilityContractError.invalidSchemaVersion(schema.version)
        }
    }

    private static func validateLimits(_ limits: CapabilityPayloadLimits) throws {
        for (name, value) in [("input", limits.maxInputBytes), ("output", limits.maxOutputBytes)] {
            guard value > 0, value <= CapabilityPayloadLimits.maximumBytes else {
                throw CapabilityContractError.invalidPayloadLimit(name, value)
            }
        }
    }

    private static func validateLease(
        _ lease: CapabilityLeaseMetadata,
        sideEffect: CapabilitySideEffectCategory
    ) throws {
        guard lease.isLeased else {
            guard lease.renewAfterMilliseconds == nil else {
                throw CapabilityContractError.invalidLeaseMetadata
            }
            return
        }

        guard sideEffect != .none,
              let duration = lease.durationMilliseconds,
              duration > 0,
              duration <= CapabilityLeaseMetadata.maximumDurationMilliseconds,
              let renewAfter = lease.renewAfterMilliseconds,
              renewAfter > 0,
              renewAfter < duration else {
            throw CapabilityContractError.invalidLeaseMetadata
        }
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty else { throw CapabilityContractError.emptyIdentifier }
        guard isValidIdentifier(value) else {
            throw CapabilityContractError.invalidIdentifier(value)
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII &&
                (scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "." || scalar == "-" || scalar == "_")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, inputSchema, outputSchema, permissions, resourceLocks
        case sideEffect, recovery, limits, lease
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            version: container.decode(Int.self, forKey: .version),
            inputSchema: container.decode(CapabilitySchema.self, forKey: .inputSchema),
            outputSchema: container.decode(CapabilitySchema.self, forKey: .outputSchema),
            permissions: container.decodeIfPresent(Set<CapabilityPermission>.self, forKey: .permissions) ?? [],
            resourceLocks: container.decodeIfPresent([CapabilityResourceLock].self, forKey: .resourceLocks) ?? [],
            sideEffect: container.decodeIfPresent(CapabilitySideEffectCategory.self, forKey: .sideEffect) ?? .none,
            recovery: container.decodeIfPresent(CapabilityRecoverySemantics.self, forKey: .recovery) ?? .none,
            limits: container.decodeIfPresent(CapabilityPayloadLimits.self, forKey: .limits) ?? CapabilityPayloadLimits(),
            lease: container.decodeIfPresent(CapabilityLeaseMetadata.self, forKey: .lease) ?? .none
        )
    }
}

public struct CapabilityInvocationEnvelope: Codable, Equatable, Hashable, Sendable {
    public let runID: UUID
    public let stepID: String
    public let capability: CapabilityReference
    public let inputPayload: Data

    public init(
        runID: UUID,
        stepID: String,
        capability: CapabilityReference,
        inputPayload: Data
    ) {
        self.runID = runID
        self.stepID = stepID
        self.capability = capability
        self.inputPayload = inputPayload
    }

    public init(
        runID: UUID,
        stepID: String,
        capabilityID: String,
        capabilityVersion: Int,
        inputPayload: Data
    ) {
        self.init(
            runID: runID,
            stepID: stepID,
            capability: CapabilityReference(id: capabilityID, version: capabilityVersion),
            inputPayload: inputPayload
        )
    }

    public var capabilityID: String { capability.id }
    public var capabilityVersion: Int { capability.version }
    public var input: Data { inputPayload }

    public func validate(against contract: CapabilityContract) throws {
        guard capability == contract.reference else {
            throw CapabilityContractError.invocationContractMismatch(
                expected: contract.reference,
                actual: capability
            )
        }
        guard !stepID.isEmpty else {
            throw CapabilityContractError.invalidInvocation("stepID is empty")
        }
        guard inputPayload.count <= contract.limits.maxInputBytes else {
            throw CapabilityContractError.payloadTooLarge(
                actual: inputPayload.count,
                maximum: contract.limits.maxInputBytes
            )
        }
    }
}

public struct CapabilityRecoveryHandle: Codable, Equatable, Hashable, Sendable {
    public let tokenID: UUID
    public let capability: CapabilityReference

    public init(tokenID: UUID, capability: CapabilityReference) {
        self.tokenID = tokenID
        self.capability = capability
    }

    public init(tokenID: UUID, capabilityID: String, capabilityVersion: Int) {
        self.init(
            tokenID: tokenID,
            capability: CapabilityReference(id: capabilityID, version: capabilityVersion)
        )
    }

    public var capabilityID: String { capability.id }
    public var capabilityVersion: Int { capability.version }

    public func validate(against contract: CapabilityContract) throws {
        guard contract.requiresRecoveryHandle, capability == contract.reference else {
            throw CapabilityContractError.recoveryHandleMismatch(contract.reference)
        }
    }
}

public struct CapabilityResultEnvelope: Codable, Equatable, Hashable, Sendable {
    public let runID: UUID
    public let stepID: String
    public let capability: CapabilityReference
    public let outputPayload: Data
    public let recoveryHandle: CapabilityRecoveryHandle?

    public init(
        runID: UUID,
        stepID: String,
        capability: CapabilityReference,
        outputPayload: Data,
        recoveryHandle: CapabilityRecoveryHandle? = nil
    ) {
        self.runID = runID
        self.stepID = stepID
        self.capability = capability
        self.outputPayload = outputPayload
        self.recoveryHandle = recoveryHandle
    }

    public init(
        runID: UUID,
        stepID: String,
        capabilityID: String,
        capabilityVersion: Int,
        outputPayload: Data,
        recoveryHandle: CapabilityRecoveryHandle? = nil
    ) {
        self.init(
            runID: runID,
            stepID: stepID,
            capability: CapabilityReference(id: capabilityID, version: capabilityVersion),
            outputPayload: outputPayload,
            recoveryHandle: recoveryHandle
        )
    }

    public var capabilityID: String { capability.id }
    public var capabilityVersion: Int { capability.version }
    public var output: Data { outputPayload }

    public func validate(
        against contract: CapabilityContract,
        matching invocation: CapabilityInvocationEnvelope? = nil
    ) throws {
        guard capability == contract.reference else {
            throw CapabilityContractError.invocationContractMismatch(
                expected: contract.reference,
                actual: capability
            )
        }
        guard outputPayload.count <= contract.limits.maxOutputBytes else {
            throw CapabilityContractError.payloadTooLarge(
                actual: outputPayload.count,
                maximum: contract.limits.maxOutputBytes
            )
        }
        if let invocation {
            guard runID == invocation.runID, stepID == invocation.stepID else {
                throw CapabilityContractError.resultIdentityMismatch
            }
        }

        if contract.requiresRecoveryHandle {
            guard let recoveryHandle else {
                throw CapabilityContractError.missingRecoveryHandle(contract.reference)
            }
            try recoveryHandle.validate(against: contract)
        } else if recoveryHandle != nil {
            throw CapabilityContractError.unexpectedRecoveryHandle(contract.reference)
        }
    }
}

// Short aliases keep call sites readable while retaining the explicit envelope
// names at XPC boundaries.
public typealias CapabilityInvocation = CapabilityInvocationEnvelope
public typealias CapabilityResult = CapabilityResultEnvelope
