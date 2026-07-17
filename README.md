# delivery-review

基于 **git-notes** 的**双 Agent 交付协作工作流**（loop 模式）。安装到 **Claude Code**，帮你把每个代码改动都经过「修复 ↔ 审查」闭环，直到收敛后交你人工验收。

> 核心理念（塔勒布）：*你不知道的，远比你知道的重要。* AI 交付必须显式声明「已知 / 不确定 / 未检查」三层——本 plugin 用"未知清单"作为核心交付物。

---

## 解决的真实痛点

| 痛点 | 传统做法 | 本 plugin 的做法 |
|------|---------|------------------|
| 子代理隔离靠模型自觉 | skill 里写"请 spawn 子代理"，模型可能跳过 | 修复 / 审查拆成独立 **agent 定义**；`/delivery-review` 用 Task 强制调用；审查者 `disallowedTools` 在**工具层强制只读** |
| loop 循环靠模型记忆 | skill 写 `while True` 伪代码，轮次记不住 | 循环状态外置到 `.delivery-review/state.json`，由**状态机**判收敛 / 质量门 / 震荡，不靠上下文记忆 |

---

## 一句话流程

```
上下文确认 → 方案 → 目标声明（= 退出标准）
  → Loop[ 修复 Agent(delivery-fixer) ↔ 审查 Agent(delivery-reviewer, 隔离只读) ]
  → 重新输出目标 → 人工验收（不可跳过、不可 AI 代理）
```

每轮 loop：
1. **修复**：按目标或按 risk 改代码，输出 `review` 留言（意图声明 + 自检 + 未知清单）
2. **审查**：独立只读审查，输出 `risk`（分级 P0/P1/P2）+ `score`（1-10）+ 收敛判断
3. **状态机**：自动判`收敛 / 质量门 / 震荡 / 达到上限`，决定继续还是退出

**退出后**：重新输出初始目标 → 你对照验收 → 不通过再跑一轮

---

## 组件

```
delivery-review/
├── .claude-plugin/plugin.json         # Claude Code plugin 清单
├── skills/delivery-review/SKILL.md    # 方法论 + 数据模型（自动触发 / 参考）
├── agents/
│   ├── delivery-fixer.md              # 修复工程师（读写）
│   └── delivery-reviewer.md           # 资深审查者（隔离 + 只读）
├── commands/delivery-review.md        # /delivery-review 确定性入口
├── install.ps1                        # Windows 一键安装
├── LICENSE                            # MIT
└── README.md                          # 本文件
```

| 组件 | 作用 |
|------|------|
| `plugin.json` | skills-dir plugin 注册入口，Claude Code 启动自动加载 |
| `SKILL.md` | 自动触发的参考知识（交付流程 / 数据模型 / 风险分级 / dispute 机制） |
| `delivery-fixer.md` | 修复 agent：按方案改代码、逐条处理 risk、输出意图声明 |
| `delivery-reviewer.md` | 审查 agent：工具层强制只读、输出分级 risk + 质量分 + 收敛判断 |
| `delivery-review.md` (command) | 确定性入口：强制走 Step 0-4，不跳步 |
| `install.ps1` | 一键装进 `~/.claude/` |

---

## 安装（仅 Claude Code）

### 方式一：双击 install.bat（本地使用，推荐）

双击项目根目录的 `install.bat`，脚本自动把插件复制到 `~/.claude/skills/delivery-review/`，**重启 Claude Code** 即加载。

若偏好 PowerShell，可在仓库根目录运行：

```powershell
.\install.ps1
```

> 提示：如果提示"因为在此系统上禁止运行脚本"，说明系统执行策略限制了 .ps1，改用双击 `install.bat` 即可绕过。

### 方式二：市场安装（公开分发，推荐）

在 Claude Code 会话中执行：

```
/plugin install delivery-review@delivery-review-marketplace
```

安装后即可使用 `/delivery-review` 命令。

## 卸载（仅 Claude Code）

### 方式一：双击 uninstall.bat（本地使用）

双击 `uninstall.bat`，自动删除 `~/.claude/skills/delivery-review/` 及所有 `.bak-*` 备份。

若偏好 PowerShell，可在仓库根目录运行：

```powershell
.\uninstall.ps1
```

### 方式二：市场卸载（公开分发）

在 Claude Code 会话中执行：

```
/plugin uninstall delivery-review@delivery-review-marketplace
```

### 手动管理

把 `skills/`、`commands/`、`agents/` 复制进 `~/.claude/skills/delivery-review/` 即加载；删除该目录即卸载。重启 Claude Code 生效。

> 本仓库是 **skills-dir plugin**：含 `.claude-plugin/plugin.json` 的目录放进 `~/.claude/skills/<name>/` 即自动注册，出现在 `claude plugin list`。

---

## 使用

在任何项目目录：

```
/delivery-review 给商品列表加 Redis 缓存，需降级方案
```

跟着提示走完：

1. **上下文确认**（做什么 / 为什么 / 顾虑） → 不清晰会拒绝退出
2. **方案**（改哪里 / 影响 / 验证方式） → 等你确认
3. **目标声明**（= 退出标准，每一条可验证）
4. **自动 loop**（修复 ↔ 审查，直到收敛 / 质量门 / 震荡 / 上限）
5. **人工验收**（⚠️ 不可 AI 代理，必须你来）

---

## Loop 退出条件（状态机，优先级从高到低）

1. **oscillation / dispute 未解** → 强制退出，人工裁决
2. **converged**：连续两轮 `risk==0` 或 `新增 risk==0` → 理想退出
3. **quality_gate**：`质量分 >= 7` 且无 P0/P1 → 次优退出
4. **max_rounds**：达到上限（默认 3） → 兜底退出

---

## 数据模型

- 对话记录：`git notes --ref=delivery-review`
- 循环状态：`.delivery-review/state.json`
  ```json
  {"round":0,"consecutive_clean":0,"last_score":0,"exit_reason":"","max_rounds":3}
  ```

```
<ID>|<from>|<type>|<reply_to>|<正文>
```

| type | 谁发 | 含义 |
|------|------|------|
| context | 编排者 | 目标 + 背景 + 方案 |
| review | 修复方 | 改动说明 + 意图声明 + 自检 + 未知清单 |
| risk | 审查方 | 问题描述 + 分级 + 质量分 |
| done | 修复方 | 对某条 risk 的处理结果 |
| score | 审查方 | 本轮质量评分 + 收敛判断 |
| approve | 审查方 | 所有 risk 已解决，建议人工验收 |
| dispute | 修复方 | 对某条 risk 的反驳（附理由） |
| confirm | 审查方 | 收到 dispute 后自我核查（仍坚持） |
| withdraw | 审查方 | 撤回原 risk（误判） |

**风险分级**：P0 阻塞（必须修） / P1 重要（修或说明理由） / P2 建议（可 defer）。

---

## Dispute 机制

```
审查方发 risk → 修复方不同意 → dispute
  → 审查方自我核查
     ├─ 仍认为有问题 → confirm → 退出 loop，人工裁决
     └─ 发现误判 → withdraw → 继续 loop
```

---

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
