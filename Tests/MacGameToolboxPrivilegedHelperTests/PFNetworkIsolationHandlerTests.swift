import Darwin
import Foundation
import MacGameToolboxCore
import Testing
@testable import MacGameToolboxPrivilegedHelper

private struct StubPFConfigurationReader: PFConfigurationReading {
    let hasAnchor: Bool

    func containsComAppleWildcardAnchor() throws -> Bool {
        hasAnchor
    }
}

private final class FakePFCommandExecutor: PFCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocations: [[String]] = []
    var reportsExpectedRules = true
    private var anchorLoaded = false

    func execute(arguments: [String], input: Data?) throws -> PFCommandResult {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(arguments)

        switch arguments {
        case ["-E"]:
            return success(stdout: "pf enabled\nToken : 4242")
        case ["-a", PFNetworkIsolationHandler.anchor, "-f", "-"]:
            guard input == Data(PFNetworkIsolationHandler.rules.utf8) else {
                return failure("unexpected rules")
            }
            anchorLoaded = true
            return success()
        case ["-F", "states"]:
            return success()
        case ["-s", "info"]:
            return success(stdout: "Status: Enabled for 0 days")
        case ["-a", PFNetworkIsolationHandler.anchor, "-sr"]:
            guard anchorLoaded else { return success() }
            if reportsExpectedRules {
                return success(stdout: "pass quick on lo0 all flags S/SA\nblock drop quick all")
            }
            return success(stdout: "pass all")
        case ["-a", PFNetworkIsolationHandler.anchor, "-F", "all"]:
            anchorLoaded = false
            return success()
        case ["-X", "4242"]:
            return success()
        default:
            return failure("unexpected command: \(arguments.joined(separator: " "))")
        }
    }

    private func success(stdout: String = "") -> PFCommandResult {
        PFCommandResult(terminationStatus: 0, stdout: stdout, stderr: "")
    }

    private func failure(_ message: String) -> PFCommandResult {
        PFCommandResult(terminationStatus: 1, stdout: "", stderr: message)
    }
}

private func makeTemporarySnapshotURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-game-toolbox-pf-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("snapshot.json")
}

private func makeHandler(
    executor: FakePFCommandExecutor,
    snapshotURL: URL,
    hasAnchor: Bool = true
) -> PFNetworkIsolationHandler {
    PFNetworkIsolationHandler(
        executor: executor,
        configurationReader: StubPFConfigurationReader(hasAnchor: hasAnchor),
        snapshotURL: snapshotURL,
        isRunningAsRoot: { true },
        snapshotOwnerID: geteuid(),
        snapshotGroupID: getegid()
    )
}

@Test func pfIsolationLoadsOnlyFixedAnchorAndRestoresOwnedEnableToken() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    let executor = FakePFCommandExecutor()
    let handler = makeHandler(executor: executor, snapshotURL: snapshotURL)
    let runID = UUID()

    let result = try handler.begin(runID: runID, leaseSeconds: 60)
    #expect(handler.hasActiveLease)
    #expect(executor.invocations == [
        ["-E"],
        ["-a", PFNetworkIsolationHandler.anchor, "-f", "-"],
        ["-F", "states"],
        ["-s", "info"],
        ["-a", PFNetworkIsolationHandler.anchor, "-sr"]
    ])

    try handler.restore(runID: runID, recoveryToken: result.recoveryToken)
    #expect(!handler.hasActiveLease)
    #expect(executor.invocations.suffix(3) == [
        ["-a", PFNetworkIsolationHandler.anchor, "-F", "all"],
        ["-a", PFNetworkIsolationHandler.anchor, "-sr"],
        ["-X", "4242"]
    ])

    let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let invocationCount = executor.invocations.count
    try handler.restore(runID: runID, recoveryToken: result.recoveryToken)
    #expect(executor.invocations.count == invocationCount)
}

@Test func pfIsolationRejectsMissingWildcardBeforeChangingPF() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    let executor = FakePFCommandExecutor()
    let handler = makeHandler(executor: executor, snapshotURL: snapshotURL, hasAnchor: false)

    #expect(throws: PFNetworkIsolationError.missingComAppleWildcardAnchor) {
        try handler.begin(runID: UUID(), leaseSeconds: 60)
    }
    #expect(executor.invocations.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
}

@Test func persistedActiveLeaseCanBeRestoredAfterHelperRestart() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    let executor = FakePFCommandExecutor()
    let runID = UUID()
    let firstHandler = makeHandler(executor: executor, snapshotURL: snapshotURL)
    let result = try firstHandler.begin(runID: runID, leaseSeconds: 60)

    let restartedHandler = makeHandler(executor: executor, snapshotURL: snapshotURL)
    #expect(restartedHandler.hasActiveLease)
    try restartedHandler.restore(runID: runID, recoveryToken: result.recoveryToken)

    #expect(!restartedHandler.hasActiveLease)
    #expect(executor.invocations.suffix(3) == [
        ["-a", PFNetworkIsolationHandler.anchor, "-F", "all"],
        ["-a", PFNetworkIsolationHandler.anchor, "-sr"],
        ["-X", "4242"]
    ])
}

