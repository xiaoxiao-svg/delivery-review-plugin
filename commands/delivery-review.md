---
description: 启动 delivery-review 双 Agent 交付协作 loop（修复 ↔ 审查隔离子代理迭代，直到收敛后人工验收）。按风险分级路由：trivial 快车道（一次确认+主会话直改+轻量审查）、standard/critical 完整流程。用法：/delivery-review <对改动的一句话描述，可留空后面补>
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
  echo "{\"round\":0,\"last_score\":0,\"exit_reason\":\"\",\"max_rounds\":3,\"open_risk_ids\":[],\"legacy_risk_ids\":[],\"defer_risk_ids\":[],\"started_at\":\"$(date +%Y-%m-%dT%H:%M:%S)\"}" > "$REPO_ROOT/.delivery-review/state.json"
fi

# 4. 记录本轮基线（1.8.0 起）：把当前工作区快照成 git tree 对象。
#    hook 之后每轮用「当前 tree − 本轮基线 tree」算本轮增量，
#    这样 tier 与 no_progress 判定都只看本轮，不被历史累计污染。
#    排除 .delivery-review：否则 hook 每次重写 material 都会把自己算成改动。
mkdir -p "$REPO_ROOT/.delivery-review/work"
BASELINE_FILE="$REPO_ROOT/.delivery-review/work/round-baseline.json"
# 先删旧基线：写失败必须表现为「缺失」（hook 回退 standard，人眼可见），
# 不能让上一轮基线残留、被 hook 当成「本轮基线」静默沿用——那样 delta 退化成累计，
# tier 虚高、same_as_prev 恒为假，no_progress / stalled 双双变成死规则
rm -f "$BASELINE_FILE"
TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" read-tree HEAD 2>/dev/null
GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" add -A -- ':(exclude).delivery-review' 2>/dev/null
GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" add -u -- ':(exclude).delivery-review' 2>/dev/null
TREE=$(GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" write-tree 2>/dev/null); rm -f "$TMPIDX"
if [ -n "$TREE" ]; then
  ROUND_NOW=$(grep -o '"round"[[:space:]]*:[[:space:]]*[0-9]*' "$REPO_ROOT/.delivery-review/state.json" 2>/dev/null | grep -o '[0-9]*$')
  printf '{"ts":"%s","head":"%s","round":"%s","tree":"%s"}\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" "${ROUND_NOW:-0}" "$TREE" \
    > "$BASELINE_FILE"
else
  echo "⚠️ 本轮基线创建失败（write-tree 无输出）：hook 将回退 standard；检查 REPO_ROOT 与 git 状态"
fi
```

> **路径纪律**：`.delivery-review` 固定存仓库根目录（hook 与命令都按 `git rev-parse --show-toplevel` 定位），从任何子目录启动会话都不在子目录创建。
> 状态全部存在 `$REPO_ROOT/.delivery-review/state.json` 和 `git notes --ref=delivery-review`。**不要在上下文里记忆轮次**——每轮开头先读 state.json。
> 审查材料由插件 hook 自动生成：`$REPO_ROOT/.delivery-review/work/material.md`（机器消费，人不需要看——人的溯源入口是交付报告与 review.log）。若首次运行发现该文件从未生成，说明插件 hooks 未注册——检查安装方式（marketplace 安装自动生效；本地开发调试用 `claude --plugin-dir <插件目录>`）。
>
> **目录分层（心智边界）**：`.delivery-review/` 下人只需要认识两个文件——`state.json`（状态）与 `review.log`（审查历史，纯文本）；`work/` 是机器工作区（材料、快照、hook 日志），编排者与审查者用，人不打开。

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
4. 改完怎么验证：（**必须是可执行的命令或明确的用户可操作步骤**——这条会被真的执行：能跑成命令的由编排者代跑并存档，跑不了的要写明为什么。写成「跑一下测试」这种无法落地的描述，等于没写）
【预估档位】trivial / standard / critical（按预估改动文件数、diff 行数、是否触碰关键路径 hooks·CI·auth·migration 等给出，供选择流程档位）
【替代路径】（有多个可行方案时列出 A/B，各附代价）
```

- 有替代路径时**让用户选择**（"选 A 还是 B？"），用户选择后方案锁定
- planner 或用户提出路径 C 时，最终仍由用户拍板

### 流程档位（用户可选，出口由 hook 机械校验兜底）

| 档位 | 流程 |
|------|------|
| **trivial 快车道**（预估 ≤2 文件、≤30 行、不碰关键路径） | Step 0/1/2 合并为一次确认；**不 spawn fixer，主会话直接改**；reviewer 走轻量模板一轮定音；精简验收；不生成独立交付报告 |
| **standard / critical**（默认） | 完整流程（下文 Step 2 → Step 5 原样） |

- 用户未指定档位且预估为 trivial 时，主动询问一句："改动很小，走快车道（预计 2-3 分钟）还是完整流程？"
- **预估档位只是路由建议**：进入审查阶段后编排者必须核对材料头部的 hook 机械分级——预估 trivial 但材料标注 standard/critical → **自动升级回完整流程**（按 Step 2 重置状态重走，轮次重新计）。宁可从严，不放水

---

## Step 1.5：方案审查（产品视角，按需触发）

满足**任一**条件则触发，否则跳过本步：
- 涉及公共接口 / 依赖变更 / 数据迁移 / 改动文件 ≥ 3
- 方案有歧义（用户确认时提出质疑即视为有歧义）
- 用户要求

触发时：用 Agent 工具调用 agent 类型 `delivery-review:delivery-planner`（若报找不到 agent，改用短名 `delivery-planner`），prompt 必须包含：
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
- 无未解决的 P0/P1 risk（本次引入的 P0/P1 与既有 P0 都算阻塞项；既有非 P0 问题不进此门，见 Step 4）
- 质量分 ≥ 7
- 未触发卡死（stalled）/ 争议

如果标准不准确，请指出。
```

用户确认后，写入 git-notes 作为 loop 基准，**并把 `$REPO_ROOT/.delivery-review/state.json` 整体重置为初始状态**（`round=0, last_score=0, exit_reason="", open_risk_ids=[], legacy_risk_ids=[], defer_risk_ids=[]`，max_rounds 不变，`started_at` 刷新为当前时间），**同时删除旧工作区** `$REPO_ROOT/.delivery-review/work/`（防止上一轮残留材料与快照被误读；`review.log` 保留追加，天然按轮次分隔）。

> **快车道合并确认**：trivial 档下，Step 0 的上下文、本 Step 的目标声明与 Step 1 的方案**一次性呈现，用户一条回复即全部确认**（例如"可以，就这么改"）。确认后同样写 context 留言、重置 state、删旧材料。确认次数可以合并，**验收环节不可合并**（Step 4 红线不变）。

---

## Step 3：Loop 迭代（状态机驱动，强制）

**每轮开始先读取 `$REPO_ROOT/.delivery-review/state.json`。** 若 `exit_reason` 非空，跳到 Step 4。

### 3.0 tier 机械校验（每轮审查前必做，快车道兜底）

改动发生后，编排者 Read `$REPO_ROOT/.delivery-review/work/material.md` 头部，取 hook 写入的「风险分级」字段：

- 材料标注 **standard / critical**，而本轮走的是快车道 → **升级完整流程**：按 Step 2 重置（state 归零 + 删 work/ + 新 context 留言），spawn fixer 重走，轮次重新计。向用户一句话说明升级原因
- 材料标注 **trivial**，本轮走完整流程 → 不降级，按原档位继续（宁严勿松）
- 材料不存在 / 无分级字段 → 视为 standard，按完整流程走，并在交付报告「未知清单」记录「hook 分级缺失」

### 快车道分支（仅 trivial，改动与审查一轮完成）

用户已确认快车道且 3.0 校验通过时：

1. **主会话直接实施改动**（不 spawn `delivery-fixer`——改动小到主会话上下文已覆盖全部背景，冷启动子代理是纯开销）。改动一律用 Write/Edit 工具（让 hook 能捕获），完成后等 hook 刷新材料
   - **动手前先拍基线**：快车道不经过 3.1，基线创建必须复制到这一步——在主会话第一次 Write/Edit **之前**执行 3.1 的基线命令。改完才拍，基线含本轮改动，delta 恒为空，no_progress 立即误判
2. **轻量审查**：刷新材料（同 3.3 的兜底刷新）→ 执行快照复制 + 向 review.log 追加 begin 事件（同 3.3）→ spawn `delivery-reviewer`，prompt 标注 `tier=trivial` 并**把材料全文内嵌进 prompt**（≤30 行 diff，内嵌省掉子代理一次文件读取），**同时内嵌本轮验证证据**（主会话直改时由编排者自己跑一遍方案里的验证命令，把命令与输出贴进 prompt；没跑就明写「未执行及原因」），**同时内嵌本轮 refresh 行原文**（快车道的可观测性要求与完整流程一致），要求走轻量模板一轮定音
3. 审查返回后：解析结论（risk / score / approve / confirm / withdraw）代写 git-notes → **向 review.log 追加 done 事件**（格式见 3.3 末尾）→ 更新 state.json（同 3.4；快车道一轮 approve 通常经 quality_gate 即当轮退出）
4. 审查报出 P0/P1 → **快车道即止**：按 Step 2 重置，转完整流程修复（小改动出了大问题，说明分级估错，回到重流程）
5. 跳到 Step 4（精简验收）与 Step 5（快车道不生成独立报告文件，review.log 条目 + git-notes 即交付记录）

### 用户介入（任意时刻）

用户随时可以插话（新消息，或 Esc 打断当前子代理）。编排者按此执行：

- **检查点**：每轮子代理返回后、Step 3.4 状态机更新前，先检查用户是否有新消息；有则先输出当前进度摘要（轮次 / 已解决 risk / 待办），与用户重新对齐后再更新状态机
- **打断**：用户 Esc 终止子代理后，编排者恢复时优先处理用户消息，再决定继续 / 重置
- **目标变更**：用户改变目标 → 执行与 Step 2 相同的完整重置（state.json 归零 + 删 work/ + 写新 context 留言），并**按 Step 1 → 1.5 → 2 重走**（重新输出方案与目标声明，用户确认后再重启 loop），轮次重新计
- **仅澄清**：未改变目标的补充说明 → 轮次延续，不重置
- **响应边界**：插话响应最迟不迟于当前子代理返回，不承诺即时打断

> fixer 被打断可能留下半成品改动（hook 已刷新材料）：重新对齐后，fixer 下一轮 prompt 以**当前工作区状态**为起点，不基于旧目标续写。

### 3.1 修复阶段 — spawn `delivery-fixer` 子代理

**spawn 前先拍本轮基线（1.8.0 起，缺它则 tier 与 no_progress 全部失效）**：基线是「本轮改动的起点」，必须在 fixer 动手**之前**记录。

```bash
mkdir -p "$REPO_ROOT/.delivery-review/work"
BASELINE_FILE="$REPO_ROOT/.delivery-review/work/round-baseline.json"
# 先删旧基线：写失败必须表现为「缺失」（hook 回退 standard，人眼可见），
# 不能让上一轮基线残留、被 hook 当成「本轮基线」静默沿用——那样 delta 退化成累计，
# tier 虚高、same_as_prev 恒为假，no_progress / stalled 双双变成死规则
rm -f "$BASELINE_FILE"
TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" read-tree HEAD 2>/dev/null
GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" add -A -- ':(exclude).delivery-review' 2>/dev/null
GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" add -u -- ':(exclude).delivery-review' 2>/dev/null
TREE=$(GIT_INDEX_FILE="$TMPIDX" git -C "$REPO_ROOT" write-tree 2>/dev/null); rm -f "$TMPIDX"
if [ -n "$TREE" ]; then
  ROUND_NOW=$(grep -o '"round"[[:space:]]*:[[:space:]]*[0-9]*' "$REPO_ROOT/.delivery-review/state.json" 2>/dev/null | grep -o '[0-9]*$')
  printf '{"ts":"%s","head":"%s","round":"%s","tree":"%s"}\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" "${ROUND_NOW:-0}" "$TREE" \
    > "$BASELINE_FILE"
else
  echo "⚠️ 本轮基线创建失败（write-tree 无输出）：hook 将回退 standard；检查 REPO_ROOT 与 git 状态"
fi
```

> **顺序错了整套机制失效**：基线若在 fixer 改完之后才拍，基线已包含本轮改动，`round-delta.json` 会读成「本轮无改动」，`no_progress` 立刻误判为 stall/收口。每轮 spawn fixer 前必须重新拍一次，不要复用上一轮的基线。

用 Agent 工具调用 agent 类型 `delivery-review:delivery-fixer`（若报找不到 agent，改用短名 `delivery-fixer`），prompt 必须包含：
- 任务目标（Step 2 内容）
- **仓库根目录 `REPO_ROOT=$REPO_ROOT`**（改动文件一律基于 REPO_ROOT 定位，防止会话从子目录启动时读写错位）
- **编排者代跑的验证结果**（如有）：命令 + 通过/失败 + 关键输出行。**失败项是本轮必修输入**，fixer 必须先修到通过或说明为何该失败与本次改动无关
- git-notes 留言（**编排者预过滤后传入，不让 fixer 自己翻**）：本轮 context 留言 + 最新一轮全部 risk / done / dispute / confirm / withdraw 留言，**按 ID 升序排列**（fixer 以最后一条的 ID 为最大编号基准）+ 在场留言总数一句话（如「共 47 条，以上为与本轮相关的全部」）。历史轮已解决的留言不传——子代理上下文按 token 计价，无关注释是重复读取税
  - **只传「本次引入」的 risk + 既有 P0**：标「归属=既有问题」的非 P0 条目**不传给 fixer**，它们已进 `legacy_risk_ids` 登记，不占修复轮次。P2 一并传入供其判断是否顺手处理，不强制（fixer 对 P2 可回「不处理 + 理由」，不必凑 done / dispute）
- 本轮角色：首轮=实现改动；后续轮=逐条处理 risk
- **要求 fixer 的 review / done 留言必须含【验证证据】**：实际执行了什么命令、输出关键行；跑不了就写「未运行 + 原因」。没有验证证据的「改好了」不被采信
- **要求同类排查**：处理每条 risk 时扫描同类位置（同根因 / 同模式），留言写清「扫描范围 / 另有 N 处 / 已修或未修原因」

等待其返回，确认它已把 `review` / `done` / `dispute` 留言写入 git-notes。

### 3.2 实时进度

```
━━━ Round N ━━━
修复方已完成：改动 M 个文件 / 处理 K 条 risk
未复查：N 条（R…）（上一轮池内条目中，本轮审查者未给结论的；无则写「无」）
意图：一句话
未知清单：X 项
→ 进入审查...
```

### 3.3 审查阶段 — spawn `delivery-reviewer` 子代理（隔离 + 全禁只读）

**先刷新审查材料（兜底，不依赖 hook）并记录 refresh 行**：编排者自己执行一次材料刷新，**必须捕获退出码与刷新后的材料 mtime**，写成一行 refresh 记录：

```bash
sha_of() { if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -c1-16; else shasum -a 1 | cut -c1-16; fi; }
MAT="$REPO_ROOT/.delivery-review/work/material.md"
BEFORE=0; [ -f "$MAT" ] && BEFORE=$(date -r "$MAT" +%s 2>/dev/null || echo 0)
powershell -NoProfile -ExecutionPolicy Bypass -File "<插件目录>/hooks/update-review-material.ps1" </dev/null >/dev/null 2>&1
HOOK_EXIT=$?
AFTER=0; [ -f "$MAT" ] && AFTER=$(date -r "$MAT" +%s 2>/dev/null || echo 0)
# refreshed=yes 才算真的刷到：只看「材料存在」或「hook 退出码」都会恒真——
# hook 的纪律是任何情况 exit 0（自吞异常），而材料文件本来就一直在。
if [ "$AFTER" -gt "$BEFORE" ]; then REFRESHED=yes; else REFRESHED=no; fi
DIFF_SHA=$(git -C "$REPO_ROOT" diff HEAD | sha_of)
NOW=$(date +%Y-%m-%dT%H:%M:%S%z)
echo "[$NOW] refresh: ts=$NOW diff_sha=$DIFF_SHA refreshed=$REFRESHED material_mtime=$(date -r "$MAT" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || echo missing) hook_exit=$HOOK_EXIT" >> "$REPO_ROOT/.delivery-review/review.log"
```

> **判据是 `refreshed`，不是 `material_ts` 或 `hook_exit`**：
> - `hook_exit` 恒为 0 —— hook 的纪律就是「任何情况 exit 0，异常只写 hook.log」，拿它当失败信号必然永远成功
> - 「材料 mtime 早于本行时间戳」也恒真 —— 本行是在刷新**之后**写的，mtime 构造上就不可能更晚
> - 唯一有区分力的是**调用前后 mtime 是否变化**。`refreshed=no` 且本轮 `round-delta.same_as_prev=false`（有改动）→ 才是真陈旧，需在 Round 结果里报给用户
> 插件目录解析：本地开发调试用 `claude --plugin-dir <插件目录>`（目录即仓库路径）；marketplace 安装可用 `claude plugin list` 查看实际路径。路径含空格需保留引号。
> 正常情况 hook 已在 fixer 每次改动后自动刷新；此步是双保险（hook 失效、用户手动改动、fixer 零改动等场景）。hook 内部按仓库根目录定位，材料写入 `$REPO_ROOT/.delivery-review/work/material.md`，不受本次调用 cwd 影响。

**刷新后立即做材料快照（溯源锚点，不可省）**：本轮审查看到的是哪份材料，必须字节级留档——材料每轮会被 hook 覆盖，不快照则中间状态永久丢失：

```bash
cp "$REPO_ROOT/.delivery-review/work/material.md" "$REPO_ROOT/.delivery-review/work/material-r<本轮轮号>.md"
```

> 快照在 `work/` 机器工作区内，人不直接看；交付报告「材料快照索引」列出各轮快照名 + HEAD + 时间，需要复原现场时才打开。

**快照后立即向 review.log 追加 begin 事件**（审查耗时从这里起算）：

```bash
echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ▶ ROUND <N> begin | tier=<材料头部tier> | snapshot=work/material-r<N>.md" >> "$REPO_ROOT/.delivery-review/review.log"
```

Read 材料头部取「风险分级」字段（完成 3.0 校验）。用 Agent 工具调用 agent 类型 `delivery-review:delivery-reviewer`（若报找不到 agent，改用短名 `delivery-reviewer`；agent 定义已工具层强制全禁 Write/Edit/Bash），prompt 必须包含：
- 任务目标（Step 2 内容）
- **仓库根目录 `REPO_ROOT=$REPO_ROOT`**（材料路径用绝对路径；diff 内文件路径以 REPO_ROOT 为基准拼接后再 Read/Grep 核实）
- 审查材料路径 `$REPO_ROOT/.delivery-review/work/material.md`（让它自行 Read）
- **本轮风险分级**：材料头部的 tier 值（critical / standard / trivial），审查者按此深度审查
- **上轮未解决 risk 清单**：上一轮 state.json 的 `open_risk_ids` 对应的 risk 全文（含 ID）。明确要求审查者**逐条复查并给出 ✅已修复（附证据）/ ❌未修复（续报）/ ⚠️无法确认**——状态机只认「✅已修复 + 证据」才出池；漏写等于留在池中继续阻塞
- **本轮验证证据**：两个来源都要给，缺一则注明——① fixer 在 review / done 留言里贴的命令与输出原文（没有就写「fixer 未提供」）；② 编排者自己代跑的结果（`verify:` 行的原文，没跑写「未代跑 + 原因」）。审查者判定某问题为「已验证」时**必须引用这两段证据之一**；引用不出则最高只能判「可复现」或「代码推断」
- **既有问题清单**：上一轮结束时 state.json 的 `legacy_risk_ids` 对应的 risk 原文。要求审查者对已登记的老问题**不再重复上报**——若认为某条仍需关注，只在存疑清单里提一句，不占 risk 名额
- **本轮 refresh 行原文**：从 review.log 取刚写的那行（`diff_sha` / `refreshed` / `material_mtime` / `hook_exit`），原样贴进 prompt。审查者据此判断材料是否陈旧——判据是 `refreshed=no` **且** `delta.view=per_round` **且** `delta.same_as_prev=false`；`view=cumulative` 时无从判断，按「无法判断」处理，不得当成陈旧
- **本轮 round-delta**：`work/round-delta.json` 的原文（含 tier / files / file_count / diff_lines / same_as_prev），让审查者知道 tier 依据的是本轮增量而非累计
- 当前 git-notes 最大留言 ID（让它编号）
- 明确"结论与**审查轨迹**写在最终回复文本中，由编排者代写进 git-notes / review.log"

**验证证据的兜底采集（编排者自己做，不能只依赖 fixer 自述）**：Step 1 方案里用户已确认的验证方式若可执行为命令，编排者代跑一次，把命令 + 输出摘要（成功/失败 + 关键行）写进 review.log 的 `verify:` 行，并一并贴进 reviewer prompt：

```bash
echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] verify: <命令> -> <通过|失败> | <输出关键行>" >> "$REPO_ROOT/.delivery-review/review.log"
```

> **验证失败不是日志噪音**：命令失败说明改动很可能没生效，必须在 Round 结果里显式报给用户，并作为下一轮修复的输入；不得只在 review.log 留一行就继续推进。方案里的验证方式若是自然语言（如「跑一下测试」）而无法直接执行为命令，编排者不要自行发明命令，标注「未能代跑」并交由 fixer 自证。

等待其返回。**编排者从返回文本提取 risk / score / approve / confirm / withdraw 结论，代写进 git-notes**（审查者禁 Bash 无法自行写入；留言 ID 沿用审查者按「最大 ID + 1」开始的编号）。

**返回后立即向 review.log 追加 done 事件（溯源核心，与代写 git-notes 同为必做）**。review.log 是**事件流式纯文本日志**——每条事件一行，ISO 8601 时间戳打头 + 符号标记（▶ 开始 / ✔ 通过 / ✖ 有 risk），无 markdown，可排序可 grep。done 事件行后跟缩进的载荷行（属同一时间点，不重复时间戳）：

```
[YYYY-MM-DDThh:mm:ss+zzzz] ✔|✖ ROUND <N> done | score=<N>/10 | risk=<X> (P0:<a> P1:<b> P2:<c>) | verdict=<approve|continue>
    evidence: <审查者实际 Read/Grep 过的 文件:行号，逐条>
    coverage: essence=<ok|miss> bug=<ok|miss> edge=<ok|miss> regress=<ok|miss> test=<ok|miss(原因)> refactor=<ok|miss> deviate=<ok|miss>
    tier-match: <yes|no(说明)>
    track: <审查者轨迹原文逐行原样粘贴>
