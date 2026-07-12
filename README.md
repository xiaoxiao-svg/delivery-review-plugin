# delivery-review

基于 git-notes 的**双 Agent 交付协作工作流（loop 模式）**。

> 核心理念（塔勒布）：*你不知道的，远比你知道的重要。* AI 交付必须显式声明「已知 / 不确定 / 未检查」三层，未知清单比检查清单更重要。

## 解决的两个真实痛点

| 痛点 | 传统做法 | 本 plugin 的做法 |
|------|---------|----------------|
| 子代理调用靠模型自愿 | skill 里写"请 spawn 子代理"，模型可能跳过/忘了隔离 | 修复/审查拆成独立 **agent 定义**；`/delivery-review` 命令强制用 Task 调用它们；审查者 `disallowedTools` 在**工具层强制只读** |
| loop 循环差点意思 | skill 用 `while True` 伪代码，模型不是解释器，轮次靠记忆 | 循环状态外置到 `.delivery-review/state.json`，由**状态机**判定收敛/质量门/震荡，不靠模型记忆；每轮开头先读状态 |

## 流程

```
上下文确认 → 方案 → 目标声明(=退出标准)
  → Loop[ 修复 Agent(delivery-fixer) ↔ 审查 Agent(delivery-reviewer,隔离只读) ]
  → 重新输出目标 → 人工验收（不可由 AI 代理）
```

## 组件

```
delivery-review/
├── .claude-plugin/plugin.json      # Claude Code 插件清单
├── skills/delivery-review/SKILL.md # 方法论 + 数据模型（自动触发 / 参考）
├── agents/
│   ├── delivery-fixer.md           # 修复工程师（读写）
│   └── delivery-reviewer.md        # 资深审查者（隔离 + 只读）
├── commands/delivery-review.md     # /delivery-review 确定性入口（强制闭环）
└── README.md
```

## 安装

### Claude Code

```bash
# 方式一：git clone 后作为本地插件加载
git clone <本仓库地址> ~/.claude/plugins/delivery-review
# 重启 Claude Code，或 /plugin install ~/.claude/plugins/delivery-review

# 方式二：marketplace 安装（若有）
/plugin install <marketplace>/delivery-review
```

启用后技能自动按描述触发；也可手动 `/delivery-review <改动描述>`。

### OpenCode

OpenCode 原生读取 `SKILL.md`，但插件注册入口与 Claude Code 不同。手动接入：

```powershell
# 1) skills：在 opencode.json 的 skills.paths 加入本仓库 skills/ 目录绝对路径
#    "skills": { "paths": ["C:/path/to/delivery-review/skills"] }

# 2) commands：软链命令文件到 opencode commands 目录
New-Item -ItemType SymbolicLink `
  -Path "$HOME/.config/opencode/commands/delivery-review.md" `
  -Target "C:/path/to/delivery-review/commands/delivery-review.md"

# 3) agents：把 agents/ 下两个 .md 放入 opencode 可发现的 agents 目录
#    （通常为项目 .opencode/agents/ 或用户级 agents 目录，详见 opencode 文档）
```

> OpenCode 侧的 `.ts` 原生插件入口（用 `config` hook 程序化注册）非必须；上述手动接入即可获得完整能力。若需一键 `plugin` 安装，可额外补一个 `.ts` 入口——欢迎 PR。

## 使用

```
/delivery-review 给商品列表加 Redis 缓存，需降级方案
```

按提示完成上下文确认、方案、目标声明后，工作流自动循环直到收敛，最后交你人工验收。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
