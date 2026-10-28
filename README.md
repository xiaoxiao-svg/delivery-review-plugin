# delivery-review

基于 **git-notes** 的**双 Agent 交付协作工作流**（loop 模式）。安装到 **Claude Code**，帮你把每个代码改动都经过「修复 ↔ 审查」闭环，直到收敛后交你人工验收。

> 核心理念（塔勒布）：*你不知道的，远比你知道的重要。* AI 交付必须显式声明「已知 / 不确定 / 未检查」三层——本 plugin 用"未知清单"作为核心交付物。

---

## 解决的真实痛点

| 痛点 | 传统做法 | 本 plugin 的做法 |
|------|---------|------------------|
| 子代理隔离靠模型自觉 | skill 里写"请 spawn 子代理"，模型可能跳过 | 修复 / 审查拆成独立 **agent 定义**；`/delivery-review` 用 Agent 工具强制调用；审查者 `disallowedTools` 在**工具层强制零命令权限** |
| loop 循环靠模型记忆 | skill 写 `while True` 伪代码，轮次记不住 | 循环状态外置到 `.delivery-review/state.json`，由**状态机**判收敛 / 质量门 / 震荡，不靠上下文记忆 |
| 小改动被大仪式拖慢 | 1 分钟能改完的活走全套审查流程，20 分钟才交付 | **风险分级路由**：hook 机械化判定 trivial/standard/critical；trivial 快车道（一次确认 + 主会话直改 + 轻量审查一轮定音）；分级规则在 hook 代码里，不在提示词里 |
| 审查过程黑箱，无法溯源 | 子代理上下文销毁后，"看了什么、凭什么判 risk"蒸发 | **溯源链四层**：对话实录（git-notes）→ 审查轨迹（review.log，审查者每轮必输出）→ 材料快照（work/material-rN.md，字节级留存每轮现场）→ git diff 基线 |

---

## 一句话流程

```
上下文确认 → 方案（双轨 + 可选 + 预估档位）→ 方案审查（大改动时）→ 目标声明（= 退出标准）
  → Loop[ 修复 Agent(delivery-fixer) ↔ 审查 Agent(delivery-reviewer, 隔离只读) ]   ← standard/critical
  → 或 trivial 快车道[ 主会话直改 → 轻量审查一轮定音 ]
  → 重新输出目标 → 人工验收（裁决权不可 AI 代理）→ 交付报告（docs/）
```

每轮 loop：
1. **修复**：按目标或按 risk 改代码，输出 `review` 留言（意图声明 + **验证证据（命令与输出）** + 自检 + 未知清单）
2. **审查**：独立只读审查，输出 `risk`（分级 P0/P1/P2）+ `score`（1-10）+ 收敛判断
3. **状态机**：自动判`质量门（收敛）/ 震荡 / 达到上限`，决定继续还是退出

**退出后**：重新输出初始目标 → 你对照验收 → 不通过再跑一轮

---

## 组件

```
delivery-review/
├── .claude-plugin/
│   ├── plugin.json                    # Claude Code plugin 清单 + hooks 声明
│   └── marketplace.json               # 市场源描述
├── hooks/
│   └── update-review-material.ps1     # PostToolUse hook：自动生成审查材料
├── skills/delivery-review/SKILL.md    # 方法论 + 数据模型（自动触发 / 参考）
├── agents/
│   ├── delivery-fixer.md              # 修复工程师（读写）
│   ├── delivery-reviewer.md           # 资深审查者（隔离 + 零命令权限）
│   └── delivery-planner.md            # 方案审查者（按需触发，零命令权限）
├── commands/delivery-review.md        # /delivery-review 确定性入口
├── CLAUDE.md                          # 项目规则书（开发用，不随安装分发）
├── LICENSE                            # MIT
└── README.md                          # 本文件
```

