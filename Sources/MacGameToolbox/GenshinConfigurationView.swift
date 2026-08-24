import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct GenshinConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var applicationPath = ""
    @State private var bottleName = ""
    @State private var executablePath = ""
    @State private var workingDirectoryPath = ""
    @State private var bottleNames: [String] = []
    @State private var errorMessage: String?
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("配置原神", "Configure Genshin"))
                    .font(.title2.weight(.semibold))
                Text(tr(
                    "选择本机的 CrossOver 环境。配置只保存在本机，不会写进可分享的游戏流程。",
                    "Choose the local CrossOver environment. This binding stays on this Mac and is never embedded in a shareable workflow."
                ))
                .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("CrossOver")
                    HStack {
                        TextField("/Applications/CrossOver.app", text: $applicationPath)
                        Button(tr("选择…", "Choose…")) { chooseCrossOverApplication() }
                    }
                }
                GridRow {
                    Text(tr("容器", "Bottle"))
                    if bottleNames.isEmpty {
                        TextField(tr("CrossOver 容器名称", "CrossOver bottle name"), text: $bottleName)
                    } else {
                        Picker("", selection: $bottleName) {
                            ForEach(bottleNames, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .onChange(of: bottleName) { _, value in
                            fillDetectedGamePath(for: value, replacingExisting: true)
                        }
                    }
                }
                GridRow {
                    Text(tr("游戏程序", "Game executable"))
                    TextField(#"Y:\Games\Genshin Impact Game\YuanShen.exe"#, text: $executablePath)
                }
                GridRow {
                    Text(tr("游戏目录", "Working directory"))
                    TextField(#"Y:\Games\Genshin Impact Game"#, text: $workingDirectoryPath)
                }
            }
            .textFieldStyle(.roundedBorder)

            Label(
                tr(
                    "启动时会短时中断这台 Mac 的全部网络；检测到原神开始渲染、启动失败或取消时都会自动恢复。",
                    "Launching briefly interrupts all network access on this Mac. It is restored when rendering starts, or if launch fails or is cancelled."
                ),
                systemImage: "network.slash"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                Button(tr("保存配置", "Save configuration")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(applicationPath.isEmpty || bottleName.isEmpty || executablePath.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear { loadOnce() }
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        let existing: CrossOverGameBinding? = model.genshinInstallation.flatMap { installation in
            guard case .crossOver(let binding) = installation.launchBinding else { return nil }
            return binding
        }
        let suggestion = GenshinInstallationDiscovery.suggestion(existing: existing)
        applicationPath = suggestion.binding.applicationPath
        bottleName = suggestion.binding.bottleName
        executablePath = suggestion.binding.executablePath
        workingDirectoryPath = suggestion.binding.workingDirectoryPath ?? ""
        bottleNames = suggestion.bottleNames
    }

    private func chooseCrossOverApplication() {
        let panel = NSOpenPanel()
        panel.title = tr("选择 CrossOver", "Choose CrossOver")
        panel.prompt = tr("选择", "Choose")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applicationPath = url.standardizedFileURL.path
    }

    private func fillDetectedGamePath(for bottle: String, replacingExisting: Bool) {
        guard replacingExisting || executablePath.isEmpty,
              let detected = GenshinInstallationDiscovery.detectedExecutable(in: bottle) else {
            return
        }
        executablePath = detected.executablePath
        workingDirectoryPath = detected.workingDirectoryPath ?? ""
    }

    private func save() {
        errorMessage = nil
        do {
            _ = try CrossOverLaunchConfiguration(
                crossOverAppURL: URL(fileURLWithPath: applicationPath),
                bottle: bottleName,
                executablePath: executablePath,
                workingDirectoryPath: workingDirectoryPath.isEmpty ? nil : workingDirectoryPath
            )
            guard FileManager.default.fileExists(atPath: applicationPath) else {
                throw ToolboxError.invalidPath(applicationPath)
            }
            model.saveGenshinInstallation(CrossOverGameBinding(
                applicationPath: applicationPath,
                bottleName: bottleName,
                executablePath: executablePath,
                workingDirectoryPath: workingDirectoryPath.isEmpty ? nil : workingDirectoryPath
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum GenshinInstallationDiscovery {
    struct Suggestion {
        let binding: CrossOverGameBinding
        let bottleNames: [String]
    }

    static func suggestion(existing: CrossOverGameBinding?) -> Suggestion {
        let applicationPath = existing?.applicationPath ?? discoveredCrossOverApplications().first ?? ""
        let bottles = Array(Set(discoveredBottleNames() + [existing?.bottleName].compactMap { $0 }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let bottle = existing?.bottleName
            ?? bottles.first(where: { $0.localizedCaseInsensitiveContains("原神") || $0.localizedCaseInsensitiveContains("genshin") })
            ?? bottles.first
            ?? ""
        let detected = detectedExecutable(in: bottle)
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

    static func detectedExecutable(in bottle: String) -> CrossOverGameBinding? {
        guard !bottle.isEmpty else { return nil }
        let bottleDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
            .appendingPathComponent(bottle, isDirectory: true)
        let dosDevices = bottleDirectory.appendingPathComponent("dosdevices", isDirectory: true)
        guard let devices = try? FileManager.default.contentsOfDirectory(
            at: dosDevices,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let relativeCandidates = [
            "Games/Genshin Impact Game/YuanShen.exe",
            "Program Files/Genshin Impact/Genshin Impact Game/YuanShen.exe",
            "Program Files/Genshin Impact/Genshin Impact game/YuanShen.exe"
        ]
        for device in devices {
            let name = device.lastPathComponent
            guard name.count == 2, name.last == ":", let drive = name.first, drive.isLetter else { continue }
            let root = device.resolvingSymlinksInPath()
            for relativePath in relativeCandidates {
                let nativeURL = root.appendingPathComponent(relativePath)
                guard FileManager.default.fileExists(atPath: nativeURL.path) else { continue }
                let windowsRelative = relativePath.replacingOccurrences(of: "/", with: "\\")
                let executable = "\(drive.uppercased()):\\\(windowsRelative)"
                let workingDirectory = String(executable.dropLast("\\YuanShen.exe".count))
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

    private static func discoveredCrossOverApplications() -> [String] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        return roots.flatMap { root -> [String] in
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries.filter { url in
                url.pathExtension.caseInsensitiveCompare("app") == .orderedSame &&
                    url.lastPathComponent.localizedCaseInsensitiveContains("CrossOver") &&
                    FileManager.default.isExecutableFile(
                        atPath: url.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/cxstart").path
                    )
            }.map(\.standardizedFileURL.path)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func discoveredBottleNames() -> [String] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
