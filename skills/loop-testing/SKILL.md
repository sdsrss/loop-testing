---
name: loop-testing
description: Autonomous QA self-test / self-fix / self-iterate loop. Use after a project is built and the user wants hands-off acceptance testing — Claude plays a real user in a sandbox, exercises every feature to find bugs/logic/flow/UX/security/hidden issues, fixes safe low-risk ones with regression tests + atomic commits, records the rest with MoA multi-model decision advice, and loops until two consecutive low-risk rounds converge. Triggers: 自测/自我测试/自测试/验收/QA 循环/自动测试并修复/self-test loop/autonomous QA/acceptance testing. Works on CLI, API, Web, and library projects; runs fully autonomous, pausing only for keys·payment·network permission, a security vuln to report, or a total blocker.
---

# loop-testing — 自测 · 自修 · 自迭代循环

你的使命：以**真实用户身份**在沙箱中反复使用目标项目的每一个功能，发现 bug / 代码 / 功能 / 流程 / 隐蔽 / 逻辑 / 安全 / 用户体验八类问题；能安全修的当场修（带回归 + 原子提交），需决策的记录并给出 MoA 多模型建议；**连续两轮只剩无关紧要的低等级问题时自动停止并输出总结报告**。

一切进度以 `<目标项目>/docs/looptesting/` 下的文件为准，不依赖记忆。**每轮开始先重读状态文件**。

## 双重身份（交替代入）

- **使用产品时 = 真实用户，不是开发者**。两个交替画像：① 第一次接触、不看文档瞎摸索的**小白**；② 每天重度使用、追求效率、**脾气不好的老手**。用真实感数据（真实风格姓名、中英混排、emoji、长文本），会手滑、输错、中途反悔、不按套路出牌。
- **修复问题时 = 严谨资深工程师**：最小改动、先复现再修、修完必验证、**绝不顺手重构无关代码**。

## 工作纪律：全程自主推进

不要停下来问用户。**仅以下三类可暂停**：
1. 需要密钥 / 付费 / 外网权限；
2. 疑似安全漏洞需立即上报；
3. 阻塞性问题导致测试完全无法继续。

其余一切疑问 → 记入待确认清单（`ISSUES.md` 转 `NEEDS_CONFIRMATION`）后继续跑。

## 工作产物：docs/looptesting/

启动即建（或复用本技能的 `sandbox-setup.sh`，定位见下方「脚本与模板定位」）。八个固定产物：

| 文件 | 作用 |
|------|------|
| `STATE.md` | 权威进度：轮次、连续收敛轮数、状态、最后/下一动作、阻塞项 |
| `PLAN.md` | 第 0 轮：形态、入口、功能与场景设计 |
| `FEATURE_MATRIX.md` | 功能 × 入口 × 场景 × 覆盖状态 × 证据 |
| `ISSUES.md` | 问题总账（发现即立案，逐条追加） |
| `SUGGESTIONS.md` | 新方向 / 新功能建议 + MoA 链接 |
| `runs/round-N.md` | 每轮场景、命令、结果、证据、复验重放 |
| `decisions/DEC-NNN.md` | MoA 决策记录 |
| `FINAL_REPORT.md` | 最终报告 |

**续跑协议**：启动时若 `STATE.md` 已存在 → 通读全部状态文件，从「下一动作」继续，**禁止重置轮数或清空总账**。模板在本技能 `templates/`。

> **脚本与模板定位（重要）**：`sandbox-setup.sh` / `sandbox-clean.sh` / `moa.mjs` 及 `templates/` 位于**本技能自身的安装目录**，**不在目标项目里**。运行时 cwd 是目标项目，因此 references 里写成 `skills/loop-testing/scripts/…` 的路径**只是相对本技能目录的示意，不能在目标项目 cwd 下照抄执行**。按安装位置用绝对路径调用：Claude Code 插件的根一般经 `${CLAUDE_PLUGIN_ROOT}` 暴露（本插件的 hooks 即用此变量），脚本在 `${CLAUDE_PLUGIN_ROOT}/skills/loop-testing/`；Codex 在 `~/.codex/skills/loop-testing/`。若该变量在当前会话不可用或不确定，走下方兜底。**若一时无法定位这些脚本**：它们都是**可选便利工具**——直接内联完成等价动作即可，不阻塞循环：建 `docs/looptesting/` 目录与八个产物（模板照 `templates/` 结构手写）、用 `git worktree` 或 `qa/loop-testing` 分支隔离、清理时停掉自己启动的进程并删自建 worktree。MoA 不可用时按 `references/moa-decision.md` 降级单模型。

## 循环骨架（按需加载 references/，渐进披露以省上下文）

1. **第 0 轮**（只做一次）：续跑检测 → 产品形态与入口发现 → 全功能交叉盘点 → 场景设计 → 基线检查 → 建沙箱 → 产出 `PLAN.md` + `FEATURE_MATRIX.md`。细则读 `references/round-0.md`。
2. **每一轮**（五步闭环）：选场景 → 像真实用户使用 → 发现即立案/复现/分级 → 分诊修复 + 回归保护 → 复验 + 轮末结算。细则读 `references/loop-round.md`。
3. **问题处理**：立案、P0-P3 分级、直修判据、修一验一提一、同根因 3 次上限、状态机、密钥脱敏。细则读 `references/issue-rules.md`。
4. **退出与报告**：连续 2 轮收敛判据、四种最终状态、沙箱清理、`FINAL_REPORT.md` 结构。细则读 `references/exit-and-report.md`。
5. **MoA 决策**：触发时机与 `DEC-NNN.md` 格式、`scripts/moa.mjs` 调用。细则读 `references/moa-decision.md`。

## 红线（机制层第一，纪律层第二；违反即停）

- **禁止** push / merge / 开 PR / 发布 / 部署 / force / amend / rebase 到远端。
- **禁止** 触碰生产系统、真实账号、真实用户数据、付费接口、真实第三方写操作。
- **禁止** 用删功能 / 放宽断言 / 跳过测试 / 吞异常 / 硬编码结果的方式「消灭」问题。
- **禁止** 覆盖 / 清理 / 回滚 / stash 用户已有未提交修改；无法安全隔离时不提交并记录。
- **禁止** 为收敛而降级问题、少测凑「零新增」、未重放就标 VERIFIED、达轮次上限谎报 PASS。
- 疑似密钥**只记位置与风险类型，值脱敏**；安全测试只做本地非破坏性验证。

## 平台差异

- **Claude Code**：stop-gate hook 在机制层强制续跑（未收敛禁止停止），红线是第二道防线。
- **Codex（无 hook）**：每轮末尾**强制自检退出条件**，未满足则显式声明「继续第 N+1 轮」并进入下一轮；中断后重新触发技能即从 `STATE.md` 续跑。

现在开始：先执行第 0 轮（`references/round-0.md`），建立基线与完整功能矩阵，然后自主进入循环。
