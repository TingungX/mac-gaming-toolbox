# ADR-0002：单一特权 helper 与双能力注册表

Status: accepted  
Owner: TingungX  
Last updated: 2026-08-24  
Scope: App 工作流步骤注册、root 能力分发、XPC 契约与 Composition Root  
Related code: `Sources/MacGameToolbox/AppModel.swift`, `Sources/MacGameToolboxCore/PrivilegedXPC.swift`, `Sources/MacGameToolbox/PrivilegedHelperClient.swift`, `Sources/MacGameToolboxPrivilegedHelper/main.swift`  
Related docs: `0001-capability-bounded-external-recipes.md`, `../design/workflow-runtime.md`, `../specs/phase-1-genshin-workflow.md`

## 背景

当前 `AppModel` 直接创建并编排多个具体服务；HoYo 流程直接知道 hosts、倒计时、Wine 检测和 QoS。root helper 则在一个 `switch` 中同时承担请求分发、能力参数验证和具体系统操作。

继续在这两处添加功能会让任何新游戏都同时修改 UI 状态、应用编排、XPC 枚举和 root 代码。另一方面，把 helper 拆成多个特权进程会成倍增加 LaunchDaemon 安装、代码签名、升级兼容、Mach service、资源协调和崩溃恢复成本。

需要把“按游戏编排步骤”和“以 root 执行原子能力”分成两个边界，同时保持单一、可恢复的特权进程。

## 决策

保留一个 root helper 进程，在 App 与 helper 内分别建立一个启动后不可变的注册表：

1. `WorkflowStepRegistry` 位于 App 进程，注册游戏启动、进程等待、readiness probe、MetalHUD 和特权能力适配步骤。
2. `PrivilegedCapabilityRegistry` 位于 root helper，注册网络、hosts、QoS、缓存、磁盘和主机名等特权原子能力 handler。

两边只共享稳定 `CapabilityContract`，其内容至少包括 capability ID/version、输入与输出 schema、权限声明、资源锁、副作用类别和回滚语义。

### 编排边界

- `WorkflowEngine` 只依赖工作流步骤协议，不认识具体游戏或特权 handler。
- `AppModel` 只依赖 `WorkflowCoordinating` 和只读运行状态，不再编排具体能力。
- helper 只依赖特权能力协议，不认识 Recipe、工作流顺序或具体游戏。
- 游戏差异由 plan/Recipe 和已注册 probe 表达，不进入 helper。

### 注册表边界

- 两个注册表只能在各自 Composition Root 完整组装。
- 组装时拒绝重复 ID、冲突版本、缺少 contract 或非法 dependency。
- 注册表构造后只读，运行中不能添加或替换 handler。
- 注册表通过构造参数显式注入，不提供全局 mutable singleton，也不能被当作 Service Locator 到处查询具体服务。

### XPC 与安全边界

- Recipe 只能引用 App 公开的白名单 step/capability ID，禁止任意 shell、任意 executable 或通用 command capability。
- App 在编译 workflow 时验证 contract，用于早期失败和权限展示；该结果不构成安全边界。
- helper 对每次 invocation 重新进行可信客户端检查、capability/version 查找、payload 大小限制、强类型解码、权限和领域输入验证。
- App 可以利用 contract 预判资源冲突；helper 必须用受信 lock-key resolver 重新计算并强制执行特权资源锁。
- XPC envelope 只传递 run/step 标识、capability ID/version 和受限 payload，不传递命令行。

### 副作用与恢复

- 每个进入工作流的副作用 handler 必须声明资源锁与回滚语义。
- handler 在修改系统状态前，将恢复快照写入 root-owned journal。
- 执行成功后返回不透明 recovery handle；App 只持久化 handle 和补偿顺序，不持有 root 快照。
- rollback 由原 capability/version 的 handler 执行，并且必须幂等。
- helper 进程统一持有资源锁、租约和 root journal，使网络、hosts、磁盘等恢复不会跨多个 root 进程竞争。

## 结果

正面影响：

- App 编排、特权分发和具体能力实现可以独立测试与演进。
- 新游戏通常只增加 plan/Recipe 和必要的 App 步骤，不修改 helper。
- 新特权能力只增加 contract 与 handler，不扩张中心大 `switch`。
- 单一 helper 简化安装、签名、版本协商和崩溃恢复。
- 双重验证使 App 被绕过或 payload 被篡改时，helper 仍保持安全边界。

代价：

- 需要维护 contract version、type erasure 和两端兼容矩阵。
- 行为保持不变的 handler 迁移必须先补 characterization tests。
- recovery handle 与 root journal 需要处理“副作用成功但 App 尚未记账便崩溃”的窗口。
- Composition Root 会承担明确的组装代码，但该复杂度集中且可测试。

## 被否决方案

### 继续扩张 `AppModel` 与 helper `switch`

短期改动少，但游戏、UI、编排和 root 能力继续耦合，无法支持稳定的工作流运行时。

### 每种能力一个 root helper

隔离更强，但第一阶段会显著放大安装、签名、XPC、升级、锁协调和恢复成本，因此不采用。

### 全局可变注册表或 Service Locator

调用方便，但依赖关系不可见、测试可被全局状态污染，运行时替换 handler 也会破坏 contract 与恢复一致性，因此禁止。

### 只在 App 侧验证 capability

无法防止被绕过的客户端或畸形 XPC payload 触发 root 操作，不构成有效安全边界，因此禁止。

## 迁移约束

1. 先建立共享 contract 与两个空注册表。
2. 保持现有 XPC 对外行为，将 helper `switch` 中能力逐项搬入 handler。
3. 抽出 WorkflowEngine，并用内建强类型 plan 迁移现有 HoYo 流程。
4. 增加用户态补偿栈、root recovery token、取消和崩溃恢复。
5. 最后开放外部 Recipe 与游戏工作流 UI。

任何副作用 handler 在具备 recovery token 和 root snapshot 语义前，都不能作为外部 Recipe 可调用步骤公开。
