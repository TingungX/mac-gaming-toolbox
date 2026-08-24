# 工作流优先界面与 Game Mode 组件

Status: accepted
Owner: TingungX
Last updated: 2026-08-24
Scope: macOS 主界面导航、工作流预览、Game Mode 功能组件
Related code: `Sources/MacGameToolbox/DashboardView.swift`, `Sources/MacGameToolbox/InformationViews.swift`, `Sources/MacGameToolboxCore/GamingServices.swift`
Related docs: `../design/workflow-runtime.md`, `phase-1-genshin-workflow.md`

## 背景

原有首页将工作流、独立工具、壁纸、教程和更新日志放在同一组功能卡片中。随着工作流运行时落地，首页的第一用户应当是“选择并启动一条工作流”，而不是理解底层能力的用户。

Wine 游戏无法稳定触发 macOS 对假全屏窗口的自动 Game Mode 识别。经过验证，当前可用的组合是通过 `gamepolicyctl game-mode set on` 强制打开全局 Game Mode，再复用已有的 CrossOver/Wine 进程优先级能力。

## 决策

### 主导航

- 主窗口只保留两个业务 Tab：`启动程序` 与 `功能模块`。
- `启动程序` 展示已绑定的游戏工作流；每个工作流卡片可以展开查看受信步骤预览，并提供主启动按钮。
- `功能模块` 展示 MetalHUD、进程优先级、磁盘、缓存和 Game Mode 等独立能力。
- 壁纸、教程和更新日志不再作为首页业务卡片，统一放入独立的 macOS Settings 窗口。
- Settings 不改变工作流运行时边界，也不直接调用具体系统服务；仍通过 `AppModel` 的应用用例接口执行操作。

### Game Mode

- Game Mode 是机器上的一份全局策略，但由工作流 run 以 **共享 claim** 占用，不由功能模块开关管辖。
- 工作流在游戏会话中占用时执行 `game-mode set on`，并记下占用前的策略；最后一个释放 claim 的 run 才把策略写回该快照（通常是 `auto`）。
- 功能模块仍可在没有 workflow holder 时手动开关；一旦有 run 持有 claim，该开关禁用，避免应用级开关覆盖工作流所有权。
- `gamepolicyctl` 不存在或当前系统不支持时，工作流跳过占用并继续；组件显示不可用并保留可诊断错误，不通过猜测性的 `defaults` 写入替代真实命令。

## 验收标准

- 应用打开后默认可见两个 Tab，且 `启动程序` 排在前面。
- 原神工作流卡片可以查看步骤顺序，预览内容与内建 workflow plan 的稳定步骤 ID 一致。
- 壁纸、教程、更新日志只能从 Settings 进入，不再占用首页卡片。
- Game Mode 开启成功后状态显示为启用，并报告实际提升的进程数量。
- 工作流占用 Game Mode 期间，功能模块开关不能改写策略；工作流结束后由最后一个 claim 持有者恢复占用前快照。
- 关闭手动开关后恢复 `auto` 策略；开启过程中的进程检测失败不会遗留强制开启状态。
- 不引入任意 shell、任意 executable 或新的 root helper 能力。

## 风险与边界

- `gamepolicyctl` 属于开发者工具，用户机器上可能不存在；UI 必须把不可用状态解释清楚。
- Game Mode 是全局策略，组件状态变化可能影响其他游戏或应用；文案必须明确“全局”。
- 进程优先级提升本身仍是现有不可逆到进程退出的操作，因此 Game Mode 只负责会话级策略恢复，不承诺恢复已经应用到进程的 QoS。
