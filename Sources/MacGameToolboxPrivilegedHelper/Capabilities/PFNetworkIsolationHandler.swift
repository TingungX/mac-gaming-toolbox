import CryptoKit
import Darwin
import Foundation
import Security
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

/// A token returned by the PF isolation capability.  Its serialized value is
/// intentionally opaque to callers; the helper persists only its digest.
struct PFNetworkIsolationRecoveryToken: Codable, Equatable, Sendable {
    private let tokenID: UUID

    init(serializedValue: String) throws {
        guard let tokenID = UUID(uuidString: serializedValue),
              tokenID.uuidString.caseInsensitiveCompare(serializedValue) == .orderedSame else {
            throw PFNetworkIsolationError.invalidRecoveryToken
        }
        self.tokenID = tokenID
    }

    init(tokenID: UUID) { self.tokenID = tokenID }

    var serializedValue: String { tokenID.uuidString }
    var id: UUID { tokenID }
}

struct PFNetworkIsolationBeginResult: Codable, Equatable, Sendable {
    let recoveryToken: PFNetworkIsolationRecoveryToken
    let deadline: Date
}

enum PFNetworkIsolationError: LocalizedError, Equatable, Sendable {
    case notRoot
    case invalidLease
    case invalidRecoveryToken
    case invalidSnapshot
    case missingComAppleWildcardAnchor
    case configurationUnavailable(String)
    case runAlreadyActive
    case wrongRun
    case commandFailed(String)
    case commandLaunchFailed(String)
    case snapshotFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRoot: "PF isolation requires a root helper"
        case .invalidLease: "PF isolation lease must be between 5 and 60 seconds"
        case .invalidRecoveryToken: "Invalid PF isolation recovery token"
        case .invalidSnapshot: "Invalid PF isolation snapshot"
        case .missingComAppleWildcardAnchor: "PF configuration does not contain anchor \"com.apple/*\""
        case .configurationUnavailable(let message): "Unable to inspect PF configuration: \(message)"
        case .runAlreadyActive: "Another PF isolation run is already active"
        case .wrongRun: "PF isolation run does not match the recovery token"
        case .commandFailed(let message): message
        case .commandLaunchFailed(let message): "Unable to launch pfctl: \(message)"
        case .snapshotFailed(let message): "Unable to persist PF isolation snapshot: \(message)"
        case .verificationFailed(let message): "Unable to verify PF isolation state: \(message)"
        }
    }
}

struct PFCommandResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

protocol PFCommandExecuting: Sendable {
    func execute(arguments: [String], input: Data?) throws -> PFCommandResult
}

struct SystemPFCommandExecutor: PFCommandExecuting {
    static let executablePath = "/sbin/pfctl"

    func execute(arguments: [String], input: Data? = nil) throws -> PFCommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        if let inputPipe {
            process.standardInput = inputPipe
        }

        do {
            try process.run()
        } catch {
            throw PFNetworkIsolationError.commandLaunchFailed(error.localizedDescription)
        }

        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            inputPipe.fileHandleForWriting.closeFile()
        }
        process.waitUntilExit()

        return PFCommandResult(
            terminationStatus: process.terminationStatus,
            stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

protocol PFConfigurationReading: Sendable {
    func containsComAppleWildcardAnchor() throws -> Bool
}

struct SystemPFConfigurationReader: PFConfigurationReading {
    static let configurationURL = URL(fileURLWithPath: "/etc/pf.conf")

    func containsComAppleWildcardAnchor() throws -> Bool {
        let contents: String
        do {
            contents = try String(contentsOf: Self.configurationURL, encoding: .utf8)
        } catch {
            throw PFNetworkIsolationError.configurationUnavailable(error.localizedDescription)
        }
        return contents.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("#") && trimmed.contains(#"anchor "com.apple/*""#)
        }
    }
}

private enum PFIsolationSnapshotPhase: String, Codable {
    case prepared
    case pfEnabled
    case active
    case anchorFlushed
    case restored
}

private struct PFIsolationSnapshot: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let anchor: String
    let runID: UUID
    let tokenID: UUID
    let tokenDigest: String
    var deadline: Date
    var phase: PFIsolationSnapshotPhase
    var pfEnableToken: String?

    init(
        runID: UUID,
        tokenID: UUID,
        tokenDigest: String,
        deadline: Date,
        phase: PFIsolationSnapshotPhase,
        pfEnableToken: String? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.anchor = PFNetworkIsolationHandler.anchor
        self.runID = runID
        self.tokenID = tokenID
        self.tokenDigest = tokenDigest
        self.deadline = deadline
        self.phase = phase
        self.pfEnableToken = pfEnableToken
    }
}

