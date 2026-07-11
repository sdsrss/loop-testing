# references/round-0.md — 第 0 轮：分析、基线与覆盖计划

> 只做一次。改任何代码前完成本轮。产出 `PLAN.md` + `FEATURE_MATRIX.md`，并建好沙箱。

## 0. 续跑检测（第一件事）

若 `docs/looptesting/STATE.md` 已存在 → 这是**中断续跑**：通读 `docs/looptesting/` 下全部文件（STATE / PLAN / FEATURE_MATRIX / ISSUES / SUGGESTIONS / runs/ / decisions/），核验其与当前工作区一致，从 `STATE.md` 的「下一动作」继续。**禁止重置轮数、禁止清空总账、禁止重跑已有有效证据的步骤**。不存在则从下面第 1 步开始。

## 1. 读项目规范

先读并遵守项目内 `AGENTS.md`、`CLAUDE.md`、`README`、`CONTRIBUTING`、测试说明、架构/产品规范及更具体的目录内指导。仓库已有更具体且不冲突的规范以仓库为准。

## 2. 识别产品形态与真实入口（无需用户填配置，自动发现）

- 形态：Web / 移动·桌面 UI / CLI / API / SDK·库 / 插件 / 后台任务，或它们的组合。
- 真实入口交叉盘点来源：产品规范、README、菜单、路由、CLI `--help`、API schema、公开导出、配置项、示例、`package.json`/`pyproject` 等脚本、已有测试。
- 原则：**不因文档未写就忽略实际可达功能，也不因代码存在就假定用户可达**。

## 3. 全功能交叉盘点 → FEATURE_MATRIX.md

列出所有用户可见功能，写入 `FEATURE_MATRIX.md`（模板见 `templates/`）。每个可达功能最终必须落 `PASS / FAIL / BLOCKED / N/A` 之一；`BLOCKED` 必须写具体原因与解除条件，不得用「未测试」冒充通过。

## 4. 角色与旅程

识别真实角色/权限与典型旅程（首次用户、回访、普通、管理员、访客）与关键业务流程。没有现成账号时只创建**本地测试身份与合成数据**。

## 5. 场景设计 → PLAN.md

为每项功能至少规划：**正常路径 / 边界值 / 错误输入 / 取消·返回 / 刷新或重启后状态 / 失败后恢复**；按风险补充角色权限、跨功能组合、并发·重复操作、可访问性、响应式、时区·语言、性能、隐私。写入 `PLAN.md`。

## 6. 基线检查（构建 / 测试 / lint / 类型检查 / 健康检查）

按项目文档启动应用并执行适用的基线检查。**既有失败与本轮引入失败分开记录**。

> **基线跑不通本身立为最高级问题（P0）**：先在 `ISSUES.md` 立案再处理，不得跳过。

## 7. 建立沙箱（`scripts/sandbox-setup.sh`）

- 优先 `git worktree`（隔离，主工作区脏也安全）；或独立分支 `qa/loop-testing`（要求工作区干净）。打基线标记 `qa-baseline`。
- 先记录 `git status`、当前分支、现有修改与未跟踪文件——它们可能属于用户：**不覆盖、不清理、不 stash、不提交、不回滚**；无法安全隔离的文件不提交并记录原因。
- 调用：`bash skills/loop-testing/scripts/sandbox-setup.sh`（默认 worktree 模式；`--mode branch` 切分支）。脚本幂等，会创建/复用 `docs/looptesting/` 并从 `templates/` 落盘状态文件。
- 验证测试环境确实与生产隔离；无法确认则停止一切可能产生外部副作用的动作，仅继续只读检查与本地测试。

## 8. 第 0 轮的修复边界

第 0 轮**只允许修复「完全阻塞后续测试且意图明确」的环境/启动问题**（且仍先立案）；其余问题一律进入正式循环处理，不在第 0 轮修。

完成后更新 `STATE.md`（`round: 0`），进入循环主体（`references/loop-round.md`）。
