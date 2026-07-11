# STATE — loop-testing 运行状态

> 唯一权威进度文件。每轮末与上下文将尽前必须更新。
> 机器判读字段为下方 `key: value` 行，禁止改动键名与格式（stop-gate hook 依赖它们）。

## 机器判读字段（勿改键名）

```
round: 0
converged_streak: 0
status: RUNNING
max_rounds: 12
last_updated: 1970-01-01T00:00:00Z
```

- `round`：当前已完成的轮次编号（第 0 轮完成后为 0，第一轮循环完成后为 1）。
- `converged_streak`：连续「收敛低风险轮」计数，达到 2 即可正常停止；出现任何 P0-P2 新发现立即归零。
- `status`：`RUNNING` | `CONVERGED` | `INCOMPLETE` | `BLOCKED`。仅收敛达标写 `CONVERGED`；达 `max_rounds` 未收敛写 `INCOMPLETE`；全部剩余工作被权限阻塞写 `BLOCKED`。
- `max_rounds`：防失控上限，默认 12。

## 运行上下文

- 运行平台：<Claude Code | Codex>
- 产品形态：<CLI | API | Web | 库/SDK | 插件 | 组合>
- 沙箱方式：<worktree 路径 | 分支 qa/loop-testing>
- 基线标记：qa-baseline @ <commit>
- 测试环境：<本地端口/临时数据库/mock 说明>

## 最后动作 / 下一动作

- 最后动作：<刚完成了什么>
- 下一动作：<下一步要做什么（续跑入口）>

## 阻塞项（若有）

- <逐条：阻塞点 + 需要的权限/条件 + 已尝试的替代方案>

## 续跑提示

若本文件存在即为中断续跑：通读 `docs/looptesting/` 下全部文件，从「下一动作」继续，禁止重置 `round` 或清空 `ISSUES.md`。