/// PF-backed global network isolation for one short-lived workflow lease.
///
/// The handler owns one fixed anchor and never reloads or flushes the main PF
/// ruleset. It is exposed only through the helper's formal capability envelope;
/// callers never supply rules, PF tokens, or anchor names.
final class PFNetworkIsolationHandler {
    static let capabilityID = NetworkIsolationCapability.reference.id
    static let contractVersion = 1
    static let anchor = "com.apple/100.com.iven.macgametoolbox"
    static let defaultSnapshotURL = URL(fileURLWithPath: "/var/db/com.iven.macgametoolbox.network-isolation.json")
    static let rules = "pass quick on lo0 all\nblock drop quick all\n"

    private let executor: any PFCommandExecuting
    private let configurationReader: any PFConfigurationReading
    private let snapshotURL: URL
    private let isRunningAsRoot: @Sendable () -> Bool
    private let snapshotOwnerID: uid_t
    private let snapshotGroupID: gid_t
    private let lock = NSLock()
    private var snapshot: PFIsolationSnapshot?
    private var expiryTimer: DispatchSourceTimer?

    init(
        executor: any PFCommandExecuting = SystemPFCommandExecutor(),
        configurationReader: any PFConfigurationReading = SystemPFConfigurationReader(),
        snapshotURL: URL = PFNetworkIsolationHandler.defaultSnapshotURL,
        isRunningAsRoot: @escaping @Sendable () -> Bool = { geteuid() == 0 },
        snapshotOwnerID: uid_t = 0,
        snapshotGroupID: gid_t = 0
    ) {
        self.executor = executor
        self.configurationReader = configurationReader
        self.snapshotURL = snapshotURL
        self.isRunningAsRoot = isRunningAsRoot
        self.snapshotOwnerID = snapshotOwnerID
        self.snapshotGroupID = snapshotGroupID
        recoverPersistedState()
    }

