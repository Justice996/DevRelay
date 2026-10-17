# DevRelay v0.1 — P0-01 / P0-02 / P0-03 集成验证报告

| 项目 | 值 |
| --- | --- |
| 报告日期 | 2026-10-17 |
| 分支 | `feat/v0.1-agent-integration` |
| 验证范围 | **仅 P0-01、P0-02、P0-03**（未开始 P0-04~P0-07，未开始网页界面） |
| 验证执行者 | 本地 Pi（DeepSeek）+ 自动化脚本 `scripts/verify-p0.ps1` |
| 自动化检查结果 | **22 项通过 / 0 失败 / 0 跳过**，脚本退出码 `0` |
| 反向（回归）测试 | **17 项通过 / 0 失败**，`tests\run-negative-tests.ps1` 退出码 `0` |
| 审查修订 | PR #1 的三项 MUST FIX 已全部修复（见 §13） |
| 人工结论 | P0-01 通过、P0-02 通过、P0-03 通过；另有 9 项性质明确标为 **未验证**（见 §8） |
| 生产环境接触 | **无**。未访问生产数据库、未调用部署服务、未提交任何密钥、未自动合并主分支 |

验证证据（可审计副本）：`docs/verification/evidence/2026-10-17/`（含 `MANIFEST.md` 与各文件 SHA-256）。
**证据只以脱敏/元数据形式入库**：不写提示词、不写业务答复、不写模型输出，只保留状态、退出码、时间线以及捕获流的字节数与 SHA-256（详见 §13 与 `MANIFEST.md`）。原始 Pi 会话与原始运行记录只留在本地 `.p0-evidence/`，重新执行即可再生。

---

## 1. 结论摘要

| 阶段 | 结论 | 依据（自动化检查 ID） |
| --- | --- | --- |
| P0-01 环境清点 | **通过** | `P0-01-01` … `P0-01-07` |
| P0-02 Spec Kit ↔ Pi 原生集成 | **通过** | `P0-02-01` … `P0-02-06` |
| P0-03 Gate 暂停与恢复 | **通过** | `P0-03-01` … `P0-03-08` |
| 全局护栏：本次运行未改动任何受版本控制的文件 | **通过** | `P0-GUARD-01` |
| 提供的 YAML 兼容性 | **无需任何修改即可运行** | `P0-03-01`（严格断言：退出码 0 + 工作流 id + 5 个步骤的 id/类型顺序全部匹配），文件 SHA-256 `28F8187B…320D16D` 与收到时一致 |

一句话结论：**Spec Kit 1.2.1 的原生 `pi` 集成确实驱动了本机 Pi 0.86.1 + DeepSeek 模型；两次人工审批节点分别完成 pause → resume，且跨进程（等价于关闭终端后重启）可以续跑；被拒绝的审批不会越过。**

---

## 2. P0-01 环境清点（通过）

| 组件 | 实测值 | 检查 |
| --- | --- | --- |
| OS | Microsoft Windows NT 10.0.26200.0（Windows, AMD64） | 记录 |
| PowerShell | 5.1.26100.9711 | 记录 |
| Node.js | **v22.21.1** | `P0-01-01` 要求 ≥ 22 ✅ |
| npm | 10.9.4 | 记录 |
| Python | **3.13.2** | `P0-01-02` 要求 ≥ 3.11 ✅ |
| Pi | **0.86.1**，包名 **`@earendil-works/pi-coding-agent`**，可执行文件 `D:\pi\pi.exe` | `P0-01-03` ✅ |
| Spec Kit | **1.2.1**（PyPI `specify-cli`），隔离 venv 安装 | `P0-01-04` ✅ |
| Git | 2.51.0.windows.1 | 记录 |
| 模型供应商 / 模型 | `deepseek-proxy` / `deepseek-v4.1-flash-expires-on-0910`（thinking=high） | 记录（见 §7 风险 R1） |
| 凭据就绪性 | `pi auth check --json` → `{"status":"ready","provider":"deepseek-proxy","authType":"api_key"}`（**未读取、未记录密钥值**） | `P0-01-05` ✅ |
| 只读问答 | 在临时空目录中 `pi -p --no-session --tools read,grep,find,ls` → 退出码 0，有中文回答，**目录前后文件数 0 → 0** | `P0-01-06` ✅ |
| 工作区完整性 | 与运行前基线相比，清点过程**没有改动任何受版本控制的文件**（工作区原本的未提交改动被允许，但不允许被本次运行新增/改变/删除） | `P0-01-07` ✅ + `P0-GUARD-01` ✅ |

