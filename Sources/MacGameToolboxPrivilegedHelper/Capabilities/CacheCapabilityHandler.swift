import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct HelperCacheCapabilityHandler: HelperPrivilegedCapabilityHandling {
    let capabilityID = "cache.systemCleanup"
    let contractVersion = 1

    private let paths = ["/Library/Caches", "/Library/Logs", "/private/var/log"]

    func handles(_ request: PrivilegedRequest) -> Bool {
        if case .clearSystemCaches = request { return true }
        return false
    }

    func perform(_ request: PrivilegedRequest) throws {
        guard case .clearSystemCaches = request else { throw HelperError.invalidArguments }
        for path in paths {
            try removeVisibleContents(path)
        }
    }

    private func removeVisibleContents(_ path: String) throws {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            capabilityLogger.error("Unable to enumerate cache path \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        for entry in entries where !entry.hasPrefix(".") {
            try FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).appendingPathComponent(entry).path)
        }
    }
}
