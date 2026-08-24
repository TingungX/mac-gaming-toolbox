import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct HelperHealthCheckCapabilityHandler: HelperPrivilegedCapabilityHandling {
    let capabilityID = "system.healthCheck"
    let contractVersion = 1

    func handles(_ request: PrivilegedRequest) -> Bool {
        if case .healthCheck = request { return true }
        return false
    }

    func perform(_ request: PrivilegedRequest) throws {
        guard case .healthCheck = request else { throw HelperError.invalidArguments }
    }
}
