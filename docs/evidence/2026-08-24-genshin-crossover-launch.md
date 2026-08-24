# 原神 CrossOver 启动配对日志分析

Status: active

Owner: TingungX

Last updated: 2026-08-24

Scope: 原神国服、CrossOver 26.2.0、断网启动、readiness probe

Related code: `../../Sources/MacGameToolbox/AppModel.swift`, `../../Sources/MacGameToolboxCore/GamingServices.swift`

Related docs: `../specs/phase-1-genshin-workflow.md`, `../design/workflow-runtime.md`

## 样本与 ground truth

原始样本 `米哈游启动器.cxlog` 来自同一个 CrossOver launcher 会话，连续包含两次参数相同的 `YuanShen.exe` 启动：

1. PID `0710`：联网启动，未通过启动阶段。
2. PID `0798`：断网启动，通过启动阶段并继续运行。

上述成功/失败标签由操作者提供。原始日志不提交到仓库，因为它包含本机路径、启动参数中的会话标识和环境摘要；用于核对样本的 SHA-256 为：

```text
ceff70d6a1980c019e144f6e0ada9eeb6543664e390726e8d58287ccb1c1c64d
```

样本环境为 CrossOver 26.2.0、64 位 Windows 10 bottle、DXMT、MoltenVK、MSync。日志实际启用了 `timestamp`、`pid`、`seh`、`unwind`、`process`、`module`、`loaddll` 和 `threadname` Wine 调试通道。

这份日志没有记录系统断网或恢复网络的准确时间，也没有连接目标或数据包元数据。因此它可以识别两条启动路径的本地分叉，不能单独证明触发失败的远端地址，也不能证明某个最短断网秒数对其他机器和版本同样成立。

## 配对时间线

两次时间都以 launcher 发出 `CreateProcessInternalW` 为 `t = 0`：

| 相对时间 | 联网失败，PID `0710` | 断网成功，PID `0798` |
|---:|---|---|
| `0.000s` | 创建 `YuanShen.exe` | 创建 `YuanShen.exe` |
| `3.153s` / `3.051s` | `MHYPBase.dll` 开始 `PROCESS_ATTACH` | `MHYPBase.dll` 开始 `PROCESS_ATTACH` |
| `3.267s` / `3.117s` | `MHYPBase.dll` 完成 `PROCESS_ATTACH` | `MHYPBase.dll` 完成 `PROCESS_ATTACH` |
| `4.848s` | 无对应事件 | `Astrolabe.dll` 完成 `PROCESS_ATTACH` |
| `4.865s` | 无对应事件 | `CrashHandler: initializing` |
| `6.150s` | `NtRaiseHardError 0x50000018` | — |
| `6.153s` | `c0000005` 写访问违例 | — |
| `6.242s` | 进程已无后续输出 | 创建 `Noelle Main` 线程 |
| `9.899s` | — | 创建 `UnityGfxDeviceWorker` 线程 |
| `12.437s` | — | 创建 `UnityMultiRenderingThread` 线程 |
| `16.426s` | — | `YuanShen.exe` 仍在持续输出 |

失败样本中的异常地址 `0x6fffeb353bc8` 位于该次加载的 `MHYPBase.dll` 映射区间 `0x6fffe9d90000-0x6fffeb492000` 内，Wine unwind 也将其归到同一个模块。异常后 PID `0710` 没有正常 detach 或继续初始化的记录，日志随后回到 launcher；这是一条可靠的失败路径特征，但当前证据不足以断言异常为何由联网触发。

两个样本都能创建 `YuanShen.exe`，也都能完成 `MHYPBase.dll` 的 `PROCESS_ATTACH`，所以这两个事件都不能作为恢复网络的 readiness 信号。`Astrolabe.dll` 和 `Noelle Main` 只出现在成功样本中，可作为诊断里程碑；但它们早于或紧贴失败样本的分叉时刻，不是当前最保守的恢复门槛。

## Phase 1 readiness 结论

