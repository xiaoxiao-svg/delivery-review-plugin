#!/usr/bin/env bash
# 1.8.0 本轮基线机制验收脚本（随仓库分发，可复现）
# 用法：bash test/verify-round-baseline.sh
# 需要：git、powershell（Windows）+ Git Bash（脚本用 cygpath 转换路径）
# 说明：与 hooks/update-review-material.ps1 的平台依赖一致——插件本身即 Windows 限定
#
# 覆盖场景：
#   A  同一文件每轮真改内容 → 每轮都算作改动（不会被误判为 no_progress）
#   A2 连续两轮不改 → same_as_prev=true（no_progress 的判定依据）
#   B  无关 untracked 存在但本轮没碰 → 不计入本轮改动（tier 不被顶高）
#   C  一次改 6 个文件 → tier=critical（阈值仍生效）
#   D  无 baseline → tier 回退 standard（不能回退 trivial，方向不能反）
#   E  新增 + 删除 + 修改 → 三种变更都体现在 files 列表里

set -u
HOOK=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)/hooks/update-review-material.ps1" 2>/dev/null || echo "")
[ -n "$HOOK" ] || { echo "无法定位 hook 脚本"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 $3，实际 $2"; fi; }

new_repo() {
  REPO=$(mktemp -d)
  cd "$REPO" || exit 1
  git init -q .
  git config user.email t@t; git config user.name t
  printf 'a\nb\n' > f1.txt; printf 'x\n' > f2.txt
  git add .; git commit -qm init
  CWD=$(cygpath -w "$REPO")
}

run_hook() {
  python -c "import json,sys;print(json.dumps({'cwd':sys.argv[1],'tool_name':'Bash'}))" "$CWD" \
    | powershell -NoProfile -ExecutionPolicy Bypass -File "$HOOK" >/dev/null 2>&1
}

mktree() {
  local idx; idx=$(mktemp)
  GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null
  GIT_INDEX_FILE="$idx" git add -A -- ':(exclude).delivery-review' 2>/dev/null
  GIT_INDEX_FILE="$idx" git add -u -- ':(exclude).delivery-review' 2>/dev/null
  GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null
  rm -f "$idx"
}

mkbase() {
  local t h; t=$(mktree); h=$(git rev-parse --short HEAD)
  mkdir -p .delivery-review/work
  printf '{"ts":"%s","head":"%s","tree":"%s"}\n' "$1" "$h" "$t" \
    > .delivery-review/work/round-baseline.json
}

delta() { python -c "
import json
d=json.load(open('.delivery-review/work/round-delta.json',encoding='utf-8'))
print(d.get('$1'))
"; }

echo "== D: 无 baseline 回退 =="
new_repo
run_hook
check "tier 回退 standard" "$(delta tier)" "standard"
check "baseline_ok=false" "$(delta baseline_ok)" "False"
cd /; rm -rf "$REPO"

echo "== A2: baseline 后无改动 =="
new_repo
mkbase r1; run_hook
check "files 为空" "$(delta files)" "[]"
check "same_as_prev=true" "$(delta same_as_prev)" "True"
cd /; rm -rf "$REPO"

echo "== A: 改一个文件 =="
new_repo
mkbase r1
printf 'a\nb\nc\nd\n' > f1.txt
run_hook
check "计入 1 个文件" "$(delta file_count)" "1"
check "same_as_prev=false" "$(delta same_as_prev)" "False"
cd /; rm -rf "$REPO"

echo "== B: 无关 untracked 不计入 =="
new_repo
echo junk > unrelated-junk.sh
mkbase r1
printf 'a\nb\nc\n' > f1.txt
run_hook
check "只计入本轮改的 1 个文件" "$(delta file_count)" "1"
cd /; rm -rf "$REPO"

echo "== C: 6 个文件 → critical =="
new_repo
mkbase r1
for i in 1 2 3 4 5 6; do printf "l$i\n" > "g$i.txt"; done
run_hook
check "tier=critical" "$(delta tier)" "critical"
cd /; rm -rf "$REPO"

echo "== E: 新增+删除+修改 =="
new_repo
mkbase r1
printf 'q\n' > f3.txt; rm f2.txt; printf 'a\nb\nc\n' > f1.txt
run_hook
check "三种变更都计入（3 个文件）" "$(delta file_count)" "3"
cd /; rm -rf "$REPO"

echo "== F: 基线 HEAD 与当前不符 → 回退 standard =="
new_repo
mkbase r1
printf 'a\nb\nc\n' > f1.txt
git add -A; git commit -qm second   # HEAD 变了，基线仍指向旧 HEAD
run_hook
check "baseline_ok=false" "$(delta baseline_ok)" "False"
check "tier 回退 standard" "$(delta tier)" "standard"
cd /; rm -rf "$REPO"

echo "== G: 无 baseline + 工作区脏 + 改动 ≤2 文件 → standard（不是 trivial）=="
new_repo
printf 'a\nb\nc\n' > f1.txt   # 工作区脏，无基线
run_hook
check "tier=standard 而非 trivial" "$(delta tier)" "standard"
cd /; rm -rf "$REPO"

echo "== H: 基线存在但 HEAD 已变 + 工作区脏 → 主路径回退 =="
new_repo
mkbase r1
printf 'a\nb\nc\n' > f1.txt
git add -A; git commit -qm second      # HEAD 变化
printf 'a\nb\nc\n' > f1.txt           # 再留脏改动，确保走主路径而非早退
run_hook
check "baseline_ok=false（主路径 HEAD 校验）" "$(delta baseline_ok)" "False"
cd /; rm -rf "$REPO"

echo "== I: 脏工作区拍基线后不再改动 → 主路径零改动分支 =="
new_repo
printf 'a
b
c
' > f1.txt      # 先弄脏
mkbase r1                          # 在脏工作区拍基线
run_hook                           # 不再改动，走主路径（工作区仍脏）
check "file_count=0" "$(delta file_count)" "0"
check "same_as_prev=true" "$(delta same_as_prev)" "True"
check "baseline_ok=true" "$(delta baseline_ok)" "True"
check "view=per_round" "$(delta view)" "per_round"
cd /; rm -rf "$REPO"

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
