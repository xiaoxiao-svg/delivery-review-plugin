<#
  update-review-material.ps1
  PostToolUse hook：代码改动后自动生成审查材料 .delivery-review/work/material.md
  材料是给审查者子代理消费的机器文件，人不需要看（人看交付报告 docs/delivery-review-*.md）
  材料头部元信息含机械化风险分级 tier（critical/trivial/standard，判定规则见下方代码注释），
  编排者据此路由三档流程；材料分三段：改动清单 / 完整 diff（>800 行截断）/ 新建文件清单（untracked）
  纪律：任何情况必须 exit 0，出错只写 .delivery-review/work/hook.log，绝不干扰被 hook 的工具调用
  输入：stdin 单行 JSON（PostToolUse hook 载荷，含 cwd / tool_name）
  兼容：PS 5.1 下 stdin 可能按 GBK 解码导致中文路径乱码，故 cwd 双来源——
        优先 stdin 载荷（字节流 + UTF8 手动解码），解析失败或路径不存在时回退当前工作目录
  落位：.delivery-review 固定在仓库根目录（git rev-parse --show-toplevel），
        无论在哪个子目录触发 hook，材料都写到根目录，不在子目录下创建
#>
$ErrorActionPreference = "Continue"
# PS 5.1 捕获原生命令输出（git diff 等）时按 GBK 解码 UTF-8 字节会乱码，先切到 UTF-8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Write-HookLog {
  param([string]$dir, [string]$msg)
  try {
    $log = Join-Path $dir "hook.log"
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $log -Append -Encoding utf8
  } catch { }
}$cwd = $null
try {
  $stdin = [Console]::OpenStandardInput()
  $ms = New-Object System.IO.MemoryStream
  $stdin.CopyTo($ms)
  $inputJson = [Text.Encoding]::UTF8.GetString($ms.ToArray())
  if ($inputJson) {
    $p = $inputJson | ConvertFrom-Json
    $cwd = $p.cwd
  }
} catch { }
if (-not $cwd -or -not (Test-Path $cwd)) { $cwd = (Get-Location).Path }
if (-not $cwd -or -not (Test-Path $cwd)) { exit 0 }

