@echo off
rem delivery-review uninstaller launcher
rem Runs uninstall.ps1 with -ExecutionPolicy Bypass so it works even when the
rem system policy blocks .ps1 scripts (the default on Windows).
chcp 65001 >nul 2>&1
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
