import Foundation
import Testing
@testable import MacGameToolboxCore

private let genshinModuleLine = "1.000:0798:079c:trace:module:map_image_into_view mapping PE file L\"Y:\\\\Games\\\\Genshin Impact Game\\\\MHYPBase.dll\" at 0x1000-0x2000\n"
private let renderThreadLine = "2.000:0798:02dc:warn:threadname:NtSetInformationThread Thread handle 0x3c0 renamed to L\"UnityGfxDeviceWorker\"\n"

private func genshinCreateLines(launcherThread: String, pid: String, tid: String) -> String {
    "1.000:0464:\(launcherThread):trace:process:CreateProcessInternalW app (null) cmdline L\"\\\"Y:\\\\Games\\\\Genshin Impact Game\\\\YuanShen.exe\\\" login_trace_id=secret\"\n" +
    "1.010:0464:\(launcherThread):trace:process:NtCreateUserProcess L\"\\\\??\\\\Y:\\\\Games\\\\Genshin Impact Game\\\\YuanShen.exe\" image L\"Y:\\\\Games\\\\Genshin Impact Game\\\\YuanShen.exe\" parent 0x0 machine 0\n" +
    "1.020:0464:\(launcherThread):trace:process:CreateProcessInternalW started process pid \(pid) tid \(tid)\n"
}

@Test func crossOverAdapterBuildsArgvWithoutShellOrGameArguments() throws {
    let configuration = try CrossOverLaunchConfiguration(
        crossOverAppURL: URL(fileURLWithPath: "/Applications/CrossOver.app"),
        bottle: "原神（国服）",
        executablePath: #"Y:\Games\Genshin Impact Game\YuanShen.exe"#,
        workingDirectoryPath: #"Y:\Games\Genshin Impact Game"#
    )
    let description = try CrossOverLaunchAdapter(configuration: configuration)
        .makeProcessLaunchDescription(logFileURL: URL(fileURLWithPath: "/tmp/genshin-run.cxlog"))

    #expect(description.executableURL.path == "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart")
    #expect(description.arguments == [
        "--bottle", "原神（国服）",
        "--workdir", #"Y:\Games\Genshin Impact Game"#,
        "--cx-log", "/tmp/genshin-run.cxlog",
        "--debugmsg", CrossOverLaunchAdapter.defaultDebugChannels,
        #"Y:\Games\Genshin Impact Game\YuanShen.exe"#
    ])
    #expect(description.arguments.allSatisfy { !$0.contains("login_trace_id") })
    #expect(description.arguments.allSatisfy { !$0.contains(";") && !$0.contains("&&") && !$0.contains("|") })
    #expect(description.extraEnvironment.isEmpty)
}

@Test func crossOverAdapterRejectsUntrustedLaunchInputs() throws {
    #expect(throws: CrossOverLaunchError.invalidExecutablePath) {
        try CrossOverExecutablePath(#"Y:\Games\YuanShen.exe --debugmsg +all"#)
    }
    #expect(throws: CrossOverLaunchError.invalidBottle) {
        try CrossOverBottle("Bottle\nInjected")
    }
    #expect(throws: CrossOverLaunchError.invalidWorkingDirectory) {
        try CrossOverWorkingDirectory("Y:\\Games\n")
    }
    #expect(throws: CrossOverLaunchError.invalidLogFile) {
        let configuration = try CrossOverLaunchConfiguration(
            crossOverAppURL: URL(fileURLWithPath: "/Applications/CrossOver.app"),
            bottle: "default",
            executablePath: #"C:\YuanShen.exe"#
        )
        _ = try CrossOverLaunchAdapter(configuration: configuration)
            .makeProcessLaunchDescription(logFileURL: URL(fileURLWithPath: "/"))
    }
}

@Test func parserHandlesHalfLinesAndIgnoresUnrelatedPID() throws {
    var parser = try CrossOverTraceParser(targetPID: 0x798)
    let unrelated = "1.001:0799:02dc:warn:threadname:NtSetInformationThread renamed to L\"UnityGfxDeviceWorker\"\n"
    #expect(parser.append(unrelated).isEmpty)

    let data = Data((genshinModuleLine + renderThreadLine).utf8)
    let split = data.count / 2
    #expect(parser.append(data.prefix(split)).isEmpty)
    let events = parser.append(data.dropFirst(split))
    #expect(events.contains(.mhypBaseMapped(pid: 0x798, lowerBound: 0x1000, upperBound: 0x2000)))
    #expect(events.contains(.threadNamed(pid: 0x798, name: .unityGfxDeviceWorker)))
}