说明：本机起始状态**未安装** Spec Kit（`specify`/`uv` 均不存在）。按官方 `docs/installation.md` 的 PyPI 路线，以**隔离 venv** 安装并锁定版本 `specify-cli==1.2.1`，venv 位于仓库之外（`%LOCALAPPDATA%\DevRelay\tools\specify-venv`），不进入 Git。

---

## 3. P0-02 Spec Kit ↔ Pi 原生集成（通过）

### 3.1 实际做了什么

1. 新建分支 `feat/v0.1-agent-integration`；
2. `specify init --here --integration pi --non-interactive --force --script ps`（非空目录合并，仅新增，无文件被覆盖）；
3. `specify integration status` → `Default integration: pi`、`Multi-install safe: yes`、缺失/被改动的受管文件均为 **0**；
4. `.pi/prompts/` 生成 10 个 Spec Kit 命令模板（`speckit.specify.md`、`speckit.plan.md` 等）；
5. 用一个**只含单步 `prompt`** 的工作流 `workflows/p0-02-pi-probe.yml` 验证真实派发。

### 3.2 检查结果

| ID | 检查 | 结果 |
| --- | --- | --- |
| `P0-02-01` | `specify integration status` 报告 `pi` | 通过 |
| `P0-02-02` | `.pi/prompts/` 已安装命令模板 | 通过（10 个） |
| `P0-02-03` | `prompt` 步骤真实派发到本机 Pi | 通过（run `a6ae2440`，`status=completed`，`dispatched=true`，`exit_code=0`） |
| `P0-02-04` | Pi 实际使用的模型有独立证据 | 通过（Pi 会话 `model_change` 事件 = `deepseek-proxy/deepseek-v4.1-flash-expires-on-0910`） |
| `P0-02-05` | 提示词由工作流文件承载，无人工复制粘贴到 Pi | 通过（工作流声明 `type: prompt` + `integration: pi`，脚本从未向交互式 Pi 会话输入文本） |
| `P0-02-06` | `capture: true` 能把模型文本带回 `steps.<id>.output.stdout` | 通过（run `c7bb434d`，捕获到 `OK`） |

### 3.3 派发机制（读源码确认，不是猜测）

Spec Kit 的 `PiIntegration` 是 `MarkdownIntegration` 子类，`prompt` 步骤最终执行：

```text
pi -p "<渲染后的提示词>"  [SPECKIT_INTEGRATION_PI_EXTRA_ARGS 追加]  [--model <model>]
```

- 提示词通过进程参数传给 `pi -p`（非交互模式），stdout/stderr 由 Spec Kit 接管；
- 未指定 `model` 时，Pi 使用本机 `~/.pi/agent/settings.json` 的 `defaultModel`；
- 我们通过官方支持的 `SPECKIT_INTEGRATION_PI_EXTRA_ARGS` 追加 `--tools read,grep,find,ls --session-dir <本地证据目录>`：**验证期间 Pi 根本无法写文件或执行命令**（比"提示词里写不要修改文件"更强的约束），同时得到可追溯的模型证据。

### 3.4 补充发现：`capture: true` 可用（对 P0-04 关键）

我最初怀疑 `capture: true` 会失败：adapter 在 `output_json=True` 时会追加 `--output-format json`，而 Pi 0.86.1 直接拒绝该参数（实测 `pi -p "回复 OK" --output-format json` → `Error: Unknown option: --output-format`，退出码 1；Pi 的等价物是 `--mode json`）。
但读源码后确认：**工作流的 `prompt` / `command` 步骤始终请求文本输出（`output_json=False`），即使开启 capture**，因此该不匹配在工作流路径下不会触发。实测 `capture: true` 正常返回模型文本。
结论：**"模型文本回传 + 结构化卡片"这条路可用**，P0-04 不必改 adapter。风险只存在于"外部程序直接调用 `dispatch_command(stream=False)` 且未显式传 `output_json=False`"的场景（记录在 §7 R3）。

---

## 4. P0-03 Gate 暂停与恢复（通过）

### 4.1 使用的文件

`DevRelay_v0.1_smoke_workflow.yml`，**原样未改**（SHA-256 `28F8187BB090F0C238BA561E83A73D39C1412A4E11E06FA2EA44D95E0320D16D`）。
`specify workflow info` 解析通过（退出码 0，5 个步骤：`prompt/gate/prompt/gate/prompt`），因此**本轮不需要做兼容性修改**。

### 4.2 三轮独立进程（等价于关闭终端后重启）

run `cbd0b65d`（审查修复后重跑，全部为不同的 OS 进程）：

