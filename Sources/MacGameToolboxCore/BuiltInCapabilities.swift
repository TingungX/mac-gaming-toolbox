import Foundation

public enum NetworkIsolationAction: String, Codable, Equatable, Sendable {
    case begin
    case renew
}

/// Input to the stable global-network-isolation capability. The mechanism
/// (currently PF) remains private to the privileged helper.
public struct NetworkIsolationInput: Codable, Equatable, Sendable {
    public let action: NetworkIsolationAction
    public let leaseSeconds: Int
    public let tokenID: UUID?

    public static func begin(leaseSeconds: Int) -> Self {
        Self(action: .begin, leaseSeconds: leaseSeconds, tokenID: nil)
    }

    public static func renew(leaseSeconds: Int, tokenID: UUID) -> Self {
        Self(action: .renew, leaseSeconds: leaseSeconds, tokenID: tokenID)
    }
}

public struct NetworkIsolationOutput: Codable, Equatable, Sendable {
    public let deadline: Date

    public init(deadline: Date) {
        self.deadline = deadline
    }
}

public enum NetworkIsolationCapability {
    public static let reference = CapabilityReference(id: "network.globalIsolation", version: 1)

    public static func contract() throws -> CapabilityContract {
        try CapabilityContract(
            id: reference.id,
            version: reference.version,
            inputSchema: CapabilitySchema(id: "network.globalIsolation.input", version: 1),
            outputSchema: CapabilitySchema(id: "network.globalIsolation.output", version: 1),
            permissions: [.privileged, .networkIsolation],
            resourceLocks: [CapabilityResourceLock(key: "network.globalIsolation")],
            sideEffect: .network,
            recovery: .idempotent(tokenVersion: 1),
            limits: CapabilityPayloadLimits(maxInputBytes: 4 * 1_024, maxOutputBytes: 4 * 1_024),
            lease: CapabilityLeaseMetadata(durationMilliseconds: 60_000, renewAfterMilliseconds: 30_000)
        )
    }
}