@Test func parserDiscoversYuanShenPIDFromCurrentLaunchAndSwitchesOnNextLaunch() throws {
    var parser = try CrossOverTraceParser()
    let first = genshinCreateLines(launcherThread: "070c", pid: "0710", tid: "0714")
    let second = genshinCreateLines(launcherThread: "06a0", pid: "0798", tid: "079c")

    #expect(parser.append(first).last == .genshinProcessStarted(pid: 0x710))
    #expect(parser.targetPID == 0x710)
    #expect(parser.append(second).last == .genshinProcessStarted(pid: 0x798))
    #expect(parser.targetPID == 0x798)
}

@Test func parserBindsChildPIDBeforeLauncherStartedLineAndKeepsEarlyModuleRange() throws {
    var parser = try CrossOverTraceParser()
    let lines = genshinCreateLines(launcherThread: "070c", pid: "0710", tid: "0714")
        .split(separator: "\n", omittingEmptySubsequences: false)
    #expect(parser.append(String(lines[0]) + "\n").isEmpty)
    #expect(parser.append(String(lines[1]) + "\n").isEmpty)

    let earlyChildModule = "1.015:0710:0714:trace:module:map_image_into_view mapping PE file L\"Y:\\\\Games\\\\Genshin Impact Game\\\\YuanShen.exe\" at 0x140000000-0x15a344000\n"
    #expect(parser.append(earlyChildModule) == [.genshinProcessStarted(pid: 0x710)])
    #expect(parser.append(genshinModuleLine.replacingOccurrences(of: "0798", with: "0710")).count == 1)
    #expect(parser.append("3.000:0710:0730:trace:seh:dispatch_exception code=c0000005 flags=0 addr=0000000000001800\n").count == 1)
    #expect(parser.append(String(lines[2]) + "\n").isEmpty)
}

@Test func parserBindsDirectCxstartLaunchFromExecutableModule() throws {
    var parser = try CrossOverTraceParser()
    let executableModule = "1.000:0710:0714:trace:module:map_image_into_view mapping PE file L\"Y:\\\\Games\\\\Genshin Impact Game\\\\YuanShen.exe\" at 0x140000000-0x15a344000\n"

    #expect(parser.append(executableModule) == [.genshinProcessStarted(pid: 0x710)])
    #expect(parser.targetPID == 0x710)
    #expect(parser.append(renderThreadLine.replacingOccurrences(of: "0798", with: "0710")) == [
        .threadNamed(pid: 0x710, name: .unityGfxDeviceWorker)
    ])
}

@Test func parserDetectsKnownMHYPBaseAccessViolationOnlyForTargetPID() throws {
    var parser = try CrossOverTraceParser(targetPID: 0x710)
    let mapping = genshinModuleLine.replacingOccurrences(of: "0798", with: "0710")
    let exception = "3.000:0710:0730:trace:seh:dispatch_exception code=c0000005 (EXCEPTION_ACCESS_VIOLATION) flags=0 addr=0000000000001800\n"

    #expect(parser.append(mapping).count == 1)
    let events = parser.append(exception)
    #expect(events == [.mhypBaseAccessViolation(pid: 0x710, code: 0xc0000005, address: 0x1800)])
}

@Test func parserCorrelatesExceptionWithMHYPBaseWhenOnlyLoadBaseIsAvailable() throws {
    var parser = try CrossOverTraceParser(targetPID: 0x710)
    let loaded = "1.000:0710:0714:trace:loaddll:build_module Loaded L\"Y:\\\\Games\\\\MHYPBase.dll\" at 0000000000001000: native\n"
    let exception = "2.000:0710:0730:trace:seh:dispatch_exception code=c0000005 flags=0 addr=0000000000001800\n"
    let unwind = "2.000:0710:0730:trace:unwind:RtlVirtualUnwind2 type 1 base 0000000000001000 rip 0000000000001800 rva 800\n"

    #expect(parser.append(loaded).isEmpty)
    #expect(parser.append(exception).isEmpty)
    #expect(parser.append(unwind) == [.mhypBaseAccessViolation(pid: 0x710, code: 0xc0000005, address: 0x1800)])
}