| 组件 | 作用 |
|------|------|
| `plugin.json` | Claude Code 插件清单 + hooks 声明（PostToolUse 自动生成审查材料）；marketplace `/plugin install` 安装时携带，hooks 生效 |
| `hooks/update-review-material.ps1` | PostToolUse hook：每次代码改动后自动刷新 `<仓库根>/.delivery-review/work/material.md`（头部含**机械化风险分级 tier**，正文含改动清单 / diff / 新建文件清单），供审查者零命令权限审查；`.delivery-review` 固定存仓库根目录，不在子目录创建 |
| `SKILL.md` | 自动触发的参考知识（交付流程 / 数据模型 / 风险分级路由 / 溯源链 / 证据等级 / dispute 机制） |
| `delivery-fixer.md` | 修复 agent：按方案改代码、逐条处理 risk、输出意图声明 |
| `delivery-reviewer.md` | 审查 agent：工具层强制零命令权限、Read 审查材料独立审查，按 tier 选深度（trivial 轻量模板 / standard·critical 两段式：第一性原理本质审查 → 症状审查）+ 对抗自查，输出分级 risk（带证据等级 + 与目标的关系）+ **审查轨迹（供溯源）** + 质量分 + 收敛判断 |
| `delivery-planner.md` | 方案审查 agent（按需触发）：方案确认前从产品视角审查（符合意图？验收可验证？更简替代？代价合理？），结论只呈现用户 |
| `delivery-review.md` (command) | 确定性入口：强制走 Step 0-5，不跳步 |

---

## 安装（仅 Claude Code）

在 Claude Code 会话中执行：

```
/plugin install delivery-review@delivery-review-marketplace
```

安装后即可使用 `/delivery-review` 命令。

### 排查：找不到 agent

若运行时提示 `Agent type 'delivery-reviewer' not found` 等错误，是 Claude Code 插件 agent 的命名空间已知 bug 导致（#36002 / #49713，插件 agent 加载被剥离命名空间前缀）。兜底办法：把三个 agent 文件复制到用户级目录（优先级高于插件 agents）：

```bash
cp agents/delivery-fixer.md agents/delivery-reviewer.md agents/delivery-planner.md ~/.claude/agents/
```

注意：副本是快照，插件更新后需重新复制；命令文件已内置「全限定名优先、短名兜底」双写法，多数情况下无需此操作。

### 本地开发调试（无需安装）

直接加载仓库目录（session 级，改完代码即时生效，重启后失效）：

```bash
claude --plugin-dir /path/to/delivery-review-plugin
```

## 卸载

在 Claude Code 会话中执行：

```
/plugin uninstall delivery-review@delivery-review-marketplace
```

---

## 使用

在任何项目目录：

```
/delivery-review 给商品列表加 Redis 缓存，需降级方案
```

跟着提示走完：

1. **上下文确认**（做什么 / 为什么 / 顾虑） → 不清晰会拒绝退出
2. **方案**（大白话 + 工程细节；有多个可行路径时让你选） → 等你确认
3. **方案审查**（大改动时自动触发产品视角检查，四项结论由你拍板）
4. **目标声明**（= 退出标准，每一条可验证）
5. **自动 loop**（修复 ↔ 审查，直到质量门（收敛）/ 震荡 / 上限；**你可随时插话**：澄清不重置，改目标则整体重置）
6. **人工验收**（裁决权必须你行使；可声明 AI 代跑验证并标证据等级）
7. **交付报告**（自动写入运行项目 `docs/`）

---

## Loop 退出条件（状态机，优先级从高到低）

1. **oscillation / dispute 未解** → 强制退出，人工裁决
2. **quality_gate**：无未解决的**本次引入** P0/P1 与既有 P0（`open_risk_ids` 为空）且 `质量分 >= 7` → 正常退出（**首轮满足即当轮退出**，不空转第二轮）
3. **max_rounds**：达到上限（默认 3） → 兜底退出

> 不再设「连续两轮收敛」这道门：实测四个真实运行项目均在首轮或次轮收敛，「重复上报拖死收敛」是臆想痛点，已移除相关计数与 risk 签名去重。
>
> **P2 不阻塞退出但登记进 `defer_risk_ids`**（P1 部分修复降级为 P2 时，旧 P1 经链归并出池，新 P2 进 defer，验收仍逐条可见）；**既有问题不阻塞退出但必须显式呈现**（登记进 `legacy_risk_ids`，验收时逐条列出由你决定是否另开任务，既有 P0 例外必须修）。

---

## 风险分级路由（tier）

审查深度与变更风险对价——1 分钟能改完的活不该走 20 分钟的仪式：

| tier | 判定（hook 机械化，LLM 不参与） | 流程 |
|------|------|------|
| trivial | 文件 ≤2 且 diff ≤30 行且不触碰关键路径（hooks/、CI、auth、migration、security 等） | **快车道**：Step 0/1/2 一次确认 → 主会话直改（不 spawn fixer）→ reviewer 轻量模板一轮定音 → 精简验收；不生成独立报告 |
| standard | 其余 | 完整流程 |
| critical | 触碰关键路径或文件 >5 或 diff >300 行 | 完整流程；以 max_rounds 兜底退出时报告显著标注，人工验收从严 |

