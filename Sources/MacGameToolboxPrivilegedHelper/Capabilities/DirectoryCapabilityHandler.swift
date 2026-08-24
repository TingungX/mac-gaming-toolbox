import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct HelperDirectoryCapabilityHandler: HelperPrivilegedCapabilityHandling {
    let capabilityID = "disk.createDirectory"
    let contractVersion = 1

    func handles(_ request: PrivilegedRequest) -> Bool {
        if case .createDirectory = request { return true }
        return false
    }

    func perform(_ request: PrivilegedRequest) throws {
        guard case .createDirectory(let value) = request else { throw HelperError.invalidArguments }
        let path = try validatedPath(value)
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func validatedPath(_ value: String) throws -> String {
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        guard value.hasPrefix("/"), path != "/", !path.contains("\0") else {
            throw HelperError.invalidPath
        }
        return path
    }
}
