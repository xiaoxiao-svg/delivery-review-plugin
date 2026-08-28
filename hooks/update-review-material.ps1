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
  if (-not $changed) { exit 0 }        # 无变化：保留旧材料不动

  $headHash = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
  if ($headHash) { $headHash = $headHash.Trim() }
  $stat = & git -C $repoRoot diff HEAD --stat 2>$null
  $diff = & git -C $repoRoot diff HEAD 2>$null
  $untracked = & git -C $repoRoot ls-files --others --exclude-standard 2>$null
  $diffLines = ($diff -split "`n").Count

  # ── 风险分级（机械化判定，LLM 不参与，编排者按此路由三档流程）──────────────
  # critical：触碰关键路径 / 文件数>5 / diff>300 行
  # trivial ：文件数≤2 且 diff≤30 行且不触碰关键路径
  # 其余 standard。判定只看客观量，与本轮是谁改的、改了什么内容无关
  # 文件集 = diff HEAD --name-only（tracked 增删改）+ ls-files --others（untracked，会展开目录；
  # 不能用 status --porcelain——它把 untracked 目录折叠成一行，文件数会被低估）
  $criticalPatterns = @('hooks/', '.github/', '.gitlab-ci', 'jenkinsfile', 'dockerfile',
                        'auth', 'permission', 'migration', 'security', 'credential', 'secret')
  $trackedNames = @(& git -C $repoRoot diff HEAD --name-only 2>$null)
  $changedFiles = @()
  foreach ($f in $trackedNames) { if ($f -is [string] -and $f.Trim()) { $changedFiles += $f.Trim() } }
  foreach ($f in $untracked) { if ($f -is [string] -and $f.Trim()) { $changedFiles += $f.Trim() } }
  # 排除工作目录自身产物（材料/日志/快照），否则 hook 每次写材料都会把自己算进改动文件集
  $changedFiles = @($changedFiles | Where-Object { $_ -notmatch '(^|/)\.delivery-review/' })
  $fileCount = @($changedFiles).Count
  $hitCritical = @()
  foreach ($f in $changedFiles) {
    if (-not $f) { continue }
    $lower = $f.ToLowerInvariant()
    foreach ($pat in $criticalPatterns) {
      if ($lower.Contains($pat)) { $hitCritical += "$f（匹配 $pat）"; break }
    }
  }
  $tier = "standard"
  $tierReason = "files=$fileCount, diff_lines=$diffLines, critical=none"
  if ($hitCritical.Count -gt 0) {
    $tier = "critical"
    $tierReason = "触碰关键路径: " + ($hitCritical -join '; ')
  } elseif ($fileCount -gt 5 -or $diffLines -gt 300) {
    $tier = "critical"
    $parts = @()
    if ($fileCount -gt 5) { $parts += "files=$fileCount（>5）" }
    if ($diffLines -gt 300) { $parts += "diff_lines=$diffLines（>300）" }
    $tierReason = $parts -join ', '
  } elseif ($fileCount -le 2 -and $diffLines -le 30) {
    $tier = "trivial"
    $tierReason = "files=$fileCount, diff_lines=$diffLines, critical=none"
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# 审查材料（hook 自动生成，机器消费——人不需要读此文件，看交付报告 docs/）")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  [void]$sb.AppendLine("- 基线 HEAD：$headHash")
  [void]$sb.AppendLine("- 风险分级：$tier（$tierReason）")
  [void]$sb.AppendLine("- 覆盖范围：Write/Edit/Bash 改动；MCP 等其他工具写入不在材料中，发现未覆盖的可疑改动列入未知清单")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## 改动清单")
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
