@echo off
rem ============================================================
rem  tiered-dispatch: install or update the plugin from this folder
rem  Runs tools\install-or-update.ps1 (asks before any cleanup).
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install-or-update.ps1"
echo.
pause