# 解析仓库根目录，.delivery-review 固定放这里；非 git 仓库直接退出（兼作 git 检测）
$repoRoot = (& git -C $cwd rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { exit 0 }
$repoRoot = $repoRoot.Trim()

try {
  $dir = Join-Path $repoRoot ".delivery-review"      # 人可见层：state.json / review.log
  $workDir = Join-Path $dir "work"                    # 机器工作区：材料 / 快照 / hook 日志（人不需要打开）
  if (-not (Test-Path $workDir)) {
    try { New-Item -ItemType Directory -Force -Path $workDir | Out-Null } catch { exit 0 }
  }

  # 工作区有变化才刷新材料（含 untracked）
  $changed = & git -C $repoRoot status --porcelain 2>$null
  if ($LASTEXITCODE -ne 0) { exit 0 }
  if (-not $changed) {
    # 无变化：保留旧材料不动，但**必须**把 round-delta 落成「本轮无改动」。
    # 否则编排者看到的还是上一轮的 delta，same_as_prev 永远不为真，
    # no_progress 就成了死规则（实测踩过：无改动时早退导致 delta 不更新）
    try {
      $deltaPath = Join-Path $workDir "round-delta.json"
      $baselinePath = Join-Path $workDir "round-baseline.json"
      $hasBaseline = Test-Path $baselinePath
      # 早退分支同样要校验基线 HEAD：中途 commit 后工作区虽干净，
      # 基线却指向旧 HEAD，此时 same_as_prev 不能为真（工作区「干净」是 commit 造成的，
      # 不是「本轮没进展」）。不校验会把「中途 commit」误报成 no_progress/stalled
      if ($hasBaseline) {
        try {
          $blE = Get-Content -Path $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
          $curHead = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
          if ($curHead) { $curHead = $curHead.Trim() }
          if ($blE -and $blE.head -and $curHead -and ($blE.head -ne $curHead)) {
            $hasBaseline = $false
          }
        } catch { $hasBaseline = $false }
      }
      $delta = [ordered]@{
        ts            = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        baseline_ok   = $hasBaseline
        baseline_note = if ($hasBaseline) { "ok（本轮无任何工作区改动）" } else { "缺失或 HEAD 已变（回退 standard）" }
        view          = if ($hasBaseline) { "per_round" } else { "cumulative" }
        tier          = "standard"
        files         = @()
        file_count    = 0
        diff_lines    = 0
        same_as_prev  = $hasBaseline
        note          = "工作区相对 HEAD 无改动，材料未刷新（若因中途 commit，same_as_prev 已置 false）"
      }
      [System.IO.File]::WriteAllText($deltaPath, ($delta | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    exit 0
  }

  $headHash = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
  if ($headHash) { $headHash = $headHash.Trim() }
  $stat = & git -C $repoRoot diff HEAD --stat 2>$null
  $diff = & git -C $repoRoot diff HEAD 2>$null
  $untracked = & git -C $repoRoot ls-files --others --exclude-standard 2>$null
  $diffLines = ($diff -split "`n").Count

  # ── 累计视图（相对 HEAD，供材料正文完整 diff 使用）────────────────────────
  # 文件集 = diff HEAD --name-only（tracked 增删改）+ ls-files --others（untracked，会展开目录；
  # 不能用 status --porcelain——它把 untracked 目录折叠成一行，文件数会被低估）
  $trackedNames = @(& git -C $repoRoot diff HEAD --name-only 2>$null)
  $changedFiles = @()
  foreach ($f in $trackedNames) { if ($f -is [string] -and $f.Trim()) { $changedFiles += $f.Trim() } }
  foreach ($f in $untracked) { if ($f -is [string] -and $f.Trim()) { $changedFiles += $f.Trim() } }
  # 排除工作目录自身产物（材料/日志/快照），否则 hook 每次写材料都会把自己算进改动文件集
  $changedFiles = @($changedFiles | Where-Object { $_ -notmatch '(^|/)\.delivery-review/' })
  $fileCount = @($changedFiles).Count

  # ── 本轮增量（per-round baseline，1.8.0 起）────────────────────────────────
  # 为什么需要：git diff HEAD 给的是整个 loop 的累计视图。拿它数文件/行数会让
  # 多轮正常改动被误判为大改动（tier 虚高），也无法回答「本轮到底改没改」。
  # 做法：编排者每轮开头写 work/round-baseline.json（含当时工作区的 git tree 对象），
  # hook 用临时 index 重建当前 tree，两个 tree 相减即本轮增量。
  #   - tree 由 read-tree HEAD + add -A 生成，因此未忽略的 untracked 会被自动收录，
  #     新增文件不会漏算；删除文件由 name-status 的 D 行体现
  #   - 临时 index 走 GIT_INDEX_FILE 隔离，用完即删（异常路径也删），绝不碰主 index
  # baseline 缺失（老仓库 / 快车道尚未初始化）→ 回退累计视图并强制 standard：
  # missing 意味着「无法判断规模」，standard 是「按正常流程走」；不能当 trivial（方向反了），
  # 也不能升 critical（没有证据说它大）。
  $baselinePath = Join-Path $workDir "round-baseline.json"
  $baselineOk = $false
  $roundFiles = @()
  $roundDiffLines = 0
  $roundDiff = @()
  $baselineNote = "缺失（回退 standard）"

  if (Test-Path $baselinePath) {
    # 临时 index 必须放仓库外：放 work/ 内会被下面 add -A 自己收进 tree，
    # 造成「每轮都多出两个文件」的假改动（实测踩过）
    $tmpIdx = Join-Path ([System.IO.Path]::GetTempPath()) ("dr-idx-" + [Guid]::NewGuid().ToString("N"))
    $oldIdx = $env:GIT_INDEX_FILE
    try {
      $bl = Get-Content -Path $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
      # 基线必须属于当前 HEAD：换了提交还沿用旧基线，等于跨基线相减，结果无意义。
      # 这条校验不依赖编排者是否遵守纪律，失效必然表现为 baseline_ok=false（可见回退）
      if ($bl -and $bl.tree -and $bl.head -and $headHash -and ($bl.head -ne $headHash)) {
        $baselineNote = "HEAD 已变（基线 $($bl.head)，当前 $headHash）→ 回退 standard"
        $bl = $null
      }
      # 轮次校验：fixer 禁止 commit 时 HEAD 全程不变，仅凭 HEAD 识别不出「漏拍基线、
      # 沿用上轮」。基线里记了拍摄时的 round，与 state.json 的当前轮比对即可识别（R13）
      if ($bl -and $bl.tree -and $bl.round) {
        try {
          $stateRaw = Get-Content -Path (Join-Path $dir "state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
          $curRound = [string]$stateRaw.round
          if ($curRound -and ([string]$bl.round -ne $curRound)) {
            $baselineNote = "轮次不符（基线 r$($bl.round)，当前 r$curRound）→ 回退 standard"
            $bl = $null
          }
        } catch { }
      }
      if ($bl -and $bl.tree) {
        $env:GIT_INDEX_FILE = $tmpIdx
        & git -C $repoRoot read-tree HEAD 2>$null | Out-Null
        # 排除 .delivery-review：hook 每次都要重写 material.md，若不排除，
        # 本次写入自己就成了「本轮改动」，每轮必 +1，no_progress 永远判不出来（实测踩过）
        & git -C $repoRoot add -A -- ':(exclude).delivery-review' 2>$null | Out-Null
        # git add 无法收录删除，补一次 -u 处理索引内的删除
        & git -C $repoRoot add -u -- ':(exclude).delivery-review' 2>$null | Out-Null
        $curTree = (& git -C $repoRoot write-tree 2>$null)
        if ($curTree) {
          $curTree = $curTree.Trim()
          $nameStatus = @(& git -C $repoRoot diff --name-status $bl.tree $curTree 2>$null)
          # 输出形如 `M<TAB>file` / `A<TAB>file` / `D<TAB>file` / `R100<TAB>old<TAB>new`
          # 重命名取新路径（最后一列），否则把「old→new」整串当文件名
          $roundFiles = @($nameStatus | ForEach-Object {
            if ($_ -is [string] -and $_.Trim()) {
              $cols = $_ -split "`t"
              if ($cols.Count -ge 2) { $cols[$cols.Count - 1].Trim() }
            }
          } | Where-Object { $_ -and ($_ -notmatch '(^|/)\.delivery-review/') })
          $roundDiff = @(& git -C $repoRoot diff $bl.tree $curTree 2>$null | Where-Object { $_ -ne $null })
          if ($roundDiff.Count -gt 0) {
            $roundDiffLines = (@($roundDiff) -join "`n" -split "`n").Count
          } else { $roundDiffLines = 0 }
          $baselineOk = $true
          $baselineNote = "ok（基线 $($bl.ts)）"
        }
      } else {
        $baselineNote = "字段缺失（回退 standard）"
      }
    } catch {
      $baselineNote = "读取异常（回退 standard）"
    } finally {
      if ($oldIdx) { $env:GIT_INDEX_FILE = $oldIdx }
      else { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
      Remove-Item -Path $tmpIdx -Force -ErrorAction SilentlyContinue
    }
  }

  # ── 风险分级（机械化判定，LLM 不参与，编排者按此路由三档流程）──────────────
  # critical：触碰关键路径 / 本轮文件数>5 / 本轮 diff>300 行
  # trivial ：本轮文件数≤2 且本轮 diff≤30 行且不触碰关键路径
  # 其余 standard。判定只看客观量，与本轮是谁改的、改了什么内容无关
  $criticalPatterns = @('hooks/', '.github/', '.gitlab-ci', 'jenkinsfile', 'dockerfile',
                        'auth', 'permission', 'migration', 'security', 'credential', 'secret')
  if ($baselineOk) {
    $effFiles = $roundFiles
    $effFileCount = @($roundFiles).Count
    $effDiffLines = $roundDiffLines
  } else {
    $effFiles = $changedFiles
    $effFileCount = $fileCount
    $effDiffLines = $diffLines
  }
  $hitCritical = @()
  foreach ($f in $effFiles) {
    if (-not $f) { continue }
    $lower = $f.ToLowerInvariant()
    foreach ($pat in $criticalPatterns) {
      if ($lower.Contains($pat)) { $hitCritical += "$f（匹配 $pat）"; break }
    }
  }
  $tier = "standard"
  $tierReason = "files=$effFileCount, diff_lines=$effDiffLines, critical=none"
  if ($hitCritical.Count -gt 0) {
    # 关键路径从严：不依赖 baseline 是否可用，命中即 critical。
    # 此时若 baseline 缺失，必须改写 note，否则会出现
    # 「本轮基线：缺失（回退 standard）」紧接「风险分级：critical」的自相矛盾
    $tier = "critical"
    $tierReason = "触碰关键路径: " + ($hitCritical -join '; ')
    if (-not $baselineOk) {
      $baselineNote = "$baselineNote；但关键路径按累计视图命中，仍判 critical"
      $tierReason = "触碰关键路径（按累计视图）: " + ($hitCritical -join '; ')
    }
  } elseif (-not $baselineOk) {
    # baseline 缺失必须排在规模判定之前：此时 $effFiles 是累计视图，
    # 多轮累积后必然 >5，若让规模分支先判，缺失一次就会长期 critical，
    # 且理由写「files=N（>5）」，人看不出这是累计量（实测审查指出）
    $tier = "standard"
    $tierReason = "baseline 缺失，无法判定本轮规模 → 回退 standard（累计 files=$effFileCount，仅供参考）"
  } elseif ($effFileCount -gt 5 -or $effDiffLines -gt 300) {
    $tier = "critical"
    $parts = @()
    if ($effFileCount -gt 5) { $parts += "files=$effFileCount（>5）" }
    if ($effDiffLines -gt 300) { $parts += "diff_lines=$effDiffLines（>300）" }
    $tierReason = $parts -join ', '
  } elseif ($effFileCount -le 2 -and $effDiffLines -le 30) {
    $tier = "trivial"
    $tierReason = "files=$effFileCount, diff_lines=$effDiffLines, critical=none"
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# 审查材料（hook 自动生成，机器消费——人不需要读此文件，看交付报告 docs/）")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  # 标明材料来自哪份 hook：已安装副本与仓库源码可能不同版本，
  # 没有这行时「新 hook 到底跑没跑」只能靠猜（实测踩过：材料缺「本轮基线」行，
  # 说明生成它的是旧副本，而仓库代码里该行是无条件输出的）
  [void]$sb.AppendLine("- 生成方：$PSCommandPath")
  [void]$sb.AppendLine("- 基线 HEAD：$headHash")
  [void]$sb.AppendLine("- 本轮基线：$baselineNote")
  [void]$sb.AppendLine("- 风险分级：$tier（$tierReason）")
  [void]$sb.AppendLine("- 覆盖范围：Write/Edit/Bash 改动；MCP 等其他工具写入不在材料中，发现未覆盖的可疑改动列入未知清单")
  [void]$sb.AppendLine("")
  if ($baselineOk) {
    [void]$sb.AppendLine("## 本轮改动（相对 round-baseline，tier 判定依据）")
    [void]$sb.AppendLine('```')
    if (@($roundFiles).Count -gt 0) {
      [void]$sb.AppendLine(((@($roundFiles) | ForEach-Object { " $_" }) -join [Environment]::NewLine))
    } else {
      [void]$sb.AppendLine(" （本轮无改动）")
    }
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine("")
  }
  [void]$sb.AppendLine("## 改动清单（累计，相对 HEAD）")
  [void]$sb.AppendLine('```')
  [void]$sb.AppendLine(($stat -join [Environment]::NewLine))
  [void]$sb.AppendLine('```')

  if ($diffLines -le 800) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## 完整 diff")
    [void]$sb.AppendLine('```diff')
    [void]$sb.AppendLine(($diff -join [Environment]::NewLine))
    [void]$sb.AppendLine('```')
  } else {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> diff 超过 800 行已省略，请按改动清单 Read 具体文件核实")
  }

  if ($untracked) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## 新建文件（untracked，不在 diff 中，请 Read 原文核实）")
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine(($untracked -join [Environment]::NewLine))
    [void]$sb.AppendLine('```')
  }

  $materialPath = Join-Path $workDir "material.md"
  [System.IO.File]::WriteAllText($materialPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

  # 本轮增量落盘（机器可读），供验收脚本断言、供编排者更新状态机时读取，
  # 避免「从材料自由文本里数文件/行数」这类 LLM 算术（1.8.0）
  # same_as_prev：本轮文件集为空且行数为 0 → 相邻两轮工作区内容全等，编排者据此判 no_progress
  $delta = [ordered]@{
    ts            = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    baseline_ok   = $baselineOk
    baseline_note = $baselineNote
    # 口径显式化：per_round = 文件数/行数确实是本轮增量；
    # cumulative = baseline 不可用，退回累计视图（消费方不得当成「本轮改动」）
    view          = if ($baselineOk) { "per_round" } else { "cumulative" }
    tier          = $tier
    files         = @($effFiles)
    file_count    = $effFileCount
    diff_lines    = $effDiffLines
    same_as_prev  = ($baselineOk -and @($roundFiles).Count -eq 0 -and $roundDiffLines -eq 0)
  }
  $deltaPath = Join-Path $workDir "round-delta.json"
  [System.IO.File]::WriteAllText($deltaPath, ($delta | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
} catch {
  try {
    if (-not $workDir) {
      $workDir = Join-Path $repoRoot ".delivery-review/work"
    }
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Force -Path $workDir | Out-Null }
    Write-HookLog $workDir "hook 异常：$($_.Exception.Message)"
  } catch { }
}
exit 0
