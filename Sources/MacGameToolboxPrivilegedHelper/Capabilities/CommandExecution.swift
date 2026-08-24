import Foundation
import OSLog

let capabilityLogger = Logger(subsystem: "com.iven.macgametoolbox", category: "PrivilegedCapability")

/// Runs fixed, helper-owned executables for capability handlers and helper setup.
///
/// Callers provide argument arrays rather than shell text.  Keeping this helper
/// separate makes the command boundary explicit without introducing a generic
/// command capability for workflows.
func run(_ executable: String, _ arguments: [String]) throws {
    _ = try runCapturing(executable, arguments)
}

@discardableResult
func runCapturing(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw HelperError.commandFailed(stderr.isEmpty ? "Command failed (\(process.terminationStatus))" : stderr)
    }
    return stdout
}