    /// Starts or returns the existing isolation lease for `runID`.
    func begin(runID: UUID, leaseSeconds: TimeInterval) throws -> PFNetworkIsolationBeginResult {
        guard isRunningAsRoot() else { throw PFNetworkIsolationError.notRoot }
        guard leaseSeconds.isFinite, leaseSeconds >= 5, leaseSeconds <= 60 else {
            throw PFNetworkIsolationError.invalidLease
        }

        lock.lock()
        defer { lock.unlock() }

        if let current = snapshot, current.phase != .restored {
            guard current.runID == runID else { throw PFNetworkIsolationError.runAlreadyActive }
            if current.phase == .active, let token = recoveryToken(from: current), current.deadline > Date() {
                scheduleExpiryTimerLocked(for: current)
                return PFNetworkIsolationBeginResult(recoveryToken: token, deadline: current.deadline)
            }
            try ensureConfiguredAnchor()
            // A previous restore was interrupted or the lease expired while
            // the helper was unavailable. Finish cleanup before a new run.
            try restoreLocked(current, expectedRunID: runID, expectedToken: recoveryToken(from: current))
        } else {
            try ensureConfiguredAnchor()
        }

        let token = try makeRecoveryToken()
        let deadline = Date().addingTimeInterval(leaseSeconds)
        var pending = PFIsolationSnapshot(
            runID: runID,
            tokenID: token.id,
            tokenDigest: Self.digest(token.serializedValue),
            deadline: deadline,
            phase: .prepared
        )

        // Persist the lease before changing PF state.  The PF enable token is
        // filled in immediately after -E succeeds and persisted again before
        // loading the anchor rules.
        try writeSnapshot(pending)
        snapshot = pending

        do {
            let enableResult = try execute(["-E"])
            guard enableResult.terminationStatus == 0,
                  let pfToken = Self.parsePFEnableToken(enableResult.combinedOutput) else {
                throw PFNetworkIsolationError.commandFailed(
                    "pfctl -E failed: \(enableResult.combinedOutput.isEmpty ? "unknown error" : enableResult.combinedOutput)"
                )
            }
            pending.pfEnableToken = pfToken
            pending.phase = .pfEnabled
            try writeSnapshot(pending)
            snapshot = pending

            let ruleResult = try execute(["-a", Self.anchor, "-f", "-"], input: Data(Self.rules.utf8))
            try requireSuccess(ruleResult, command: "pfctl -a <anchor> -f -")

            // State flush is deliberately global: states created before the
            // anchor existed would otherwise keep established connections
            // alive through the new block rule.  This does not reload or flush
            // the main ruleset.
            let stateResult = try execute(["-F", "states"])
            try requireSuccess(stateResult, command: "pfctl -F states")
            try verifyIsolationActive()

            pending.phase = .active
            try writeSnapshot(pending)
            snapshot = pending
            scheduleExpiryTimerLocked(for: pending)
            return PFNetworkIsolationBeginResult(recoveryToken: token, deadline: deadline)
        } catch {
            do {
                try restoreLocked(pending, expectedRunID: runID, expectedToken: token)
            } catch {
                capabilityLogger.error("PF begin cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// Restores the anchor and releases only the PF enable token owned by this
    /// lease.  Repeating the same call after a successful restore is a no-op.
    func restore(runID: UUID, recoveryToken: PFNetworkIsolationRecoveryToken) throws {
        guard isRunningAsRoot() else { throw PFNetworkIsolationError.notRoot }
        lock.lock()
        defer { lock.unlock() }

        guard let current = snapshot else { throw PFNetworkIsolationError.invalidRecoveryToken }
        try validate(current, runID: runID, token: recoveryToken)
        guard current.phase != .restored else { return }
        try restoreLocked(current, expectedRunID: runID, expectedToken: recoveryToken)
    }

    func restore(runID: UUID, tokenID: UUID) throws {
        try restore(runID: runID, recoveryToken: PFNetworkIsolationRecoveryToken(tokenID: tokenID))
    }

    func renew(runID: UUID, tokenID: UUID, leaseSeconds: TimeInterval) throws -> PFNetworkIsolationBeginResult {
        guard isRunningAsRoot() else { throw PFNetworkIsolationError.notRoot }
        guard leaseSeconds.isFinite, leaseSeconds >= 5, leaseSeconds <= 60 else {
            throw PFNetworkIsolationError.invalidLease
        }

        lock.lock()
        defer { lock.unlock() }
        guard var current = snapshot, current.phase == .active else {
            throw PFNetworkIsolationError.invalidRecoveryToken
        }
        let token = PFNetworkIsolationRecoveryToken(tokenID: tokenID)
        try validate(current, runID: runID, token: token)
        guard current.deadline > Date() else {
            try restoreLocked(current, expectedRunID: runID, expectedToken: token)
            throw PFNetworkIsolationError.invalidRecoveryToken
        }

        current.deadline = Date().addingTimeInterval(leaseSeconds)
        try writeSnapshot(current)
        snapshot = current
        scheduleExpiryTimerLocked(for: current)
        return PFNetworkIsolationBeginResult(recoveryToken: token, deadline: current.deadline)
    }

    /// Restores the current project-owned lease without requiring the App to
    /// present a recovery handle. A no-op when no lease is active.
    func restoreActive() throws -> (didRestore: Bool, recoveryToken: PFNetworkIsolationRecoveryToken, deadline: Date) {
        guard isRunningAsRoot() else { throw PFNetworkIsolationError.notRoot }
        lock.lock()
        defer { lock.unlock() }

        guard let current = snapshot, current.phase != .restored else {
            let token = snapshot.flatMap(recoveryToken) ?? PFNetworkIsolationRecoveryToken(tokenID: UUID())
            return (false, token, Date())
        }
        let token = recoveryToken(from: current) ?? PFNetworkIsolationRecoveryToken(tokenID: current.tokenID)
        try restoreLocked(current, expectedRunID: current.runID, expectedToken: nil)
        return (true, token, current.deadline)
    }

    /// Compensation from the formal capability envelope carries only its UUID
    /// token ID. The snapshot supplies the run identity and the digest check
    /// still prevents an arbitrary token from reaching PF.
    func recover(tokenID: UUID) throws {
        guard isRunningAsRoot() else { throw PFNetworkIsolationError.notRoot }
        lock.lock()
        defer { lock.unlock() }
        guard let current = snapshot else { throw PFNetworkIsolationError.invalidRecoveryToken }
        try validate(current, runID: current.runID, token: PFNetworkIsolationRecoveryToken(tokenID: tokenID))
        guard current.phase != .restored else { return }
        try restoreLocked(current, expectedRunID: current.runID, expectedToken: PFNetworkIsolationRecoveryToken(tokenID: tokenID))
    }

    /// Returns the persisted lease for diagnostics and helper composition-root
    /// recovery.  It never exposes the opaque recovery token.
    var hasActiveLease: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot else { return false }
        return snapshot.phase != .restored
    }

    private func recoverPersistedState() {
        do {
            guard let persisted = try readSnapshot() else { return }
            try validateSnapshot(persisted)
            lock.lock()
            snapshot = persisted
            if persisted.phase == .restored {
                lock.unlock()
                return
            }
            if persisted.phase != .active || persisted.deadline <= Date() {
                do {
                    try restoreLocked(persisted, expectedRunID: persisted.runID, expectedToken: recoveryToken(from: persisted))
                    lock.unlock()
                } catch {
                    capabilityLogger.error("PF persisted-state recovery failed: \(error.localizedDescription, privacy: .public)")
                    scheduleRecoveryRetryLocked()
                    lock.unlock()
                }
            } else {
                do {
                    try verifyIsolationActive()
                    scheduleExpiryTimerLocked(for: persisted)
                    lock.unlock()
                } catch {
                    capabilityLogger.error(
                        "PF persisted lease is active but current PF state does not match: \(error.localizedDescription, privacy: .public)"
                    )
                    do {
                        try restoreLocked(
                            persisted,
                            expectedRunID: persisted.runID,
                            expectedToken: recoveryToken(from: persisted)
                        )
                        lock.unlock()
                    } catch {
                        capabilityLogger.error("PF reboot-state restore failed: \(error.localizedDescription, privacy: .public)")
                        scheduleRecoveryRetryLocked()
                        lock.unlock()
                    }
                }
            }
        } catch {
            capabilityLogger.error("PF snapshot ignored: \(error.localizedDescription, privacy: .public)")
            guard isRunningAsRoot() else { return }
            do {
                let flushResult = try execute(["-a", Self.anchor, "-F", "all"])
                try requireSuccess(flushResult, command: "pfctl -a <anchor> -F all")
                try verifyIsolationRestored()
            } catch {
                capabilityLogger.error("PF emergency anchor cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func restoreLocked(
        _ current: PFIsolationSnapshot,
        expectedRunID: UUID,
        expectedToken: PFNetworkIsolationRecoveryToken?
    ) throws {
        guard current.runID == expectedRunID else { throw PFNetworkIsolationError.wrongRun }
        if let expectedToken {
            try validate(current, runID: expectedRunID, token: expectedToken)
        }

        if current.phase == .active || current.phase == .pfEnabled {
            let flushResult = try execute(["-a", Self.anchor, "-F", "all"])
            try requireSuccess(flushResult, command: "pfctl -a <anchor> -F all")
            try verifyIsolationRestored()
        }

        var flushing = current
        flushing.phase = .anchorFlushed
        try writeSnapshot(flushing)
        snapshot = flushing

        if let pfToken = flushing.pfEnableToken {
            let releaseResult = try execute(["-X", pfToken])
            try requireSuccess(releaseResult, command: "pfctl -X <owned-token>")
        }

        var restored = flushing
        restored.phase = .restored
        restored.pfEnableToken = nil
        try writeSnapshot(restored)
        snapshot = restored
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    private func validate(
        _ current: PFIsolationSnapshot,
        runID: UUID,
        token: PFNetworkIsolationRecoveryToken
    ) throws {
        guard current.runID == runID else { throw PFNetworkIsolationError.wrongRun }
        guard Self.constantTimeEqual(current.tokenDigest, Self.digest(token.serializedValue)) else {
            throw PFNetworkIsolationError.invalidRecoveryToken
        }
    }

    private func validateSnapshot(_ value: PFIsolationSnapshot) throws {
        guard value.schemaVersion == PFIsolationSnapshot.schemaVersion,
              value.anchor == Self.anchor,
              !value.tokenDigest.isEmpty,
              Self.constantTimeEqual(value.tokenDigest, Self.digest(value.tokenID.uuidString)) else {
            throw PFNetworkIsolationError.invalidSnapshot
        }
        if let pfToken = value.pfEnableToken, !Self.isValidPFEnableToken(pfToken) {
            throw PFNetworkIsolationError.invalidSnapshot
        }
    }

    private func recoveryToken(from value: PFIsolationSnapshot) -> PFNetworkIsolationRecoveryToken? {
        PFNetworkIsolationRecoveryToken(tokenID: value.tokenID)
    }

    private func makeRecoveryToken() throws -> PFNetworkIsolationRecoveryToken {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PFNetworkIsolationError.commandFailed("Unable to generate recovery token")
        }
        let tokenID = bytes.withUnsafeBytes { rawBuffer -> UUID in
            let tuple: uuid_t = (
                rawBuffer[0], rawBuffer[1], rawBuffer[2], rawBuffer[3],
                rawBuffer[4], rawBuffer[5], rawBuffer[6], rawBuffer[7],
                rawBuffer[8], rawBuffer[9], rawBuffer[10], rawBuffer[11],
                rawBuffer[12], rawBuffer[13], rawBuffer[14], rawBuffer[15]
            )
            return UUID(uuid: tuple)
        }
        return PFNetworkIsolationRecoveryToken(tokenID: tokenID)
    }

    private func execute(_ arguments: [String], input: Data? = nil) throws -> PFCommandResult {
        try executor.execute(arguments: arguments, input: input)
    }

    private func ensureConfiguredAnchor() throws {
        guard try configurationReader.containsComAppleWildcardAnchor() else {
            throw PFNetworkIsolationError.missingComAppleWildcardAnchor
        }
    }

    private func requireSuccess(_ result: PFCommandResult, command: String) throws {
        guard result.terminationStatus == 0 else {
            let output = result.combinedOutput
            throw PFNetworkIsolationError.commandFailed(
                "\(command) failed (status \(result.terminationStatus))\(output.isEmpty ? "" : ": \(output)")"
            )
        }
    }

    private func verifyIsolationActive() throws {
        let status = try execute(["-s", "info"])
        try requireSuccess(status, command: "pfctl -s info")
        guard status.combinedOutput.range(
            of: #"\bStatus:\s+Enabled\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            throw PFNetworkIsolationError.verificationFailed("PF is not enabled")
        }

        let rules = try execute(["-a", Self.anchor, "-sr"])
        try requireSuccess(rules, command: "pfctl -a <anchor> -sr")
        let lines = rules.stdout.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard lines.count == 2,
              lines[0].hasPrefix("pass quick on lo0 all"),
              lines[1].hasPrefix("block drop quick all") else {
            throw PFNetworkIsolationError.verificationFailed("anchor rules do not match the fixed policy")
        }
    }

    private func verifyIsolationRestored() throws {
        let rules = try execute(["-a", Self.anchor, "-sr"])
        try requireSuccess(rules, command: "pfctl -a <anchor> -sr")
        guard rules.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PFNetworkIsolationError.verificationFailed("anchor is not empty after restore")
        }
    }

    private func scheduleExpiryTimerLocked(for value: PFIsolationSnapshot) {
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.iven.macgametoolbox.pf-lease"))
        let delay = max(0.1, value.deadline.timeIntervalSinceNow)
        timer.schedule(deadline: .now() + delay, repeating: .never)
        timer.setEventHandler { [weak self] in
            self?.expireLease()
        }
        timer.resume()
        expiryTimer = timer
    }

    private func scheduleRecoveryRetryLocked() {
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.iven.macgametoolbox.pf-recovery"))
        timer.schedule(deadline: .now() + 5, repeating: .never)
        timer.setEventHandler { [weak self] in
            self?.retryRecovery()
        }
        timer.resume()
        expiryTimer = timer
    }

    private func expireLease() {
        lock.lock()
        defer { lock.unlock() }
        guard let current = snapshot, current.phase != .restored else { return }
        do {
            try restoreLocked(current, expectedRunID: current.runID, expectedToken: nil)
        } catch {
            capabilityLogger.error("PF lease expiry recovery failed: \(error.localizedDescription, privacy: .public)")
            scheduleRecoveryRetryLocked()
        }
    }

    private func retryRecovery() {
        lock.lock()
        defer { lock.unlock() }
        guard let current = snapshot, current.phase != .restored else { return }
        do {
            try restoreLocked(current, expectedRunID: current.runID, expectedToken: nil)
        } catch {
            capabilityLogger.error("PF recovery retry failed: \(error.localizedDescription, privacy: .public)")
            scheduleRecoveryRetryLocked()
        }
    }

    private func readSnapshot() throws -> PFIsolationSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
            guard let owner = attributes[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == snapshotOwnerID,
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o777 == 0o600 else {
                throw PFNetworkIsolationError.invalidSnapshot
            }
        } catch let error as PFNetworkIsolationError {
            throw error
        } catch {
            throw PFNetworkIsolationError.snapshotFailed(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(PFIsolationSnapshot.self, from: Data(contentsOf: snapshotURL))
        } catch {
            throw PFNetworkIsolationError.snapshotFailed(error.localizedDescription)
        }
    }

    private func writeSnapshot(_ value: PFIsolationSnapshot) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw PFNetworkIsolationError.snapshotFailed(error.localizedDescription)
        }

        let directory = snapshotURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(snapshotURL.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
        )
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            throw PFNetworkIsolationError.snapshotFailed(String(cString: strerror(errno)))
        }

        var isClosed = false
        var committed = false
        defer {
            if !isClosed { close(descriptor) }
            if !committed { unlink(temporaryURL.path) }
        }

        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else {
                        throw PFNetworkIsolationError.snapshotFailed(String(cString: strerror(errno)))
                    }
                    offset += written
                }
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fchown(descriptor, snapshotOwnerID, snapshotGroupID) == 0,
                  fsync(descriptor) == 0 else {
                throw PFNetworkIsolationError.snapshotFailed(String(cString: strerror(errno)))
            }
            guard close(descriptor) == 0 else {
                throw PFNetworkIsolationError.snapshotFailed(String(cString: strerror(errno)))
            }
            isClosed = true
            guard rename(temporaryURL.path, snapshotURL.path) == 0 else {
                throw PFNetworkIsolationError.snapshotFailed(String(cString: strerror(errno)))
            }
            committed = true
        } catch let error as PFNetworkIsolationError {
            throw error
        } catch {
            throw PFNetworkIsolationError.snapshotFailed(error.localizedDescription)
        }
    }