---
```

### 3.4 编排者更新状态机（关键，必须执行）

读取本轮 reviewer 的 score 结论，解析 `质量评分` 与 risk 列表，更新 `$REPO_ROOT/.delivery-review/state.json`。**本步必须输出标准化的 state update block，不可省略任何字段**：

```
round = round + 1

# 1. 分拣本轮 risk（只统计正式 risk：证据等级 ∈ 已验证/可复现/代码推断；经验猜测不进入）
本次引入 risk = 本轮 risk 中「归属=本次引入」的（未标归属的默认按本次引入处理，从严）
既有问题     = 本轮 risk 中「归属=既有问题」的（必须附证据：该位置不在相对基线 HEAD 的 diff 改动行内）

# 1b. 基线时效校验（防止「漏拍基线」静默沿用上轮）
#    HEAD 校验只能挡「中途 commit」；fixer 禁止 commit 时 HEAD 全程不变，
#    漏拍 3.1 会让 delta 变成跨轮累计而无人察觉。用 delta 的基线线索兜底：
#    若 delta.baseline_ok=false → 本轮增量不可信，tier 与 same_as_prev 都不采信
#    （3.4 第 5 步已要求「baseline_ok=false 按有改动处理」，此处再确认一次）

# 2. 未解决池维护（open_risk_ids，跨轮累积）
#    池内每条只能通过下面三种明确出口离开，其余一律留在池中
new_open = 本次引入 risk 中 P0/P1 的 ID
        ∪ 既有问题中 P0 的 ID（既有 P0 同样必须修，一并阻塞退出）

