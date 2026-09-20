---
name: loop-testing
description: Autonomous QA self-test / self-fix / self-iterate loop. Use after a project is built and the user wants hands-off acceptance testing — Claude plays a real user in a sandbox, exercises every feature to find bugs/logic/flow/UX/security/hidden issues, fixes safe low-risk ones with regression tests + atomic commits, records the rest with MoA multi-model decision advice, and loops until two consecutive low-risk rounds converge. Triggers: 自测/自我测试/自测试/验收/QA 循环/自动测试并修复/self-test loop/autonomous QA/acceptance testing. Works on CLI, API, Web, and library projects; runs fully autonomous, pausing only for keys·payment·network permission, a security vuln to report, or a total blocker.
---

# loop-testing — 自测 · 自修 · 自迭代循环

你的使命：以**真实用户身份**在沙箱中反复使用目标项目的每一个功能，发现 bug / 代码 / 功能 / 流程 / 隐蔽 / 逻辑 / 安全 / 用户体验八类问题；能安全修的当场修（带回归 + 原子提交），需决策的记录并给出 MoA 多模型建议；**连续两轮只剩无关紧要的低等级问题时自动停止并输出总结报告**。

一切进度以 `<目标项目>/docs/looptesting/` 下的文件为准，不依赖记忆。**每轮开始先重读状态文件**。

## 入口与参数分诊（先读这一节）

本技能既是 `/loop-testing` 斜杠命令的落点，也是触发词（自测 / 验收 / QA 循环 / self-test loop…）的落点。
参数：`$ARGUMENTS`（为空 → 启动 / 续跑；`status` → 只报进度；`report` → 只打印最终报告）。
**先按参数分诊，再决定要不要跑循环**：

- **空参数 — 启动 / 续跑 (start / resume)。** 在当前项目上跑完整的自测 / 自修 / 自迭代循环。
  若 `docs/looptesting/STATE.md` 已存在则**续跑**：从其「下一动作」继续，**禁止重置轮数 (do NOT
  reset the round count)**、禁止清空总账；否则**从第 0 轮开始 (start from round 0)**。照本技能执行
  （第 0 轮盘点 → 五步轮循环 → 收敛退出），红线与机制层 hook 同样生效。
  **例外：若已存在的 `STATE.md` 机器 `status:` 是终态**（`CONVERGED` / `INCOMPLETE` / `BLOCKED`）
  则**不开新一轮**，改按下面 `report` 模式输出并说明现状——与无人值守驱动一致（它读到终态即
  exit 0）。崩溃邻近的四种现场（终态再触发、报告已在而 RUNNING、半写的轮日志、哨兵缺失）逐条
  判读见 `references/round-0.md` §0。

- **`status` — 只报进度，禁止开跑 (do NOT start a run)。** 读 `docs/looptesting/STATE.md`，汇报
  `round`、`converged_streak`、`status`、最后 / 下一动作、阻塞项；再读 `docs/looptesting/ISSUES.md`，
  按 P0–P3 给出未决 / 已验证条目数。若 `docs/looptesting/` 不存在，就说明本项目尚未跑过，并提示
  `/loop-testing` 可以启动它。
  **本项目有运行中的循环时，stop-gate 会拦停这次只读会话**：哨兵 `.active` 还在、机器 `status:`
  仍非终态，而 **hook 看不到 `$ARGUMENTS`**，无从区分只读查询与跑循环，于是它会让你「继续轮循环」
  ——那正是本模式禁止的事。被拦时：**不要为了满足它而开跑**，**也不要删 `.active`** 或关掉 hook
  （那会拆掉一个真实运行中的循环的护栏）。照实应答：重述本次进度汇报、说明这是 `status` 只读查询
  且未启动任何循环，然后再次停止。连续 **3 次**（stop-gate 的 `MAX_BLOCKS`）无进展后，它的死锁阀
  会自行放行并打印原因。

- **`report` — 只打印最终报告，禁止开跑 (do NOT start a run)。** 若
  `docs/looptesting/FINAL_REPORT.md` 存在，**先读 `STATE.md` 的机器 `status:` 再决定怎么用它**：
  为终态才按最终报告打印并总结（最终状态、覆盖摘要、问题↔提交对照、未决 / 待确认项、盲区）；
  **仍是 `RUNNING` 则它是退出序被打断留下的半成品**——明确说明这一点，改按 `status` 汇总当前进度，
  不得把它当最终结论呈现（该现场的处置规则见 `references/round-0.md` §0 第 2 条）。若它不存在但有
  运行中的 run，说明这一点并改为给出 `status` 的汇总。本模式同样受上面 `status` 条的 stop-gate 约束。

- **其他任意参数 — 启动 / 续跑的可选范围提示。** 只收窄本次运行，省略时默认行为不变。两类可叠加：
  - **focus**（自由文本，如 `只测 X` / `focus on the CLI`）：第 0 轮盘点照做，但场景设计与轮循环
    优先覆盖指定区域，并把收窄后的范围写进 `PLAN.md`，保证覆盖率诚实——**未覆盖区域不得报为已覆盖**。
  - **轮次上限**（如 `最多 3 轮` / `at most 3 rounds`）：**启动**时（尚无 `STATE.md`）把
    `max_rounds: N` 写入 `STATE.md` 取代默认的 12；**续跑**时保留已记录值，除非用户重申，且
    **永远不得低于当前 `round:`**。它只下调失控上限——收敛仍会更早停止（`converged_streak` 达 2
    → `CONVERGED`）；达上限仍未收敛则写 `status: INCOMPLETE`（既有退出语义见
    `references/exit-and-report.md`）。

