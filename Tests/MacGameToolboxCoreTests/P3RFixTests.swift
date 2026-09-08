import Foundation
import Testing
@testable import MacGameToolboxCore

@Test func p3rAndDemoInstallAspectFixAndPreferWin64Executable() {
    #expect(BuiltInDirectLaunchWorkflows.p3r.installsP3RFix)
    #expect(BuiltInDirectLaunchWorkflows.p3rDemo.installsP3RFix)
    #expect(
        BuiltInDirectLaunchWorkflows.p3r.executableRelativeCandidates.first
            == "Program Files (x86)/Steam/steamapps/common/P3R/P3R/Binaries/Win64/P3R.exe"
    )
    #expect(
        BuiltInDirectLaunchWorkflows.p3rDemo.executableRelativeCandidates.contains {
            $0.hasSuffix("P3R Demo/P3R/Binaries/Win64/P3R.exe")
        }
    )
}

@Test func p3rFixManagedINIEnablesOnlyGameplayAspectFixes() {
    let ini = P3RFixRelease.managedINI
    #expect(ini.contains("[Fix Aspect Ratio]"))
    #expect(ini.contains("[Fix FOV]"))
    #expect(ini.contains("[Fix HUD]"))
    #expect(ini.contains("SkipLogos = false"))
    #expect(ini.contains("[Enable Console]\nEnabled = false") || ini.contains("Enabled = false\n\n[Fix HUD]"))
    #expect(!ini.contains("SkipLogos = true"))
    #expect(ini.contains("[Custom Resolution]"))
    #expect(ini.contains("Enabled = false"))
    #expect(!ini.contains("No Cinematic"))
}

@Test func p3rFixInstallerWritesLoaderAndManagedININextToExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent("Win64", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let exe = directory.appendingPathComponent("P3R.exe")
    try Data("exe".utf8).write(to: exe)
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = P3RFixPayload(dsoundDLL: Data("dsound-bytes".utf8), asi: Data("asi-bytes".utf8))
    try P3RFixInstaller.install(payload: payload, executableURL: exe)

    #expect(try Data(contentsOf: directory.appendingPathComponent("dsound.dll")) == payload.dsoundDLL)
    #expect(try Data(contentsOf: directory.appendingPathComponent("P3RFix.asi")) == payload.asi)
    let ini = try String(contentsOf: directory.appendingPathComponent("P3RFix.ini"), encoding: .utf8)
    #expect(ini == P3RFixRelease.managedINI)
}

@Test func p3rFixInstallerRejectsMissingExecutableAndEmptyPayload() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-p3r.exe")
    let payload = P3RFixPayload(dsoundDLL: Data("dll".utf8), asi: Data("asi".utf8))
    #expect(throws: P3RFixInstallError.executableNotFound) {
        try P3RFixInstaller.install(payload: payload, executableURL: missing)
    }
    #expect(throws: P3RFixInstallError.payloadEmpty) {
        try P3RFixInstaller.install(
            payload: P3RFixPayload(dsoundDLL: Data(), asi: Data("asi".utf8)),
            executableURL: missing
        )
    }
}

@Test func p3rFixPayloadVerifiedRejectsTamperedBytes() {
    let payload = P3RFixPayload(dsoundDLL: Data("not-dsound".utf8), asi: Data("not-asi".utf8))
    #expect(throws: P3RFixInstallError.payloadHashMismatch("dsound.dll")) {
        _ = try payload.verified()
    }
}

@Test func bottleNativeURLResolvesForwardSlashWindowsPathAndRejectsEscape() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let drive = home.appendingPathComponent("drive_c", isDirectory: true)
    let exeDir = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/P3R/P3R/Binaries/Win64")
    let dosDevices = home
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles/Persona 3/dosdevices", isDirectory: true)
    try FileManager.default.createDirectory(at: exeDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dosDevices, withIntermediateDirectories: true)
    try Data("exe".utf8).write(to: exeDir.appendingPathComponent("P3R.exe"))
    try FileManager.default.createSymbolicLink(
        at: dosDevices.appendingPathComponent("c:"),
        withDestinationURL: drive
    )
    defer { try? FileManager.default.removeItem(at: home) }

    let resolved = CrossOverGamePathDiscovery.nativeURL(
        forWindowsPath: #"C:/Program Files (x86)/Steam/steamapps/common/P3R/P3R/Binaries/Win64/P3R.exe"#,
        inBottle: "Persona 3",
        homeURL: home
    )
    #expect(resolved?.path == exeDir.appendingPathComponent("P3R.exe").path)

    let escaped = CrossOverGamePathDiscovery.nativeURL(
        forWindowsPath: #"C:\..\..\tmp\evil.exe"#,
        inBottle: "Persona 3",
        homeURL: home
    )
    #expect(escaped == nil)
}

@Test func detectedExecutablePrefersWin64Candidate() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let drive = home.appendingPathComponent("drive_c", isDirectory: true)
    let win64 = drive.appendingPathComponent(
        "Program Files (x86)/Steam/steamapps/common/P3R/P3R/Binaries/Win64",
        isDirectory: true
    )
    let dosDevices = home
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles/P3R/dosdevices", isDirectory: true)
    try FileManager.default.createDirectory(at: win64, withIntermediateDirectories: true)
    try Data("exe".utf8).write(to: win64.appendingPathComponent("P3R.exe"))
    try FileManager.default.createDirectory(at: dosDevices, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: dosDevices.appendingPathComponent("c:"),
        withDestinationURL: drive
    )
    defer { try? FileManager.default.removeItem(at: home) }

    let detected = CrossOverGamePathDiscovery.detectedExecutable(
        in: "P3R",
        relativeCandidates: BuiltInDirectLaunchWorkflows.p3r.executableRelativeCandidates,
        homeURL: home
    )
    #expect(
        detected?.executablePath
            == #"C:\Program Files (x86)\Steam\steamapps\common\P3R\P3R\Binaries\Win64\P3R.exe"#
    )
}

@Test func p3rLaunchAdapterAllowsOnlyPinnedDsoundOverride() throws {
    let configuration = try CrossOverLaunchConfiguration(
        crossOverAppURL: URL(fileURLWithPath: "/Applications/CrossOver.app"),
        bottle: "Persona 3",
        executablePath: #"C:\P3R\P3R.exe"#
    )
    let description = try CrossOverLaunchAdapter(configuration: configuration)
        .makeProcessLaunchDescription(
            logFileURL: URL(fileURLWithPath: "/tmp/p3r-run.cxlog"),
            wineDllOverrides: P3RFixRelease.wineDllOverrides
        )
    #expect(description.extraEnvironment == ["WINEDLLOVERRIDES": "dsound=n,b"])

    #expect(throws: CrossOverLaunchError.invalidWineDllOverrides) {
        _ = try CrossOverLaunchAdapter(configuration: configuration)
            .makeProcessLaunchDescription(
                logFileURL: URL(fileURLWithPath: "/tmp/p3r-run.cxlog"),
                wineDllOverrides: "kernel32=n"
            )
    }
}