# 出口 A：已修复（reviewer 在【上轮未解决 risk 复查】段写 ✅ 且带证据）
已确认修复 = 上一轮 open_risk_ids 中，本轮 reviewer 明确判定「已修复」的 ID
             判定须带证据，且证据必须锚定到相对基线 HEAD 的 diff 改动行
             （原问题行或修复行均可；证据指向未改动的行 = 未修复）

# 出口 B：误报撤回（reviewer 输出 withdraw，或在复查段写「⚠️误报/撤回」）
已撤回 = 上一轮 open_risk_ids 中，本轮被 withdraw 或复查段判定为误报的 ID
         出口须在 review.log 记一行 `withdrawn: R<ID> | 理由`

# 出口 C：链归并（续报时新 risk 的 reply_to 指向池内旧 ID，**含降级续报**）
若**本轮任一 risk（P0/P1/P2 都算）**的 reply_to ∈ open_risk_ids：
    不新增独立条目，按链归并为 **最新 ID**，旧 ID 标记 superseded 后出池
    降级续报（如 P1 部分修复后剩 P2）：旧 ID 出池，新 P2 按常规进 defer_risk_ids
    复查时对链上任一 ID 判 ✅ 已修复 → 整链一并出池
    链归并同样在 review.log 记一行 `superseded: R<旧>(<旧级别>) -> R<新>(<新级别>)`（带级别，验收面据此看出是降级还是同级）
   ⚠️ 谓词必须覆盖 P2：只看 new_open 会漏掉「P1 修掉主因、剩细节降为 P2」这条最常见的结局，
      该旧 ID 将无处可去，卡到 oscillation/max_rounds，把机制缺陷伪装成「未收敛」