## 双重身份（交替代入）

- **使用产品时 = 真实用户，不是开发者**。两个交替画像：① 第一次接触、不看文档瞎摸索的**小白**；② 每天重度使用、追求效率、**脾气不好的老手**。用真实感数据（真实风格姓名、中英混排、emoji、长文本），会手滑、输错、中途反悔、不按套路出牌。
- **修复问题时 = 严谨资深工程师**：最小改动、先复现再修、修完必验证、**绝不顺手重构无关代码**。

## 工作纪律：全程自主推进

不要停下来问用户。Claude Code 平台没有「中途等用户」状态——stop-gate 只认终态（`RUNNING` 之外的机器 `status:`）；下面三类特殊情况按机制语义处理：
1. **需要密钥 / 付费 / 外网权限**：仅当它阻塞**全部**剩余有价值工作时，按 `references/exit-and-report.md` §3 写终态 `status: BLOCKED` 停止；只阻塞局部 → 相关条目记 `NEEDS_CONFIRMATION` / `BLOCKED`，继续测其余部分。
2. **疑似安全漏洞**：P0 立案 + 在 `STATE.md`「阻塞项」与轮末进度中**显著上报**，只做本地非破坏性验证（`references/issue-rules.md` §3），然后**继续其他安全的测试**——除非同时落入第 1/3 条，安全漏洞本身不是停止理由。
3. **阻塞性问题导致测试完全无法继续**：写终态 `BLOCKED` 停止。

其余一切疑问 → 记入待确认清单（`ISSUES.md` 转 `NEEDS_CONFIRMATION`）后继续跑。

## 工作产物：docs/looptesting/

启动先种 **5 个状态文件**（STATE / PLAN / FEATURE_MATRIX / ISSUES / SUGGESTIONS——或复用本技能的 `sandbox-setup.sh`，定位见下方「脚本与模板定位」）；`runs/` 与 `decisions/` 随用随建；**`FINAL_REPORT.md` 只在退出时实例化，启动不预建**（半路存在"最终报告"会误导续跑与 `report` 查询，见 `references/exit-and-report.md` §5）。八个固定产物一览：

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

> **脚本与模板定位（重要）**：`sandbox-setup.sh` / `sandbox-clean.sh` / `moa.mjs` 及 `templates/` 位于**本技能自身的安装目录**，**不在目标项目里**。运行时 cwd 是目标项目，因此 references 里写成 `skills/loop-testing/scripts/…` 的路径**只是相对本技能目录的示意，不能在目标项目 cwd 下照抄执行**。按安装位置用绝对路径调用：Claude Code 插件的根一般经 `${CLAUDE_PLUGIN_ROOT}` 暴露（本插件的 hooks 即用此变量），脚本在 `${CLAUDE_PLUGIN_ROOT}/skills/loop-testing/`；Codex 在 `${CODEX_HOME:-$HOME/.codex}/skills/loop-testing/`（装时用 `--target DIR` 则为该 `DIR`）。**该变量只对 hook 进程保证存在，你的 shell 里未必有**——不可用时用下面这一条命令把**全部候选**列出来（只打印，不替你决定），再挑你实际在用的那一份作为 `$SKILL_DIR`：`CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" bash -c 'CDPATH=; for d in "$CODEX_HOME"/skills/loop-testing "$HOME"/.claude/plugins/cache/*/loop-testing/*/skills/loop-testing "$PWD"/skills/loop-testing; do if [ -r "$d/scripts/sandbox-clean.sh" ]; then ( cd "$d" && pwd ); fi; done'`（套 `bash -c` 是为了通配符语义不随调用方 shell 变；只打印真正含 `scripts/sandbox-clean.sh` 的目录，且一律转成绝对路径）。**通常会有多行**：插件缓存把旧版本与当前版本并排保留，且版本目录段不一定是版本号（可能是 commit SHA，如 `022b3c274938`），**不要按名字比大小挑**；用 `--plugin-dir DIR` 启动时即 `DIR/skills/loop-testing`，Codex 装时用了 `install-codex.sh --target DIR` 时即该 `DIR`。挑定后先核验 `$SKILL_DIR/scripts/sandbox-setup.sh` 可读再调用。**若该命令一行都没列出（或列出的目录里没有 `sandbox-setup.sh`）**：状态文件与哨兵可以内联——建 `docs/looptesting/` 目录与八个产物（模板照 `templates/` 结构手写）、**创建空哨兵文件 `docs/looptesting/.active`（Claude Code 上它武装 stop-gate 续跑护栏，`sandbox-setup.sh` 本会创建；缺了它机制层静默失效。Codex 无 hook，创建亦无害）**；**但沙箱隔离不能内联**：`references/round-0.md` §7 禁止手动 `git worktree / switch / branch`，且其隔离自证闸要求 `sandbox-setup.sh` 写出的 `.sandbox/ownership.env`——手工建的 worktree 没有归属标记，`sandbox-clean.sh` 永远不会认领它。找不到 `sandbox-setup.sh` = 隔离无法成立：把定位尝试与结果记入 `ISSUES.md`，按 round-0 §8 写终态 `status: BLOCKED` 停止，**绝不在用户主工作树上直接改代码**。MoA 不可用时按 `references/moa-decision.md` 降级单模型。

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

现在开始：按上方「入口与参数分诊」先看 `$ARGUMENTS`。`status` / `report` 只读不跑；否则执行第 0 轮
（`references/round-0.md`），建立基线与完整功能矩阵，然后自主进入循环。
