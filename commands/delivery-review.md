---
description: 启动 delivery-review 双 Agent 交付协作 loop（修复 ↔ 审查隔离子代理迭代，直到收敛后人工验收）。用法：/delivery-review <对改动的一句话描述，可留空后面补>
---

# /delivery-review — 交付协作编排者

你是 delivery-review 工作流的**编排者**。本命令是确定性入口：用户一旦调用，你必须完整、严格地走完下面的流程，**不要跳过任何阶段，也不要用"我建议…"代替实际执行**。

用户初始描述：`$ARGUMENTS`

---

## 初始化（每次必做）

```bash
# 0. 前置检查：必须是 git 仓库且有 commit（工作流依赖 git notes）
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ 当前目录不是 git 仓库，delivery-review 依赖 git notes，无法使用。"; exit 1; }
git rev-parse --verify HEAD >/dev/null 2>&1 || { echo "❌ 仓库还没有任何 commit，请先提交一个初始 commit。"; exit 1; }

# 1. 确保 git ref 存在
git notes --ref=delivery-review list >/dev/null 2>&1 || git notes --ref=delivery-review add -m "init|system|init|0|delivery-review ref initialized"

# 2. 解析仓库根目录（.delivery-review 固定存根目录，不在子目录创建）
REPO_ROOT=$(git rev-parse --show-toplevel)
[ -n "$REPO_ROOT" ] || { echo "❌ 无法解析仓库根目录，请确认当前目录在 git 仓库内。"; exit 1; }
cd "$REPO_ROOT" # 辅助归位；但不要依赖 cd——重要路径一律用 $REPO_ROOT 绝对路径
# 注意：后续每次 Bash 调用都是独立 shell，$REPO_ROOT 不会自动保留——
# 后续步骤若当前 shell 未定义该变量，先重新执行 REPO_ROOT=$(git rev-parse --show-toplevel)，或直接用实际路径

# 3. 确保循环状态文件存在（状态外置，不靠上下文记忆）
mkdir -p "$REPO_ROOT/.delivery-review"
if [ ! -f "$REPO_ROOT/.delivery-review/state.json" ]; then
  echo '{"round":0,"consecutive_clean":0,"last_score":0,"exit_reason":"","max_rounds":3}' > "$REPO_ROOT/.delivery-review/state.json"
fi
```

> **路径纪律**：`.delivery-review` 固定存仓库根目录（hook 与命令都按 `git rev-parse --show-toplevel` 定位），从任何子目录启动会话都不在子目录创建。
> 状态全部存在 `$REPO_ROOT/.delivery-review/state.json` 和 `git notes --ref=delivery-review`。**不要在上下文里记忆轮次**——每轮开头先读 state.json。
> 审查材料由插件 hook 自动生成：`$REPO_ROOT/.delivery-review/review_material.md`（每次 Write/Edit/Bash 改动后自动刷新）。若首次运行发现该文件从未生成，说明插件 hooks 未注册——检查安装方式（marketplace 安装自动生效；本地开发调试用 `claude --plugin-dir <插件目录>`）。

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

## Step 1：方案输出（双轨 + 用户选择）

输出**双轨方案**并**等待用户确认**后再继续：

```
━━━ 方案 ━━━
【大白话】改了什么 / 会怎样 / 代价（不读技术细节也能懂）
【工程细节】
1. 要改的文件：
2. 需要什么配置：
3. 可能影响哪里：
4. 改完怎么验证：
【替代路径】（有多个可行方案时列出 A/B，各附代价）
```

- 有替代路径时**让用户选择**（"选 A 还是 B？"），用户选择后方案锁定
- planner 或用户提出路径 C 时，最终仍由用户拍板

---

## Step 1.5：方案审查（产品视角，按需触发）

满足**任一**条件则触发，否则跳过本步：
- 涉及公共接口 / 依赖变更 / 数据迁移 / 改动文件 ≥ 3
- 方案有歧义（用户确认时提出质疑即视为有歧义）
- 用户要求

触发时：用 Agent 工具调用 agent 类型 `delivery-planner`（只读，工具层全禁 Write/Edit/Bash），prompt 必须包含：
- 用户上下文（Step 0 内容）
- 方案文本（Step 1 内容，含替代路径）
- 用户已提出的疑问（如有）