open_risk_ids = (open_risk_ids - 已确认修复 - 已撤回 - 被归并旧ID) ∪ new_open
   ❌ 禁止用「本轮未再被上报」推定已修复——reviewer 漏报会让真问题静默出池
   ⚠️ 上轮 open risk 本轮既未判定「已修复」、也未 withdraw、也未续报的，视为「未复查」，
      **留在池中**，并在 3.2 进度里标注「未复查 N 条」，下一轮 prompt 强制点名要求复查

# 2b. 编排者抽检（两条通道都要查，防止「省事全标」与「降级逃避」）
① ✅ 已修复证据抽检：抽检数量随 ✅ 条数伸缩——≤2 条全查，>2 条至少查一半
   Read 证据指向的行，确认改动确实存在且相关
   不合格 → 该 ID 退回池中，review.log 记 `verify-reject: R<ID> | 不合格原因`
② 既有问题归属抽检：本轮新登记进 legacy_risk_ids 的条目至少查 1 条
   Read 该行，确认它确实不在相对基线 diff 的改动范围内
   不合格 → 改判为「本次引入」重新入池，review.log 记 `misfiled: R<ID> | 实际属于本次引入`
本轮无可抽检项 → 跳过并在 3.2 标注「本轮无可抽检项」

# 3. 既有问题登记（legacy_risk_ids，跨轮累积，不参与退出判定；既有 P0 已进 open_risk_ids）
legacy_risk_ids = legacy_risk_ids ∪ (既有问题ID - 既有P0的ID)