**两级判定，不一致从严**：入口由编排者预估 + 用户选择（路由建议）；出口由 hook 按实际改动机械判定写进材料头部——预估 trivial 实际 standard/critical → 自动升级完整流程。分级规则在 hook 代码里，不依赖提示词自觉、不随上下文压缩失忆。

---

## 溯源链（可观测性四层）

子代理上下文销毁后过程即蒸发——隔离买来无污染视角，可观测性作为对价显式补回：

```
交付报告
 ├─ 对话实录      ← 谁说了什么（git-notes，报告中原样渲染）
 ├─ 审查轨迹      ← 凭什么这么说（reviewer 每轮必输出 → 编排者落盘 review.log）
 ├─ 材料快照索引  ← 当时看到的是什么（work/material-rN.md，字节级留存每轮现场）
 └─ git 锚点      ← 基线 HEAD → 终态 diff 随时可复核
```

> 材料每轮被 hook 覆盖，中间状态没有 commit 可回放——快照是中间态的唯一留存。快车道同样留痕（轻量轨迹 + 快照），可观测性不分档。
>
> 心智边界：`.delivery-review/` 下人只看 `state.json`（状态）与 `review.log`（审查历史）；材料、快照、hook 日志都在 `work/` 机器工作区内，人的溯源入口是交付报告。

---

## 数据模型

- 对话记录：`git notes --ref=delivery-review`（审查者留言由编排者代写——审查者零命令权限）
- 审查材料：`<仓库根>/.delivery-review/work/material.md`，由 PostToolUse hook 自动刷新（头部元信息：生成时间 / 基线 HEAD / **风险分级 tier**；正文：改动清单 / 完整 diff / 新建文件清单）
- 审查材料快照：`work/material-rN.md`（每轮审查前由编排者复制，字节级留存）
- 审查日志：`review.log`（**事件流式纯文本，无 markdown**——每条事件一行，ISO 8601 时间戳打头 + 符号标记 ▶/✔/✖，done 行后跟缩进载荷：证据 / 覆盖 / 轨迹原样粘贴，tail/grep 友好）
- 循环状态：`<仓库根>/.delivery-review/state.json`（`.delivery-review` 固定存仓库根目录，不在子目录创建）
  ```json
  {"round":0,"last_score":0,"exit_reason":"","max_rounds":3,"open_risk_ids":[],"legacy_risk_ids":[],"defer_risk_ids":[],"file_mod_counts":{},"started_at":"2026-08-28T15:04:05"}
  ```

```
<ID>|<from>|<type>|<reply_to>|<正文>
```

| type | 谁发 | 含义 |
|------|------|------|
| context | 编排者 | 目标 + 背景 + 方案 |
| review | 修复方 | 改动说明 + 意图声明 + **验证证据（命令与输出）** + 自检 + 未知清单 |
| risk | 审查方 | 问题描述 + 分级 + 证据等级 + 证据出处 + 归属 + 与目标的关系（必填） |
| done | 修复方 | 对某条 risk 的处理结果 |
| score | 审查方 | 本轮质量评分 + 收敛判断 |
| approve | 审查方 | 所有 risk 已解决，建议人工验收 |
| dispute | 修复方 | 对某条 risk 的反驳（附理由） |
| confirm | 审查方 | 收到 dispute 后自我核查（仍坚持） |
| withdraw | 审查方 | 撤回原 risk（误判） |

**风险分级**：P0 阻塞（必须修） / P1 重要（修或说明理由） / P2 建议（可 defer）。

**证据等级**（每条 risk 必带）：已验证（**有实际运行输出为凭**，须引用 fixer / 编排者提供的命令与输出，引用不出即降级）/ 可复现（有复现步骤）/ 代码推断（读代码推断）/ 经验猜测（无依据，不算 risk，只进**存疑清单**）。P0 必须"已验证 / 可复现"；状态机统计排除猜测级。

> 审查者零命令权限跑不了任何东西，所以「已验证」只能来自修复方或编排者的实际运行记录。这条约束是防止审查结论虚高的唯一闸门。

**风险归属**（每条 risk 必带）：`本次引入`（位置在相对基线 HEAD 的累计 diff 改动行内，P0/P1 阻塞退出）/ `既有问题`（位置不在该 diff 内，须给依据；不阻塞退出、不占修复轮次，验收时逐条呈现，**既有 P0 例外必须修，同样进阻塞池**）。

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
