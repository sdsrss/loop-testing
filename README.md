# loop-testing

**自测 · 自修 · 自迭代 · 自循环**的验收测试技能 / 插件。项目开发完成后，让编码智能体（Claude Code / Codex）以**真实用户身份**在沙箱中反复使用你项目的每一个功能，发现 bug / 代码 / 功能 / 流程 / 隐蔽 / 逻辑 / 安全 / 用户体验八类问题；能安全修的当场修（带回归测试 + 原子提交），需决策的记录在案并给出 **MoA（Mixture of Agents）多模型决策建议**；连续两轮只剩无关紧要的低等级问题时自动停止并输出总结报告。

一条命令启动，全程自主推进——除三类例外（需密钥/付费/外网权限、疑似安全漏洞需上报、阻塞性问题导致无法继续），不需要你每轮确认。

---

## 工作方式

- **双重身份**：使用产品时是真实用户（交替代入"瞎摸索的小白"与"脾气不好的重度老手"，用真实感数据、会误操作）；修复问题时切换为严谨资深工程师（最小改动、先复现再修、修完必验证）。
- **一切进度以文件为准**：状态写在目标项目的 `docs/looptesting/` 下，会话中断 / 上下文压缩后重新触发即从状态文件续跑，不重置进度。
- **收敛才停**：连续 2 轮"收敛低风险轮"（本轮无新增 P0-P2、完成全功能回归且覆盖量不缩水）才正常停止；达 `MAX_ROUNDS` 上限未收敛则如实报 `INCOMPLETE`，不谎报 PASS。

---

## 安装

### Claude Code（插件）

已发布市场：

```
/plugin marketplace add <this-repo>      # 例如 git URL，或本地仓库路径 ./
/plugin install loop-testing@loop-testing
```

本地开发 / 尚未发布时，直接以插件目录加载：

```
claude --plugin-dir .
```

安装后在会话中用触发词（见下）即可启动。

> **机制增强层**（Stop-hook 强制续跑、VERIFIED 台账防伪写）由仓库 `hooks/` 提供。当插件包含 `hooks/` 时，新版 Claude Code 会随插件自动加载 `hooks/hooks.json`，旧版按 `hooks/` 内说明手动注册。未启用机制层时，循环续跑与红线由**提示词纪律**保证（见"已知限制"）。

### Codex（技能目录）

Codex（2025-12 起）与 Claude Code 共用同一 `SKILL.md` 技能格式，技能目录为 `~/.codex/skills/<name>/`。用随仓库脚本安装：

```
install/install-codex.sh                       # 装到 ~/.codex/skills/loop-testing
install/install-codex.sh --target <skills-dir> # 指定技能目录
install/install-codex.sh --dry-run             # 只打印将执行的动作，不写任何文件
install/install-codex.sh --uninstall           # 卸载（fail-closed：非本插件目录拒删）
```

目标技能目录解析顺序：`--target` > `$CODEX_HOME/skills` > `~/.codex/skills`。脚本**幂等**（重装会先把旧安装备份为 `<dest>.bak` 再覆盖），且**只删自己安装的目录**（依据安装时写入的 `.loop-testing-codex-install` 标记文件；目标若无此标记则拒绝删除/覆盖）。`hooks/` **不复制**——Codex 无 hook 机制，走提示词纪律降级路径（SKILL.md「平台差异」段已覆盖）。

---

## 使用

**触发词**（任一即可）：`自测` / `自我测试` / `验收` / `QA 循环` / `自动测试并修复` / `self-test loop` / `autonomous QA` / `acceptance testing`。

技能会在目标项目下建立 `docs/looptesting/` 功能目录，产物如下（默认保留但不提交，也不为隐藏它改动你项目的 `.gitignore`）：

| 文件 | 作用 |
|------|------|
| `STATE.md` | 权威进度：轮次、连续收敛轮数、状态、最后/下一动作、阻塞项 |
| `PLAN.md` | 第 0 轮：产品形态、入口、要测的功能与场景设计 |
| `FEATURE_MATRIX.md` | 功能 × 入口 × 场景 × 覆盖状态 × 证据位置 |
| `ISSUES.md` | 问题总账（发现即立案，逐条追加，含状态机） |
| `SUGGESTIONS.md` | 新方向 / 新功能建议 + MoA 决策链接 |
| `runs/round-N.md` | 每轮场景、命令、结果、证据、复验重放记录 |
| `decisions/DEC-NNN.md` | MoA 多模型决策记录 |
| `FINAL_REPORT.md` | 最终报告：最终状态 + 覆盖摘要 + 修复清单（问题↔commit）+ 待确认清单 + 遗留 + 盲区 |

---

## MoA 多模型决策配置

需要决策的问题（NEEDS_CONFIRMATION、重大架构/方向/重构/决策、新功能建议）会走 `skills/loop-testing/scripts/moa.mjs`（Node ≥ 20，零第三方依赖）：多个参考模型并行独立分析 → 聚合模型综合出最终建议 → 写入 `docs/looptesting/decisions/DEC-NNN.md` 供你拍板（智能体**不自行执行决策**）。

**API key 一律从环境变量读取，禁止写入代码/配置/日志；输出与日志中 key 值一律脱敏。**