# 4. P2 延后清单（defer_risk_ids，跨轮累积，持久化以替代记忆；同样要有出池规则）
defer_risk_ids = (defer_risk_ids - 已修复的deferID) ∪ 本轮 P2 的 ID
   「已修复的deferID」= reviewer 明确判 ✅ 已修复、或被链归并到已修 ID 的 defer 条目
   出池同样记一行 `defer-closed: R<ID>`——只入不出会让已修的 P2 永久挂在验收清单上

# 5. 本轮改动（读 work/round-delta.json，不由 LLM 数文件）
delta = Read work/round-delta.json
   delta.files / delta.file_count / delta.diff_lines / delta.same_as_prev / delta.baseline_ok
   ❌ 禁止从 material.md 自由文本里数文件或行数——那是 LLM 算术，正是 1.8.0 要消灭的东西
   delta 缺失或 baseline_ok=false → 本轮增量不可知，按「有改动」处理（不判 no_progress）

# 6. 质量分
last_score = 本轮 score

# 7. 退出判定（按优先级）
1. dispute 未解决 → exit_reason="dispute"，强制退出
2. delta.same_as_prev 为真（相邻两轮工作区内容全等，本轮没改进任何东西）：
     open_risk_ids 为空 且 last_score >= 7 → exit_reason="no_progress"
        （注意：这是 quality_gate 的真子集，行为无差异，仅用于报表区分「收敛时本轮零改动」）
     否则                                   → exit_reason="stalled"（没进展但活没干完，交人工裁决）
