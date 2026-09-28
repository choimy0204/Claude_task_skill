@echo off
rem ============================================================
rem  tiered-dispatch: clean up legacy setup and install the plugin
rem  Runs tools\setup-this-pc.ps1 (asks before every step).
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\setup-this-pc.ps1"
echo.
pause
