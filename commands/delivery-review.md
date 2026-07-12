---
description: 启动 delivery-review 双 Agent 交付协作 loop（修复 ↔ 审查隔离子代理迭代，直到收敛后人工验收）。用法：/delivery-review <对改动的一句话描述，可留空后面补>
---

# /delivery-review — 交付协作编排者

你是 delivery-review 工作流的**编排者**。本命令是确定性入口：用户一旦调用，你必须完整、严格地走完下面的流程，**不要跳过任何阶段，也不要用"我建议…"代替实际执行**。

用户初始描述：`$ARGUMENTS`

---

## 初始化（每次必做）

```bash
# 1. 确保 git ref 存在
git notes --ref=delivery-review list >/dev/null 2>&1 || git notes --ref=delivery-review add -m "init|system|init|0|delivery-review ref initialized"

# 2. 确保循环状态文件存在（状态外置，不靠上下文记忆）
mkdir -p .delivery-review
if [ ! -f .delivery-review/state.json ]; then
  echo '{"round":0,"consecutive_clean":0,"last_score":0,"exit_reason":"","max_rounds":3}' > .delivery-review/state.json
fi
```

> 状态全部存在 `.delivery-review/state.json` 和 `git notes --ref=delivery-review`。**不要在上下文里记忆轮次**——每轮开头先读 state.json。

---

## Step 0：上下文确认

向用户明确询问（若 `$ARGUMENTS` 已包含清晰描述，可据此整理并直接呈现确认）：

```
━━━ 上下文确认 ━━━
1. 要做什么改动？
2. 为什么要做这个改动？（背景/动机）
3. （可选）有什么顾虑或已知风险？
```

- 用户回复**不清晰 / 不确定** → 输出 `❌ 目标不清晰，退出 delivery-review。请想清楚后重新调用 /delivery-review。` 并停止。
- 用户回复**清晰** → 写入 git-notes：
  ```
  <ID>|system|context|0|
  目标：[用户说的内容]
  背景：[用户说的原因]
  ```

---

## Step 1：方案输出

输出方案并**等待用户确认**后再继续：

```
━━━ 方案 ━━━
1. 要改的文件：
2. 需要什么配置：
3. 可能影响哪里：
4. 改完怎么验证：
```

---

## Step 2：目标声明（验收标准 == loop 退出标准）

```
━━━ 目标声明（验收标准 / Loop 退出标准）━━━
本次交付目标：
1. [具体行为/数据/指标]
2. ...

Loop 退出标准：
- 所有目标达成
- 审查方确认无新增风险
- 连续两轮收敛
- 质量分 ≥ 7

如果标准不准确，请指出。
```

用户确认后，写入 git-notes 作为 loop 基准，并把 `state.json` 的 `round` 归零。

---

## Step 3：Loop 迭代（状态机驱动，强制）

**每轮开始先读取 `.delivery-review/state.json`。** 若 `exit_reason` 非空，跳到 Step 4。

### 3.1 修复阶段 — spawn `delivery-fixer` 子代理

用 Task 工具调用 agent 类型 `delivery-fixer`，prompt 必须包含：
- 任务目标（Step 2 内容）
- `git notes --ref=delivery-review` 当前全部留言
- 本轮角色：首轮=实现改动；后续轮=逐条处理 risk

等待其返回，确认它已把 `review` / `done` / `dispute` 留言写入 git-notes。

### 3.2 实时进度

```
━━━ Round N ━━━
修复方已完成：改动 M 个文件 / 处理 K 条 risk
意图：一句话
未知清单：X 项
→ 进入审查...
```

### 3.3 审查阶段 — spawn `delivery-reviewer` 子代理（隔离 + 只读）

用 Task 工具调用 agent 类型 `delivery-reviewer`（已在 agent 定义中层级强制只读、隔离），prompt 必须包含：
- 任务目标（Step 2 内容）
- 修复方的 `review` 留言全文（意图 + 自检 + 未知清单）

等待其返回，确认它已把 `risk` / `score` / `approve` 留言写入 git-notes。

### 3.4 编排者更新状态机（关键，必须执行）

读取本轮 reviewer 的 score 留言，解析 `质量评分` 与 `收敛判断`，更新 `.delivery-review/state.json`：

```
round = round + 1
本轮 risk 数 / 新增 risk 数 从最新 risk 留言统计
if 本轮 risk == 0 或 新增 risk == 0:
    consecutive_clean += 1
else:
    consecutive_clean = 0

退出判定（按优先级）：
1. 同一文件被反复修改 ≥ 3 次，或 dispute 未解决 → exit_reason="oscillation"/"dispute"，强制退出
2. consecutive_clean >= 2 → exit_reason="converged"
3. last_score >= 7 且无 P0/P1 → exit_reason="quality_gate"
4. round >= max_rounds(3) → exit_reason="max_rounds"
否则：继续下一轮（回到 3.1）
```

输出本轮审查结果：
```
━━━ Round N 审查结果 ━━━
质量评分：N/10
收敛判断：...
新增 risk：X 条（P0:a P1:b P2:c）
审查未知清单：Y 项
状态：继续 → Round N+1 / ✅ 收敛 / ⚠️ 达到上限 / ⚠️ 震荡退出
```

---

## Step 4：重新输出目标 → 人工验收

Loop 退出后（`state.json.exit_reason` 非空），**重新输出 Step 2 的目标声明**，让用户对着目标验收：

```
━━━ Loop 完成，准备人工验收 ━━━
【原目标】
【Loop 最终状态】总轮数 / 退出原因 / 最终质量评分
【已解决 risk】逐条
【未解决 / defer 项】
【双方未知清单（人工验收重点关注）】
  修复方：...
  审查方：...
【建议验收重点】具体操作/场景

⚠️ 人工验收不可跳过、不可由 AI 代理。
```

验收通过 → 交付完成；不通过 → 重新调用 `/delivery-review`。

---

## 元认知纪律（贯穿全程）

- **边界三层**：已知(✅/❌) / 不确定(⚠️+原因) / 未检查(🔍 列出，最重要)
- 每个交付节点必须输出「未知清单」——它比检查清单更重要
- 你不知道的，远比你知道的重要（塔勒布）
