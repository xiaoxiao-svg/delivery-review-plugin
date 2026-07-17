<#
  delivery-review installer (Windows / PowerShell)
  - Local: robocopy to ~/.claude/skills/delivery-review/
  - Market: print the /plugin install command
#>
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
$dest = "$env:USERPROFILE\.claude\skills\delivery-review"

try {
  if (Test-Path $dest) {
    $bak = "$dest.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Rename-Item $dest $bak
    Write-Host "已备份旧版 -> $bak"
  }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  robocopy $repo $dest /MIR /XD .git .claude-plugin /XF install.ps1 install.bat uninstall.ps1 uninstall.bat README.md LICENSE /R:3 /W:3 /NDL /NFL /NJH /NJS
  Write-Host ""
  Write-Host "本地 skills-dir 安装完成。" -ForegroundColor Green
  Write-Host "  安装位置：$dest" -ForegroundColor Gray
} catch {
  Write-Host "安装失败: $($_.Exception.Message)" -ForegroundColor Red
  Read-Host "Press Enter to exit"
  exit 1
}

Write-Host ""
Write-Host "【市场安装（推荐）】在 Claude Code 会话中执行：" -ForegroundColor Yellow
Write-Host "  /plugin install delivery-review@delivery-review-marketplace" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to exit"
