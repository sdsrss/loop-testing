# loop-testing

**[English](README.md) | 简体中文**

[![CI](https://github.com/sdsrss/loop-testing/actions/workflows/ci.yml/badge.svg)](https://github.com/sdsrss/loop-testing/actions/workflows/ci.yml)

> **面向 Claude Code 与 Codex 的自主 QA 循环。** 让 AI 智能体以**真实用户身份**在沙箱里
> 反复使用你已完成的项目——自动发现 bug、自动修复能安全修的、自动收敛。一条命令,全程放手。

`loop-testing` 是一个双平台技能,支持 [Claude Code](https://claude.com/claude-code) 与
[OpenAI Codex](https://openai.com/codex/)。项目开发完成后,它驱动 AI 智能体从真实用户入口
(CLI / API / Web / 库)把每个功能都用一遍,发现 **bug / 逻辑 / 流程 / 边界 / 隐蔽 / 安全 /
体验**等问题,**能安全修的当场修**(复现 → 修根因 → 加回归测试 → 原样重放复验 → 原子提交),
需要拍板的交给**多模型委员会**决策,直到**连续两轮只剩无关紧要的小问题**才停止。全程自主推进,
仅在需要密钥 / 付费 / 外网权限、疑似安全漏洞、或阻塞性问题时才暂停问你。

---

## ✨ 优秀亮点

- **真用产品,不是只读代码。** 从真实入口用真实感数据实际操作、会手滑、会中途反悔、不按套路
  出牌,而非静态扫代码或只跑现成测试。
- **发现即修复。** 低风险问题当场修:复现 → 修根因 → 加回归断言 → 原样重放复验 → 单独原子提交
  (`fix(qa): [ISSUE-xxx]`)。
- **多模型决策(MoA)。** 产品决策类问题不擅自拍板:多个参考模型并行分析 → 聚合模型给最终建议
  → 落盘成决策记录供你确认。
- **反作弊收敛。** 连续两轮"干净轮"才停,且第二轮必须换场景反证;覆盖量不许缩水、未重放不许标
  通过、达轮次上限如实报 `INCOMPLETE`,绝不谎报 `PASS`。
- **断点续跑。** 一切进度写在文件里,会话中断或上下文压缩后重新触发即从断点继续,不重置轮数、
  不清空台账。
- **机制层强化(Claude Code)。** Stop-hook 拦截未收敛的停会话——fail-closed,带有界死锁阀
  (同轮 3 次拦截后强制放行、24h 崩溃残留自动解除、`LOOP_TESTING_DISABLE_STOP_GATE=1` 退出);另一个 hook
  抬高伪造"已验证"的成本——best-effort、可被绕过,残余靠红线纪律与人工 diff 审查兜底,并非硬拦截。
- **一份技能,两个平台。** Claude Code 与 Codex 共用同一 `SKILL.md`,一个仓库两处安装。
- **安全内建。** 沙箱隔离、失败即拒(fail-closed)、密钥只从环境变量读且日志脱敏、绝不
  push / 部署 / 碰生产。

---

## 🧩 功能说明

| 能力 | 说明 |
|---|---|
| **双重身份** | 用产品时是真实用户(两个交替画像:不看文档的小白 / 追求效率的暴躁老手);修问题时切换严谨工程师(最小改动、先复现再修、修完必验证、不顺手重构)。 |
| **第 0 轮盘点** | 识别产品形态与入口,交叉盘点全部可达功能,设计正常 / 边界 / 误用 / 取消恢复场景,跑基线检查,产出 `PLAN.md` + `FEATURE_MATRIX.md`。 |
| **每轮闭环** | 选场景 → 像真实用户使用 → 发现即立案 / 复现 / 分级(P0-P3)→ 分诊修复 + 回归保护 → 原样重放复验 → 轮末结算。 |
| **问题台账** | 所有问题(含顺手发现的)先立案再处理,状态机全程可审计(`OPEN / FIXING / FIXED_UNVERIFIED / VERIFIED / NEEDS_CONFIRMATION / BLOCKED / WONT_FIX / CANNOT_REPRODUCE`)。 |
| **MoA 决策引擎** | 零依赖 Node 脚本,支持 OpenAI / OpenRouter 双格式、代理优先、优雅降级,产出结构化决策记录。 |
| **无头续跑驱动** | `unattended-loop.sh`(Claude)/ `unattended-codex.sh`(Codex)反复从断点续跑到收敛,带墙钟看门狗、熔断器与并发锁。 |
| **沙箱建 / 清** | `git worktree` 隔离 + 归属标记;清理失败即拒(无标记不删),保留证据、不碰用户数据。 |

一切进度写在目标项目的 `docs/looptesting/`(默认保留但不提交,也不改动你的 `.gitignore`):

| 文件 | 作用 |
|---|---|
| `STATE.md` | 权威进度:轮次、连续收敛轮数、状态、下一动作、阻塞项。 |
| `PLAN.md` | 第 0 轮:产品形态、入口、功能与场景设计。 |
| `FEATURE_MATRIX.md` | 功能 × 入口 × 场景 × 覆盖状态 × 证据位置。 |
| `ISSUES.md` | 问题总账(发现即立案,含状态机)。 |
| `SUGGESTIONS.md` | 新方向 / 新功能建议 + MoA 决策链接。 |
| `runs/round-N.md` | 每轮场景、命令、结果、证据、复验重放。 |
| `decisions/DEC-NNN.md` | MoA 多模型决策记录。 |
| `FINAL_REPORT.md` | 最终状态 + 覆盖摘要 + 修复清单(问题 ↔ commit)+ 待确认清单 + 盲区。 |

---

## 🆚 差异对比

| | 单元测试 / CI | 一次性 AI 代码审查 | **loop-testing** |
|---|---|---|---|
| 发现方式 | 校验**已知**断言 | 静态读代码 | **实际使用**产品找**未知**问题 |
| 覆盖视角 | 开发者写的用例 | 单次快照 | 真实用户 + 误操作 + 边界 + 恢复 |
| 处理问题 | 只报红 | 给建议 | 安全的**当场修 + 回归 + 提交** |
| 决策类问题 | 不涉及 | 单模型建议 | **MoA 多模型委员会** |
| 何时停 | 跑完即止 | 单轮结束 | **收敛才停**(反作弊、诚实报告) |
| 中断恢复 | 重跑 | 重来 | **文件断点续跑** |

一句话:单元测试防回归,AI 审查看代码,**loop-testing 像真实用户一样把产品用崩再修好。**

---

## 📦 安装方式

### Claude Code(插件)

```bash
/plugin marketplace add sdsrss/loop-testing
/plugin install loop-testing@loop-testing
```

本地 / 未发布——直接以插件目录加载:

```bash
claude --plugin-dir .
```

机制增强层(Stop-hook 强制续跑 + VERIFIED 防伪写的 best-effort 成本抬升)由 `hooks/` 提供,
随插件自动加载。已实测 `/plugin install` 与 `--plugin-dir` 两种模式下 Stop hook 均自动生效;
极旧版本若不自动加载,按 `hooks/` 内说明手动注册。

**更新:** `claude plugin update loop-testing`。插件还带一个 **SessionStart 通知**:装的版本
落后于 GitHub 最新 tag 时,会话开始提示一行"有新版可用"——**只提示不自动下载**,每 24 小时至多
查一次,离线或本地开发模式即静默。关闭:`LOOP_TESTING_DISABLE_UPDATE_CHECK=1`。

### Codex(技能目录)

Codex 与 Claude Code 共用同一 `SKILL.md` 格式,用随仓库脚本安装:

```bash
bash install/install-codex.sh                 # 装到 ~/.codex/skills/loop-testing
bash install/install-codex.sh --target <dir>  # 指定技能目录
bash install/install-codex.sh --dry-run       # 只打印动作,不写文件
bash install/install-codex.sh --check-update  # 比对已装版本与 GitHub 最新 tag
bash install/install-codex.sh --uninstall     # 卸载(fail-closed:非本插件目录拒删)
```

脚本**幂等**(重装先备份 `<dest>.bak`)、**只删自己装的目录**(依据 `.loop-testing-codex-install`
标记)。**更新技能后必须重跑此脚本**——Codex 侧无自动更新,否则会静默运行旧副本;`--check-update`
会在有新版时提醒你。

---

## 🚀 使用说明

### 启动

在目标项目里,两种方式都行:

- **Slash 命令(确定性,不靠触发词):**
  - `/loop-testing` —— 启动或续跑循环
  - `/loop-testing status` —— 读 `STATE.md` 报当前进度
  - `/loop-testing report` —— 打印 `FINAL_REPORT.md`
  - `/loop-testing <聚焦 / 轮上限>` —— 可选收窄本次运行,如 `只测 X`、`最多 3 轮`(轮上限只下调 `max_rounds`,收敛仍优先)。省略即全量循环。
- **触发词** —— 对智能体说以下任一:
  > `自测` · `验收` · `QA 循环` · `自动测试并修复` · `self-test loop` · `autonomous QA` · `acceptance testing`

Codex 侧同样的 `/loop-testing` prompt 由 `install-codex.sh` 一并安装(默认 / `CODEX_HOME`
布局下装到 `~/.codex/prompts/`)。

### 无头 / 长时运行

`claude -p` 与 `codex exec` 都是单次调用,长循环可能未收敛就结束。无头运行请用外层续跑驱动,
它反复从 `STATE.md` 断点续跑到终态:

```bash
# Claude Code 无头
bash skills/loop-testing/scripts/unattended-loop.sh --project <目标项目> \
  --max-sessions 15 --max-minutes 240 --plugin-dir <本插件目录>

# Codex 无头
bash skills/loop-testing/scripts/unattended-codex.sh --project <目标项目> \
  --max-minutes 90 --session-minutes 40
```

退出码:`0` 技能自身收敛终态 · `2` 参数错误 · `3` 达 `--max-sessions` · `4` 达 `--max-minutes`
· `5` 连续两会话无进展。每会话进度写入 `docs/looptesting/driver.log`。

### MoA 多模型决策配置

需决策的问题走 `scripts/moa.mjs`(Node ≥ 20,零第三方依赖)。**API key 只从环境变量读,日志一律脱敏。**

| 环境变量 | 作用 |
|---|---|
| `OPENROUTER_API_KEY` | OpenRouter key(base 默认官方地址) |
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | OpenAI 兼容端点 key 与 base |
| `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` | 存在即 LLM 调用走代理 |
| `LOOP_TESTING_MOA_MODELS` | 逗号分隔覆盖参考模型 |
| `LOOP_TESTING_MOA_AGGREGATOR` | 覆盖聚合模型 |
| `LOOP_TESTING_MOA_TIMEOUT_MS` | 单次调用超时毫秒(默认 120000) |

也可用 `docs/looptesting/moa.config.json` 或 `--config <path>` 覆盖。
**默认模型为发布时校准的顶级组合,会过时——请按需覆盖。**

```bash
node skills/loop-testing/scripts/moa.mjs --input <ctx.md> --output <DEC.md>
node skills/loop-testing/scripts/moa.mjs --input <ctx.md> --dry-run   # 只打印配置,不发请求
```

**降级链:** 部分参考模型失败 → 用其余继续 → 全部失败 → 仅聚合模型出建议 → 聚合失败 / 无 key
→ 退出码 2,编排层改单模型建议。循环绝不阻塞。

---

## ❓ 常见问题

**Q:它和单元测试 / CI 有什么区别?**
单元测试和 CI 校验你**已经写好**的断言,防止回归;loop-testing 像真实用户一样**实际使用**产品,
去发现你**没想到**的 bug、体验和逻辑问题,能修的还顺手修掉。两者互补。

**Q:它会不会擅自改我的代码、把东西搞坏?**
只在沙箱分支 / worktree 里改,且只做低风险、可验证、不改变产品语义的修复;每个修复单独原子提交、
可回滚。全程禁止 push / 部署 / 碰生产 / 动你的未提交改动。需要决策的一律记录不擅动。

**Q:需要联网 / API key 吗?**
QA 循环本体离线可用。只有 MoA 多模型决策需要 LLM API(`OPENROUTER_API_KEY` 或 OpenAI 兼容端点);
没有 key 时自动降级为单模型建议,不阻塞。环境有代理会自动走代理。

**Q:会话跑一半断了 / 上下文满了怎么办?**
一切进度写在 `docs/looptesting/` 文件里。重新触发技能即从 `STATE.md` 断点续跑,不重置轮数、
不清空台账。无头长跑用 `unattended-*.sh` 驱动自动续跑到收敛。

**Q:它什么时候算"做完"?**
连续两轮"收敛低风险轮"(无新增 P0-P2、完成全功能回归且覆盖不缩水)才正常停止,输出
`FINAL_REPORT.md`。达轮次上限仍未收敛则如实标 `INCOMPLETE`,绝不把"用完轮次"写成"通过"。

**Q:Claude Code 和 Codex 上体验一样吗?**
核心技能与产物完全一致。区别:Claude Code 有 hooks 机制层(未收敛机制性禁止停止);Codex 无
hooks,靠提示词纪律 + 无头驱动兜底(详见"已知限制")。

---

## ⚠️ 已知限制

- **Codex 无机制层 gate。** Codex 没有 Stop-hook,续跑与"未收敛禁止停止"仅靠提示词纪律。已实测
  一次真实 Codex 会话把完整循环驱到合法收敛,但为单模型单样例;建议以 `unattended-codex.sh`
  多会话续跑兜底。
- **Codex 侧 stale 安装。** 改了技能后必须重跑 `install-codex.sh`(无自动更新);`--check-update`
  会在有新版时提醒。
- **MoA 默认模型会过时。** 默认模型列表为发布时校准,遇 provider 白名单会优雅 404——按需经
  环境变量 / 配置覆盖。
- **无头单次调用截断。** `claude -p` / `codex exec` 单次可能未收敛就结束——无头运行请用续跑驱动。
- **Node ≥ 20 仅 MoA 需要。** QA 循环本体离线可用;缺 Node 时 MoA 降级为单模型建议。

### 卡住的哨兵 / 崩溃残留恢复

`docs/looptesting/.active` 是 Stop-hook 的续跑哨兵。正常退出时会自动摘除;若一次运行被强杀
(`SIGKILL`)而 `STATE.md` 停在非终态,哨兵可能残留、导致此后每次停止被反复拦截。恢复方式(任一):

- **自动:** Stop-hook 会把 `STATE.md` 超过 24 小时未更新的非终态运行(可用
  `LOOP_TESTING_GATE_STALE_SECONDS` 覆盖,`0` 关闭)判为遗弃,摘哨兵并放行。
- **手动:** `rm docs/looptesting/.active`,或本次会话设 `LOOP_TESTING_DISABLE_STOP_GATE=1`。
- **续跑:** 重新触发技能即从 `STATE.md` 断点继续(不重置轮数)。

**并发锁 `docs/looptesting/.driver.lock`:** 无人值守驱动启动时建此锁,避免两个驱动在同一项目上
并发跑而互相污染 STATE / 台账 / worktree。正常退出即释放,持有 PID 已死则自动偷用。这是**尽力而为
的防误重启守卫,非硬互斥**。若某次被 `SIGKILL` 且锁内 PID 不可读,后续启动会**保守拒绝**并提示——
确认无驱动在跑后 `rm -rf docs/looptesting/.driver.lock` 即可。

**提前停掉无人值守长跑:** Ctrl-C(SIGINT 打到整个进程组)会立即停掉驱动与子会话。裸的
`kill -TERM <driver-pid>` 只在**会话间隙**生效——bash 在前台子进程运行期间推迟 trap,最坏延迟
= 剩余会话预算(`--session-minutes`,受看门狗封顶)。程序化即时停机请对进程组发信号:
`kill -TERM -- -<driver-pgid>`。另外:PATH 上没有 `timeout`/`gtimeout` 时驱动现在**拒绝启动**
(否则 wall-clock 看门狗会静默缺失);确要接受无界会话请显式传 `--no-watchdog`。

---

## 🔒 红线(与 `SKILL.md` 一致,违反即停)

- **禁止** push / merge / 开 PR / 发布 / 部署 / force / rebase 到远端。
- **禁止** 触碰生产系统、真实账号、真实用户数据、付费接口、真实第三方写操作。
- **禁止** 用删功能 / 放宽断言 / 跳过测试 / 吞异常的方式"消灭"问题。
- **禁止** 覆盖 / 清理 / 回滚用户已有未提交修改;无法安全隔离时不提交并记录。
- **禁止** 为收敛而降级问题、少测凑"零新增"、未重放就标 `VERIFIED`、达上限谎报 `PASS`。
- 疑似密钥**只记位置与风险类型,值一律脱敏**;安全测试只做本地非破坏性验证。

---

MIT 许可证。欢迎 issue 与贡献。
