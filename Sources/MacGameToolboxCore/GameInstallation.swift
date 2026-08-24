import Foundation

/// Machine-local CrossOver binding. Recipe files refer to the surrounding
/// `GameInstallation.id`; they never carry these paths themselves.
public struct CrossOverGameBinding: Codable, Equatable, Sendable {
    public var applicationPath: String
    public var bottleName: String
    public var executablePath: String
    public var workingDirectoryPath: String?

    public init(
        applicationPath: String,
        bottleName: String,
        executablePath: String,
        workingDirectoryPath: String? = nil
    ) {
        self.applicationPath = applicationPath
        self.bottleName = bottleName
        self.executablePath = executablePath
        self.workingDirectoryPath = workingDirectoryPath
    }
}

public enum GameLaunchBinding: Codable, Equatable, Sendable {
    case crossOver(CrossOverGameBinding)
}

/// A local installation selected by the user and stored separately from a
/// shareable workflow recipe.
public struct GameInstallation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var launchBinding: GameLaunchBinding

    public init(id: String, displayName: String, launchBinding: GameLaunchBinding) {
        self.id = id
        self.displayName = displayName
        self.launchBinding = launchBinding
    }
}