@Test func probeSucceedsOnlyAfterCurrentPIDRenderThread() throws {
    var probe = try GenshinReadinessProbe(targetPID: 0x798)
    #expect(probe.append("1.0:0799:02dc:warn:threadname:NtSetInformationThread renamed to L\"UnityGfxDeviceWorker\"\n") == .waiting)
    #expect(probe.append(genshinModuleLine) == .waiting)
    #expect(probe.append(renderThreadLine) == .ready)
    #expect(probe.append(renderThreadLine) == .ready)
}

@Test func probeUsesNewYuanShenPIDAfterFirstAttemptFails() throws {
    var probe = try GenshinReadinessProbe()
    let firstStart = genshinCreateLines(launcherThread: "070c", pid: "0710", tid: "0714")
    let secondStart = genshinCreateLines(launcherThread: "06a0", pid: "0798", tid: "079c")
    let firstMapping = genshinModuleLine.replacingOccurrences(of: "0798", with: "0710")
    let firstException = "3.000:0710:0730:trace:seh:dispatch_exception code=c0000005 flags=0 addr=0000000000001800\n"

    #expect(probe.append(firstStart) == .waiting)
    #expect(probe.targetPID == 0x710)
    #expect(probe.append(firstMapping) == .waiting)
    #expect(probe.append(firstException) == .failed(.mhypBaseAccessViolation))

    #expect(probe.append(secondStart) == .waiting)
    #expect(probe.targetPID == 0x798)
    #expect(probe.append(genshinModuleLine) == .waiting)
    #expect(probe.append(renderThreadLine) == .ready)
}

@Test func probeFailsOnProcessExitBeforeReadinessAndIgnoresPIDReuseUntilReset() throws {
    var probe = try GenshinReadinessProbe(targetPID: 0x710)
    #expect(probe.processDidExit(pid: 0x710) == .failed(.processExited))
    #expect(probe.append(renderThreadLine.replacingOccurrences(of: "0798", with: "0710")) == .failed(.processExited))

    try probe.beginNewRun(targetPID: 0x710)
    #expect(probe.state == .waiting)
    #expect(probe.append(renderThreadLine.replacingOccurrences(of: "0798", with: "0710")) == .ready)
}

@Test func probeTreatsTraceLimitAsFailureWithoutReturningRawLogContent() throws {
    var probe = try GenshinReadinessProbe(
        targetPID: 0x798,
        limits: CrossOverTraceParser.Limits(maximumLogBytes: 24, maximumLineBytes: 128)
    )
    let events = probe.append(Data("secret login_trace_id=do-not-return".utf8))
    #expect(probe.state == .failed(.traceLimitExceeded))
    #expect(events == .failed(.traceLimitExceeded))
}

@Test func probeFailsOnMHYPBaseExceptionAndTimeoutIsTerminal() throws {
    var probe = try GenshinReadinessProbe(targetPID: 0x710)
    let mapping = genshinModuleLine.replacingOccurrences(of: "0798", with: "0710")
    let exception = "3.000:0710:0730:trace:seh:dispatch_exception code=c0000005 flags=0 addr=0000000000001800\n"
    #expect(probe.append(mapping) == .waiting)
    #expect(probe.append(exception) == .failed(.mhypBaseAccessViolation))
    #expect(probe.timeout() == .failed(.mhypBaseAccessViolation))

    var timedOut = try GenshinReadinessProbe(targetPID: 0x710)
    #expect(timedOut.timeout() == .failed(.timedOut))
    #expect(timedOut.append(renderThreadLine.replacingOccurrences(of: "0798", with: "0710")) == .failed(.timedOut))
}

@Test func parserEnforcesLineLimitAndCanFlushFinalLine() throws {
    var parser = try CrossOverTraceParser(
        targetPID: 0x798,
        limits: CrossOverTraceParser.Limits(maximumLogBytes: 512, maximumLineBytes: 32)
    )
    #expect(parser.append("123456789012345678901234567890123456789\n") == [.lineLimitExceeded])

    var finalLineParser = try CrossOverTraceParser(targetPID: 0x798)
    let partial = String(renderThreadLine.dropLast())
    #expect(finalLineParser.append(partial).isEmpty)
    #expect(finalLineParser.finish() == [.threadNamed(pid: 0x798, name: .unityGfxDeviceWorker)])
}

@Test func readinessProbeFlushingAnUnterminatedRenderLineBecomesReady() throws {
    var probe = try GenshinReadinessProbe(targetPID: 0x798)
    #expect(probe.append(genshinModuleLine) == .waiting)
    #expect(probe.append(String(renderThreadLine.dropLast())) == .waiting)
    #expect(probe.finish() == .ready)
}
