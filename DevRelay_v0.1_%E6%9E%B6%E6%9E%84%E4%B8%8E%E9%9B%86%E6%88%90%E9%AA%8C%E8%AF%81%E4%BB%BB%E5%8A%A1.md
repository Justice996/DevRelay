# DevRelay v0.1｜方案 C：Pi + DeepSeek + Spec Kit Workflow

> 项目仓库：https://github.com/Justice996/DevRelay  
> 文档性质：第一阶段架构与集成验证任务（RFC / Pi 开发交接）  
> 状态：待在本地验证；**不代表已构建、运行、提交 GitHub 或测试通过**。  
> 版本基线：编写时参考 2026-10-17 的官方在线文档；开始开发时应锁定实际使用的版本。

## 0. 北极星

让 AI 自主完成业务分析、技术研究、编码与验证；让人类像项目同事一样提供现实业务信息，并在存在业务影响的技术取舍上做决策。**AI 不把 Redis、数据库锁之类问题直接推给产品经理；应先转译为业务可理解的后果。**

### 本阶段要证明的唯一核心闭环

> 输入模糊需求 → AI 提出产品/运营听得懂的问题 → 工作流暂停 → 人类拿回答复 → AI 提交 2–3 种方案和推荐理由 → 工作流暂停 → 人类选方案 → 形成 ADR 与开发任务 → 输出可追溯的验收标准。

v0.1 **暂不**自动部署、访问生产资源、自动合并 PR、打造复杂 SaaS 平台或重新实现 Agent 运行时。

## 1. 推荐架构

```text
人类（开发者/产品/运营）
        │ 业务答复与关键审批
        ▼
DevRelay 交互层（MVP 先 CLI/文件，未来 Vue 3）
        │ 业务问题卡 / 方案卡 / ADR / 验收报告
        ▼
DevRelay 领域协议层（薄 TypeScript 层）
        │ 业务对象与审计；不自造工作流状态机
        ▼
Spec Kit Workflow （**工作流运行状态唯一来源**）
        │ Pi integration / pause / resume / gate
        ▼
Pi Coding Agent（用户本机的现有 Pi + DeepSeek 配置）
        │ 工具执行/文件编辑/结果事件
        ▼
独立测试 + Git / GitHub PR / CI 证据
```

### 核心边界

1. **Pi 是执行引擎**，复用现有 DeepSeek 模型配置；不把模型供应商写死在 DevRelay 领域对象里。
2. **Spec Kit 是 v0.1 的工作流编排者**。避免另建 Node 调度器和双份执行状态；其运行态位于 `.specify/workflows/runs/<run_id>/`。
3. **DevRelay 的真正自研能力是业务协作协议**：问题卡、方案卡、规则来源、决策记录、权限/证据引用。先以文件及 JSON Schema 实现，证明价值后再升级界面与数据库。
4. **Git 为规范版本载体**：人类批准后的需求/ADR/验收标准进入受审查的版本库；Pi 的会话历史不等于被批准的业务事实。
5. **测试运行事实不由大模型口头判定**：命令、退出码、日志、commit SHA 和最终状态必须有独立证据。

### 开源复用原则

- 官方 Pi 包名以本地版本为准；新版官网文档显示 `@earendil-works/pi-coding-agent`，不要混用旧包名 `@mariozechner/pi-coding-agent`。
- 官方 Spec Kit 使用 `specify init --here --integration pi` 初始化，并提供 YAML `command`、`prompt`、`gate`、`if`、`switch`、`shell` 等节点。
- 第一版优先通过 **Spec Kit 的原生 Pi integration** 运行，不额外嵌入 Pi SDK；以后需要浏览器事件流时再评估 Pi RPC/SDK，避免重复接入。
- 参考项目的许可证、版本/API 兼容和依赖锁定，均需由本地 Agent 实际验证。

## 2. 最小业务协议

### BusinessQuestion（业务协作卡）

必填：`id`、`requirement_id`、`target_role`（产品/运营/其他）、`question`（通俗中文）、`why_needed`、`blocking_work_items`、`status`、`source`（回答来源/确认人/时间）。

问题原则：单个问题不要求对方懂技术；给出必要的场景和回答选项；能否阻塞要标明。答案有冲突则升级人类确认，而不是自行裁定。

### ArchitectureOption / Decision（方案决策卡）

候选方案至少两种；每个方案必填：`option_id`、`approach`、`business_fit`、`pros`、`cons`、`cost`、`risks`、`evidence_status`。报告还应包含 `recommendation`、`recommendation_reason` 和 `unknowns`。选定后写 ADR：`decision_id`、`selected_option`、`approved_by`、`decision_context`、`constraints`、`revisit_triggers`。

### AcceptanceCriterion / Evidence（独立验证）

