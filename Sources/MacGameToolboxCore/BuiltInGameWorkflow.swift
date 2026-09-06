import Foundation

/// A built-in, shareable game identity. Machine-local CrossOver paths live on
/// `GameInstallation`; this value only names the workflow, process, and
/// discovery hints.
public struct BuiltInGameWorkflow: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let workflowID: WorkflowID
    public let displayNameChinese: String
    public let displayNameEnglish: String
    public let processNames: [String]
    public let bottleNameHints: [String]
    public let bottleNameExclusions: [String]
    public let executableRelativeCandidates: [String]
    public let processWaitTimeoutSeconds: Int

    public init(
        id: String,
        workflowID: WorkflowID,
        displayNameChinese: String,
        displayNameEnglish: String,
        processNames: [String],
        bottleNameHints: [String],
        bottleNameExclusions: [String] = [],
        executableRelativeCandidates: [String],
        processWaitTimeoutSeconds: Int = 90
    ) {
        self.id = id
        self.workflowID = workflowID
        self.displayNameChinese = displayNameChinese
        self.displayNameEnglish = displayNameEnglish
        self.processNames = processNames
        self.bottleNameHints = bottleNameHints
        self.bottleNameExclusions = bottleNameExclusions
        self.executableRelativeCandidates = executableRelativeCandidates
        self.processWaitTimeoutSeconds = processWaitTimeoutSeconds
    }

    public var displayName: String {
        coreText(displayNameChinese, displayNameEnglish)
    }
}

/// CrossOver games that launch without a privileged network gate. Genshin stays
/// on its own coordinator because its readiness probe and PF isolation are
/// game-specific.
public enum BuiltInDirectLaunchWorkflows {
    public static let p3r = BuiltInGameWorkflow(
        id: "game.atlus.p3r",
        workflowID: "game.atlus.p3r.launch",
        displayNameChinese: "女神异闻录3 Reload",
        displayNameEnglish: "Persona 3 Reload",
        processNames: ["P3R.exe"],
        bottleNameHints: ["p3r", "p3 reload", "persona 3"],
        bottleNameExclusions: ["demo"],
        executableRelativeCandidates: [
            "Program Files (x86)/Steam/steamapps/common/P3R/P3R.exe",
            "Program Files (x86)/Steam/steamapps/common/Persona 3 Reload/P3R.exe",
            "Program Files/Steam/steamapps/common/P3R/P3R.exe",
            "Program Files/Steam/steamapps/common/Persona 3 Reload/P3R.exe"
        ]
    )

    public static let p3rDemo = BuiltInGameWorkflow(
        id: "game.atlus.p3r.demo",
        workflowID: "game.atlus.p3r.demo.launch",
        displayNameChinese: "女神异闻录3 Reload Demo",
        displayNameEnglish: "Persona 3 Reload Demo",
        processNames: ["P3R.exe"],
        bottleNameHints: ["p3r demo", "p3rdemo", "p3 reload demo", "persona 3 reload demo"],
        executableRelativeCandidates: [
            "Program Files (x86)/Steam/steamapps/common/P3RDemo/P3R.exe",
            "Program Files (x86)/Steam/steamapps/common/Persona 3 Reload Demo/P3R.exe",
            "Program Files/Steam/steamapps/common/P3RDemo/P3R.exe",
            "Program Files/Steam/steamapps/common/Persona 3 Reload Demo/P3R.exe"
        ]
    )

    public static let all: [BuiltInGameWorkflow] = [p3r, p3rDemo]

    public static func workflow(id: String) -> BuiltInGameWorkflow? {
        all.first { $0.id == id }
    }

    public static func workflow(workflowID: WorkflowID) -> BuiltInGameWorkflow? {
        all.first { $0.workflowID == workflowID }
    }
}

public enum DirectLaunchWorkflowStepKind {
    public static let preflight = "environment.preflight"
    public static let claimProcessSession = "process.session.claim"
    public static let configureMetalHUD = "metalhud.configure"
    public static let launch = "game.launch.crossover"
    public static let awaitProcess = "game.awaitProcess"
    public static let applyQoS = "process.applyQoS"
    public static let claimGameMode = "system.gameMode.claim"
    public static let awaitExit = "game.awaitExit"
    public static let terminateResiduals = "process.terminateClaimed"
    public static let releaseGameMode = "system.gameMode.release"
    public static let releaseProcessSession = "process.session.release"
}

public enum DirectLaunchWorkflowPlan {
    public struct MetalHUDInput: Codable, Sendable {
        public let enabled: Bool
        public init(enabled: Bool) { self.enabled = enabled }
    }

    public struct ProcessWaitInput: Codable, Sendable {
        public let timeoutSeconds: Int
        public init(timeoutSeconds: Int) { self.timeoutSeconds = timeoutSeconds }
    }

    public static let stepIDs = [
        "preflight",
        "claim-process-session",
        "configure-metalhud",
        "launch-game",
        "await-process",
        "apply-qos",
        "claim-game-mode",
        "await-exit",
        "terminate-residuals",
        "release-game-mode",
        "release-process-session"
    ]

    public static func compiled(
        workflowID: WorkflowID,
        metalHUDEnabled: Bool,
        processWaitTimeoutSeconds: Int
    ) throws -> CompiledWorkflow {
        let encoder = JSONEncoder()
        return CompiledWorkflow(
            id: workflowID,
            revision: 1,
            steps: [
                WorkflowStepDefinition(id: "preflight", kind: DirectLaunchWorkflowStepKind.preflight),
                WorkflowStepDefinition(
                    id: "claim-process-session",
                    kind: DirectLaunchWorkflowStepKind.claimProcessSession
                ),
                WorkflowStepDefinition(
                    id: "configure-metalhud",
                    kind: DirectLaunchWorkflowStepKind.configureMetalHUD,
                    input: try encoder.encode(MetalHUDInput(enabled: metalHUDEnabled))
                ),
                WorkflowStepDefinition(id: "launch-game", kind: DirectLaunchWorkflowStepKind.launch),
                WorkflowStepDefinition(
                    id: "await-process",
                    kind: DirectLaunchWorkflowStepKind.awaitProcess,
                    input: try encoder.encode(ProcessWaitInput(timeoutSeconds: processWaitTimeoutSeconds))
                ),
                WorkflowStepDefinition(id: "apply-qos", kind: DirectLaunchWorkflowStepKind.applyQoS),
                WorkflowStepDefinition(
                    id: "claim-game-mode",
                    kind: DirectLaunchWorkflowStepKind.claimGameMode
                ),
                WorkflowStepDefinition(
                    id: "await-exit",
                    kind: DirectLaunchWorkflowStepKind.awaitExit,
                    holding: true
                ),
                WorkflowStepDefinition(
                    id: "terminate-residuals",
                    kind: DirectLaunchWorkflowStepKind.terminateResiduals
                ),
                WorkflowStepDefinition(
                    id: "release-game-mode",
                    kind: DirectLaunchWorkflowStepKind.releaseGameMode
                ),
                WorkflowStepDefinition(
                    id: "release-process-session",
                    kind: DirectLaunchWorkflowStepKind.releaseProcessSession
                )
            ]
        )
    }
}