    private static func parsePFEnableToken(_ output: String) -> String? {
        let tokens = output.split { $0.isWhitespace || $0 == ":" }.map(String.init)
        for (index, token) in tokens.enumerated()
        where token.caseInsensitiveCompare("token") == .orderedSame {
            let nextIndex = index + 1
            if nextIndex < tokens.count, isValidPFEnableToken(tokens[nextIndex]) {
                return tokens[nextIndex]
            }
        }
        return nil
    }

    private static func isValidPFEnableToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Data(lhs.utf8)
        let right = Data(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) {
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// Formal-envelope adapter for the PF handler.  The legacy request switch does
/// not know about this capability; the helper composition root registers this
/// adapter in `PrivilegedCapabilityRegistry` for the new invocation path.
final class PFNetworkIsolationCapabilityAdapter: PrivilegedCapabilityHandling, @unchecked Sendable {
    private let handler: PFNetworkIsolationHandler
    private let reference: CapabilityReference

    init(handler: PFNetworkIsolationHandler) {
        self.handler = handler
        self.reference = CapabilityReference(
            id: PFNetworkIsolationHandler.capabilityID,
            version: PFNetworkIsolationHandler.contractVersion
        )
    }

    func invoke(_ invocation: CapabilityInvocationEnvelope) async throws -> CapabilityResultEnvelope {
        let payload = try JSONDecoder().decode(NetworkIsolationInput.self, from: invocation.inputPayload)
        let result: PFNetworkIsolationBeginResult
        let restored: Bool
        switch payload.action {
        case .begin:
            guard payload.tokenID == nil else {
                throw PFNetworkIsolationError.invalidLease
            }
            result = try handler.begin(
                runID: invocation.runID,
                leaseSeconds: TimeInterval(payload.leaseSeconds)
            )
            restored = false
        case .renew:
            guard let tokenID = payload.tokenID else {
                throw PFNetworkIsolationError.invalidRecoveryToken
            }
            result = try handler.renew(
                runID: invocation.runID,
                tokenID: tokenID,
                leaseSeconds: TimeInterval(payload.leaseSeconds)
            )
            restored = false
        case .restoreActive:
            let restoredResult = try handler.restoreActive()
            restored = restoredResult.didRestore
            result = PFNetworkIsolationBeginResult(
                recoveryToken: restoredResult.recoveryToken,
                deadline: restoredResult.deadline
            )
        }
        let output = try JSONEncoder().encode(
            NetworkIsolationOutput(deadline: result.deadline, restored: restored)
        )
        return CapabilityResultEnvelope(
            runID: invocation.runID,
            stepID: invocation.stepID,
            capability: reference,
            outputPayload: output,
            recoveryHandle: CapabilityRecoveryHandle(tokenID: result.recoveryToken.id, capability: reference)
        )
    }

    func recover(_ handle: CapabilityRecoveryHandle) async throws {
        try handler.recover(tokenID: handle.tokenID)
    }
}

func makePFNetworkIsolationContract() throws -> CapabilityContract {
    try NetworkIsolationCapability.contract()
}