`criterion_id`、`business_rule_refs`、`given_when_then`、`expected_result`、`frozen_version`、`result`（passed/failed/not_run）、`evidence_path`、`git_sha`、`executed_at`。没有真实运行记录，不得标记 passed。开发者不可在测试失败后自行放宽业务验收条件。

## 3. 阶段与任务清单（按先后顺序）

### P0-01 环境清点（不修改生产或主分支）

**执行**：本地 Pi + DeepSeek。记录 OS、`node --version`、`pi --version`、`pi --help`、`python --version`、`specify version`、`specify workflow --help`、`git status`（不记录 API Key 值）。确认 Pi 实际安装包版本、模型调用正常，Python >= 3.11；新版 Pi 的 Node 要求按已安装包说明核实（官方主线文档提示 Node >= 22.19）。

**通过标准**：版本与命令输出截图/文本存在；Pi 在**临时空目录**完成只读问答；不存在无意修改文件。

### P0-02 Spec Kit ↔ Pi 原生集成验证

**执行**：在独立分支或临时工作树上初始化 Spec Kit `--integration pi`；检查 `.pi/prompts/` 和 `.specify/`；验证 `specify integration status`；运行一个只读 `prompt` 步骤；记录 stdout/stderr、退出码、Pi 实际用到的模型。

**通过标准**：Spec Kit 能调用本机 Pi 进行提示；没有手工复制提示词到 Pi 的步骤；版本/环境不可用时给出明确日志。

### P0-03 Gate 暂停与恢复实验

**执行**：运行本附件 `DevRelay_v0.1_smoke_workflow.yml`；预期先暂停于 `question-gate`。使用另一个终端或进程结束后，按输入参数恢复；随后暂停于 `decision-gate`；再选择 A/B/C 并恢复。参照官方 `--json` 输出和 `.specify/workflows/runs/<run_id>/` 的状态证据。

**通过标准**：两次 pause、两次 resume，最后为 completed；重启终端后仍能恢复；已完成步骤不会重新执行；拒绝时不越过审批。

### P0-04 业务协作卡最小实现

**执行**：Pi 解析“优惠券转赠”模糊需求，先查已知规则；生成**一条真实未确认业务问题**：如“转赠后对方未领取，原用户还能使用吗？”标记“建议问产品经理”；保存结构化问题卡；人工录入答案并注明来源；同步更新业务规则。

**通过标准**：问题表述不含要求产品理解的 Java/SQL/锁术语；问句、回复、来源、状态可查询；重启后不丢失；没回答不能冒充已确认。

### P0-05 多方案决策卡最小实现

**执行**：Pi 针对“同一张优惠券只能成功领取一次”给出 MySQL 条件更新、Redis 协调 + MySQL、队列异步处理的对比；能解释为何推荐 A，也能标注尚未压测的性能假设；人类选择 A 后写入 ADR；B/C 保留为备选。

**通过标准**：每个方案有业务场景、优点、缺点、成本、风险和证据状态；推荐有理由；决策记录写明人类选择和重评条件；未授权不得悄悄换成 B/C。

### P0-06 自动生成开发交接包与独立验收

**执行**：根据已确认业务规则与 ADR，生成 `tasks.md`、`acceptance.md` 和开发 Agent 的输入；先冻结验收标准再让开发 Agent 修改样例代码；保存测试运行命令与结果。第一版仅在隔离仓库或测试项目运行，不对真实业务系统执行写操作。

**通过标准**：任务有依赖关系和清晰完成定义；至少包含并发抢同一张券、重复请求、无权限领取、故障恢复的验证场景；通过/失败/未验证可区分；测试失败不会导致 AI 修改验收规则。

### P0-07 GitHub 交付与独立审查

**执行**：本地 Pi 将上述设计和可运行原型提交 feature 分支，创建 PR（不用自动合并）；报告包含复现命令、实际 CI/测试结果、遗留缺陷。我通过 GitHub 读取 PR diff、关键文件、CI 状态，反馈必须修改/建议优化/无法验证之处。

**通过标准**：PR 可追溯到本需求与 ADR；任何未经运行的测试不得宣称通过；主分支未被自动改动。

> 已知协作阻碍：先前通过当前 GitHub 集成创建 Issue 返回 HTTP 403，**不能假定我可以写入 Issue/PR**。本地 Pi 有权限时可提交 PR；我可继续审查可读取的仓库内容。修复 GitHub App 写权限后再尝试直接发布审查意见。

## 4. 第一版演示脚本

输入需求："实现用户向朋友转赠优惠券，一张券不能被重复领取。"

- Agent 发现领取资格及未领取情况下的使用权不明确，向产品生成通俗中文问句。
- 工作流暂停，用户带回现实同事的回答，附来源。
- Agent 生成 2–3 个技术方案，用业务语言解释取舍，推荐 A 并声明未完成的验证。
- 用户选择 A；形成 ADR-001，冻结业务验收标准，生成开发任务。
- 如果后续需求变化或出现证据冲突，重新进入 Question/Decision Gate，而不是静默覆盖。