3. open_risk_ids 为空 且 last_score >= 7 → exit_reason="quality_gate"
4. round >= max_rounds(3) → exit_reason="max_rounds"
否则：继续下一轮（回到 3.1）

# 已移除：file_mod_counts >= 3 判震荡（1.8.0）
#   原因：阈值 3 与 max_rounds 3 相等，正常 loop 跑满必然触发；且累计 diff 计数让
#   「没改也 +1」。
#   覆盖面说明（勿夸大）：stalled/no_progress 只抓「工作区零改动」这一种卡死；
#   「改了但风险不减少」（反复无效改动）仍由 max_rounds 兜底，没有专门判据。
# 已移除：risk reopen ≥2 次、A→B→A 回摆两条判据（1.8.0）
#   原因：max_rounds ≤ 3 下结构上不可达（reopen 第 2 次最早第 4 轮；回摆最早第 3 轮
#   且与 max_rounds 同时到点，只换标签不产生行为差异）。若未来调大 max_rounds，
#   需重新评估是否恢复——恢复前先验算可达性。

# 写回 state.json（必须包含全部字段）
{
  "round": round,
  "last_score": last_score,
  "exit_reason": exit_reason,
  "max_rounds": max_rounds,
  "open_risk_ids": [ ... ],        // 全量，未解决的阻塞项（本次引入 P0/P1 + 既有 P0）
  "legacy_risk_ids": [ ... ],      // 全量，已登记的既有问题（不含既有 P0）
  "defer_risk_ids": [ ... ],       // 全量，延后的 P2
  "started_at": started_at         // 原值，不刷新
}
```

> **为什么不再做「新增 risk」计数**：实测四个项目均未出现重复上报拖死收敛，重复计数属臆想需求；收敛判定只看「阻塞项是否清零 + 分数是否达标」，机制简单且不依赖 LLM 给 risk 打签名。既有问题单独登记，不影响退出，但**必须在 Step 4 验收中显式列出，不许静默吞掉**。
> **出池只能靠正向确认**：`open_risk_ids` 的每一条，都必须有 reviewer 明确的「已修复」判定才能离开。让审查者比对「上轮清单 vs 本轮代码」是有意为之——它拿到的是累计 diff，看得见坏修复，但看不见自己上轮提过什么，所以必须把上轮清单喂给它。
> **状态机执行纪律**：每轮必须输出完整的 state update block，`open_risk_ids` / `legacy_risk_ids` / `defer_risk_ids` 三个字段全量写回，不可依赖 LLM 记忆或心算。
> **P2 不阻塞退出**：P2 只进 `defer_risk_ids`，一轮全是 P2 时 `open_risk_ids` 为空，分数达标即当轮退出，不空转；但 P2 必须持久化登记，验收时从 `defer_risk_ids` 读取，不靠回忆。

输出本轮审查结果：

```
━━━ Round N 审查结果 ━━━
质量评分：N/10
本次引入 risk：X 条（P0:a P1:b P2:c）
既有问题（登记不修）：Y 条
未解决池：K 条（P0/P1，决定是否继续循环）
验证证据：已执行 / 未执行（原因）
审查未知清单：M 项
审查方存疑清单：Z 项（不参与统计，人工验收判断）
状态：继续 → Round N+1 / ✅ 收敛（quality_gate / no_progress）/ ⚠️ 达到上限 / ⚠️ 卡死（stalled）
```

---

## Step 4：重新输出目标 → 人工验收

> **快车道精简验收**：trivial 档输出精简版——【原目标】/【审查结论】（score + risk 数）/【未知清单】三项即可，附 review.log 路径与 notes 查询命令（`git notes --ref=delivery-review`）。形式精简，**验收裁决权仍归用户，不可跳过**。快车道完成验收后结束（不执行 Step 5 的报告生成）。

Loop 退出后（`$REPO_ROOT/.delivery-review/state.json` 的 `exit_reason` 字段非空），**重新输出 Step 2 的目标声明**，让用户对着目标验收：

```
━━━ Loop 完成，准备人工验收 ━━━
【原目标】
【Loop 最终状态】总轮数 / 退出原因 / 最终质量评分
【已解决 risk】逐条
【未解决 / defer 项】
【撤回 / 归并记录】R<旧> → 撤回（理由） / R<旧> → R<新>（归并原因）
  数据源：review.log 中**本次运行全部轮次**的 `withdrawn:` / `superseded:` 行（不限本轮——第 1 轮撤回的条目，第 3 轮退出时同样要列出）；没有则写「无」
  作用：池内条目消失时，让你看得见是撤回了还是换了 ID，而不是凭空少几条