| 进程 | 命令 | 结果 | 退出码 |
| --- | --- | --- | --- |
| A | `specify workflow run <yaml> --input spec=… --json` | `status=paused`，`current_step_id=question_gate`，`gate.choice=null` | 0 |
| B | `specify workflow resume cbd0b65d --input question_verdict=approve --input product_answer=… --json` | `status=paused`，`current_step_id=decision_gate` | 0 |
| C | `specify workflow resume cbd0b65d --input decision_verdict=A --json` | `status=completed` | 0 |

`specify workflow status cbd0b65d --json` 显示 5/5 步骤 `completed`。
执行日志（`log.jsonl`）证明**已完成步骤没有重跑**：

```text
04:37:23 step_started     identify_business_gap
04:37:50 step_completed   identify_business_gap completed
04:37:51 step_completed   question_gate paused      ← 第一次暂停
04:37:52 step_completed   question_gate completed   ← resume 消费 verdict
04:38:14 step_completed   decision_gate paused      ← 第二次暂停
04:38:17 step_completed   decision_gate completed   ← resume 消费 verdict
04:38:31 step_completed   report_choice completed
04:38:31 workflow_finished completed
```

统计断言：`identify_business_gap` **只启动 1 次**、`propose_architecture` **只启动 1 次**（且严格在第一次审批通过后）、`question_gate` 启动 2 次（暂停一次 + 消费 verdict 一次）。这正是"暂停—恢复不重复执行已完成步骤"的证据。

### 4.3 审批结论确实进入后续提示词

最后一步引用的 `{{ steps.decision_gate.output.choice }}` 解析为 `A`，`report_choice` 步骤收到的提示词中出现"人类选择的技术方案为 A"（`P0-03-07`）。说明 **Gate 的人类决定是可追溯、可下传的数据，不是口头约定**。

### 4.4 拒绝路径（关键安全性质）

run `5223705e`：run 暂停在 `question_gate` → `resume --input question_verdict=reject` → `status=aborted`，退出码 **1**，`error: Gate rejected by user at step 'question_gate'`，`steps` 里**只存在** `identify_business_gap`(completed) 与 `question_gate`(failed)，`propose_architecture`/`decision_gate`/`report_choice` 完全没有启动（`P0-03-08`）。
→ **被拒绝的审批不会越过，也不会静默降级为"通过"。**

### 4.5 附带得到的真实产出（人工预跑，run `d511e16a`）

同一工作流在人工预跑中完整跑通，Pi 产出：一条面向产品经理的通俗问句（"用户把券转给朋友、朋友还没点领取之前，这张券算谁的？原用户这段时间自己还能不能用？"）、A/B/C 方案比较、以人类选择 A 为前提的 ADR 草稿与 12 条 `not_run` 业务验收标准草稿。它证明闭环的**内容质量**可用；但该产出**未被采纳为业务事实**（见 §8）。

---

## 5. 与官方文档的差异记录（已核对官方文档 + 实测）

> 规则：先核对官方文档 → 做最小兼容调整 → 记录差异。本轮**没有对提供的 YAML 做任何修改**，但发现了下列文档/实现差异，必须写进交接口径，否则后续阶段会踩坑。

| # | 差异 | 影响 | 处理 |
| --- | --- | --- | --- |
| D1 | **Gate 只在 stdin 不是 TTY 时暂停**。Windows 上 `< NUL` 重定向**无效**：NUL 是字符设备，`sys.stdin.isatty()` 仍为真 → 进入交互提示 → 读到 EOF → 按"未答复=拒绝"**自动 reject**（实测 run `aca6ce2b`、`6e3501e1` 均因此 `aborted`，退出码 1） | 自动化中若用 `< NUL` 想"暂停"，会**静默变成拒绝**；AI 代理必须用**管道**（关闭的 stdin pipe）才能拿到 `paused` | 验证脚本统一用 `ProcessStartInfo` + 关闭 stdin 管道；已在脚本注释与此处显式记录 |
| D2 | 官方 `workflows.md` 提到 `specify workflow validate`，但 1.2.1 的 `specify workflow` 子命令里**没有** `validate` | 无法用该命令做预校验 | 用 `specify workflow info <file>`（退出码 0 = 结构通过）+ `run` 校验 |
| D3 | 提供的 YAML **没有** `requires.speckit_version` | `requires` 只是 advisory precondition，不是运行时闸门，缺省等于不校验 | 建议（未擅自改）在下个版本加入 `requires.speckit_version: ">=1.2.1"` |
| D4 | 提供的 YAML 的 `prompt` 步骤**没有** `capture: true` | `state.json` 里只留 `exit_code`，业务问题/方案原文**不落盘**（只停留在终端与 Pi 会话） | P0-04 必须开启 capture（已验证可用）；本轮按"最小改动"原则未改附件 |
| D5 | `state.json` 中 `model` 恒为 `null`（除非步骤显式写 `model:`） | 无法仅凭 Spec Kit 状态证明用了哪个模型 | 用 Pi 会话 `model_change` 事件作为证据；或后续在步骤上固定 `model:` |
| D6 | adapter 在 `output_json=True` 时追加 `--output-format json`，Pi 无此参数（Pi 用 `--mode json`） | 工作流路径不触发（始终 `output_json=False`）；外部 Python 调用 `dispatch_command(stream=False)` 会触发 | 记为已知风险 R3；不改 Spec Kit 源码 |
| D7 | 附件正文写 `question-gate` / `decision-gate`，YAML 实为 `question_gate` / `decision_gate` | 仅命名不一致 | 以 YAML 为准；报告沿用 YAML 命名 |
| D8 | `specify init` 会警告 `.pi/` 可能存放凭据 | 直接提交 `.pi/` 有泄露风险 | `.gitignore` 忽略 `.pi/agent/`、`.pi/auth.json`，只提交 `.pi/prompts/`（10 个模板，无凭据） |
| D9 | 官方文档把 gate `verdict_input` + `on_reject: retry` 的 enum 要求写为"必须包含空串" | 附件使用 `on_reject: abort`，但 enum 已含 `""` | 无需改动 |

