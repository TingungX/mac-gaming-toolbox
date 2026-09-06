import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif

struct CrossOverGameConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let profile: BuiltInGameWorkflow

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
                Text(tr("配置 \(profile.displayName)", "Configure \(profile.displayName)"))
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
                    TextField(profile.executableRelativeCandidates.first ?? "C:\\Game\\Game.exe", text: $executablePath)
                }
                GridRow {
                    Text(tr("游戏目录", "Working directory"))
                    TextField("", text: $workingDirectoryPath)
                }
            }
            .textFieldStyle(.roundedBorder)

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
        let existing: CrossOverGameBinding? = model.installation(for: profile).flatMap { installation in
            guard case .crossOver(let binding) = installation.launchBinding else { return nil }
            return binding
        }
        let suggestion = CrossOverGamePathDiscovery.suggestion(existing: existing, workflow: profile)
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
              let detected = CrossOverGamePathDiscovery.detectedExecutable(
                in: bottle,
                relativeCandidates: profile.executableRelativeCandidates
              ) else {
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
            model.saveDirectLaunchInstallation(
                profile,
                CrossOverGameBinding(
                    applicationPath: applicationPath,
                    bottleName: bottleName,
                    executablePath: executablePath,
                    workingDirectoryPath: workingDirectoryPath.isEmpty ? nil : workingDirectoryPath
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
