import Foundation

/// Discovers CrossOver apps, bottles, and Windows executables on this Mac.
/// Results are suggestions only; the user still confirms a `GameInstallation`.
public enum CrossOverGamePathDiscovery {
    public struct Suggestion: Equatable, Sendable {
        public let binding: CrossOverGameBinding
        public let bottleNames: [String]

        public init(binding: CrossOverGameBinding, bottleNames: [String]) {
            self.binding = binding
            self.bottleNames = bottleNames
        }
    }

    public static func discoveredCrossOverApplications(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeURL.appendingPathComponent("Applications", isDirectory: true)
        ]
        return roots.flatMap { root -> [String] in
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries.filter { url in
                url.pathExtension.caseInsensitiveCompare("app") == .orderedSame &&
                    url.lastPathComponent.localizedCaseInsensitiveContains("CrossOver") &&
                    fileManager.isExecutableFile(
                        atPath: url.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/cxstart").path
                    )
            }.map(\.standardizedFileURL.path)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func discoveredBottleNames(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let directory = bottlesDirectory(homeURL: homeURL)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func preferredBottle(
        from bottles: [String],
        matching hints: [String],
        excluding exclusions: [String] = []
    ) -> String? {
        func matches(_ bottle: String, _ needles: [String]) -> Bool {
            guard !needles.isEmpty else { return false }
            let lower = bottle.lowercased()
            return needles.contains { lower.contains($0.lowercased()) }
        }

        let ranked = bottles.filter { matches($0, hints) && !matches($0, exclusions) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ranked.first
    }

    public static func detectedExecutable(
        in bottle: String,
        relativeCandidates: [String],
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CrossOverGameBinding? {
        guard !bottle.isEmpty else { return nil }
        let dosDevices = bottlesDirectory(homeURL: homeURL)
            .appendingPathComponent(bottle, isDirectory: true)
            .appendingPathComponent("dosdevices", isDirectory: true)
        guard let devices = try? fileManager.contentsOfDirectory(
            at: dosDevices,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for device in devices {
            let name = device.lastPathComponent
            guard name.count == 2, name.last == ":", let drive = name.first, drive.isLetter else { continue }
            let root = device.resolvingSymlinksInPath()
            for relativePath in relativeCandidates {
                let nativeURL = root.appendingPathComponent(relativePath)
                guard fileManager.fileExists(atPath: nativeURL.path) else { continue }
                let windowsRelative = relativePath.replacingOccurrences(of: "/", with: "\\")
                let executable = "\(drive.uppercased()):\\\(windowsRelative)"
                let workingDirectory: String
                if let separator = executable.lastIndex(of: "\\") {
                    workingDirectory = String(executable[..<separator])
                } else {
                    workingDirectory = executable
                }
                return CrossOverGameBinding(
                    applicationPath: "",
                    bottleName: bottle,
                    executablePath: executable,
                    workingDirectoryPath: workingDirectory
                )
            }
        }
        return nil
    }

    public static func suggestion(
        existing: CrossOverGameBinding?,
        workflow: BuiltInGameWorkflow,
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Suggestion {
        let applicationPath = existing?.applicationPath
            ?? discoveredCrossOverApplications(fileManager: fileManager, homeURL: homeURL).first
            ?? ""
        let bottles = Array(
            Set(discoveredBottleNames(fileManager: fileManager, homeURL: homeURL) + [existing?.bottleName].compactMap { $0 })
        ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let bottle = existing?.bottleName
            ?? preferredBottle(
                from: bottles,
                matching: workflow.bottleNameHints,
                excluding: workflow.bottleNameExclusions
            )
            ?? bottles.first
            ?? ""
        let detected = detectedExecutable(
            in: bottle,
            relativeCandidates: workflow.executableRelativeCandidates,
            fileManager: fileManager,
            homeURL: homeURL
        )
        return Suggestion(
            binding: CrossOverGameBinding(
                applicationPath: applicationPath,
                bottleName: bottle,
                executablePath: existing?.executablePath ?? detected?.executablePath ?? "",
                workingDirectoryPath: existing?.workingDirectoryPath ?? detected?.workingDirectoryPath
            ),
            bottleNames: bottles
        )
    }

    private static func bottlesDirectory(homeURL: URL) -> URL {
        homeURL.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }
}