---

## 6. 复用了哪些开源能力 / 仍需 DevRelay 自研

### 6.1 已实测复用（不自研）

| 能力 | 来源 | 本轮证据 |
| --- | --- | --- |
| 工作流定义与执行（顺序、gate、变量插值） | Spec Kit 1.2.1 workflow 引擎 | `P0-03-01` … `P0-03-05` |
| 暂停/恢复与运行态持久化（`state.json` / `inputs.json` / `log.jsonl`） | Spec Kit | 三轮进程续跑、5/5 completed |
| 已完成步骤不重复执行的 replay 语义 | Spec Kit | `P0-03-06` |
| 人类审批 verdict 作为输入并下传 | Spec Kit `gate.verdict_input` + `output.choice` | `P0-03-07` |
| Agent 派发（无需自建 Agent 引擎） | Spec Kit `pi` 原生集成 → `pi -p` | `P0-02-03` |
| 模型与供应商解耦（用本机既有 DeepSeek 配置） | Pi 0.86.1 `--model` / settings | `P0-02-04` |
| 模型文本回传（capture）与 `--json` 机器可读输出 | Spec Kit | `P0-02-06`、全部检查解析 `--json` |
| 工具白名单/会话留痕 | Pi `--tools`、`--session-dir`、`--mode json` | `P0-01-06`、`P0-02-04` |
| 命令模板脚手架（`/speckit.*`） | Spec Kit `init --integration pi` | `P0-02-02` |

**没有**另建 Node 调度器、**没有**自造状态机、**没有**嵌入 Pi SDK 重复接入。

### 6.2 仍必须 DevRelay 自研

1. **业务协作协议与校验**：`BusinessQuestion` / `ArchitectureOption` / `Decision(ADR)` / `AcceptanceCriterion` / `Evidence` 的 JSON Schema 与语义校验（"问题不含 Java/SQL/锁术语""必填来源与确认人"）。
2. **业务语言转译层**：把技术取舍翻译成产品经理能判断的业务后果；这是北极星的核心，不能交给通用 Agent 自由发挥。
3. **业务事实的 provenance 与冻结**：回答来源、确认人、时间、版本号；未回答不得冒充已确认；答案冲突升级人类。
4. **卡片持久化与查询**（先文件/JSON，后续再谈数据库）。
5. **ADR 生成 + 人类批准闸门**：模型只能"起草"，`approved_by` 必须由人类写入。
6. **独立证据采集与判定**：命令、退出码、日志、`git_sha`、`executed_at`；`passed/failed/not_run` 的判定必须来自运行证据，而不是模型自述。
7. **权限与安全策略**：工具白名单、禁止生产资源、禁止自动合并、运行态脱敏。
8. **交互层**（本轮不做）：先 CLI/文件，未来 Vue 3。

---

## 7. 已知风险与限制

