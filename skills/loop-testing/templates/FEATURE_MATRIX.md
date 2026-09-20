# FEATURE_MATRIX — 功能覆盖矩阵

> 每轮更新。每个可达功能最终必须落一个覆盖状态；`BLOCKED` 必须写明原因与解除条件，不得用「未测试」冒充通过。
> 覆盖状态取值：`PASS` | `FAIL` | `BLOCKED` | `N/A`

| 功能 | 入口 | 角色 | 场景（正常/边界/误用/恢复）| 覆盖状态 | 最近轮次 | 关联 ISSUE | 证据位置 |
|------|------|------|---------------------------|----------|----------|-----------|----------|
| <功能A> | <入口> | <小白/老手> | 正常 | PASS | R1 | — | runs/round-1.md#featA |
| <功能A> | <入口> | <老手> | 边界:超长输入 | FAIL | R1 | ISSUE-003 | runs/round-1.md#featA-boundary |

## 覆盖统计（每轮末更新，供收敛判据比对）

```
total_features: 0
covered: 0
pass: 0
fail: 0
blocked: 0
na: 0
cases_this_round: 0
```

> `cases_this_round` 为本轮实际执行的用例数。**此处是本轮的工作副本**：收敛判据读的是各轮 `runs/round-N.md` 里的同名字段（`references/exit-and-report.md` §1 判据 7 —— 本轮不得低于此前各轮最大值的 80%）。轮末必须把这个数字与本轮 `runs/round-N.md` 对齐，冲突时以轮日志为准。
