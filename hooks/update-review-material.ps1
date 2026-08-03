<#
  update-review-material.ps1
  PostToolUse hook：代码改动后自动生成审查材料 .delivery-review/review_material.md
  材料分三段：改动清单 / 完整 diff（>800 行截断）/ 新建文件清单（untracked）
  纪律：任何情况必须 exit 0，出错只写 .delivery-review/hook.log，绝不干扰被 hook 的工具调用
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
}

$cwd = $null
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
  $dir = Join-Path $repoRoot ".delivery-review"
  if (-not (Test-Path $dir)) {
    try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { exit 0 }
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

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# 审查材料（自动生成，请勿手改）")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  [void]$sb.AppendLine("- 基线 HEAD：$headHash")
  [void]$sb.AppendLine("- 触发工具：$($p.tool_name)")
  [void]$sb.AppendLine("- 覆盖范围：Write/Edit/Bash 工具调用后的工作区变化；MCP 等其他工具的写入不在材料中，请人工核对")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## 改动清单")
  [void]$sb.AppendLine('```')
  [void]$sb.AppendLine(($stat -join [Environment]::NewLine))
  [void]$sb.AppendLine('```')

  $diffLines = ($diff -split "`n").Count
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

  $materialPath = Join-Path $dir "review_material.md"
  [System.IO.File]::WriteAllText($materialPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
} catch {
  try {
    if (-not $repoRoot) { $repoRoot = $cwd }
    $dir = Join-Path $repoRoot ".delivery-review"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Write-HookLog $dir "hook 异常：$($_.Exception.Message)"
  } catch { }
}
exit 0
