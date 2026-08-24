import Darwin
import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct HelperProcessQoSCapabilityHandler: HelperPrivilegedCapabilityHandling {
    let capabilityID = "process.qos"
    let contractVersion = 1

    func handles(_ request: PrivilegedRequest) -> Bool {
        if case .renice = request { return true }
        return false
    }

    func perform(_ request: PrivilegedRequest) throws {
        guard case .renice(let pids) = request else { throw HelperError.invalidArguments }
        guard !pids.isEmpty, pids.count <= 64 else { throw HelperError.invalidArguments }

        var updatedCount = 0
        for pid in pids {
            guard pid > 1 else { throw HelperError.invalidArguments }
            // Process scans are inherently racy; a short-lived Wine child may
            // disappear before the helper handles the complete PID batch.
            if try boostProcess(pid) { updatedCount += 1 }
        }
        guard updatedCount > 0 else { throw HelperError.invalidProcess }
    }

    private func boostProcess(_ pid: Int32) throws -> Bool {
        guard kill(pid, 0) == 0 else { return false }

        do {
            _ = try runCapturing(ProcessPriorityBoost.taskpolicyExecutable, ProcessPriorityBoost.taskpolicyArguments(pid: pid))
        } catch {
            guard !ProcessPriorityBoost.isMissingProcess(error.localizedDescription) else { return false }
            guard kill(pid, 0) == 0 else { return false }
            do {
                _ = try runCapturing(ProcessPriorityBoost.taskpolicyExecutable, ProcessPriorityBoost.taskpolicyFallbackArguments(pid: pid))
            } catch {
                guard !ProcessPriorityBoost.isMissingProcess(error.localizedDescription) else { return false }
                throw error
            }
        }

        guard kill(pid, 0) == 0 else { return true }
        errno = 0
        if setpriority(PRIO_PROCESS, UInt32(pid), ProcessPriorityBoost.niceValue) != 0, errno != ESRCH {
            capabilityLogger.error("setpriority(-20) failed for \(pid): errno \(errno)")
        }
        return true
    }
}
