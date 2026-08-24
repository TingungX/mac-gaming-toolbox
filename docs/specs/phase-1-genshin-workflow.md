# 第一阶段：原神一键启动工作流

Status: draft  
Owner: TingungX  
Last updated: 2026-08-24  
Scope: 原神、CrossOver、短时网络隔离、自动恢复、工作流基础设施  
Related code: `Sources/MacGameToolbox/AppModel.swift`, `Sources/MacGameToolboxCore/GamingServices.swift`, `Sources/MacGameToolboxCore/HostsFileEditor.swift`, `Sources/MacGameToolboxCore/NetworkProxyBypass.swift`, `Sources/MacGameToolboxPrivilegedHelper/main.swift`  
Related docs: `../design/workflow-runtime.md`, `../decisions/0001-capability-bounded-external-recipes.md`

## 问题

当前 HoYo 启动助手在固定倒计时内写入 8 个 hosts 项并修改系统 HTTP 代理 bypass，然后要求用户手动启动游戏。用户实测原神仍无法通过反作弊；可靠的手工流程是启动游戏前完全断网，通过启动阶段后再联网。

当前证据只能证明既有 hosts/代理绕过方案没有覆盖真实失败边界，尚不能证明是遗漏某个域名、直接 IP 连接、TUN 路径或“存在任意网络连通性”触发了失败。因此不能继续凭猜测扩充域名表。

## 已确认方向

- 第一款验收游戏为原神。
- 成功基线为“先断网，再启动游戏”。
- 网络方案采用“先稳后精”：先把已验证的全局网络闸门自动化并保证恢复，同时采集证据；后续再判断能否定向隔离。
- 游戏流程由外部可编辑、能力受限的 Recipe 描述。
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
    { "id": "ready", "kind": "game.awaitReadiness", "probe": "genshin.launchAccepted", "timeoutSeconds": 40 },
    { "id": "restore-network", "kind": "network.restore" },
    { "id": "qos", "kind": "process.applyQoS", "target": "gameProcessTree" }
  ]
}
```

`genshin.launchAccepted` 必须是 App 内注册、经过实测的 probe；外部 Recipe 不能提供 probe 脚本。

## 实施顺序

### 1. 诊断基线

- 建立可重复的三组启动记录。
- 找到 readiness 候选信号。
- 用证据选择全局网络闸门实现并新增 ADR。

退出条件：至少一条成功断网运行和对应失败对照具有完整、可比较的时间线。

### 2. Workflow Core

- 实现 Recipe loader、validator、GameInstallation 和 compiler。
- 实现单运行 WorkflowEngine、journal 和反向补偿。
- 先使用无特权 fake executor 完成状态机与故障注入测试。

退出条件：所有步骤边界的失败、取消和模拟崩溃都能得到确定的补偿结果。

### 3. 特权网络租约

- 扩展语义化 XPC 请求和 helper root journal。
- 实现隔离、续租、恢复、过期恢复和启动恢复。
- 验证不会覆盖或删除其他工具的网络配置。

退出条件：App 强制退出、helper 重启、租约过期后网络均自动恢复，且原始状态逐项验证一致。

### 4. CrossOver 与原神适配

- 实现用户绑定和 CrossOver 启动适配器。
- 实现经证据确认的 readiness probe。
- 将现有 QoS 和可选 MetalHUD executor 接入工作流。

退出条件：无需固定倒计时或手动启动即可完成一次成功流程。

### 5. 游戏优先 UI

- 首页改为游戏列表与每款游戏的主要启动按钮。
- 展示当前 step、恢复状态和精简日志。
- 将原有单项组件移入高级工具或游戏配置，不再与一键启动争夺主层级。

退出条件：用户能从首页完成配置、启动、取消和失败恢复，不需要理解底层组件顺序。

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
- 现有 hosts block 不再作为原神主流程的事实来源。
- 单元测试、集成测试、Swift build/test 与 Xcode 构建无新增 warning。

## 风险

- 反作弊或游戏更新可能改变 readiness 信号；probe 必须版本化并能明确报“不兼容”。
- 全局网络隔离会短时影响其他 App；首次授权与每次运行状态必须清晰可见。
- 外部 Recipe 容易被误解为脚本系统；UI 和文档必须持续强调 capability 边界。
- 当前 helper 和 App 身份仍与上游冲突；在发布或安装新构建前必须完成独立身份迁移。

## 未决问题

- 哪个进程或日志事件稳定表示原神已通过需要断网的启动阶段？
- 首个验收环境使用哪个 CrossOver 版本、bottle 和原神渠道？
- 全局网络闸门采用哪个候选实现？
- 第一版 Recipe 的字段、大小、步骤数量和 timeout 上限是多少？

