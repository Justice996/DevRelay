# DevRelay

让 AI 自主研发，让人类掌握关键决策。

## 当前状态

第一阶段（v0.1）按 `DevRelay_v0.1_架构与集成验证任务.md` 推进，**本轮仅完成 P0-01 / P0-02 / P0-03（集成验证）**：

- P0-01 环境清点：通过
- P0-02 Spec Kit ↔ Pi 原生集成：通过（Spec Kit 1.2.1 → Pi 0.86.1 + DeepSeek）
- P0-03 两次人工审批节点的暂停与恢复：通过

详见 [docs/verification/P0-01-P0-03-integration-report.md](docs/verification/P0-01-P0-03-integration-report.md)，其中同时列出了**未验证项**与**需要人类决策的取舍**。

尚未开始：业务协作卡（P0-04）、方案决策卡（P0-05）、开发交接包与独立验收（P0-06）、网页界面。

## 架构边界（一句话版）

- **Pi** 是执行引擎（复用本机既有 DeepSeek 配置）；
- **Spec Kit Workflow** 是工作流运行状态的唯一来源（`prompt` / `gate` / pause / resume）；
- **DevRelay 自研的**是业务协作协议：问题卡、方案卡、决策记录、证据与权限策略。

## 快速开始

```powershell
# 安装锁定版本的 Spec Kit（隔离 venv，不动全局环境）
powershell -ExecutionPolicy Bypass -File .\scripts\setup-specify.ps1
$env:SPECIFY_BIN = "$env:LOCALAPPDATA\DevRelay\tools\specify-venv-1.2.1\Scripts\specify.exe"

# 跑全量 P0 验证（P0-01 + P0-02 + P0-03，含拒绝路径），退出码 0 表示全部通过
powershell -ExecutionPolicy Bypass -File .\scripts\verify-p0.ps1

# 导出可审查的证据快照（剔除原始 Pi 会话）
powershell -ExecutionPolicy Bypass -File .\scripts\export-evidence.ps1
```

## 目录约定

| 路径 | 作用 |
| --- | --- |
| `.specify/`、`.pi/prompts/` | Spec Kit 初始化结果 + Pi 集成模板（随版本控制） |
| `workflows/` | 工作流定义（`prompt` / `gate`） |
| `scripts/` | 可重复执行的安装、验证、证据导出脚本 |
| `docs/verification/` | 验证报告与证据快照 |
| `.specify/workflows/runs/`、`.p0-evidence/` | 本地运行态与原始证据（**已被 `.gitignore` 排除**） |

## 安全红线

不访问生产数据库、不调用生产部署、不提交密钥、不自动合并主分支；工作流不使用 `shell` 步骤；模型输出不得自行判定测试通过。
