import Foundation
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct AppDependencies {
    let application: any ToolboxApplicationCoordinating
    let genshinWorkflow: any GenshinWorkflowCoordinating
    let workflowInitializationError: String?
}

enum AppCompositionRoot {
    static func make() -> AppDependencies {
        let privileged = PrivilegedHelperClient()
        let configurationStore = ConfigurationStore()
        let diskService = DiskService()
        let gamingService = GamingService(privileged: privileged)
        let hostnameService = HostnameService(privileged: privileged)
        let cacheService = CacheService(privileged: privileged)
        let application = ToolboxApplicationService(
            privileged: privileged,
            configurationStore: configurationStore,
            diskService: diskService,
            gamingService: gamingService,
            hostnameService: hostnameService,
            cacheService: cacheService
        )

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("com.iven.macgametoolbox", isDirectory: true)
        let journalURL = applicationSupport
            .appendingPathComponent("Workflows", isDirectory: true)
            .appendingPathComponent("journal.json")
        let runsDirectory = applicationSupport.appendingPathComponent("WorkflowRuns", isDirectory: true)

        let workflow: any GenshinWorkflowCoordinating
        let initializationError: String?
        do {
            let journal = try FileWorkflowJournal(url: journalURL)
            workflow = try GenshinWorkflowCoordinator(
                capabilityClient: privileged,
                privileged: privileged,
                gamingService: gamingService,
                journal: journal,
                runsDirectory: runsDirectory
            )
            initializationError = nil
        } catch {
            let message = error.localizedDescription
            workflow = UnavailableGenshinWorkflowCoordinator(message: message)
            initializationError = message
        }

        return AppDependencies(
            application: application,
            genshinWorkflow: workflow,
            workflowInitializationError: initializationError
        )
    }
}

private actor UnavailableGenshinWorkflowCoordinator: GenshinWorkflowCoordinating {
    let message: String

    init(message: String) {
        self.message = message
    }

    func run(
        installation: GameInstallation,
        metalHUDEnabled: Bool,
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> WorkflowRunResult {
        throw ToolboxError.commandFailed(message)
    }

    func cancel() async {}

    func recoverIncompleteRuns(
        update: @escaping @Sendable (GenshinWorkflowUpdate) async -> Void
    ) async throws -> [WorkflowRunResult] {
        throw ToolboxError.commandFailed(message)
    }
}