| ID | 风险 | 现状 | 建议 |
| --- | --- | --- | --- |
| R1 | 本机只配置了**单一模型别名** `deepseek-v4.1-flash-expires-on-0910`，且名称自带过期日期（`expires-on-0910`） | 当前可调用（auth `ready`，多次实跑成功），但属于**单点** | 需人类决定（§9 决策 D3）：换稳定模型 ID / 保留别名 + 备用模型 |
| R2 | 自动化中 gate 可能因 EOF 被**自动 reject**（D1） | 已用管道规避并写入脚本 | 把"必须用管道 stdin"固化进 DevRelay 自己的运行封装，禁止 `< NUL` |
| R3 | `--output-format json` 与 Pi 不兼容（D6） | 工作流路径不触发 | 若将来用 Python API 调 `dispatch_command`，显式传 `output_json=False` |
| R4 | `state.json` 与 `runs/` 含模型原文与业务原文 | 已 `.gitignore`，仅本地 | 需人类决定（§9 决策 D4）云端协作时的脱敏/权限方案 |
| R5 | `prompt` 步骤不 capture 时业务文本不落盘（D4） | 附件 YAML 保持原样 | P0-04 起对需要入库的步骤开启 `capture: true` |
| R6 | 单次运行时长观测：业务问题 ~26s、方案比较 ~45s、ADR 草稿 ~16s；`prompt` 步骤默认 timeout 300s | 无超时失败 | 长任务需显式加大 `timeout` 并保留 `timed_out` 判据 |
| R7 | 仓库根目录保留了两个中文/URL 编码命名的原始输入文件 | 未重命名，保持可追溯 | 由人类决定是否归档到 `docs/requirements/` |

---

## 8. 明确「未验证」（`not_run`）清单

以下能力本轮**没有**运行过，禁止在任何对外材料中声称通过：

1. **人类在真实终端里交互式点选审批**（TTY 输入 `1`/`2` 走 `_prompt` 分支）：需要真人在终端操作，本轮所有路径都走"非 TTY 管道 → paused → resume"。
2. **`command` 步骤**（`speckit.specify` / `speckit.plan` 等真实 SDD 命令）经 Pi 执行——本轮只用 `prompt` 步骤。
3. **长文本 / 多行 / 含引号的 `product_answer`** 经 `--input` 传入并在 `state.json` 正确往返（本轮为单行中文）。
4. **Ctrl+C 中断后恢复**、**进程崩溃/机器重启后的恢复**（本轮是"正常 paused → 新进程 resume"）。
5. 工作流的 `if` / `switch` / `shell` / `while` / `fan-out` / `fan-in` / `workflow` 嵌套 / overlay（本轮不需要）。
6. **多 run 并发**执行与同一 run 并发 resume 的互斥行为。
7. **跨机器/跨用户复现**（本轮为单一开发机；未在 CI 中运行）。
8. **Pi 写权限下的行为**（编辑/写文件/powershell 工具）：本轮刻意只授予只读工具，因此"AI 修改代码是否正确受控"未验证。
9. **模型输出质量的稳定性/回归**（同一提示多次抽样的一致性）：只做了单次实跑。

---

## 9. 需要人类决策的事项（我不替你决定）

> 这些是业务/合规/成本取舍，不是技术实现细节。

**D1｜审批交互形态（影响产品体验与安全默认值）**
- A) 全自动管道模式：AI 代理永远得到 `paused`，人类在别处（CLI/GitHub/未来网页）答复——本轮已验证；
- B) 人类在自己终端里当场点选（`[1] approve / [2] reject`）——**未验证**，且响应无法留痕，需额外审计；
- C) 两者都支持：默认 A，显式开关启用 B。
- 我的建议：**C**。但请注意：B 在非 TTY 环境下会退化成"EOF=拒绝"，必须由 DevRelay 封装层显式拦截。

**D2｜业务答复的承载方式（影响可追溯性与长度上限）**
- A) `resume --input product_answer="…"` 字符串（已验证，但受命令行长度与转义约束，多行/含引号**未验证**）；
- B) 答复写入文件，`resume` 只传路径（需 `show_file` 或自定义步骤，未验证）；
- C) 结构化 JSON 卡片文件（问题/回答/来源/确认人/时间/哈希）+ 工作流只传卡片 ID。
- 我的建议：**C**，因为它天然满足"答案必须带来源与确认状态"。是否接受"人必须手写/确认一份 JSON"这个操作成本，需要你判断。

**D3｜模型可用性（单点风险）**
- A) 继续只用 `deepseek-v4.1-flash-expires-on-0910`；
- B) 换一个不含过期日期的稳定模型 ID；
- C) 配置主备两个模型，并在失败时明确降级（DevRelay 记录"本次由备用模型产出"）。
- 需你决定（涉及供应商与成本）。**注意**：当前机器上 `pi --list-models` 只有这一个模型可选。

**D4｜运行态数据治理**
- A) 保持现状：`runs/` 与 Pi 会话只留本地、`.gitignore`；
- B) 加密后提交或上传；
- C) 只提交脱敏摘要（本轮 `docs/verification/evidence/` 即 C 的样例：保留命令、退出码、状态、日志，剔除原始会话）。
- 需你（或合规）确认；当前默认是 A + 证据用 C。

