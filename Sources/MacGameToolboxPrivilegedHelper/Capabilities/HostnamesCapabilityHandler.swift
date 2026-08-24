import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct HelperHostnamesCapabilityHandler: HelperPrivilegedCapabilityHandling {
    let capabilityID = "system.hostnames"
    let contractVersion = 1

    func handles(_ request: PrivilegedRequest) -> Bool {
        if case .setHostnames = request { return true }
        return false
    }

    func perform(_ request: PrivilegedRequest) throws {
        guard case .setHostnames(let names) = request else { throw HelperError.invalidArguments }
        guard InputValidation.computerName(names.computerName),
              InputValidation.hostname(names.hostName),
              InputValidation.hostname(names.localHostName) else {
            throw HelperError.invalidArguments
        }
        try run("/usr/sbin/scutil", ["--set", "ComputerName", names.computerName])
        try run("/usr/sbin/scutil", ["--set", "HostName", names.hostName])
        try run("/usr/sbin/scutil", ["--set", "LocalHostName", names.localHostName])
        try run("/usr/bin/dscacheutil", ["-flushcache"])
    }
}
