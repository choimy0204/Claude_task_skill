@echo off
rem ============================================================
rem  tiered-dispatch: roll back to v2.4.0 (snapshot in rollback\v2.4.0)
rem  To return to the latest version, run install_or_update.bat.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install-or-update.ps1" -SourceRoot "%~dp0rollback\v2.4.0" -Reinstall
echo.
pause