**D5｜开发阶段的工具权限（P0-04~P0-06 需要写文件/执行命令）**
- A) 允许 Pi 在隔离 checkout 内自由写（最快，但无沙箱）；
- B) 容器/虚拟机隔离后放开；
- C) 每次写操作前人工 `gate` 确认（最慢，最安全）。
- 需要你选择；本轮为验证目的只给了只读工具。

**D6｜是否把两个原始输入文件归档重命名**（`DevRelay_v0.1_架构与集成验证任务.md` 当前文件名是 URL 编码形式）。
- A) 保持原样；B) 归档为 `docs/requirements/v0.1-architecture-and-integration-tasks.md`；C) 拆分为 `docs/architecture/v0.1.md` + `docs/requirements/`。
- 我倾向 **B**（不改内容、只改位置与名字），但这是仓库信息架构决定，等你确认。

---

## 10. 可重复执行的命令

前置：Python ≥ 3.11；本机已有 Pi 且已配置 DeepSeek 凭据。

```powershell
# 0) 进入仓库、切分支
git clone git@github.com:Justice996/DevRelay.git
cd DevRelay
git checkout feat/v0.1-agent-integration

# 1) 安装锁定版本的 Spec Kit（隔离 venv，不动全局环境）
powershell -ExecutionPolicy Bypass -File .\scripts\setup-specify.ps1
#    -> %LOCALAPPDATA%\DevRelay\tools\specify-venv-1.2.1\Scripts\specify.exe
$env:SPECIFY_BIN = "$env:LOCALAPPDATA\DevRelay\tools\specify-venv-1.2.1\Scripts\specify.exe"

# 2) 一次性环境清点（不改任何受版本控制文件）
& $env:SPECIFY_BIN version
& $env:SPECIFY_BIN integration status
& $env:SPECIFY_BIN workflow --help
pi --version
node --version
python --version
git status

# 3) 初始化（如果是全新 clone；本仓库已提交初始化结果，通常无需重跑）
#    非空目录必须加 --force，且只做合并、不删除已有文件
& $env:SPECIFY_BIN init --here --integration pi --non-interactive --force --script ps

# 4) 全量验证（P0-01 + P0-02 + P0-03 + 全局护栏）
powershell -ExecutionPolicy Bypass -File .\scripts\verify-p0.ps1
#    -> passed=22 failed=0 not_run=0，verdict: all checks passed，退出码 0
#    可选单阶段：-Phase p0-01 | p0-02 | p0-03
#    注意：not_run（必需检查未执行）与 failed 同样返回退出码 1

# 4b) 反向测试（证明上述断言真的会失败）
powershell -ExecutionPolicy Bypass -File .\tests\run-negative-tests.ps1
#    -> passed=17 failed=0，退出码 0

# 5) 导出可审查的证据快照（默认安全模式：只写元数据，不写模型输出/业务文本）
powershell -ExecutionPolicy Bypass -File .\scripts\export-evidence.ps1
#    如需本地排查原始文本（不得入库）：
#    .\scripts\export-evidence.ps1 -IncludeModelOutput -TargetRoot "$env:TEMP\devrelay-evidence-raw"

# 6) 手工复现"两次暂停 + 两次恢复"（关键：stdin 必须是管道，不能是 < NUL）
$spec = '实现用户向朋友转赠优惠券，一张券不能被重复领取'
'' | & $env:SPECIFY_BIN workflow run .\DevRelay_v0.1_smoke_workflow.yml --input "spec=$spec" --json
#   记下 run_id，期望 {"status":"paused","current_step_id":"question_gate",...}
'' | & $env:SPECIFY_BIN workflow resume <run_id> `
       --input question_verdict=approve `
       --input 'product_answer=产品确认（演示数据）：转赠后原券立即冻结，仅指定接收人可领取，24 小时未领取自动退回' --json
#   期望 {"status":"paused","current_step_id":"decision_gate",...}
'' | & $env:SPECIFY_BIN workflow resume <run_id> --input decision_verdict=A --json
#   期望 {"status":"completed"}
'' | & $env:SPECIFY_BIN workflow status <run_id> --json
Get-Content .\.specify\workflows\runs\<run_id>\log.jsonl -Encoding UTF8

# 7) 拒绝路径（必须 aborted 且退出码非 0，后续步骤不得启动）
'' | & $env:SPECIFY_BIN workflow resume <新run_id> --input question_verdict=reject --json
```

查看证据：`docs/verification/evidence/2026-10-17/`（`MANIFEST.md` 内有每个文件的 SHA-256）。

---

## 11. 安全与合规声明（本轮自查）

