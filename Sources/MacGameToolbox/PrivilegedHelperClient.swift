import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif
import OSLog
import Security

public final class PrivilegedHelperClient: PrivilegedOperating, PrivilegedCapabilityOperating, @unchecked Sendable {
    static let serviceName = "com.iven.macgametoolbox.helper.v8"
    static let installedHelperPath = "/Library/PrivilegedHelperTools/com.iven.macgametoolbox.helper.v8"
    private let coordinator = PrivilegedHelperCoordinator()

    public init() {}

    public func diagnosticStatus() -> String {
        let installed = FileManager.default.fileExists(atPath: Self.installedHelperPath)
        let signing = Self.teamIdentifier() == nil ? "development signing" : "Developer ID signing"
        return "persistent helper v8: \(installed ? "installed" : "not installed"), \(signing)"
    }

    public func perform(_ operation: PrivilegedOperation) async throws {
        try await coordinator.perform(Self.request(for: operation))
    }

    public func invoke(_ invocation: CapabilityInvocationEnvelope) async throws -> CapabilityResultEnvelope {
        let response = try await coordinator.performCapability(.invoke(invocation))
        guard case .invocation(let result) = response else {
            throw ToolboxError.malformedOutput("Helper returned the wrong capability response")
        }
        return result
    }

    public func recover(_ handle: CapabilityRecoveryHandle) async throws {
        let response: PrivilegedCapabilityXPCResponse
        do {
            response = try await coordinator.performCapability(.recover(handle))
        } catch ToolboxError.helperTimedOut {
            // Capability contracts require idempotent recovery, so repeating
            // the same opaque handle is safe when the first XPC reply was lost.
            response = try await coordinator.performCapability(.recover(handle))
        }
        guard case .recoveryCompleted = response else {
            throw ToolboxError.malformedOutput("Helper returned the wrong recovery response")
        }
    }

    static func request(for operation: PrivilegedOperation) throws -> PrivilegedRequest {
        switch operation {
        case .healthCheck: return .healthCheck
        case .addHoYoHosts: return .addHoYoHosts
        case .removeHoYoHosts: return .removeHoYoHosts
        case .clearSystemCaches: return .clearSystemCaches
        case .renice(let pids):
            if pids.isEmpty || pids.count > 64 || pids.contains(where: { $0 <= 1 }) {
                throw ToolboxError.commandFailed("Invalid process list")
            }
            return .renice(pids)
        case .setHostnames(let names):
            guard InputValidation.computerName(names.computerName),
                  InputValidation.hostname(names.hostName),
                  InputValidation.hostname(names.localHostName) else {
                throw ToolboxError.commandFailed("Invalid hostname")
            }
            return .setHostnames(names)
        case .createDirectory(let path):
            return .createDirectory(try InputValidation.normalizedAbsolutePath(path))
        }
    }

