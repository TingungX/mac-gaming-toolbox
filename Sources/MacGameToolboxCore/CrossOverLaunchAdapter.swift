import Foundation

/// Errors raised while validating a CrossOver launch description.
public enum CrossOverLaunchError: Error, Equatable, Sendable {
    case invalidCrossOverApp
    case invalidBottle
    case invalidExecutablePath
    case invalidWorkingDirectory
    case invalidLogFile
    case invalidWineDllOverrides
}

/// A CrossOver application bundle. The bundle is only used to derive cxstart;
/// it is never passed through a shell or interpolated into a command string.
public struct CrossOverApp: Equatable, Hashable, Sendable {
    public let url: URL

    public init(url: URL) throws {
        let normalized = url.standardizedFileURL
        guard normalized.isFileURL,
              normalized.path.hasPrefix("/"),
              normalized.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              !normalized.path.contains("\0") else {
            throw CrossOverLaunchError.invalidCrossOverApp
        }
        self.url = normalized
    }

    public var cxstartURL: URL {
        url.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/cxstart")
    }
}

/// A validated CrossOver bottle name.
public struct CrossOverBottle: Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard Self.isValid(value) else {
            throw CrossOverLaunchError.invalidBottle
        }
        self.value = value
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.count <= 256 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f && scalar != "/" && scalar != "\\"
        }
    }
}

/// A validated Windows executable path accepted by cxstart.
public struct CrossOverExecutablePath: Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard Self.isValid(value, requireExecutableExtension: true) else {
            throw CrossOverLaunchError.invalidExecutablePath
        }
        self.value = value
    }

    fileprivate static func isValid(_ value: String, requireExecutableExtension: Bool) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.count <= 4_096,
              !value.hasPrefix("-") else {
            return false
        }

        let forbidden: Set<UnicodeScalar> = ["\0", "\r", "\n", "\"", "<", ">", "|", "?", "*"]
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f && !forbidden.contains(scalar)
        }) else {
            return false
        }

        guard requireExecutableExtension else { return true }
        let leaf = value.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? value
        return leaf.lowercased().hasSuffix(".exe")
    }
}

/// A validated Windows working directory. It is kept distinct from an
/// executable path so callers cannot accidentally swap the two fields.
public struct CrossOverWorkingDirectory: Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard CrossOverExecutablePath.isValid(value, requireExecutableExtension: false) else {
            throw CrossOverLaunchError.invalidWorkingDirectory
        }
        self.value = value
    }
}

/// The only persisted inputs accepted by the CrossOver launch adapter.
public struct CrossOverLaunchConfiguration: Equatable, Sendable {
    public let crossOverApp: CrossOverApp
    public let bottle: CrossOverBottle
    public let executable: CrossOverExecutablePath
    public let workingDirectory: CrossOverWorkingDirectory?

    public init(
        crossOverApp: CrossOverApp,
        bottle: CrossOverBottle,
        executable: CrossOverExecutablePath,
        workingDirectory: CrossOverWorkingDirectory? = nil
    ) {
        self.crossOverApp = crossOverApp
        self.bottle = bottle
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    public init(
        crossOverAppURL: URL,
        bottle: String,
        executablePath: String,
        workingDirectoryPath: String? = nil
    ) throws {
        let workingDirectory = try workingDirectoryPath.map(CrossOverWorkingDirectory.init)
        self.init(
            crossOverApp: try CrossOverApp(url: crossOverAppURL),
            bottle: try CrossOverBottle(bottle),
            executable: try CrossOverExecutablePath(executablePath),
            workingDirectory: workingDirectory
        )
    }
}

/// An argv-based process description. A caller can pass this directly to
/// Foundation.Process without involving a shell.
public struct CrossOverProcessLaunchDescription: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let traceLogURL: URL
    public let extraEnvironment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String],
        traceLogURL: URL,
        extraEnvironment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.traceLogURL = traceLogURL
        self.extraEnvironment = extraEnvironment
    }
}

/// Builds a safe cxstart invocation. This adapter does not launch a process
/// and intentionally has no API for arbitrary game arguments or shell code.
public struct CrossOverLaunchAdapter: Sendable {
    public static let defaultDebugChannels = "+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname"

    private let configuration: CrossOverLaunchConfiguration

    public init(configuration: CrossOverLaunchConfiguration) {
        self.configuration = configuration
    }

    public func makeProcessLaunchDescription(
        logFileURL: URL,
        wineDllOverrides: String? = nil
    ) throws -> CrossOverProcessLaunchDescription {
        let normalizedLogURL = logFileURL.standardizedFileURL
        guard normalizedLogURL.isFileURL,
              normalizedLogURL.path.hasPrefix("/"),
              normalizedLogURL.path != "/",
              normalizedLogURL.path.unicodeScalars.count <= 4_096,
              normalizedLogURL.path.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7f
              }) else {
            throw CrossOverLaunchError.invalidLogFile
        }

        var extraEnvironment: [String: String] = [:]
        if let wineDllOverrides {
            guard wineDllOverrides == P3RFixRelease.wineDllOverrides else {
                throw CrossOverLaunchError.invalidWineDllOverrides
            }
            extraEnvironment["WINEDLLOVERRIDES"] = wineDllOverrides
        }

        var arguments = ["--bottle", configuration.bottle.value]
        if let workingDirectory = configuration.workingDirectory {
            arguments += ["--workdir", workingDirectory.value]
        }
        arguments += [
            "--cx-log", normalizedLogURL.path,
            "--debugmsg", Self.defaultDebugChannels,
            configuration.executable.value
        ]

        return CrossOverProcessLaunchDescription(
            executableURL: configuration.crossOverApp.cxstartURL,
            arguments: arguments,
            traceLogURL: normalizedLogURL,
            extraEnvironment: extraEnvironment
        )
    }
}

/// Asks a bottle's wineserver to tear down its Windows processes. This is the
/// CrossOver-supported way to force-quit a hung `YuanShen.exe` after an in-game
/// exit; PID signals remain as a follow-up for anything that survives.
public enum CrossOverBottleShutdown {
    public static func wineserverURL(applicationPath: String) -> URL {
        URL(fileURLWithPath: applicationPath)
            .appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wineserver")
    }

    public static func winePrefix(
        bottle: String,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeURL.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles/\(bottle)",
            isDirectory: true
        )
    }

    public static func requestWineserverExit(
        applicationPath: String,
        bottle: String,
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        run: (URL, URL) -> Void = { wineserver, prefix in
            let process = Process()
            process.executableURL = wineserver
            process.arguments = ["-k"]
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefix.path
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    ) {
        let wineserver = wineserverURL(applicationPath: applicationPath)
        let prefix = winePrefix(bottle: bottle, homeURL: homeURL)
        guard fileManager.isExecutableFile(atPath: wineserver.path) else { return }
        run(wineserver, prefix)
    }
}