- 未访问生产数据库，未调用生产/灰度部署服务，未执行任何部署动作；
- 未提交任何密钥：凭据检查使用 `pi auth check --json`（不带 `--credentials`），仓库内无 token；`.gitignore` 排除 `.pi/agent/`、`.pi/auth.json`、`.p0-evidence/`、`.specify/workflows/runs/`；
- 验证期间 Pi 被 `--tools read,grep,find,ls` 强制只读，**技术上无法**写文件或执行 shell；
- 所有 Spec Kit 工作流只用 `prompt` + `gate`，**未使用** `shell` 步骤（按官方安全说明，`shell` 不是沙箱）；
- 只在功能分支 `feat/v0.1-agent-integration` 上提交，未改动 `main`，未自动合并；
- 入仓证据**只含元数据**：不写提示词、不写业务答复、不写模型输出；个人路径与 token 形状被替换；原始 Pi 会话在任何模式下都不导出；raw 模式拒绝写入仓库（`-IncludeModelOutput` 守卫）；
- 未开始任何网页界面开发。

---

## 12. 下一轮（P0-04 起）前的准备清单

1. 需要人类答复 §9 的 D1/D2/D3/D4/D5（尤其 D2、D5 会直接决定 P0-04 的落盘结构与权限边界）。
2. P0-04 起对需要入库的模型输出步骤开启 `capture: true`（已验证可用），并在模型输出后加**确定性校验步骤**（JSON Schema），不信任模型自述。
3. 为"业务问题卡"引入 `requires.speckit_version` 与运行封装，把"必须用管道 stdin"写成代码级约束。
4. 保持 `.py` 校验脚本（PS 5.1 对中文 `.ps1` 需 UTF-8 BOM——本轮踩过一次，脚本已带 BOM）。

---

## 13. PR #1 审查修复记录

审查结论：「P0-01～03 基础集成达到预期，但建议修复以下问题后再合并」。三项 MUST FIX 已全部修复，并各自配套了**反向测试**（证明缺陷真的能被抓到）。

### FIX-01 P0-03-01 没有检查退出码与完整步骤信息

- **问题**：原实现只把 `workflow info` 的几行输出当“描述性文本”返回，退出码非 0、步骤缺失、步骤顺序/类型漂移都不会失败。
- **修复**：新增 `scripts/lib/verification-lib.ps1`，把 `specify workflow info` 解析与断言做成可单测的纯函数 `ConvertFrom-WorkflowInfoText` / `Test-WorkflowInfoStrict`。现在 `P0-03-01` 严格断言 **退出码 = 0、工作流 id = `devrelay-smoke`、声明步骤数 = 实际解析数、5 个步骤 id 顺序、5 个步骤类型顺序**；解析失败也会直接失败（防止 Spec Kit 升级后解析静默返回空列表）。
- **反向测试**：`R02` 非 0 退出码、`R03` 少一个步骤、`R04` 步骤顺序错、`R05` gate 被降级成 prompt、`R06` 输出不可解析、`R07` 工作流 id 不符 —— 全部必须被拒；`R01` 用合法输入防止“永远失败”的假检查。
- **附带修复**：`P0-01-07` 原本要求工作区干净，等于把“开发者正在改脚本”误判成失败（本轮实际踩到：`M scripts/...` 导致 `P0-01-07` 失败）。现在改为**与运行前基线比对**：允许预先存在的未提交改动，但本次运行不得新增/改变/删除任何受版本控制文件。
- **新增护栏**：`P0-GUARD-01` 在所有 Pi 调用结束后再比对一次基线，覆盖 P0-02/P0-03 的模型调用。

### FIX-02 退出条件没有考虑 `not_run`

- **问题**：原逻辑只在 `failed > 0` 时返回 1。必需检查因前置失败而 `not_run` 时，脚本仍可能返回 0（“未验证”被当成“通过”）。
- **修复**：退出判定移入 `Get-VerificationExitCode`：**无任何检查 → 1；任一 `failed` → 1；任一 `not_run` → 1；出现未知状态（拼写错误）→ 1；全部 `passed` 才 0**。并输出 `verdict:` 说明具体原因，`summary.json` 里记录 `exit_code` 与 `verdict`。
- **反向测试**：`R10` 有一个 failed → 1、`R11` 有一个 not_run → 1（回归主项）、`R12` 空结果 → 1、`R13` 状态拼写错误 → 1、`R09` 全通过 → 0。

### FIX-03 证据导出仍包含模型输出与业务文本

