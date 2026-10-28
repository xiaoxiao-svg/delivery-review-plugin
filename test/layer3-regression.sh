#!/usr/bin/env bash
# 第 3 层「回归层」验收：确认 1.7.0 的机制没被 1.8.0 改坏
#
# 1.8.0 只改了退出条件与 tier 输入，没动 open_risk_ids 的出池逻辑。
# 本脚本用注入法验证 1.7.0 的四条核心语义仍在：
#   R3-1「已修复」出口：reviewer 判 ✅+证据 → 该 ID 出池
#   R3-2「误报撤回」出口：reviewer 判 ⚠️误报 → 该 ID 出池
#   R3-3 降级续报：新 P2 的 reply_to 指向池内 P1 → 旧 P1 出池、新 P2 进 defer
#   R3-4 既有 P0：标「既有问题」的 P0 → 仍进 open_risk_ids 阻塞退出
#
# 用法：bash test/layer3-regression.sh [场景号]
#   不带参数跑全部；带参数只跑一个（r3-1 ... r3-4）

set -u
export PYTHONIOENCODING=utf-8
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="${DR_VERIFY_DIR:-$HOME/AppData/Local/Temp/dr-verify}"
STATE="$V/.delivery-review/state.json"
REVIEW="$V/.delivery-review/work/review-input.json"
RESULT="$V/.delivery-review/layer3-result.json"
CMD_DOC="$REPO_ROOT/commands/delivery-review.md"

die() { echo "✗ $1" >&2; exit 1; }
need_win() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

[ -d "$V/.git" ] || die "临时仓库不存在：$V"
cd "$V" || die "进不去 $V"

run_case() {
  local ID="$1" BASE_STATE="$2" REVIEW_JSON="$3" EXPECT_OPEN="$4" EXPECT_DEFER="$5" DESC="$6"

  printf '%s\n' "$BASE_STATE" > "$STATE"
  printf '%s\n' "$REVIEW_JSON" > "$REVIEW"
  rm -f "$RESULT"

  local PROMPT_TEXT="读取以下文件（只读，不要修改任何文件、不要执行任何命令）：
1. $(need_win "$STATE")            —— 当前 state.json
2. $(need_win "$REVIEW")           —— 本轮 reviewer 的 risk 输出（模拟）
3. $(need_win "$CMD_DOC") 的 Step 3.4「更新状态机」全段

严格按 Step 3.4 的规则算出**更新后**的 state，重点看 open_risk_ids 与 defer_risk_ids。
注意：${DESC}

只输出一个 JSON 到 $(need_win "$RESULT")：
{\"open_risk_ids\":[...],\"defer_risk_ids\":[...],\"reason\":\"<一句话依据>\"}
写完只回一行：结果已写入。"

  echo "── $ID"
  claude -p "$PROMPT_TEXT" >/tmp/layer3-llm.out 2>&1 || true

  [ -f "$RESULT" ] || { echo "  ✗ 结果文件未生成（LLM 没写）"; return 1; }

  local GOT_OPEN GOT_DEFER REASON
  GOT_OPEN=$(python -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8-sig'));print(json.dumps(sorted(map(str,d.get('open_risk_ids',[]))),ensure_ascii=False))" "$(need_win "$RESULT")")
  GOT_DEFER=$(python -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8-sig'));print(json.dumps(sorted(map(str,d.get('defer_risk_ids',[]))),ensure_ascii=False))" "$(need_win "$RESULT")")
  REASON=$(python -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8-sig'));print(d.get('reason',''))" "$(need_win "$RESULT")")

  local OK=1
  [ "$GOT_OPEN" = "$EXPECT_OPEN" ] || OK=0
  if [ -n "$EXPECT_DEFER" ]; then
    [ "$GOT_DEFER" = "$EXPECT_DEFER" ] || OK=0
  fi

  if [ "$OK" = "1" ]; then
    echo "  ✓ open=$GOT_OPEN defer=$GOT_DEFER"
    echo "    依据：$REASON"
    return 0
  else
    echo "  ✗ 期望 open=$EXPECT_OPEN${EXPECT_DEFER:+ defer=$EXPECT_DEFER}"
    echo "    实际 open=$GOT_OPEN defer=$GOT_DEFER"
    echo "    依据：$REASON"
    return 1
  fi
}

PASS=0; FAIL=0
only="${1:-}"

# R3-1：已修复出口 —— 池内 R1 被 reviewer 判已修复+证据 → 出池
if [ -z "$only" ] || [ "$only" = "r3-1" ]; then
  if run_case "R3-1 已修复出口（✅+证据 → 出池）" \
    '{"round":2,"last_score":7,"exit_reason":"","max_rounds":3,"open_risk_ids":[1],"legacy_risk_ids":[],"defer_risk_ids":[],"started_at":"2026-10-28T20:00:00"}' \
    '{"reviewer_output":"【上轮未解决 risk 复查】R1（原：命令文件缺 refresh 行）=✅已修复（证据：commands/delivery-review.md:250 已写 refresh 行）","risks":[],"score":8}' \
    '[]' '' "R1 已带证据判为已修复"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
fi

# R3-2：误报撤回出口 —— 判「⚠️误报撤回」→ 出池
if [ -z "$only" ] || [ "$only" = "r3-2" ]; then
  if run_case "R3-2 误报撤回出口（⚠️误报 → 出池）" \
    '{"round":2,"last_score":7,"exit_reason":"","max_rounds":3,"open_risk_ids":[1],"legacy_risk_ids":[],"defer_risk_ids":[],"started_at":"2026-10-28T20:00:00"}' \
    '{"reviewer_output":"【上轮未解决 risk 复查】R1：⚠️误报撤回（理由：该行本来就是正确的，我上轮看错了）","risks":[],"score":8}' \
    '[]' '' "R1 被判误报撤回"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
fi

# R3-3：降级续报 —— 新 P2 reply_to=1 → 旧 P1 出池、新 P2 进 defer
if [ -z "$only" ] || [ "$only" = "r3-3" ]; then
  if run_case "R3-3 降级续报（P1→P2，旧出池新进 defer）" \
    '{"round":2,"last_score":7,"exit_reason":"","max_rounds":3,"open_risk_ids":[1],"legacy_risk_ids":[],"defer_risk_ids":[],"started_at":"2026-10-28T20:00:00"}' \
    '{"reviewer_output":"【上轮未解决 risk 复查】R1：❌未修复，剩余为文案级细节，降级续报","risks":[{"id":5,"reply_to":1,"severity":"P2","attribution":"本次引入","desc":"refresh 行措辞可再简洁"}],"score":8}' \
    '[]' '' "新 P2 的 reply_to=1，按出口 C 链归并：旧 R1 出池，新 P2 进 defer_risk_ids"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
fi

# R3-4：既有 P0 —— 标「既有问题」的 P0 仍进 open 阻塞
if [ -z "$only" ] || [ "$only" = "r3-4" ]; then
  if run_case "R3-4 既有 P0 仍阻塞（既有问题但 P0 → 进 open）" \
    '{"round":2,"last_score":8,"exit_reason":"","max_rounds":3,"open_risk_ids":[],"legacy_risk_ids":[],"defer_risk_ids":[],"started_at":"2026-10-28T20:00:00"}' \
    '{"reviewer_output":"本轮发现一个既有问题","risks":[{"id":7,"severity":"P0","attribution":"既有问题","evidence":"verified","desc":"老代码里的命令注入","basis":"该行不在相对基线 diff 内"}],"score":9}' \
    '["7"]' '' "P0 即便归属为既有问题，也必须进 open_risk_ids 阻塞退出"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
fi

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
