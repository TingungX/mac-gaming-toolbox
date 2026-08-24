# 第一阶段：原神一键启动工作流

Status: draft  
Owner: TingungX  
Last updated: 2026-08-24  
Scope: 原神、CrossOver、短时网络隔离、自动恢复、工作流基础设施  
Related code: `Sources/MacGameToolbox/AppModel.swift`, `Sources/MacGameToolboxCore/GamingServices.swift`, `Sources/MacGameToolboxCore/HostsFileEditor.swift`, `Sources/MacGameToolboxCore/NetworkProxyBypass.swift`, `Sources/MacGameToolboxPrivilegedHelper/main.swift`  
Related docs: `../design/workflow-runtime.md`, `../decisions/0001-capability-bounded-external-recipes.md`, `../decisions/0002-single-helper-dual-capability-registries.md`, `../evidence/2026-08-24-genshin-crossover-launch.md`

## 问题

当前 HoYo 启动助手在固定倒计时内写入 8 个 hosts 项并修改系统 HTTP 代理 bypass，然后要求用户手动启动游戏。用户实测原神仍无法通过反作弊；可靠的手工流程是启动游戏前完全断网，通过启动阶段后再联网。

当前证据只能证明既有 hosts/代理绕过方案没有覆盖真实失败边界，尚不能证明是遗漏某个域名、直接 IP 连接、TUN 路径或“存在任意网络连通性”触发了失败。因此不能继续凭猜测扩充域名表。

## 已确认方向

- 第一款验收游戏为原神。
- 成功基线为“先断网，再启动游戏”。
- 网络方案采用“先稳后精”：先把已验证的全局网络闸门自动化并保证恢复，同时采集证据；后续再判断能否定向隔离。
- 第一版 readiness 采用保守的渲染起点：只在当前 `YuanShen.exe` PID 出现 `UnityGfxDeviceWorker` 线程后恢复网络；用户实测约 3 秒可用只作为后续优化数据，不作为成功条件。
- 游戏流程由外部可编辑、能力受限的 Recipe 描述。
- App 侧使用不可变 `WorkflowStepRegistry`，helper 侧使用不可变 `PrivilegedCapabilityRegistry`；两边只共享稳定 `CapabilityContract`。
- 保留一个 root helper 进程，在进程内拆分能力 handler，暂不拆成多个特权服务。
- 解耦顺序优先于外部配方和新 UI：先切断 `AppModel` 与 helper 大 `switch`，再建立事务恢复，最后开放 Recipe。
- fork 最终采用独立品牌与 App 身份；`Mac GameFlow` 暂作内部工作名，品牌迁移不阻塞本 spec。

## 目标

- 用户完成一次安装绑定后，可以从游戏页一键启动原神。
- App 在启动游戏前建立短时全局网络隔离，并在检测到可靠 readiness 信号后自动恢复。
- 不再要求用户在固定 10/15/20 秒倒计时内手动启动游戏。
- 网络隔离、MetalHUD、进程识别和 QoS 作为同一 workflow 的步骤执行。
- 取消、超时、App 崩溃、helper 重启后都能恢复原始网络状态。
- 同一运行产生足以比较“正常联网 / hosts 屏蔽 / 完全断网”的结构化诊断证据。

## 非目标

- 不承诺绕过、修改或禁用反作弊程序本身。
- 不修改游戏二进制、Wine 二进制或反作弊文件。
- 不拦截或解密 TLS，不记录账号或游戏数据正文。
- 第一阶段不支持崩坏：星穹铁道、绝区零的完整配方。
- 第一阶段不实现在线配方市场。
- 第一阶段不拆分多个 root helper 进程，也不建立可在运行时修改的全局 Service Locator。
- 在获得实测证据前不决定 PF、网络服务禁用或 Network Extension 的最终方向。

## 用户流程

### 首次配置

1. 导入或选择原神 Recipe。
2. 绑定本机 CrossOver App、bottle 和原神启动目标。
3. App 验证路径、启动适配器和预期进程标识。
4. App 展示 Recipe 所需能力，特别说明会短时中断全机网络。
5. 用户确认后保存 GameInstallation。

### 一键启动

```text
预检 helper 与安装绑定
  -> 创建 run journal
  -> 开启带租约的全局网络隔离
  -> 验证隔离已经生效
  -> 自动启动原神
  -> 等待“反作弊启动阶段已通过”的 readiness probe
  -> 恢复并验证网络
  -> 对已识别的游戏进程树应用 QoS
  -> 进入运行中状态
```

任何一步失败、取消或超时都进入补偿流程。只有网络和其他系统状态验证恢复后，UI 才能显示最终失败或取消状态。

## 根因证据阶段

在选择定向隔离机制前，完成三组可重复运行：

1. 正常联网启动。
2. 当前 hosts + HTTP proxy bypass 启动。
3. 启动前完全断网，成功后恢复网络。

每组采集同一时间线：