| 环境变量 | 作用 |
|----------|------|
| `OPENROUTER_API_KEY` | OpenRouter 的 key（base 默认 `https://openrouter.ai/api/v1`）|
| `OPENAI_API_KEY` | OpenAI 兼容端点的 key |
| `OPENAI_BASE_URL` | OpenAI 兼容端点 base（默认 `https://api.openai.com/v1`）|
| `OPENROUTER_BASE_URL` | 覆盖 OpenRouter base（默认官方地址）|
| `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` | 存在即 LLM 调用走代理（Node 全局 fetch 默认不读代理，脚本显式处理）|
| `LOOP_TESTING_MOA_MODELS` | 逗号分隔覆盖参考模型列表 |
| `LOOP_TESTING_MOA_AGGREGATOR` | 覆盖聚合模型 |
| `LOOP_TESTING_MOA_TIMEOUT_MS` | 每次模型调用超时毫秒数（默认 60000）|

也可用配置文件覆盖（当前工作目录 `docs/looptesting/moa.config.json`，或 `--config <path>`）：

```json
{
  "reference_models": [
    { "model": "openai/gpt-5.5", "provider": "openrouter" },
    { "model": "deepseek/deepseek-v4-pro", "provider": "openrouter" }
  ],
  "aggregator": { "model": "anthropic/claude-opus-4.8", "provider": "openrouter" },
  "reference_temperature": 0.6,
  "aggregator_temperature": 0.4
}
```

默认模型为发布时校准的顶级模型组合，**会过时**——请按需通过上述配置覆盖。provider 未指定时：有 `OPENROUTER_API_KEY` 则默认 `openrouter`，否则 `openai`。

直接调用与自检：

```
node skills/loop-testing/scripts/moa.mjs --input <decision-context.md> --output <DEC-NNN.md>
node skills/loop-testing/scripts/moa.mjs --input <ctx.md> --dry-run   # 打印解析后的配置，不发网络请求
```

**降级行为**：部分参考模型失败 → 用其余模型继续（元数据记 `partial-references`）；全部参考模型失败 → 仅聚合模型出建议（`degraded: no-references`）；聚合模型失败或无可用 key → 退出码 **2**，编排层改用单模型给建议并标 `degraded: single-model`，**不阻塞循环**。

---

## 红线声明

与 `skills/loop-testing/SKILL.md` 一致，违反即停：

- **禁止** push / merge / 开 PR / 发布 / 部署 / force / amend / rebase 到远端。
- **禁止** 触碰生产系统、真实账号、真实用户数据、付费接口、真实第三方写操作。
- **禁止** 用删功能 / 放宽断言 / 跳过测试 / 吞异常 / 硬编码结果的方式"消灭"问题。
- **禁止** 覆盖 / 清理 / 回滚 / stash 用户已有未提交修改；无法安全隔离时不提交并记录。
- **禁止** 为收敛而降级问题、少测凑"零新增"、未重放就标 VERIFIED、达轮次上限谎报 PASS。
- 疑似密钥**只记位置与风险类型，值一律脱敏**；安全测试只做本地非破坏性验证。

---

## 已知限制

- **Codex 无机制层 gate**：Codex 没有 Stop-hook，循环续跑与"未收敛禁止停止"仅靠提示词纪律（每轮末尾强制自检退出条件、显式声明进入下一轮）；相较 Claude Code 的机制层强制，作弊/早停的成本更低。
- **机制增强层依赖 hooks/**：Stop-gate 与 VERIFIED 防伪写由仓库 `hooks/` 提供；未启用机制层（或 Codex 端）时，续跑与红线由提示词纪律保证。
- **D1 基石假设（双平台共用 SKILL.md）已实测通过**：在本机真实 Codex 会话（codex-cli 0.144.1，model `gpt-5.6-sol`）中验证——由 `install-codex.sh` 装入 `~/.codex/skills/loop-testing/` 的技能被 Codex 发现，并读取 `SKILL.md` 与 `references/round-0.md` 后正确进入第 0 轮起点（复述了"续跑检测"起始步骤与全部 8 个 `docs/looptesting/` 产物文件名）。**注**：Codex 的 `read-only` bwrap 沙箱在部分容器中无法创建 user namespace（`bwrap: loopback: Failed RTM_NEWADDR`），此为环境限制、与本技能无关；上述验证在一次性沙箱工作区、并将已装技能目录临时置为只读的前提下完成。若某版本 Codex 的 skills 机制与此不符，回退方案为向 `~/.codex/prompts` 生成等价 prompt 文件。
- **Node ≥ 20 仅 MoA 功能需要**：QA 循环本体离线可用；缺 Node 时 MoA 降级为单模型建议。
- **`claude -p` 无头模式的循环截断（F4）**：在非交互 `claude -p` 下，若模型把循环**委派给 sub-agent / Task 工具**，该后台任务会被 print 模式的后台等待上限（`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`，默认 600000ms = 600s）在约 10 分钟后终止，循环停在中途（STATE 卡 `RUNNING`、`.active` 仍武装）。交互式 `claude` 与 Codex 无此问题。**无头运行请用外层续跑驱动** `skills/loop-testing/scripts/unattended-loop.sh`：它设 `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`、给每个会话加墙钟看门狗，并反复以 `claude -p` 从 `STATE.md` 续跑直到终态（续跑提示词已内联要求「在当前会话执行、禁止委派 sub-agent」）。

  ```bash
  bash skills/loop-testing/scripts/unattended-loop.sh --project <目标项目> \
    --max-sessions 15 --max-minutes 240 --plugin-dir <本插件目录>
  ```

  熔断与如实退出：连续 2 个会话无进展 → `NO_PROGRESS`（退出码 5）；达 `--max-sessions` / `--max-minutes` → 按 INCOMPLETE 退出（3 / 4）；终态由技能自身收敛（退出码 0）。每会话进度追加到 `<目标项目>/docs/looptesting/driver.log`。
