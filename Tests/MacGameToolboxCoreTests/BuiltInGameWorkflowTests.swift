import Foundation
import Testing
@testable import MacGameToolboxCore

@Test func directLaunchCatalogSeparatesP3RAndDemo() {
    let p3r = BuiltInDirectLaunchWorkflows.p3r
    let demo = BuiltInDirectLaunchWorkflows.p3rDemo

    #expect(p3r.id == "game.atlus.p3r")
    #expect(p3r.workflowID == "game.atlus.p3r.launch")
    #expect(demo.id == "game.atlus.p3r.demo")
    #expect(demo.workflowID == "game.atlus.p3r.demo.launch")
    #expect(p3r.id != demo.id)
    #expect(p3r.workflowID != demo.workflowID)
    #expect(p3r.processNames == ["P3R.exe"])
    #expect(demo.processNames == ["P3R.exe"])
    #expect(BuiltInDirectLaunchWorkflows.workflow(id: p3r.id) == p3r)
    #expect(BuiltInDirectLaunchWorkflows.workflow(workflowID: demo.workflowID) == demo)
}

@Test func directLaunchPlanOmitsNetworkIsolationAndMarksExitAsHolding() throws {
    let workflow = try DirectLaunchWorkflowPlan.compiled(
        workflowID: BuiltInDirectLaunchWorkflows.p3r.workflowID,
        metalHUDEnabled: true,
        processWaitTimeoutSeconds: 90
    )

    #expect(workflow.id == "game.atlus.p3r.launch")
    #expect(workflow.steps.map(\.id) == DirectLaunchWorkflowPlan.stepIDs)
    #expect(workflow.steps.filter(\.holding).map(\.id) == ["await-exit"])
    #expect(!workflow.steps.contains { $0.kind.contains("network") })
    #expect(!workflow.steps.contains { $0.id.contains("network") })

    let metalHUD = try JSONDecoder().decode(
        DirectLaunchWorkflowPlan.MetalHUDInput.self,
        from: workflow.steps.first { $0.id == "configure-metalhud" }?.input ?? Data()
    )
    #expect(metalHUD.enabled)

    let wait = try JSONDecoder().decode(
        DirectLaunchWorkflowPlan.ProcessWaitInput.self,
        from: workflow.steps.first { $0.id == "await-process" }?.input ?? Data()
    )
    #expect(wait.timeoutSeconds == 90)
}

@Test func preferredBottleHonorsHintsAndExclusions() {
    let bottles = ["Steam", "P3R", "P3R Demo", "原神"]
    #expect(
        CrossOverGamePathDiscovery.preferredBottle(
            from: bottles,
            matching: BuiltInDirectLaunchWorkflows.p3r.bottleNameHints,
            excluding: BuiltInDirectLaunchWorkflows.p3r.bottleNameExclusions
        ) == "P3R"
    )
    #expect(
        CrossOverGamePathDiscovery.preferredBottle(
            from: bottles,
            matching: BuiltInDirectLaunchWorkflows.p3rDemo.bottleNameHints
        ) == "P3R Demo"
    )
}

@Test func detectedExecutableUsesDriveLetterAndCandidatePath() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let drive = home.appendingPathComponent("drive_c", isDirectory: true)
    let game = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/P3R", isDirectory: true)
    let dosDevices = home
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles/P3R/dosdevices", isDirectory: true)
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    try Data("exe".utf8).write(to: game.appendingPathComponent("P3R.exe"))
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

    #expect(detected?.bottleName == "P3R")
    #expect(detected?.executablePath == #"C:\Program Files (x86)\Steam\steamapps\common\P3R\P3R.exe"#)
    #expect(detected?.workingDirectoryPath == #"C:\Program Files (x86)\Steam\steamapps\common\P3R"#)
}

@Test func demoDiscoveryDoesNotPickFullGameExecutable() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let drive = home.appendingPathComponent("drive_c", isDirectory: true)
    let fullGame = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps/common/P3R", isDirectory: true)
    let dosDevices = home
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles/P3R/dosdevices", isDirectory: true)
    try FileManager.default.createDirectory(at: fullGame, withIntermediateDirectories: true)
    try Data("exe".utf8).write(to: fullGame.appendingPathComponent("P3R.exe"))
    try FileManager.default.createDirectory(at: dosDevices, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: dosDevices.appendingPathComponent("c:"),
        withDestinationURL: drive
    )
    defer { try? FileManager.default.removeItem(at: home) }

    let detected = CrossOverGamePathDiscovery.detectedExecutable(
        in: "P3R",
        relativeCandidates: BuiltInDirectLaunchWorkflows.p3rDemo.executableRelativeCandidates,
        homeURL: home
    )
    #expect(detected == nil)
}