- 活跃网络服务、默认路由与系统代理模式摘要；
- CrossOver、Wine、游戏和反作弊相关进程的出现、退出与父子关系；
- 游戏日志中与启动阶段有关的状态行，进行敏感信息过滤；
- 连接目标的地址、端口、进程和时间戳元数据，不采集 payload；
- 用户确认“通过反作弊/进入下一阶段”的时间点，仅用于为自动 probe 建立 ground truth。

分析结果需要回答：

- hosts 方案下是否仍存在绕过 DNS 的直接连接或未覆盖目标；
- 完全断网与选择性失败的可观察差异；
- 哪个本地进程或日志事件可以稳定作为恢复网络的 readiness signal；
- 定向规则能否跨代理模式、TUN 和目标地址变化保持稳定。

如果证据显示无法建立稳定定向规则，第一阶段保留短时全局网络隔离，不用易碎域名表伪装成精确方案。

### 2026-08-24 配对日志结论

同一个 CrossOver 26.2.0 launcher 会话中包含一次联网失败和一次断网成功的 `YuanShen.exe` 启动。两次都在约 3.1 秒完成 `MHYPBase.dll` 挂载；失败样本在约 6.15 秒进入 `MHYPBase.dll` 内的写访问违例并停止，成功样本则继续创建 `Astrolabe.dll`、`Noelle Main` 和 Unity 渲染线程。

成功样本在启动后约 9.9 秒出现 `UnityGfxDeviceWorker`。该事件晚于已观察到的失败分叉，且语义上对应 Unity render thread，因此确定为 `genshin.renderingStarted.v1` 的首个候选正向信号。完整时间线、证据边界和复测条件见[配对日志分析](../evidence/2026-08-24-genshin-crossover-launch.md)。在复测完成前它仍是候选，不把单个配对样本写成跨版本稳定结论。

## 网络闸门候选实现

所有候选都必须位于统一 `NetworkIsolationOperating` 抽象之后，Recipe 不感知具体机制。

### 独立 PF anchor

优点是可以原子加载/移除规则且不主动断开 Wi-Fi 关联；需要验证与 macOS 系统 PF、VPN/TUN 和现有第三方规则的共存，以及 App/helper 崩溃后的清理行为。

### 网络服务状态快照与禁用

使用系统网络服务控制，行为直观；但多网卡、VPN/Tailscale、重新关联延迟和重启后残留风险更高，恢复验证更复杂。

### Network Extension

具备长期实现按 App/flow 控制的潜力，但需要额外 entitlement、签名和分发设计。除非前两种无法满足验收标准，否则不进入第一阶段。

最终选择必须通过单独 ADR 记录，不能直接藏在实现 commit 中。

## Recipe 第一版草案

以下只表达预期语义，不是最终 schema：

```json
{
  "schemaVersion": 1,
  "id": "game.hoyo.genshin.cn",
  "revision": 1,
  "capabilities": [
    "network.globalIsolation",
    "game.launch",
    "process.observe",
    "process.qos"
  ],
  "steps": [
    { "id": "preflight", "kind": "environment.preflight" },
    { "id": "isolate", "kind": "network.isolate", "leaseSeconds": 45 },
    { "id": "launch", "kind": "game.launch" },
    { "id": "ready", "kind": "game.awaitReadiness", "probe": "genshin.renderingStarted.v1", "timeoutSeconds": 40 },
    { "id": "restore-network", "kind": "network.restore" },
    { "id": "qos", "kind": "process.applyQoS", "target": "gameProcessTree" }
  ]
}
```

`genshin.renderingStarted.v1` 必须是 App 内注册、经过实测的 probe；它只跟踪本次启动的 `YuanShen.exe` PID，并以该 PID 的 `UnityGfxDeviceWorker` 线程事件为当前候选正向信号。外部 Recipe 不能提供日志模式或 probe 脚本。若 probe 超时、目标进程提前退出或出现已知失败签名，工作流必须恢复网络并报告失败，不能因倒计时结束而报告成功。

## 实施顺序

### 0. 诊断与行为基线

- 建立可重复的三组启动记录。
- 复测 `genshin.renderingStarted.v1` readiness 候选信号。
- 为当前 `PrivilegedRequest`、helper 分发和 HoYo 流程补齐 characterization tests。
- 用证据选择全局网络闸门实现并新增 ADR；结构解耦不得预设这一结论。

退出条件：至少一条成功断网运行和对应失败对照具有完整、可比较的时间线；候选 probe 在连续三次成功与三次失败对照中无误报，并验证在 probe 后恢复网络仍可继续进入游戏。

### 1. 共享能力契约与双注册表

- 在共享 core 中建立版本化 `CapabilityContract` 与 invocation/result/recovery-handle envelope。
- 在 App Composition Root 建立不可变 `WorkflowStepRegistry`。
- 在 helper Composition Root 建立不可变 `PrivilegedCapabilityRegistry`。
- 定义重复 ID、未知版本、输入大小、权限、资源锁与副作用元数据的启动期校验。

退出条件：双注册表只能由 Composition Root 构造；启动后不可变；不存在全局 Service Locator 或任意命令 capability。

### 2. 拆分 helper 能力 handler

