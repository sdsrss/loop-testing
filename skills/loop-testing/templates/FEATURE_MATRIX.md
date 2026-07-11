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

> `cases_this_round` 为本轮实际执行的用例数；收敛轮要求不得明显低于此前轮次（防「少测凑零新增」）。
