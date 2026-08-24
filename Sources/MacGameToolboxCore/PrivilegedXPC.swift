import Foundation

public enum PrivilegedRequest: Codable, Equatable, Sendable {
    case healthCheck
    case addHoYoHosts
    case removeHoYoHosts
    case renice([Int32])
    case clearSystemCaches
    case setHostnames(HostnameBackup)
    case createDirectory(String)
}

public enum PrivilegedCapabilityXPCRequest: Codable, Equatable, Sendable {
    case invoke(CapabilityInvocationEnvelope)
    case recover(CapabilityRecoveryHandle)
}

public enum PrivilegedCapabilityXPCResponse: Codable, Equatable, Sendable {
    case invocation(CapabilityResultEnvelope)
    case recoveryCompleted
}

public enum PrivilegedCapabilityXPC {
    public static let maximumEnvelopeBytes = 128 * 1_024
}

public protocol PrivilegedCapabilityOperating: Sendable {
    func invoke(_ invocation: CapabilityInvocationEnvelope) async throws -> CapabilityResultEnvelope
    func recover(_ handle: CapabilityRecoveryHandle) async throws
}

public enum HelperRegistrationState: Sendable {
    case enabled, notRegistered, requiresApproval, notFound
}

public enum HelperRegistrationDecision: Equatable, Sendable {
    case connect, register, requestApproval, unavailable
}

public func helperRegistrationDecision(for state: HelperRegistrationState) -> HelperRegistrationDecision {
    switch state {
    case .enabled: .connect
    case .notRegistered: .register
    case .requiresApproval: .requestApproval
    case .notFound: .unavailable
    }
}

@objc(PrivilegedHelperXPCProtocol) public protocol PrivilegedHelperXPCProtocol {
    func perform(request: Data, withReply reply: @escaping (Bool, String?) -> Void)
    func performCapability(request: Data, withReply reply: @escaping (Data?, String?) -> Void)
}