- **问题**：原 `export-evidence.ps1` 直接把 `phase*-run.txt`、`probe-run.txt`、`full-run-console.txt`、`summary.json` 等复制进 `docs/verification/evidence/`，这些文件含 Pi 的业务问答、方案比较与 ADR 草稿。
- **修复**：默认改为**安全模式（元数据）**：
  - 只导出**状态、退出码、时间线和捕获流的字节数 + SHA-256**（`run-state-snapshot.md`），以及不包含提示词/模型文本的白名单元数据（`environment.txt`、`integration-status.txt`、`workflow-info.txt`）；
  - **不导出**任何提示词、业务答复、模型输出，连截断版本也不导出；失败详情也不入仓（本地 `summary.json` 保留，可用脚本复现）；
  - `MANIFEST.md` 内置**“拒绝导出清单”**：列出每个被扣留的本地文件及其 SHA-256 与原因，可审计但不可读内容；
  - 原始 Pi 会话目录 `pi-sessions/` **任何模式都不导出**（目录用聚合摘要体现）；
  - `-IncludeModelOutput`（raw 模式）**拒绝写入 git 工作树**，只能导出到仓库外；
  - 所有导出文本经过 `Protect-EvidenceText`：`C:\Users\<name>` → `%USERPROFILE%`，`ghp_/gho_/ghs_/sk-/AKIA/xox*-` → `<redacted-*>`。
- **反向测试**：`R14` 安全模式全目录扫描无植入业务标记、`R15` 仍保留摘要与拒绝清单（可审计）、`R16` raw 模式写入仓库必须被拒且不落盘、`R17` raw 模式导出到仓库外可用但**仍不含** Pi 会话、`R18` 路径/token 被替换。
- **已清理历史**：旧的 `docs/verification/evidence/2026-10-17/`（含原始模型文本）已从仓库删除，并按新策略重新生成；同时修复了目录（`pi-sessions/`）被当普通文件摘要导致的崩溃。

### 修复后的复跑结果

| 套件 | 结果 | 退出码 |
| --- | --- | --- |
| `scripts/verify-p0.ps1`（P0-01/P0-02/P0-03 + 全局护栏） | **22 passed / 0 failed / 0 not_run**，`verdict: all checks passed` | 0 |
| `tests/run-negative-tests.ps1`（反向测试） | **17 passed / 0 failed** | 0 |

本次为**重新执行**，不是复用旧日志：run `cbd0b65d`（双闸门）、`5223705e`（拒绝路径）、`a6ae2440` / `c7bb434d`（P0-02 探测）。

> 审查备注：“本次审查未在独立 Windows 环境复跑测试，结论基于仓库代码及已有执行证据。”——本次修复已在本机 Windows 10.0.26200 + PowerShell 5.1 环境**实际复跑**上述两个套件，日志与摘要见 `docs/verification/evidence/2026-10-17/`。

---

## 14. 下阶段强制要求：P0-05 的“方案语义漂移”防护

审查提出：**P0-05 必须解决方案语义漂移**——人类审批时保存完整技术方案、唯一标识、版本及内容哈希，后续 Agent 不能重新解释或静默修改已经批准的方案。

本轮不实现（不在 P0-01～03 范围），但把约束写成可验收的设计基线，作为 P0-05 的 Definition of Done：

1. **决策卡（DecisionCard）最小字段**
   `decision_id`（不可变唯一标识）、`requirement_id`、`options[]`（每个方案含 `option_id`、完整正文、`evidence_status`）、`selected_option_id`、`approved_by`（人类）、`approved_at`、`decision_context`、`constraints`、`revisit_triggers`、`schema_version`、`content_sha256`。
2. **冻结语义**
   - 审批通过时对“方案全文 + 元数据 + 版本号”计算 `content_sha256` 并随决策卡一起固化；
   - `resume` 只传 `decision_id`（不传方案正文），下游步骤按 ID 读取已冻结快照；
   - 后续任何步骤只能**引用**该快照，任何字段被改动 → 哈希不匹配 → 工作流**必须失败**，而不是“重新解释后继续”。
3. **变更只能走新的决策**
   需求变化或出现证据冲突时，必须新建 `decision_id`（版本递增）并重新进 Decision Gate；旧决策保留为历史，禁止原地覆盖。
4. **可验收的负向测试（P0-05 必须交付）**
   - 篡改已批准方案的任一字段 → 哈希校验失败、工作流不进入实现阶段；
   - 传旧 `decision_id` 但内容被替换 → 拒绝执行；
   - Agent 自行“优化”已批准方案 → 触发失败并要求人类重新审批；
   - 未批准的方案不得出现在实现输入中（`approved_by` 为空即视为未批准）。
5. **与工作流状态的关系**
   `decision_id` + `content_sha256` 作为业务记录的主键；Spec Kit 的 `run_id` 只作为执行证据引用，**不得**成为业务事实的第二份真相源。

该项已列入 §9 的待决策范围：`decision_id` 的生成方式、快照存放位置（文件/Git/未来数据库）需要人类确认后落地。