@Test func renewalKeepsTheSameOpaqueHandleWithoutReloadingRules() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    let executor = FakePFCommandExecutor()
    let handler = makeHandler(executor: executor, snapshotURL: snapshotURL)
    let runID = UUID()
    let initial = try handler.begin(runID: runID, leaseSeconds: 30)
    let commandCount = executor.invocations.count

    let renewed = try handler.renew(
        runID: runID,
        tokenID: initial.recoveryToken.id,
        leaseSeconds: 60
    )

    #expect(renewed.recoveryToken == initial.recoveryToken)
    #expect(renewed.deadline > initial.deadline)
    #expect(executor.invocations.count == commandCount)
    try handler.restore(runID: runID, recoveryToken: renewed.recoveryToken)
}

@Test func pfIsolationVerificationFailureRunsTheSameRestorePath() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    let executor = FakePFCommandExecutor()
    executor.reportsExpectedRules = false
    let handler = makeHandler(executor: executor, snapshotURL: snapshotURL)

    #expect(throws: PFNetworkIsolationError.verificationFailed("anchor rules do not match the fixed policy")) {
        try handler.begin(runID: UUID(), leaseSeconds: 60)
    }
    #expect(!handler.hasActiveLease)
    #expect(executor.invocations.suffix(3) == [
        ["-a", PFNetworkIsolationHandler.anchor, "-F", "all"],
        ["-a", PFNetworkIsolationHandler.anchor, "-sr"],
        ["-X", "4242"]
    ])
}

@Test func corruptRootSnapshotStillClearsTheOwnedAnchor() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    try Data("not-json".utf8).write(to: snapshotURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: snapshotURL.path
    )
    let executor = FakePFCommandExecutor()

    let handler = makeHandler(executor: executor, snapshotURL: snapshotURL)

    #expect(!handler.hasActiveLease)
    #expect(executor.invocations == [
        ["-a", PFNetworkIsolationHandler.anchor, "-F", "all"],
        ["-a", PFNetworkIsolationHandler.anchor, "-sr"]
    ])
}

@Test func everyLegacyRequestMapsToExactlyOneCapabilityHandler() {
    let handlers: [any HelperPrivilegedCapabilityHandling] = [
        HelperHealthCheckCapabilityHandler(),
        HelperHostsCapabilityHandler(),
        HelperProcessQoSCapabilityHandler(),
        HelperCacheCapabilityHandler(),
        HelperHostnamesCapabilityHandler(),
        HelperDirectoryCapabilityHandler()
    ]
    let requests: [PrivilegedRequest] = [
        .healthCheck,
        .addHoYoHosts,
        .removeHoYoHosts,
        .renice([42]),
        .clearSystemCaches,
        .setHostnames(HostnameBackup(
            computerName: "Mac",
            hostName: "mac.local",
            localHostName: "mac"
        )),
        .createDirectory("/Users/test/Games")
    ]

    for request in requests {
        #expect(handlers.filter { $0.handles(request) }.count == 1)
    }
}

@Test func restoreActiveClearsTheCurrentLeaseWithoutACallerToken() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    let executor = FakePFCommandExecutor()
    let handler = makeHandler(executor: executor, snapshotURL: snapshotURL)
    _ = try handler.begin(runID: UUID(), leaseSeconds: 60)

    let restored = try handler.restoreActive()
    #expect(restored.didRestore)
    #expect(!handler.hasActiveLease)

    let noop = try handler.restoreActive()
    #expect(!noop.didRestore)
}

@Test func persistedActiveLeaseIsRestoredWhenPFStateNoLongerMatches() throws {
    let snapshotURL = try makeTemporarySnapshotURL()
    defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }
    let firstExecutor = FakePFCommandExecutor()
    let firstHandler = makeHandler(executor: firstExecutor, snapshotURL: snapshotURL)
    _ = try firstHandler.begin(runID: UUID(), leaseSeconds: 60)
    #expect(firstHandler.hasActiveLease)

    let rebootExecutor = FakePFCommandExecutor()
    let restartedHandler = makeHandler(executor: rebootExecutor, snapshotURL: snapshotURL)
    #expect(!restartedHandler.hasActiveLease)
    #expect(rebootExecutor.invocations.contains(["-a", PFNetworkIsolationHandler.anchor, "-F", "all"]))
}
