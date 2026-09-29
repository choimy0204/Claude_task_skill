@echo off
rem ============================================================
rem  tiered-dispatch: remove the plugin and restore the default state
rem  Runs tools\restore.ps1 (asks before each step that changes files).
rem  To apply again, run install_or_update.bat.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\restore.ps1"
echo.
pause