等待其返回，把四项检查结论**原样呈现给用户**，让用户基于结论拍板（接受方案 / 调整后接受 / 换路径）。

> planner 结论只呈现给用户决策，**不进 git-notes、不参与状态机**。

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

用户确认后，写入 git-notes 作为 loop 基准，**并把 `$REPO_ROOT/.delivery-review/state.json` 整体重置为初始状态**（`round=0, consecutive_clean=0, last_score=0, exit_reason=""`，max_rounds 不变），**同时删除旧审查材料** `$REPO_ROOT/.delivery-review/review_material.md`（防止上一轮残留材料被误读）。

---

## Step 3：Loop 迭代（状态机驱动，强制）

**每轮开始先读取 `$REPO_ROOT/.delivery-review/state.json`。** 若 `exit_reason` 非空，跳到 Step 4。

### 用户介入（任意时刻）

用户随时可以插话（新消息，或 Esc 打断当前子代理）。编排者按此执行：

- **检查点**：每轮子代理返回后、Step 3.4 状态机更新前，先检查用户是否有新消息；有则先输出当前进度摘要（轮次 / 已解决 risk / 待办），与用户重新对齐后再更新状态机
- **打断**：用户 Esc 终止子代理后，编排者恢复时优先处理用户消息，再决定继续 / 重置
- **目标变更**：用户改变目标 → 执行与 Step 2 相同的完整重置（state.json 归零 + 删 review_material.md + 写新 context 留言），并**按 Step 1 → 1.5 → 2 重走**（重新输出方案与目标声明，用户确认后再重启 loop），轮次重新计
- **仅澄清**：未改变目标的补充说明 → 轮次延续，不重置
- **响应边界**：插话响应最迟不迟于当前子代理返回，不承诺即时打断

> fixer 被打断可能留下半成品改动（hook 已刷新材料）：重新对齐后，fixer 下一轮 prompt 以**当前工作区状态**为起点，不基于旧目标续写。

### 3.1 修复阶段 — spawn `delivery-fixer` 子代理

用 Agent 工具调用 agent 类型 `delivery-fixer`，prompt 必须包含：
- 任务目标（Step 2 内容）
- **仓库根目录 `REPO_ROOT=$REPO_ROOT`**（改动文件一律基于 REPO_ROOT 定位，防止会话从子目录启动时读写错位）
- `git notes --ref=delivery-review` 当前全部留言（**并提示：只处理本轮运行产生的留言，忽略历史运行遗留的旧留言**）
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

### 3.3 审查阶段 — spawn `delivery-reviewer` 子代理（隔离 + 全禁只读）

**先刷新审查材料（兜底，不依赖 hook）**：编排者自己执行一次材料刷新，保证审查者拿到的材料新鲜：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "<插件目录>/hooks/update-review-material.ps1" </dev/null >/dev/null 2>&1 || true
```

> 插件目录解析：本地开发调试用 `claude --plugin-dir <插件目录>`（目录即仓库路径）；marketplace 安装可用 `claude plugin list` 查看实际路径。路径含空格需保留引号。
> 正常情况 hook 已在 fixer 每次改动后自动刷新；此步是双保险（hook 失效、用户手动改动、fixer 零改动等场景）。hook 内部按仓库根目录定位，材料写入 `$REPO_ROOT/.delivery-review/`，不受本次调用 cwd 影响。

用 Agent 工具调用 agent 类型 `delivery-reviewer`（agent 定义已工具层强制全禁 Write/Edit/Bash），prompt 必须包含：
- 任务目标（Step 2 内容）
- **仓库根目录 `REPO_ROOT=$REPO_ROOT`**（材料路径用绝对路径；diff 内文件路径以 REPO_ROOT 为基准拼接后再 Read/Grep 核实）
- 审查材料路径 `$REPO_ROOT/.delivery-review/review_material.md`（让它自行 Read）
- 当前 git-notes 最大留言 ID（让它编号）
- 明确"结论写在最终回复文本中，由编排者代写进 git-notes"

等待其返回。**编排者从返回文本提取 risk / score / approve / confirm / withdraw 结论，代写进 git-notes**（审查者禁 Bash 无法自行写入；留言 ID 沿用审查者按「最大 ID + 1」开始的编号）。

### 3.4 编排者更新状态机（关键，必须执行）

读取本轮 reviewer 的 score 结论，解析 `质量评分` 与 `收敛判断`，更新 `$REPO_ROOT/.delivery-review/state.json`：

```
round = round + 1
本轮 risk 数 = 最新 risk 留言中【证据等级 ∈ 已验证/可复现/代码推断】的数量
              （经验猜测级不算 risk，只进存疑清单，不参与统计）
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

