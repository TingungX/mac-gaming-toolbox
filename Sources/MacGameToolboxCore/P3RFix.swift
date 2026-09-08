import CryptoKit
import Foundation

/// Pinned P3RFix 1.2.4 Steam payload. Only aspect ratio, FOV, and HUD are
/// enabled; cinematic-bar mods and custom render resolutions are out of scope.
public enum P3RFixRelease: Sendable {
    public static let version = "1.2.4"
    public static let wineDllOverrides = "dsound=n,b"
    public static let dsoundDLLFileName = "dsound.dll"
    public static let asiFileName = "P3RFix.asi"
    public static let iniFileName = "P3RFix.ini"
    public static let dsoundDLLSHA256 = "bb8767f918c52a2ad055d2de9baffd2478598643b9894f09abd20d1f1ffd170c"
    public static let asiSHA256 = "636a222edbea5f0d8e0ea40bf733385b3caa19f4a864e66c95370fc3fb7902fd"

    /// Managed ini: gameplay letterbox only. Intro skip, console, FPS cap,
    /// mouse fix, and custom resolution stay off.
    public static let managedINI = """
        ; Managed by Mac Gaming Toolbox. Gameplay aspect/FOV/HUD only.
        ; P3RFix \(version) — https://github.com/Lyall/P3RFix

        [Custom Resolution]
        Enabled = false
        Width = 0
        Height = 0

        [Intro Skip]
        SkipLogos = false
        SkipTo = 2

        [Uncap 60FPS Menus]
        Enabled = false

        [Pause on Focus Loss]
        Enabled = true

        [Enable Console]
        Enabled = false

        [Fix HUD]
        Enabled = true

        [Fix Aspect Ratio]
        Enabled = true

        [Fix FOV]
        Enabled = true

        [Screen Percentage]
        Enabled = false
        Value = 100

        [Render Texture Resolution]
        Enabled = true
        Multiplier = 1

        [FPS Cap]
        AdjustFPSCap = false
        Framerate = 120

        [Mouse Fix]
        Enabled = false
        IgnoreGamepad = true
        MouseMultiplierX = 1.0
        MouseMultiplierY = 1.0

        """
}

public struct P3RFixPayload: Equatable, Sendable {
    public let dsoundDLL: Data
    public let asi: Data

    public init(dsoundDLL: Data, asi: Data) {
        self.dsoundDLL = dsoundDLL
        self.asi = asi
    }

    public func verified() throws -> P3RFixPayload {
        try Self.requireHash(dsoundDLL, P3RFixRelease.dsoundDLLSHA256, P3RFixRelease.dsoundDLLFileName)
        try Self.requireHash(asi, P3RFixRelease.asiSHA256, P3RFixRelease.asiFileName)
        return self
    }

    private static func requireHash(_ data: Data, _ expected: String, _ name: String) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw P3RFixInstallError.payloadHashMismatch(name)
        }
    }
}

public enum P3RFixInstallError: Error, Equatable, LocalizedError {
    case payloadEmpty
    case payloadHashMismatch(String)
    case executableNotFound
    case destinationEscapedBottle

    public var errorDescription: String? {
        switch self {
        case .payloadEmpty:
            coreText("P3RFix 安装包为空", "The P3RFix payload is empty")
        case .payloadHashMismatch(let name):
            coreText("P3RFix 文件校验失败：\(name)", "P3RFix file hash mismatch: \(name)")
        case .executableNotFound:
            coreText("找不到 P3R.exe，无法安装去黑边补丁", "P3R.exe was not found, so the aspect-ratio fix cannot be installed")
        case .destinationEscapedBottle:
            coreText("P3R 安装路径超出当前 CrossOver 容器", "The P3R path is outside the current CrossOver bottle")
        }
    }
}

/// Copies the ASI loader and P3RFix next to `P3R.exe` and writes the managed ini.
public enum P3RFixInstaller: Sendable {
    public static func install(
        payload: P3RFixPayload,
        executableURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !payload.dsoundDLL.isEmpty, !payload.asi.isEmpty else {
            throw P3RFixInstallError.payloadEmpty
        }
        let executable = executableURL.standardizedFileURL
        guard fileManager.fileExists(atPath: executable.path) else {
            throw P3RFixInstallError.executableNotFound
        }
        let directory = executable.deletingLastPathComponent()
        try write(payload.dsoundDLL, to: directory.appendingPathComponent(P3RFixRelease.dsoundDLLFileName), fileManager: fileManager)
        try write(payload.asi, to: directory.appendingPathComponent(P3RFixRelease.asiFileName), fileManager: fileManager)
        try write(
            Data(P3RFixRelease.managedINI.utf8),
            to: directory.appendingPathComponent(P3RFixRelease.iniFileName),
            fileManager: fileManager
        )
    }

    private static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path),
           let existing = try? Data(contentsOf: url),
           existing == data {
            return
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
