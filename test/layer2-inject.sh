#!/usr/bin/env bash
# 第 2 层「行为层」注入式验收：验证 stalled / no_progress 的判定逻辑
#
# 为什么需要注入：这两个退出条件写在 commands/delivery-review.md 的提示词里，
# 由 LLM 执行，hook 只提供 round-delta.json 这一份输入。所以无法用纯脚本断言，
# 只能「造好输入 → 让 LLM 按提示词判 → 校验它写的结论」。
#
# 用法：
#   bash test/layer2-inject.sh run a2       # 一条命令跑完（造场景→判定→校验）
#   bash test/layer2-inject.sh run a3
#   bash test/layer2-inject.sh prepare a2   # 只造场景并打印提示词（手工模式）
#   bash test/layer2-inject.sh check a2     # 校验已有结果
#
# 前提：在 claude --plugin-dir <本仓库> 的会话里执行 prepare 打印的提示词，
#       否则测的是已安装副本，不是本分支代码。

set -u
export PYTHONIOENCODING=utf-8
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/update-review-material.ps1"
V="${DR_VERIFY_DIR:-$HOME/AppData/Local/Temp/dr-verify}"
STATE="$V/.delivery-review/state.json"
DELTA="$V/.delivery-review/work/round-delta.json"
RESULT_BASE="$V/.delivery-review"   # 实际文件按场景区分：layer2-result-a2.json / -a3.json

die() { echo "✗ $1" >&2; exit 1; }
need_win() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

run_hook() {
  python -c "import json,sys;print(json.dumps({'cwd':sys.argv[1],'tool_name':'Bash'}))" "$(need_win "$V")" \
    | powershell -NoProfile -ExecutionPolicy Bypass -File "$(need_win "$HOOK")" >/dev/null 2>&1
}

case "${1:-}" in
prepare)
  SCENARIO="${2:-}"
  [ "$SCENARIO" = "a2" ] || [ "$SCENARIO" = "a3" ] || die "场景必须是 a2 或 a3"
  [ -d "$V/.git" ] || die "临时仓库不存在：$V（先按第 0 层步骤建好）"

  cd "$V" || die "进不去 $V"

  # 0) .delivery-review 必须被忽略：它每轮都被重写，一旦进了 git 就永远脏，
  #    hook 走主路径而不是早退分支，same_as_prev 永远是 false
  grep -qxF '.delivery-review/' .gitignore 2>/dev/null || echo '.delivery-review/' >> .gitignore

  # 1) 清空工作区：delta 要读到「本轮零改动」
  git add -A >/dev/null 2>&1
  git commit -qm "layer2 prep" >/dev/null 2>&1 || true

  # 2) 基线指向当前 HEAD 的 tree：让 hook 走 per_round 且判 same_as_prev=true
  HEAD_SHORT=$(git rev-parse --short HEAD)
  HEAD_TREE=$(git rev-parse HEAD^{tree})
  mkdir -p "$V/.delivery-review/work"
  printf '{"ts":"%s","head":"%s","round":"1","tree":"%s"}\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$HEAD_SHORT" "$HEAD_TREE" \
    > "$V/.delivery-review/work/round-baseline.json"

  # 3) 写场景 state
  if [ "$SCENARIO" = "a2" ]; then
    OPEN='[]'; SCORE=8; EXPECT=no_progress
  else
    OPEN='["R1"]'; SCORE=6; EXPECT=stalled
  fi
  printf '{"round":2,"last_score":%s,"exit_reason":"","max_rounds":3,"open_risk_ids":%s,"legacy_risk_ids":[],"defer_risk_ids":[],"started_at":"2026-10-28T20:00:00"}\n' \
    "$SCORE" "$OPEN" > "$STATE"

  # 4) 触发 hook，确认 delta 前置条件成立
  run_hook
  [ -f "$DELTA" ] || die "round-delta.json 未生成"
  SAME=$(python -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(d.get('same_as_prev'))" "$(need_win "$DELTA")")
  VIEW=$(python -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(d.get('view'))" "$(need_win "$DELTA")")
  [ "$SAME" = "True" ] || die "delta.same_as_prev=$SAME，不是「本轮零改动」；检查工作区是否干净"
  [ "$VIEW" = "per_round" ] || die "delta.view=$VIEW，不是 per_round；检查基线是否指向当前 HEAD"

  RESULT="$RESULT_BASE/layer2-result-$SCENARIO.json"
  rm -f "$RESULT"
  echo "✓ 场景 $SCENARIO 已就绪（same_as_prev=True / view=per_round）"
  echo "  期望结论：$EXPECT"
  ;;

run)
  # 一条命令跑完：prepare → 无头调用 claude 判 → check
  SCENARIO="${2:-}"
  "$0" prepare "$SCENARIO" || exit 1
  RESULT="$RESULT_BASE/layer2-result-$SCENARIO.json"

  command -v claude >/dev/null 2>&1 || die "claude 命令不可用，无法自动判定；可改用 prepare 后手工在会话里跑"
  echo
  echo "→ 调用 claude -p 按 Step 3.4 判定（约 20-40 秒）..."
  PROMPT_TEXT="读取以下文件（只读，不要修改任何文件、不要执行任何命令）：
1. $(need_win "$STATE")
2. $(need_win "$DELTA")
3. $(need_win "$REPO_ROOT/commands/delivery-review.md") 的 Step 3.4「退出判定」

按 Step 3.4 的优先级逐条判定本轮 exit_reason。注意 delta 中 same_as_prev 与 view 的含义，以及 state 中 open_risk_ids 与 last_score。

判完把结论写入 $(need_win "$RESULT")，内容为 JSON：{\"exit_reason\":\"<你的判定>\",\"reason\":\"<一句话依据>\"}
写完只回一行：结果已写入。"

  if ! claude -p "$PROMPT_TEXT" >/tmp/layer2-llm.out 2>&1; then
    echo "  提示：claude 调用有告警，继续校验结果文件"
  fi

  "$0" check "$SCENARIO"
  ;;

check)
  SCENARIO="${2:-}"
  [ "$SCENARIO" = "a2" ] || [ "$SCENARIO" = "a3" ] || die "场景必须是 a2 或 a3"
  [ "$SCENARIO" = "a2" ] && EXPECT=no_progress || EXPECT=stalled
  RESULT="$RESULT_BASE/layer2-result-$SCENARIO.json"
  [ -f "$RESULT" ] || die "结果文件不存在：$RESULT（先跑 run $SCENARIO）"

  GOT=$(python -c "
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8-sig'))
    print(d.get('exit_reason',''))
except Exception:
    print('PARSE_ERROR')
" "$(need_win "$RESULT")")
  REASON=$(python -c "
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8-sig'))
    print(d.get('reason',''))
except Exception:
    print('')
" "$(need_win "$RESULT")")
  if [ "$GOT" = "$EXPECT" ]; then
    echo "✓ 场景 $SCENARIO 通过：exit_reason=$GOT"
    echo "  依据：$REASON"
    exit 0
  else
    echo "✗ 场景 $SCENARIO 失败：期望 $EXPECT，实际 $GOT"
    echo "  依据：$REASON"
    echo "  说明：判定逻辑在 commands/delivery-review.md 的 Step 3.4 提示词里，不在 hook"
    exit 1
  fi
  ;;

*)
  echo "用法：bash test/layer2-inject.sh run a2|a3        （一条命令跑完，推荐）"
  echo "      bash test/layer2-inject.sh prepare a2|a3    （只造场景，打印提示词）"
  echo "      bash test/layer2-inject.sh check a2|a3      （校验已有结果）"
  exit 1
  ;;
esac