第一版候选 probe 定义为 `genshin.renderingStarted.v1`：

- 只接受本次 workflow 所启动并持续跟踪的 `YuanShen.exe` PID，禁止匹配其他 Wine 进程的同名日志行。
- 正向信号为该 PID 的线程被命名为 `UnityGfxDeviceWorker`。
- `UnityMultiRenderingThread` 作为后续确认和诊断信号记录，但不额外延长正常路径的断网时间。
- 在正向信号前，如果目标 PID 退出，或出现本样本中的 `MHYPBase.dll` 访问违例签名，则立即判定启动失败并补偿恢复网络。
- 超时只触发失败与补偿，不能把固定倒计时到期伪装成 readiness 成功。

Unity 官方文档说明，在多线程渲染模式下，render thread 通过内部 `GfxDeviceWorker` 读取图形命令并转换为平台图形 API 命令。因此，这个信号比“进程存在”“模块已加载”更接近操作者所说的“游戏真正开始渲染”，同时不需要屏幕录制或像素识别权限。

CrossOver 26.2.0 的 `cxstart` 支持为单次启动指定 `--cx-log` 和 `--debugmsg`。实现时可以只采集带时间戳、PID、进程、异常、模块和线程名的必要通道，逐行解析当前 run 的临时日志；外部 Recipe 只能引用 probe ID，不能提供日志模式或任意命令。诊断导出必须过滤本机路径、账号参数和会话标识，并对单次日志设置大小与保留上限。

## 外部交叉证据

- [YAAGL 当前原神启动实现](https://github.com/yaagl/yet-another-anime-game-launcher/blob/ca78abc29c2fc236261d088c6907d28cab6e9476/src/clients/mhy/hk4e/program-launch-game.ts#L133-L149)在启用 launch fix 时写入临时 hosts 项，并在 10 秒后移除。它只能支持“约 10 秒是社区实践中的保守量级”，不能证明其域名规则覆盖本项目的国服失败路径。
- [HoyoNetFix 实现](https://github.com/Augmeneco/HoyoNetFix/blob/410d472be4a5c4ca9ad089f76442cf08a5586cac/hoyonetfix.c#L18-L109)默认在 10 秒内拒绝非本地网络调用。它是 Linux `LD_PRELOAD` 方案，只作为时间尺度和“完整网络失败语义”的旁证，不作为 macOS 实现候选，也不采信其未经独立验证的反作弊安全声明。
- [Reddit 上的 CrossOver 实测](https://www.reddit.com/r/macgaming/comments/1k7ld92/problem_with_genshin_on_whisky/)描述了启动前断网、进入游戏后恢复的手工流程；相邻 HoYoverse 游戏的实测也常以看到 HoYoverse 标志为恢复时刻。这些是用户经验，不是稳定契约。
- [Unity 多线程渲染文档](https://docs.unity3d.com/6000.0/Documentation/ScriptReference/Rendering.RenderingThreadingMode.MultiThreaded.html)给出了 `GfxDeviceWorker` 与 render thread 的语义依据。

操作者在当前机器上观察到约 3 秒断网也可能成功。该数值作为后续优化的经验下界记录，不进入 `genshin.renderingStarted.v1` 的成功条件；第一版优先选择约 10 秒出现的渲染线程事件，而不是依赖固定 3 秒计时。

## 尚需验证

在把候选 probe 标记为稳定前，至少补充以下复测：

1. 连续三次断网成功启动都出现 `UnityGfxDeviceWorker`，并在该事件后恢复网络仍能继续进入游戏。
2. 连续三次联网失败启动都不会在失败前出现该事件。
3. 记录游戏版本、渠道、CrossOver 版本、bottle 图形后端和从启动到 probe 的耗时分布。
4. 验证日志截断、行拆分、PID 复用、launcher 二次启动和 probe 超时时均不会误报 readiness。
5. 游戏或 CrossOver 更新后若事件缺失，probe 明确报告“不兼容”，不得自动退回固定倒计时成功。
