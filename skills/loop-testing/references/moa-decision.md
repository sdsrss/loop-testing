# MoA 多模型决策：触发、调用与决策文件格式

> 归属：`skills/loop-testing/` 编排层引用文档。对应需求 FR-5.1..5.7、架构 §4。
> 引擎脚本：`skills/loop-testing/scripts/moa.mjs`（Node ≥ 20，零第三方依赖）。

MoA（Mixture of Agents，委员会制）用于**需要决策而非当场修复**的问题：先让 N 个参考模型各自独立分析，再由一个聚合模型综合所有意见给出最终建议。QA 循环 agent 只负责**产出决策建议并归档**，**绝不自行执行决策**——最终由用户拍板。

---

## 1. 何时触发 MoA

满足以下任一情形，即走 MoA 流程（不要当场改代码）：

1. **NEEDS_CONFIRMATION 类问题**：`ISSUES.md` 中被判为需确认的条目（改动会触及产品策略 / 公开契约 / 安全边界 / 不可逆结构，或期望不明确、根因存在多个合理解释）。
2. **重大问题**：重大架构 / 重大方向 / 重大重构 / 重大决策类问题。
3. **新建议方向 / 新功能建议**：`SUGGESTIONS.md` 中每一条新方向都应附一份 MoA 决策建议。

反例（**不要**用 MoA）：满足 FR-4.5 直修判据（稳定复现、期望明确、根因有证据、改动局部可逆、不改契约/安全边界、可验证）的低风险问题——直接修，走"修一验一提一"。

---

## 2. 准备决策上下文 markdown

在调用引擎前，先写一份决策上下文文件（建议临时放 `docs/looptesting/decisions/DEC-NNN.context.md`）。结构必须包含：

- **现象**：问题是什么，在哪个功能 / 入口 / 场景下暴露。
- **证据**：可机械重放的复现步骤、报错、日志位置、相关 `file:line`、失败测试名。疑似密钥只记位置与风险类型，**值一律脱敏**。
- **候选方案（≥ 2 个）**：每个方案的做法、代价、影响面；单一方案不构成"决策"，至少给出两个可比选项（含"保持现状 / 不做"也算一个）。
- **影响**：涉及的用户群、公开契约、安全边界、迁移成本、回滚难度。

上下文要自洽、可独立阅读——参考模型只读这份文本，没有工具、没有仓库访问。信息不足时在文中明确写出"缺什么"，让模型据此给出保守建议。

> **精炼纪律（控制 token 消耗）**：这份上下文会被**每个参考模型 + 聚合模型各付费读一遍**。证据只**摘录关键行**（报错首行 + 定位行），全量日志留在 `runs/` 里给人看，不要粘贴进来；总长控制在 200 行以内（引擎侧硬上限 16000 字符，超出会被截断并标注）。引擎对输出同样设了精炼约束与 max_tokens 硬上限——决策质量来自证据密度，不是篇幅。

---

## 3. 调用命令

```bash
node "$SKILL_DIR"/scripts/moa.mjs \
  --input docs/looptesting/decisions/DEC-007.context.md \
  --output docs/looptesting/decisions/DEC-007.md
```

> `$SKILL_DIR` = 本技能安装目录（Claude：`${CLAUDE_PLUGIN_ROOT}/skills/loop-testing`；Codex：`~/.codex/skills/loop-testing`；定位详见 SKILL.md「脚本与模板定位」）。**先跑 `--dry-run` 确认配置与 key 就绪，再发起付费调用；引擎定位不到 ≠ MoA 不可用**——找不到脚本时先按上述路径解析，仍找不到才走 §5 的 `degraded: single-model` 降级。

可选参数：

- `--config <moa.config.json>`：覆盖默认模型组合。默认还会自动读取当前工作目录下的 `docs/looptesting/moa.config.json`（存在即生效）。
- `--dry-run`：只打印解析后的配置（模型、provider、代理开关、各 key 是否 `set`/`missing`），**不发起任何网络请求**，用于排查配置与 key/代理是否就绪。

环境变量（**key 只从环境变量读，禁止写入代码/配置/日志**）：