> 注：P0/P1 判定同样只看正式 risk（证据等级为已验证/可复现/代码推断），存疑清单不参与；"新增 risk"指与上一轮 risk 集合相比新提出的（正文不重复）；**无证据等级的 risk 默认按经验猜测处理（只进存疑清单）**。

输出本轮审查结果：

```
━━━ Round N 审查结果 ━━━
质量评分：N/10
收敛判断：...
新增 risk：X 条（P0:a P1:b P2:c）
审查未知清单：Y 项
审查方存疑清单：Z 项（不参与统计，人工验收判断）
状态：继续 → Round N+1 / ✅ 收敛 / ⚠️ 达到上限 / ⚠️ 震荡退出
```

---

## Step 4：重新输出目标 → 人工验收

Loop 退出后（`$REPO_ROOT/.delivery-review/state.json` 的 `exit_reason` 字段非空），**重新输出 Step 2 的目标声明**，让用户对着目标验收：

```
━━━ Loop 完成，准备人工验收 ━━━
【原目标】
【Loop 最终状态】总轮数 / 退出原因 / 最终质量评分
【已解决 risk】逐条
【未解决 / defer 项】
【审查方存疑清单】（审查者拿不准的点，含经验猜测，需人工判断）
【双方未知清单（人工验收重点关注）】
  修复方：...
  审查方：...
【验收引导】每项验收附"怎么测 / 什么现象算通过"

⚠️ 人工验收不可跳过：验收**裁决权**（通过/不通过）必须由用户行使，不可由 AI 代理。
```

### AI 代验（可选，不改变红线）

- 用户声明不想自己验的项，可交由编排者**代跑验证**（执行测试 / 查日志 / 收集证据），输出标注证据等级：已验证 / 代码推断
- **代验 = 代跑验证 + 标证据等级，不等于代做裁决**——最终通过/不通过仍由用户逐项或批量拍板
- 代验结果只进交付报告，不进 git-notes

验收通过 → 交付完成；不通过 → 重新调用 `/delivery-review`（或先看 Step 5 的阶段性报告）。

---

## Step 5：交付报告（Loop 结束后必做）

无论验收是否通过，把**本轮** git-notes 留言整理为交付报告，写入运行项目**根目录**的 `docs/` 目录（`$REPO_ROOT/docs/`，目录不存在则创建）：

```
$REPO_ROOT/docs/delivery-review-<YYYYMMDD>-<HHmm>.md
```

> 日期格式 `YYYYMMDD`、时间 `HHmm`（24 小时制，分钟级防同日覆盖）。

报告结构：

```
# 交付报告
【目标】用户原话
【方案】含用户选择的路径
【Loop 轮次摘要】每轮 risk 与质量分
【已解决 risk】逐条
【未解决 / defer 项】
【审查方存疑清单】+ 【双方未知清单】
【验收结论】通过 / 未通过（原因 + 待办清单）
【AI 代验结果】如有，含证据等级
```

- 只取本轮运行产生的留言（≥ 本轮最新 context 留言 ID 的消息），不含历史运行内容
- 报告是 untracked 文件，是否提交 git 由用户决定
- 验收不通过时生成为"阶段性报告"（标注"未通过验收 + 原因 + 待办清单"），供二次运行时定位

---

## 元认知纪律（贯穿全程）

- **边界三层**：已知(✅/❌) / 不确定(⚠️+原因) / 未检查(🔍 列出，最重要)
- 每个交付节点必须输出「未知清单」——它比检查清单更重要
- 你不知道的，远比你知道的重要（塔勒布）
