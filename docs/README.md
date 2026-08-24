# Mac GameFlow 文档索引

`Mac GameFlow` 是当前 fork 的内部工作名，不代表最终品牌、Bundle ID 或发布名称。

## 当前设计

- [工作流运行时设计](design/workflow-runtime.md) — 配方加载、执行状态机、补偿恢复与特权边界。
- [第一阶段：原神一键启动工作流](specs/phase-1-genshin-workflow.md) — 第一阶段范围、证据收集、实施顺序与验收标准。

## 已接受决策

- [ADR-0001：外部可编辑、能力受限的工作流配方](decisions/0001-capability-bounded-external-recipes.md)
- [ADR-0002：单一特权 helper 与双能力注册表](decisions/0002-single-helper-dual-capability-registries.md)
- [ADR-0003：使用临时 PF anchor 实现全局网络隔离](decisions/0003-ephemeral-pf-network-isolation.md)

## 诊断证据

- [原神 CrossOver 启动配对日志分析](evidence/2026-08-24-genshin-crossover-launch.md) — 对比联网失败与断网成功路径，记录 `genshin.renderingStarted.v1` 候选信号及复测边界。

## 文档状态

- `draft`：仍有未决问题，不能单独作为实施依据。
- `active`：描述当前系统设计，应随代码一起更新。
- `accepted`：架构决策已经接受；后续变更通过新 ADR 替代。
- `superseded`：已被更新设计或决策替代。
- `archived`：仅供历史追溯。