【既有问题清单（本次未修，需你决定是否另开任务）】
  逐条：文件:行号 + 分级 + 一句话 + 为什么判定为既有问题（不属于本次改动范围）
【验证证据】实际跑过的命令 + 结果（通过 / 失败 / 未能代跑及原因）
【审查方存疑清单】（审查者拿不准的点，含经验猜测，需人工判断）
【双方未知清单（人工验收重点关注）】
  修复方：...
  审查方：...
【验收引导】每项验收附"怎么测 / 什么现象算通过"

⚠️ 人工验收不可跳过：验收**裁决权**（通过/不通过）必须由用户行使，不可由 AI 代理。
⚠️ 既有问题清单不许静默省略：退出 loop 时不代表老问题消失，必须逐条摆到用户面前。
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
【流程档位】trivial / standard / critical + 升级记录（快车道被 hook 校验打回的，注明轮次与原因）
【Loop 轮次摘要】每轮：本次引入 risk 数 / 既有问题数 / 质量分 / 分数与退出判定
【已解决 risk】逐条
【未解决 / defer 项】
【撤回 / 归并记录】R<旧> → 撤回（理由） / R<旧> → R<新>（归并原因）
【既有问题清单（本次未修）】逐条 + 是否建议另开任务
【验证证据】跑过的命令与输出摘要（通过 / 失败 / 未能代跑原因）
【审查方存疑清单】+ 【双方未知清单】
【对话实录】本轮 git-notes 全部留言按 ID 顺序原样渲染（ID｜from｜type｜正文）——risk 怎么提出、fixer 怎么回应、dispute 怎么收场，一屏可查；这是人工复核的对话级证据
【审查轨迹汇总】各轮轨迹（从 review.log 逐 Round 摘录）——审查者看了什么、核实到 文件:行号、哪些维度未覆盖
【材料快照索引】逐轮列出快照文件名 + 基线 HEAD + 生成时间——人工复核据此复原任意一轮审查时的代码现场
【运行耗时】state.json started_at → 报告生成时刻（总耗时 / 轮数 / 平均轮耗时）
【验收结论】通过 / 未通过（原因 + 待办清单）
【AI 代验结果】如有，含证据等级
【漏检复盘】（仅验收不通过时填写）当时审查材料缺了什么 / 哪条规则没覆盖 / 建议沉淀到哪个文件（CLAUDE.md / SKILL.md / agent 定义 / hook），为下次同类问题留抓手
```

> 溯源链闭环：报告 → 对话实录（谁说了什么）→ 审查轨迹（凭什么说）→ 材料快照（当时看到的是什么）→ git diff 基线（终态随时可 diff 复核）。四层缺一，人工复核即断链——报告生成前编排者按此清单自检。

- 只取本轮运行产生的留言（≥ 本轮最新 context 留言 ID 的消息），不含历史运行内容
- 报告是 untracked 文件，是否提交 git 由用户决定
- 验收不通过时生成为"阶段性报告"（标注"未通过验收 + 原因 + 待办清单"），供二次运行时定位

---

## 元认知纪律（贯穿全程）

- **边界三层**：已知(✅/❌) / 不确定(⚠️+原因) / 未检查(🔍 列出，最重要)
- 每个交付节点必须输出「未知清单」——它比检查清单更重要
- 你不知道的，远比你知道的重要（塔勒布）