| 变量 | 作用 |
|------|------|
| `OPENROUTER_API_KEY` | OpenRouter provider 的 key（base：`https://openrouter.ai/api/v1`）|
| `OPENAI_API_KEY` | OpenAI 兼容 provider 的 key |
| `OPENAI_BASE_URL` | OpenAI 兼容端点 base（默认 `https://api.openai.com/v1`）|
| `OPENROUTER_BASE_URL` | 覆盖 OpenRouter base（默认官方地址；主要用于测试指向本地 stub）|
| `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` | 存在即 LLM 调用走代理（FR-5.4）|
| `LOOP_TESTING_MOA_MODELS` | 逗号分隔覆盖参考模型列表 |
| `LOOP_TESTING_MOA_AGGREGATOR` | 覆盖聚合模型 |

provider 解析：config 可为每个模型单独指定 `provider`；未指定时，默认 provider = 有 `OPENROUTER_API_KEY` 则 `openrouter`，否则 `openai`。

> **直连 `openai` provider 的参数限制**：默认参考/聚合模型经 OpenRouter 路由（provider 侧会规范化参数）。若在 config 里给某模型显式 `provider: openai` 且用的是 OpenAI 推理系模型（如 o 系列），该模型可能拒绝 `temperature`（要求 =1）或要求 `max_completion_tokens` 而非引擎发送的 `max_tokens`，返回 400。遇此改走 OpenRouter，或换非推理模型。默认组合不受影响。

---

## 4. 输出与归档

引擎输出一个 Markdown 决策块，含六节：**问题摘要 / 各参考模型意见（逐个）/ 聚合推荐方案 / 理由 / 风险与分歧点 / 元数据**（元数据含使用的模型、降级标记 `degraded`、时间戳）。

归档规则：

- 落盘为 `docs/looptesting/decisions/DEC-NNN.md`，`NNN` 三位递增编号。
- 在 `ISSUES.md` 对应条目 / `SUGGESTIONS.md` 对应建议中回链该 DEC 文件。
- 决策文件是**给用户拍板用的档案**——agent 不得据此自行改架构、改方向、执行重构。

---

## 5. 降级行为（FR-5.7）

引擎按可用资源优雅降级，**不阻塞循环**：

| 情况 | 引擎行为 | 退出码 |
|------|---------|--------|
| 正常 / 部分参考模型失败（超时 / HTTP 错误 / 响应异常）| 产出决策文件；部分失败时元数据记 `partial-references` | 0 |
| 全部参考模型失败 | 仅聚合模型出建议，标 `degraded: no-references` | 0 |
| 聚合模型失败，或根本没有可用 key | 报错到 stderr（已脱敏），**不产出决策文件** | **2** |
| 用户侧错误：未知 CLI flag、`--config` 不可读 / 非法 JSON / `reference_models` 非非空数组、非法 provider、`--input` 缺失 / 不可读 / 为空、`--output` 写盘失败 | 打干净 `error: <msg>`（**非** `fatal:` 栈），不产出文件；写盘失败时决策已先打到 stdout | **1** |

**退出码语义**：`0` = 成功（含优雅降级）；`1` = 用户侧错误（配置/参数/输入/写盘），修正后重试；`2` = MoA 不可用（付费聚合链断）。

- 引擎 **exit 2** 时（MoA 不可用）：编排 agent 自行用**单模型推理**给出建议，写入 `DEC-NNN.md`，并在文件与元数据中**显式标注 `degraded: single-model`**，说明缺少多模型委员会视角的局限。循环照常继续，绝不因 MoA 不可用而谎报或停摆。
- 引擎 **exit 1** 时（用户侧错误）：先按 stderr 的 `error:` 修正配置/参数/输入再重试；**若错误是 `--output` 写盘失败，完整决策块已打到 stdout**——把它捕获落盘为 `DEC-NNN.md`，不要丢弃已付费的结论。

真实 key 冒烟属**付费接口 / 外网调用**，按 FR-6.7 需先获授权，不在自主推进范围内。

---

## 6. 铁律

- **agent 永不自行执行决策**：MoA 只产出建议并归档，执行与否由用户决定。
- **key 脱敏**：命令输出、日志、决策文件、报错摘要中不得出现任何 key 值。
- **每条问题单列**：决策文件一问题一档，不把多个问题揉成模糊的一团。
