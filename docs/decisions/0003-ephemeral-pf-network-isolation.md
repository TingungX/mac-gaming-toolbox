# ADR-0003：使用临时 PF anchor 实现全局网络隔离

Status: accepted

Owner: TingungX

Last updated: 2026-08-24

Scope: 第一阶段全局网络隔离、租约、崩溃恢复与 PF 共存

Related code: `Sources/MacGameToolboxPrivilegedHelper/`, `Sources/MacGameToolboxCore/PrivilegedXPC.swift`

Related docs: `../design/workflow-runtime.md`, `../specs/phase-1-genshin-workflow.md`, `0002-single-helper-dual-capability-registries.md`

## 背景

原神当前可重复的成功基线是在启动前完全断网，进入渲染阶段后恢复网络。本机当前同时存在 Wi-Fi、以太网硬件端口、Tailscale、Shadowrocket 和其他 VPN 服务，默认路由实际经过 `utun`。只关闭 Wi-Fi 不能构成全局隔离；依次禁用所有网络服务也不是原子操作，且很难准确恢复 VPN/TUN 的连接状态。

第一阶段需要一个短时、全局、与接口数量无关的网络闸门，同时不能覆盖系统或其他软件已有的 PF 配置。

## 决策

采用 root helper 管理的临时 PF 子 anchor。该能力是 helper 内的原子、可回滚 capability；Recipe、WorkflowEngine 和 `AppModel` 不感知 PF 细节。

### Anchor 与规则边界

- 使用 `/etc/pf.conf` 现有的 `anchor "com.apple/*"` attachment point，在其下加载项目独占的直接子 anchor。
- 当前身份阶段的 anchor 名集中定义为 `com.apple/100.com.iven.macgametoolbox`；正式身份迁移时统一替换，不散落在 Recipe 或业务代码中。
- 子 anchor 排序在当前 `200.AirDrop` 与 `250.ApplicationFirewall` 之前，内部使用 `quick` 规则，使隔离不依赖后续 anchor 的 pass 规则。
- 规则只允许 loopback，阻断其余双向 IPv4/IPv6 流量：

```text
pass quick on lo0 all
block drop quick all
```

- 不修改 `/etc/pf.conf`，不 reload 或 flush 主 ruleset，不读取后再重写其他 anchor，也不接管其他组件的 PF enable reference。
- preflight 必须确认预期 wildcard attachment point 仍存在；若 macOS 更新改变该边界，则在产生副作用前明确失败，不能自动改写系统配置。

### 建立隔离

handler 按 write-ahead 顺序执行：

1. 验证可信 XPC client、contract version、单 active run、5–60 秒租约上限和全局网络资源锁。
2. 生成不透明 recovery token，并将 run、token、anchor、租约截止时间和 `prepared` 状态原子写入权限为 `0600` 的 root journal。
3. 只向项目 anchor 加载固定规则；规则文本不来自 App 或 Recipe。
4. 使用 `pfctl -E` 获取本次能力自己的 PF enable reference token，并更新 root journal。
5. 在阻断规则已生效后清理现有 PF states，确保隔离前已经建立的连接不能继续绕过新规则。
6. 验证 PF 已启用且项目 anchor 中只有预期规则，再将 token 标记为 `active` 并返回 opaque recovery handle。

清理既有 states 会中断其他 App 的 TCP/UDP 会话；恢复网络只恢复连通性，不能复活原连接。这与“全机短时断网”的产品语义一致，必须在首次授权和运行状态中明确展示。

### 恢复与租约

- rollback 只接受 helper 生成并仍在 root journal 中的 recovery handle；伪造、跨 run 或错误版本 handle 被拒绝。
- 恢复时先清空项目 anchor，再使用 `pfctl -X` 释放本次 `pfctl -E` 获得的 enable token，绝不直接 `pfctl -d`。
- 恢复操作幂等；anchor 已空、token 已释放或 App 重试都不能影响其他 PF 使用者。
- helper 为 active token 维护租约计时器。租约到期自动恢复；App 只能在 contract 上限内续租。
- helper 重启时读取 root journal：已过期的 token 立即恢复，未过期的 token 重建剩余租约计时器。系统重启会清空临时 PF rules，helper 随后清理过期 journal。
- App journal 只保存 opaque handle 和补偿顺序，不保存 PF enable token、规则或 root 快照。

### 失败语义

- 任一步骤失败都进入同一幂等恢复路径；即使失败发生在“anchor 已加载但回复尚未发给 App”的窗口，helper 也能根据 root journal 清理。
- readiness 成功、用户取消、游戏提前退出、probe 超时和 workflow 崩溃都调用相同 rollback。
- 恢复验证失败必须报告 `recoveryFailed`，不能显示普通失败或取消完成。
- 第一阶段只允许一个 active workflow；并发网络隔离请求明确返回资源冲突。

## 结果

正面影响：

- 一次规则切换覆盖 Wi-Fi、以太网、热点和当前/未来的 `utun`，不依赖接口枚举。
- 加载和清空独立 anchor 是原子、局部的，不需要改变用户网络服务配置。
- PF enable reference、固定 anchor、root journal 和租约可以形成确定的崩溃恢复协议。
- helper handler 可以独立测试；上层只依赖稳定 `network.globalIsolation` contract。

代价与风险：

- 必须以 root 调用 PF，并维护 enable token 和 crash window。
- 为保证已有连接也被隔离，需要清理全局 PF states，会中断其他 App 的现有连接。
- 依赖 macOS 当前保留 `com.apple/*` wildcard anchor；系统配置变化必须显式判为不兼容。
- PF 规则证明“本机已配置阻断”，不等同于远端连通性测试；验证需要同时检查 PF 状态、anchor 内容与 workflow 的实际启动结果。

## 被否决方案

### 依次禁用所有网络服务

`networksetup` 可以保存并恢复 enable 状态，但 Wi-Fi、以太网和多个 VPN/TUN 服务需要逐项切换，中间存在部分联网窗口。VPN extension 的运行状态也不等同于 network service enable 位，恢复延迟和失真风险更高。

### 只关闭 Wi-Fi

无法覆盖以太网、USB 网络、热点或 `utun` 默认路由，不满足“全局隔离”的事实语义。

### 删除默认路由

需要同时处理 IPv4、IPv6、物理接口和动态隧道路由；VPN 可以重新注入路由，恢复快照也容易过期。

### Network Extension

长期可以提供更细粒度控制，但第一阶段会引入 entitlement、系统扩展安装、签名与分发成本。若 PF 在受支持系统上不可用，再通过新 ADR 替代本决策。
