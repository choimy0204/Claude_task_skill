@echo off
setlocal

rem ============================================================
rem  Claude Code global agent setup - UNINSTALL (restore)
rem  Put this .bat in the same folder as install_claude_agents.bat
rem  and the source files (CLAUDE.md, code-searcher.md, implementer.md).
rem
rem  For each file:
rem    - backup (.bak_*) exists -> restore the OLDEST backup
rem                                (= the state before the first install)
rem    - no backup, same as source -> delete (it was created by the installer)
rem    - no backup, modified       -> leave it and show a warning
rem ============================================================

set "SRC=%~dp0"
set "DEST=%USERPROFILE%\.claude"
set "AGENTS=%DEST%\agents"

echo.
echo Target : %DEST%
echo.

call :restore "%AGENTS%" code-searcher.md
call :restore "%AGENTS%" implementer.md
call :restore "%DEST%"   CLAUDE.md

echo.
echo Done. Restart Claude Code to apply.
echo.
pause
exit /b 0


rem ============================================================
rem  :restore <folder> <file name>
rem ============================================================
:restore
set "DIR=%~1"
set "NAME=%~2"
set "TARGET=%DIR%\%NAME%"

rem Find the oldest backup (names end with a timestamp, so name order = time order)
set "OLDEST="
set "BAK_COUNT=0"
for /f "delims=" %%B in ('dir /b /a:-d /o:n "%TARGET%.bak_*" 2^>nul') do (
    if not defined OLDEST set "OLDEST=%%B"
    set /a BAK_COUNT+=1
)

if defined OLDEST goto :restore_from_backup

rem --- No backup: the installer created this file -----------
if not exist "%TARGET%" (
    echo [SKIP] %NAME% is not installed
    exit /b
)

if not exist "%SRC%%NAME%" (
    echo [WARN] %NAME% : source file not found here, cannot verify. Left as is.
    exit /b
)

fc /b "%SRC%%NAME%" "%TARGET%" >nul
if errorlevel 1 (
    echo [WARN] %NAME% was modified after install. Left as is.
    exit /b
)

del "%TARGET%"
echo [DEL]  %NAME%  (created by installer)
exit /b


:restore_from_backup
move /y "%DIR%\%OLDEST%" "%TARGET%" >nul
echo [OK]   %NAME% restored from %OLDEST%

set /a REMAIN=BAK_COUNT-1
if %REMAIN% GTR 0 (
    echo [INFO] %REMAIN% newer backup^(s^) of %NAME% left in %DIR%
)
exit /b