## 5. 运行检查（以实际 CLI 版本为准）

环境核对：

```bash
node --version
pi --version
pi --help
python --version
specify version
specify integration status
specify workflow --help
```

首次安装 Spec Kit（仅当本地没有 `specify` 时）：

```bash
# uv 已安装的前提下；正式执行可锁定官方 release tag
uv tool install specify-cli
```

在已创建的 Git 仓库中，先切换 feature 分支并检查工作区状态，再初始化：

```bash
git checkout -b feat/v0.1-agent-integration
specify init --here --integration pi
# 如果该版本拒绝非空目录，先备份/提交，再按官方说明审慎使用 --force
```

Smoke workflow 测试：

```bash
specify workflow info ./DevRelay_v0.1_smoke_workflow.yml
specify workflow run ./DevRelay_v0.1_smoke_workflow.yml \
  --input spec="开发优惠券转赠：一张券只能被领取一次" --json
# 从输出读取 <run_id>，预期 status=paused
specify workflow resume <run_id> \
  --input question_verdict=approve \
  --input product_answer="产品确认：赠送后只有指定接收人可领取，确认人和日期须单独记录" --json
# 预期第二次 paused
specify workflow resume <run_id> --input decision_verdict=A --json
# 预期 completed
specify workflow status <run_id> --json
```

本附件 YAML 只演示 **Spec Kit 调用 Pi 与两个静态 gate**；动态生成结构化问题卡、ADR 写盘、独立验收、权限策略将在 P0-04 至 P0-07 完成。**YAML 仅经过语法解析检查，未在你的 Pi / Spec Kit 环境执行。**

## 6. 项目文件布局（逐步落地，不要一次造全）

```text
DevRelay/
  README.md
  AGENTS.md                         # 开发与安全规则
  docs/
    architecture/v0.1.md           # 本文的正式版
    decisions/ADR-001.md           # 人类批准后才创建
    requirements/rules.md          # 业务事实、来源、版本
    acceptance/v0.1.md             # 冻结的独立验收要求
  workflows/
    devrelay-smoke.yml             # 最小工作流
  contracts/
    question.schema.json
    decision.schema.json
    evidence.schema.json
  .specify/                         # Spec Kit 管理的工作流配置
  .pi/                              # Spec Kit/Pi 扩展和提示模板
  tests/                            # v0.1 合同/暂停恢复验证
```

注意 `.specify/workflows/runs/` 可能包含原始模型输出及真实业务信息；默认作为本地运行态，不把敏感输出推到公开 GitHub。后续需要云端协作时，应定义脱敏和权限策略。

## 7. 故障与安全红线

- 必须在隔离工作目录验证；无生产 DB/生产 Jenkins 权限。
- Spec Kit 的 `shell` 步骤不是沙箱，任何包含外部输入插值的 shell 命令须避免或使用严格白名单，不允许 AI 拼接任意业务文本为 shell 指令。
- Pi 子进程异常退出/模型调用失败/超时，需要保存失败状态，不得标记任务成功。
- Spec Kit 工作流状态与 DevRelay 业务记录的引用关系以 `run_id` 和内容版本号关联，不设计第二份竞争的工作流状态真相。
- 外部产品答案必须保留来源、确认状态，不是模型引用就算业务确认。
- 所有未验证的性质明确报告 `not_run`；不自动批准部署和合并。
- 锁定 Pi、Spec Kit 主版本，升级须通过 P0-02/03 回归实验。

## 8. 第一阶段完成定义（Definition of Done）

- [ ] 已记录本地 Pi（DeepSeek）和 Spec Kit 版本与实际可用命令。
- [ ] `specify workflow` 能通过原生 Pi integration 调用现有 Pi。
- [ ] 两次 gate 均能暂停，在关闭进程后继续，最终完成。
- [ ] 一张通俗业务提问卡已由 AI 生成、获得人类回答并记录来源。
- [ ] 至少两种技术方案经 AI 比较，人类选定方案，生成 ADR。
- [ ] 自动生成带依赖的开发任务与提前确认的验收标准。
- [ ] 实际成功/失败的测试证据可查询；未运行项目明确为未验证。
- [ ] 所有成果经 feature 分支提交，可供 GitHub PR 审核。

## 9. 参考依据

- Pi 官方 SDK：https://pi.dev/docs/latest/sdk
- Pi 官方 RPC：https://pi.dev/docs/latest/rpc
- Pi 官方 CLI：https://pi.dev/docs/latest/cli
- Pi 官方 GitHub：https://github.com/earendil-works/pi
- Spec Kit 安装与 `pi` 集成：https://github.com/github/spec-kit/blob/main/docs/installation.md
- Spec Kit Workflow：https://github.com/github/spec-kit/blob/main/docs/reference/workflows.md
- Spec Kit 的 Agent 集成：https://github.com/github/spec-kit/blob/main/docs/reference/integrations.md
