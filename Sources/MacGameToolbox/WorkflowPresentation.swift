#if SWIFT_PACKAGE
import MacGameToolboxCore
#endif
import Foundation

struct WorkflowStepPreview: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
}

enum DirectLaunchWorkflowPresentation {
    static func stepPreviews(for profile: BuiltInGameWorkflow) -> [WorkflowStepPreview] {
        let name = profile.displayName
        return [
            WorkflowStepPreview(
                id: "preflight",
                title: tr("环境预检", "Environment preflight"),
                detail: tr("检查 CrossOver 与已绑定的游戏配置", "Check CrossOver and the bound game configuration"),
                icon: "checkmark.shield"
            ),
            WorkflowStepPreview(
                id: "claim-process-session",
                title: tr("占用容器", "Claim bottle"),
                detail: tr("以本机安装绑定为锁，独占这个 CrossOver 容器", "Exclusively claim this CrossOver bottle from the local installation binding"),
                icon: "lock.fill"
            ),
            WorkflowStepPreview(
                id: "configure-metalhud",
                title: tr("配置 MetalHUD", "Configure MetalHUD"),
                detail: tr("按当前偏好准备性能监视器", "Prepare the performance monitor when enabled"),
                icon: "gauge.with.dots.needle.67percent"
            ),
            WorkflowStepPreview(
                id: "launch-game",
                title: tr("启动游戏", "Launch game"),
                detail: tr("通过已验证的 CrossOver 启动适配器启动", "Launch through the verified CrossOver adapter"),
                icon: "play.fill"
            ),
            WorkflowStepPreview(
                id: "await-process",
                title: tr("等待游戏进程", "Wait for game process"),
                detail: tr("等待已绑定的 \(name) 进程出现", "Wait until the bound \(name) process appears"),
                icon: "eye"
            ),
            WorkflowStepPreview(
                id: "apply-qos",
                title: tr("优化进程", "Optimize processes"),
                detail: tr("提升本容器中的 CrossOver/Wine 进程优先级", "Boost CrossOver/Wine processes in this bottle"),
                icon: "bolt.fill"
            ),
            WorkflowStepPreview(
                id: "claim-game-mode",
                title: tr("占用 Game Mode", "Claim Game Mode"),
                detail: tr("由本 run 占用全局 Game Mode；最后释放者才恢复原策略", "This run claims global Game Mode; the last releaser restores the previous policy"),
                icon: "flag.checkered"
            ),
            WorkflowStepPreview(
                id: "await-exit",
                title: tr("跟踪至退出", "Track until exit"),
                detail: tr("等待本容器中的 \(name) 进程退出", "Wait until the \(name) process in this bottle exits"),
                icon: "eye.circle"
            ),
            WorkflowStepPreview(
                id: "terminate-residuals",
                title: tr("结束残留进程", "Terminate residuals"),
                detail: tr("只终止本 run 声称的容器进程", "Terminate only processes claimed by this run"),
                icon: "xmark.circle"
            ),
            WorkflowStepPreview(
                id: "release-game-mode",
                title: tr("交还 Game Mode", "Release Game Mode"),
                detail: tr("释放本 run 的 claim；无其他持有者时恢复自动策略", "Release this run's claim and restore auto when no holders remain"),
                icon: "flag"
            )
        ]
    }
}
