# ADR-0001：外部可编辑、能力受限的工作流配方

Status: accepted  
Owner: TingungX  
Last updated: 2026-08-24  
Scope: 游戏工作流的来源、扩展边界与特权安全模型  
Related code: `Sources/MacGameToolboxCore/`, `Sources/MacGameToolboxPrivilegedHelper/`  
Related docs: `../design/workflow-runtime.md`, `../specs/phase-1-genshin-workflow.md`

## 背景

项目将从功能组件面板转为“每款游戏一条一键启动流程”。配方需要能够独立于 App 版本被用户编辑和分享，但其中会组合网络隔离、进程调整等高权限能力。

如果外部配方可以携带 shell、AppleScript、任意 executable 或任意 XPC 参数，导入配方就等同于安装一个可请求 root 权限的脚本。这与工具的安全边界冲突。

## 决策

采用外部可编辑的声明式 Recipe，但把执行能力限制在 App 编译时注册的 capability 与 step executor 内。

- Recipe 是数据，不是代码。
- 外部 Recipe 可以排序、组合和配置受限步骤。
- Recipe 不能定义新步骤实现，也不能包含任意 shell、脚本、动态库、环境变量或 root 命令。
- 游戏安装路径和启动目标由用户在 App 内绑定，与可分享 Recipe 分开存储。
- 每个 Recipe 显式声明 capabilities；导入时校验并向用户展示权限摘要。
- helper 只接受语义化、逐项验证的请求；不提供通用 command runner XPC。
- 未知 schema、步骤和字段不得静默忽略。
- 第一阶段允许本地编辑和手动导入，不做在线市场或静默自动更新。

外部可编辑并不意味着默认信任。bundled、local 和 imported 配方使用同一验证器；来源只影响界面呈现和更新策略。

## 结果

正面影响：

- 新游戏大部分差异可以通过配方表达，不继续扩张 `AppModel` 条件分支。
- 用户可以检查、编辑和分享流程。
- 高权限能力仍由可审计的 Swift 实现控制。
- 配方升级与本机安装路径解耦。

代价：

- 每增加一种真正的新能力，仍需发布包含新 executor 的 App 版本。
- 需要维护 schema 版本、validator、迁移和权限差异展示。
- 配方表达能力刻意小于通用脚本，部分特殊游戏需要先扩充受信能力。

## 被否决方案

### 只提供 App 内置配方

安全和实现最简单，但用户无法独立修订或分享流程，不符合已确定的扩展方向。

### 每款游戏在 Swift 中写死流程

首款游戏实现较快，但游戏差异会进入界面和状态管理分支，无法形成稳定工作流模型。

### 外部任意脚本

扩展能力最强，但无法为 root 操作建立可靠信任边界，也难以静态生成权限与补偿摘要，因此明确禁止。

### 第一阶段实现完整插件系统

会引入代码签名、隔离、版本兼容和分发信任问题，超出第一阶段目标；未来若需要，应通过新的 ADR 替代本决策的相应范围。

