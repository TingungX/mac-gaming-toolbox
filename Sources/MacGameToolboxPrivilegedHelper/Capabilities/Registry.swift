import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

/// The helper-local handler seam used while the shared CapabilityContract is
/// being introduced in Core.  A handler owns both validation and execution for
/// the request cases it registers.
protocol HelperPrivilegedCapabilityHandling {
    var capabilityID: String { get }
    var contractVersion: Int { get }
    func handles(_ request: PrivilegedRequest) -> Bool
    func perform(_ request: PrivilegedRequest) throws
}

/// Immutable dispatch table for the single root helper process.
///
/// This is deliberately not a global service locator: the table is assembled
/// once by `builtIn()` and retained by `HelperService` for the lifetime of the
/// XPC service.  Each handler still performs its own payload and domain checks.
struct HelperPrivilegedCapabilityRegistry {
    private let handlers: [any HelperPrivilegedCapabilityHandling]

    init(handlers: [any HelperPrivilegedCapabilityHandling]) {
        precondition(!handlers.isEmpty, "Privileged helper requires at least one capability handler")
        let registrations = handlers.map { "\($0.capabilityID)@\($0.contractVersion)" }
        precondition(Set(registrations).count == registrations.count, "Duplicate privileged capability registration")
        self.handlers = handlers
    }

    static func builtIn() -> Self {
        Self(handlers: [
            HelperHealthCheckCapabilityHandler(),
            HelperHostsCapabilityHandler(),
            HelperProcessQoSCapabilityHandler(),
            HelperCacheCapabilityHandler(),
            HelperHostnamesCapabilityHandler(),
            HelperDirectoryCapabilityHandler()
        ])
    }

    func dispatch(_ request: PrivilegedRequest) throws {
        guard let handler = handlers.first(where: { $0.handles(request) }) else {
            throw HelperError.invalidArguments
        }
        try handler.perform(request)
    }
}

/// Helper composition root.  `legacyRegistry` keeps the current XPC request
/// behavior during migration; `privilegedRegistry` is the formal contract path
/// and already includes PF network isolation.
struct HelperCapabilityCompositionRoot {
    let legacyRegistry: HelperPrivilegedCapabilityRegistry
    let privilegedRegistry: PrivilegedCapabilityRegistry

    static func builtIn() -> Self {
        let pfHandler = PFNetworkIsolationHandler()
        do {
            let contract = try makePFNetworkIsolationContract()
            let registry = try PrivilegedCapabilityRegistry(registrations: [
                PrivilegedCapabilityRegistration(
                    contract: contract,
                    handler: PFNetworkIsolationCapabilityAdapter(handler: pfHandler)
                )
            ])
            return Self(
                legacyRegistry: .builtIn(),
                privilegedRegistry: registry
            )
        } catch {
            preconditionFailure("Unable to assemble privileged capability registry: \(error)")
        }
    }
}