- 保留一个 root helper 进程和现有 XPC 对外行为。
- 将大 `switch` 中的 hosts、QoS、缓存、磁盘目录和主机名操作逐项迁入独立 handler。
- XPC service 只负责可信客户端检查、envelope 限制与 registry dispatch。
- 每个 handler 在 helper 内重新强类型解码和验证，不信任 App 侧验证结果。
- 使用 characterization tests 证明迁移前后行为一致。

退出条件：helper 核心分发不再按具体能力扩张 `switch`；现有 UI 和请求行为不变。

### 3. 抽出 WorkflowEngine 并迁移 HoYo 流程

- 实现只依赖 `WorkflowStepExecuting` 的单运行引擎。
- 先用内建、强类型 workflow plan 迁移现有 HoYo 倒计时、hosts 和 QoS 流程，不同时开放外部 Recipe。
- 将具体能力编排从 `AppModel` 移出；`AppModel` 只调用 `WorkflowCoordinating` 并映射呈现状态。
- 通过 `WorkflowStepRegistry` 接入启动、进程等待、MetalHUD 和特权 capability adapter。

退出条件：`AppModel` 和 WorkflowEngine 都不直接认识 hosts、网络、QoS handler 或具体游戏服务；旧流程行为仍可回归验证。

### 4. 事务日志、取消与崩溃恢复

- 实现用户态 workflow journal 和反向补偿栈。
- 副作用 handler 在 root journal 中先保存快照，再返回不透明 recovery handle。
- 实现取消、App 重启、helper 重启、租约过期与 stale run 恢复。
- 根据诊断证据实现选定的网络隔离 handler、租约和原神 readiness probe。
- 实现用户绑定和 CrossOver 启动适配器，将 QoS 与可选 MetalHUD 接入最终流程。

退出条件：所有步骤边界的失败、取消和模拟崩溃都有确定补偿结果；App 强退、helper 重启或租约过期不会永久断网；原神无需固定倒计时或手动启动即可完成一次成功流程。

### 5. 外部 Recipe 与游戏优先 UI

- 实现 Recipe loader、validator、GameInstallation 和 compiler。
- 外部 Recipe 只能引用 `WorkflowStepRegistry` 公开的白名单 step/capability ID；特权步骤由受信 adapter 映射到 helper contract，Recipe 不能直接访问 helper registry、注册 handler 或携带任意 shell。
- 首页改为游戏列表与每款游戏的主要启动按钮。
- 展示当前 step、恢复状态和精简日志。
- 将原有单项组件移入高级工具或游戏配置，不再与一键启动争夺主层级。

退出条件：用户能导入受限配方，并从首页完成配置、启动、取消和失败恢复，不需要理解底层组件顺序。

### 6. 身份迁移与发布准备

- 正式品牌确定后统一修改 App 名称、Bundle ID、helper service、日志 subsystem 和数据目录。
- 设计显式的一次性旧配置导入，不与上游 App 共用可写状态。
- 更新中英文 README、版权与打包脚本。

退出条件：fork 与上游 App 可并存，helper 和配置互不覆盖。

## 验收标准

- 原神可以从已绑定配置一键启动，不需要用户另行点击 CrossOver 或游戏。
- 启动前网络确实隔离，readiness 后自动恢复；不使用固定倒计时作为唯一条件。
- 正常成功运行中，网络中断时间有上限并在日志中可见。
- 取消、readiness 超时、游戏立即退出、App 强退和 helper 重启均不会永久断网。
- 恢复失败不会被报告为成功或普通取消。
- 外部 Recipe 中的任意 shell、任意 executable 和未知特权 capability 均被拒绝。
- `AppModel` 不再直接编排具体能力，helper 不再通过单一大 `switch` 实现具体能力。
- 两个注册表只在 Composition Root 组装并在启动后保持不可变。
- App 侧校验无法替代 helper 的独立解码、版本、权限和输入验证。
- 每个进入工作流的副作用 handler 都返回不透明 recovery handle，root 快照不离开 helper。
- 现有 hosts block 不再作为原神主流程的事实来源。
- 单元测试、集成测试、Swift build/test 与 Xcode 构建无新增 warning。

## 风险

- 反作弊或游戏更新可能改变 readiness 信号；probe 必须版本化并能明确报“不兼容”。
- `UnityGfxDeviceWorker` 表示渲染线程已经建立，不等同于对所有游戏版本都证明首帧已经显示；若复测出现误报，应以新 probe 版本替代，不能暗中加固定延时掩盖。
- 全局网络隔离会短时影响其他 App；首次授权与每次运行状态必须清晰可见。
- 外部 Recipe 容易被误解为脚本系统；UI 和文档必须持续强调 capability 边界。
- 当前 helper 和 App 身份仍与上游冲突；在发布或安装新构建前必须完成独立身份迁移。

## 未决问题

- `genshin.renderingStarted.v1` 能否在连续复测、游戏更新和计划支持的 CrossOver 图形后端中稳定出现，且恢复网络后不再回到失败路径？
- 首个验收环境使用哪个 CrossOver 版本、bottle 和原神渠道？
- 全局网络闸门采用哪个候选实现？
- 第一版 Recipe 的字段、大小、步骤数量和 timeout 上限是多少？
