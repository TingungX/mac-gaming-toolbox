import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

/// Preserves the legacy HoYo hosts/proxy-bypass request semantics behind one
/// capability handler.  The network workflow can replace this capability later
/// without changing the XPC service boundary.
struct HelperHostsCapabilityHandler: HelperPrivilegedCapabilityHandling {
    let capabilityID = "network.hoyoHosts"
    let contractVersion = 1

    private let snapshotURL = URL(fileURLWithPath: "/var/db/com.iven.macgametoolbox.proxy-bypass.json")
    private let hoyoDomains = GamingService.hoyoDomains

    func handles(_ request: PrivilegedRequest) -> Bool {
        switch request {
        case .addHoYoHosts, .removeHoYoHosts: true
        default: false
        }
    }

    func perform(_ request: PrivilegedRequest) throws {
        switch request {
        case .addHoYoHosts:
            try applyManagedProxyBypass()
            do {
                try rewriteHosts(addBlock: true)
            } catch {
                try restoreManagedProxyBypass()
                throw error
            }
        case .removeHoYoHosts:
            try rewriteHosts(addBlock: false)
            try restoreManagedProxyBypass()
        default:
            throw HelperError.invalidArguments
        }
    }

    private func applyManagedProxyBypass() throws {
        let currentByService = proxyBypassDomainsByService()
        let plan = NetworkProxyBypass.planApply(
            currentByService: currentByService,
            existingSnapshot: loadProxyBypassSnapshot(),
            extra: hoyoDomains
        )
        try persistProxyBypassSnapshot(plan.snapshot)
        var applied = 0
        var lastError: Error?
        for assignment in plan.assignments {
            do {
                try run("/usr/sbin/networksetup", NetworkProxyBypass.setArguments(service: assignment.service, domains: assignment.domains))
                applied += 1
            } catch {
                lastError = error
                capabilityLogger.error("Failed to set proxy bypass on \(assignment.service, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if applied == 0, !plan.assignments.isEmpty, let lastError {
            throw lastError
        }
    }

    private func restoreManagedProxyBypass() throws {
        let snapshot = loadProxyBypassSnapshot()
        let assignments = NetworkProxyBypass.planRestore(
            snapshot: snapshot,
            currentByService: proxyBypassDomainsByService(),
            managed: hoyoDomains
        )
        var lastError: Error?
        for assignment in assignments {
            do {
                try run("/usr/sbin/networksetup", NetworkProxyBypass.setArguments(service: assignment.service, domains: assignment.domains))
            } catch {
                lastError = error
                capabilityLogger.error("Failed to restore proxy bypass on \(assignment.service, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let lastError { throw lastError }
        try removeProxyBypassSnapshot()
    }

    private func proxyBypassDomainsByService() -> [String: [String]] {
        let list: String
        do {
            list = try runCapturing("/usr/sbin/networksetup", ["-listallnetworkservices"])
        } catch {
            capabilityLogger.error("Unable to list network services: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        var current: [String: [String]] = [:]
        for service in NetworkProxyBypass.enabledServices(from: list) {
            do {
                let output = try runCapturing("/usr/sbin/networksetup", ["-getproxybypassdomains", service])
                current[service] = NetworkProxyBypass.parseBypassDomains(output)
            } catch {
                capabilityLogger.error("Skipping proxy bypass for \(service, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return current
    }

    private func loadProxyBypassSnapshot() -> ProxyBypassSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(ProxyBypassSnapshot.self, from: Data(contentsOf: snapshotURL))
        } catch {
            capabilityLogger.error("Unable to read proxy bypass snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func persistProxyBypassSnapshot(_ snapshot: ProxyBypassSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: snapshotURL.path
        )
    }

    private func removeProxyBypassSnapshot() throws {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        try FileManager.default.removeItem(at: snapshotURL)
    }

    private func rewriteHosts(addBlock: Bool) throws {
        let url = URL(fileURLWithPath: "/etc/hosts")
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = HostsFileEditor.replacingManagedBlock(in: original, domains: hoyoDomains, enabled: addBlock)
        let temporary = URL(fileURLWithPath: "/etc/.mac-game-toolbox-hosts-\(getpid())")
        try updated.write(to: temporary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        try run("/usr/bin/dscacheutil", ["-flushcache"])
    }
}
