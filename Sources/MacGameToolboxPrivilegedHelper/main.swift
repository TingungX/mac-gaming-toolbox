import Darwin
import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif
import Security
import OSLog

private let serviceName = "com.iven.macgametoolbox.helper.v8"
private let installedHelperPath = "/Library/PrivilegedHelperTools/com.iven.macgametoolbox.helper.v8"
private let installedPlistPath = "/Library/LaunchDaemons/com.iven.macgametoolbox.helper.v8.plist"
private let requirementPath = "/Library/PrivilegedHelperTools/com.iven.macgametoolbox.helper.v8.requirement"
private let expectedAppPath = "/Applications/Mac 游戏工具箱.app"
private let logger = Logger(subsystem: "com.iven.macgametoolbox", category: "PrivilegedHelper")

enum HelperError: LocalizedError {
    case notRoot, invalidClient, invalidArguments, invalidPath, invalidProcess, commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .notRoot: "Helper is not running as root"
        case .invalidClient: "Untrusted XPC client"
        case .invalidArguments: "Invalid privileged operation arguments"
        case .invalidPath: "Invalid directory path"
        case .invalidProcess: "Invalid or missing process"
        case .commandFailed(let message): message
        }
    }
}

final class HelperService: NSObject, PrivilegedHelperXPCProtocol, @unchecked Sendable {
    private let compositionRoot = HelperCapabilityCompositionRoot.builtIn()

    func perform(request: Data, withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            guard geteuid() == 0 else { throw HelperError.notRoot }
            let request = try JSONDecoder().decode(PrivilegedRequest.self, from: request)
            logger.info("Received request: \(String(describing: request), privacy: .public)")
            try performValidated(request)
            reply(true, nil)
        } catch {
            logger.error("Request failed: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func performCapability(request: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard request.count <= PrivilegedCapabilityXPC.maximumEnvelopeBytes else {
            reply(nil, "Capability request envelope is too large")
            return
        }

        let replyBox = CapabilityXPCReply(reply)
        Task {
            do {
                guard geteuid() == 0 else { throw HelperError.notRoot }
                let request = try JSONDecoder().decode(PrivilegedCapabilityXPCRequest.self, from: request)
                let response: PrivilegedCapabilityXPCResponse
                switch request {
                case .invoke(let invocation):
                    let result = try await compositionRoot.privilegedRegistry.invoke(invocation)
                    response = .invocation(result)
                case .recover(let handle):
                    try await compositionRoot.privilegedRegistry.recover(handle)
                    response = .recoveryCompleted
                }
                let data = try JSONEncoder().encode(response)
                guard data.count <= PrivilegedCapabilityXPC.maximumEnvelopeBytes else {
                    throw HelperError.commandFailed("Capability response envelope is too large")
                }
                replyBox.finish(data, nil)
            } catch {
                logger.error("Capability request failed: \(error.localizedDescription, privacy: .public)")
                replyBox.finish(nil, error.localizedDescription)
            }
        }
    }

    private func performValidated(_ request: PrivilegedRequest) throws {
        try compositionRoot.legacyRegistry.dispatch(request)
    }

}

private final class CapabilityXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data?, String?) -> Void)?

    init(_ reply: @escaping (Data?, String?) -> Void) {
        self.reply = reply
    }

    func finish(_ data: Data?, _ error: String?) {
        lock.lock()
        guard let reply else {
            lock.unlock()
            return
        }
        self.reply = nil
        lock.unlock()
        reply(data, error)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard trustedClient(connection) else {
            logger.error("Rejected XPC client pid \(connection.processIdentifier)")
            return false
        }
        logger.info("Accepted XPC client pid \(connection.processIdentifier)")
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    private func trustedClient(_ connection: NSXPCConnection) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }

        let appURL = URL(fileURLWithPath: expectedAppPath)
        guard appURL.pathExtension == "app",
              let appBundle = Bundle(url: appURL),
              let expectedExecutable = appBundle.executableURL?.standardizedFileURL else { return false }
        var clientURL: CFURL?
        guard SecCodeCopyPath(staticCode, [], &clientURL) == errSecSuccess,
              let clientPath = (clientURL as URL?)?.standardizedFileURL,
              clientPath == appURL.standardizedFileURL || clientPath == expectedExecutable else { return false }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String == "com.iven.macgametoolbox" else { return false }

        guard let requirementText = try? String(contentsOfFile: requirementPath, encoding: .utf8),
              !requirementText.isEmpty else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
}

func containingAppURL() -> URL? {
    var selfCode: SecCode?
    var staticCode: SecStaticCode?
    var executableURL: CFURL?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
          SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopyPath(staticCode, [], &executableURL) == errSecSuccess,
          var url = executableURL as URL? else { return nil }
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url.standardizedFileURL
}

func installPersistentHelper(for appPath: String) throws {
    guard URL(fileURLWithPath: appPath).standardizedFileURL.path == expectedAppPath else { throw HelperError.invalidPath }
    let appURL = URL(fileURLWithPath: expectedAppPath)
    var appCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &appCode) == errSecSuccess, let appCode,
          SecStaticCodeCheckValidity(appCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
        throw HelperError.invalidClient
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(appCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let dictionary = information as? [String: Any],
          dictionary[kSecCodeInfoIdentifier as String] as? String == "com.iven.macgametoolbox" else {
        throw HelperError.invalidClient
    }
    var requirement: SecRequirement?
    var requirementText: CFString?
    guard SecCodeCopyDesignatedRequirement(appCode, [], &requirement) == errSecSuccess, let requirement,
          SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
          let requirementText else { throw HelperError.invalidClient }

    let fileManager = FileManager.default
    try fileManager.createDirectory(atPath: "/Library/PrivilegedHelperTools", withIntermediateDirectories: true)
    _ = try? run("/bin/launchctl", ["bootout", "system/\(serviceName)"])

    guard let sourceURL = selfExecutableURL() else { throw HelperError.invalidPath }
    if fileManager.fileExists(atPath: installedHelperPath) { try fileManager.removeItem(atPath: installedHelperPath) }
    try fileManager.copyItem(at: sourceURL, to: URL(fileURLWithPath: installedHelperPath))
    try fileManager.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: installedHelperPath)

    try (requirementText as String).write(toFile: requirementPath, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: requirementPath)

    let plist: [String: Any] = [
        "Label": serviceName,
        "ProgramArguments": [installedHelperPath],
        "MachServices": [serviceName: true],
        "RunAtLoad": true
    ]
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: URL(fileURLWithPath: installedPlistPath), options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: installedPlistPath)
    try run("/bin/launchctl", ["bootstrap", "system", installedPlistPath])
}

func selfExecutableURL() -> URL? {
    var selfCode: SecCode?
    var staticCode: SecStaticCode?
    var executableURL: CFURL?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
          SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopyPath(staticCode, [], &executableURL) == errSecSuccess else { return nil }
    return executableURL as URL?
}

guard geteuid() == 0 else { fatalError(HelperError.notRoot.localizedDescription) }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--install" {
    do {
        try installPersistentHelper(for: CommandLine.arguments[2])
        exit(EXIT_SUCCESS)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: serviceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
