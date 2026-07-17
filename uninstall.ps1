<#
  delivery-review uninstaller (Windows / PowerShell)
  - Local: remove ~/.claude/skills/delivery-review/ and its .bak-* backups
  - Market: print the /plugin uninstall command
#>
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$ErrorActionPreference = "Stop"
$dest = "$env:USERPROFILE\.claude\skills\delivery-review"
$bakPattern = "$env:USERPROFILE\.claude\skills\delivery-review.bak-*"

try {
  if (-not (Test-Path $dest)) {
    Write-Host "未检测到本地 skills-dir 安装: $dest" -ForegroundColor Gray
  } else {
    Remove-Item -Path $dest -Recurse -Force
    Write-Host "已删除本地 skills-dir 安装。" -ForegroundColor Green
    Write-Host "  删除位置：$dest" -ForegroundColor Gray
  }
  $bakItems = Get-ChildItem -Path $bakPattern -Directory -ErrorAction SilentlyContinue
  if ($bakItems) {
    $bakItems | ForEach-Object { Remove-Item $_.FullName -Recurse -Force }
    Write-Host "已清理旧备份：$($bakItems.Name -join ', ')" -ForegroundColor Gray
  }
} catch {
  Write-Host "卸载失败: $($_.Exception.Message)" -ForegroundColor Red
  Read-Host "Press Enter to exit"
  exit 1
}

Write-Host ""
Write-Host "【市场卸载（推荐）】在 Claude Code 会话中执行：" -ForegroundColor Yellow
Write-Host "  /plugin uninstall delivery-review@delivery-review-marketplace" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to exit"