    private static func teamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

private actor PrivilegedHelperCoordinator {
    private let logger = Logger(subsystem: "com.iven.macgametoolbox", category: "PrivilegedClient")
    private var installedThisSession = false

    func perform(_ request: PrivilegedRequest) async throws {
        if !FileManager.default.fileExists(atPath: PrivilegedHelperClient.installedHelperPath) {
            try await install()
        }
        let data = try JSONEncoder().encode(request)
        logger.info("Sending persistent helper request: \(String(describing: request), privacy: .public)")
        DiagnosticFileLogger.write("Sending persistent helper request: \(String(describing: request))")

        do {
            try await sendWithStartupRetries(data)
        } catch let error as ToolboxError {
            guard case .helperUnavailable = error, !installedThisSession else { throw error }
            try await install()
            try await sendWithStartupRetries(data)
        }
        DiagnosticFileLogger.write("Persistent helper request completed")
    }

    func performCapability(
        _ request: PrivilegedCapabilityXPCRequest
    ) async throws -> PrivilegedCapabilityXPCResponse {
        if !FileManager.default.fileExists(atPath: PrivilegedHelperClient.installedHelperPath) {
            try await install()
        }
        let data = try JSONEncoder().encode(request)
        guard data.count <= PrivilegedCapabilityXPC.maximumEnvelopeBytes else {
            throw ToolboxError.commandFailed("Capability request envelope is too large")
        }
        DiagnosticFileLogger.write("Sending persistent helper capability request")

        let response: PrivilegedCapabilityXPCResponse
        do {
            response = try await sendCapabilityWithStartupRetries(data)
        } catch let error as ToolboxError {
            guard case .helperUnavailable = error, !installedThisSession else { throw error }
            try await install()
            response = try await sendCapabilityWithStartupRetries(data)
        }
        DiagnosticFileLogger.write("Persistent helper capability request completed")
        return response
    }

    private func install() async throws {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/MacGameToolboxPrivilegedHelper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path),
              Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Mac 游戏工具箱.app" else {
            throw ToolboxError.helperUnavailable("Install the app in /Applications before enabling privileged features")
        }
        DiagnosticFileLogger.write("Requesting one-time persistent helper installation")
        let script = """
        on run argv
            do shell script quoted form of (item 1 of argv) & " --install " & quoted form of (item 2 of argv) with administrator privileges
        end run
        """
        let result: (Int32, String) = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, "--", helperURL.path, Bundle.main.bundleURL.path]
            process.standardOutput = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, message)
        }.value
        guard result.0 == 0 else {
            if result.1.contains("(-128)") { throw ToolboxError.authorizationCancelled }
            throw ToolboxError.helperUnavailable(result.1.isEmpty ? "Helper installation failed" : result.1)
        }
        installedThisSession = true
        DiagnosticFileLogger.write("Persistent helper installation completed")
    }

    private func sendWithStartupRetries(_ data: Data) async throws {
        var lastError: Error = ToolboxError.helperUnavailable("XPC service did not start")
        for attempt in 0..<5 {
            do {
                try await sendOnce(data)
                return
            } catch let error as ToolboxError {
                lastError = error
                guard case .helperUnavailable = error, attempt < 4 else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }

    private func sendOnce(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(machServiceName: PrivilegedHelperClient.serviceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
            let reply = XPCReply<Void>(connection: connection, continuation: continuation)
            connection.interruptionHandler = { reply.finish(.failure(ToolboxError.helperUnavailable("XPC connection interrupted"))) }
            connection.invalidationHandler = { reply.finish(.failure(ToolboxError.helperUnavailable("XPC connection invalidated"))) }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.finish(.failure(ToolboxError.helperUnavailable(error.localizedDescription)))
            }) as? PrivilegedHelperXPCProtocol else {
                reply.finish(.failure(ToolboxError.helperUnavailable("Invalid XPC proxy")))
                return
            }
            proxy.perform(request: data) { success, message in
                reply.finish(success
                    ? .success(())
                    : .failure(ToolboxError.commandFailed(message ?? "Privileged operation failed")))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                reply.finish(.failure(ToolboxError.helperTimedOut))
            }
        }
    }

    private func sendCapabilityWithStartupRetries(
        _ data: Data
    ) async throws -> PrivilegedCapabilityXPCResponse {
        var lastError: Error = ToolboxError.helperUnavailable("XPC service did not start")
        for attempt in 0..<5 {
            do {
                return try await sendCapabilityOnce(data)
            } catch let error as ToolboxError {
                lastError = error
                guard case .helperUnavailable = error, attempt < 4 else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }

    private func sendCapabilityOnce(
        _ data: Data
    ) async throws -> PrivilegedCapabilityXPCResponse {
        let responseData: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let connection = NSXPCConnection(
                machServiceName: PrivilegedHelperClient.serviceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
            let reply = XPCReply<Data>(connection: connection, continuation: continuation)
            connection.interruptionHandler = {
                reply.finish(.failure(ToolboxError.helperUnavailable("XPC connection interrupted")))
            }
            connection.invalidationHandler = {
                reply.finish(.failure(ToolboxError.helperUnavailable("XPC connection invalidated")))
            }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.finish(.failure(ToolboxError.helperUnavailable(error.localizedDescription)))
            }) as? PrivilegedHelperXPCProtocol else {
                reply.finish(.failure(ToolboxError.helperUnavailable("Invalid XPC proxy")))
                return
            }
            proxy.performCapability(request: data) { response, error in
                guard let response else {
                    reply.finish(.failure(ToolboxError.commandFailed(error ?? "Privileged capability failed")))
                    return
                }
                guard response.count <= PrivilegedCapabilityXPC.maximumEnvelopeBytes else {
                    reply.finish(.failure(ToolboxError.malformedOutput("Capability response envelope is too large")))
                    return
                }
                reply.finish(.success(response))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                reply.finish(.failure(ToolboxError.helperTimedOut))
            }
        }
        do {
            return try JSONDecoder().decode(PrivilegedCapabilityXPCResponse.self, from: responseData)
        } catch {
            throw ToolboxError.malformedOutput(error.localizedDescription)
        }
    }
}

private final class XPCReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var connection: NSXPCConnection?

    init(connection: NSXPCConnection, continuation: CheckedContinuation<Value, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        continuation.resume(with: result)
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
    }
}
