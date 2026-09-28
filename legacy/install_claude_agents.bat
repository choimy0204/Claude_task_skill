@echo off
setlocal

rem ============================================================
rem  Claude Code global agent setup
rem  Put this .bat in the same folder as:
rem    CLAUDE.md, code-searcher.md, implementer.md
rem ============================================================

set "SRC=%~dp0"
set "DEST=%USERPROFILE%\.claude"
set "AGENTS=%DEST%\agents"

echo.
echo Source : %SRC%
echo Target : %DEST%
echo.

rem --- 1. Check source files ---------------------------------
for %%F in (CLAUDE.md code-searcher.md implementer.md) do (
    if not exist "%SRC%%%F" (
        echo [ERROR] %%F not found in this folder.
        goto :fail
    )
)

rem --- 2. Create folders -------------------------------------
if not exist "%AGENTS%" mkdir "%AGENTS%"

rem Timestamp for backup file names (e.g. 20260928_154800)
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%T"

rem --- 3. Agent files ----------------------------------------
call :install_agent code-searcher.md
call :install_agent implementer.md

rem --- 4. CLAUDE.md ------------------------------------------
if not exist "%DEST%\CLAUDE.md" (
    copy /y "%SRC%CLAUDE.md" "%DEST%\CLAUDE.md" >nul
    echo [OK]   CLAUDE.md created
    goto :done
)

rem Existing CLAUDE.md: skip if rules were already added
findstr /c:"code-searcher" "%DEST%\CLAUDE.md" >nul
if not errorlevel 1 (
    echo [SKIP] CLAUDE.md already has the delegation rules
    goto :done
)

rem Otherwise back it up and append the rules at the end
copy /y "%DEST%\CLAUDE.md" "%DEST%\CLAUDE.md.bak_%TS%" >nul
>>"%DEST%\CLAUDE.md" echo(
>>"%DEST%\CLAUDE.md" echo(
type "%SRC%CLAUDE.md" >>"%DEST%\CLAUDE.md"
echo [OK]   CLAUDE.md rules appended  (backup: CLAUDE.md.bak_%TS%)
goto :done


rem ============================================================
rem  :install_agent <file name>
rem  - same content already installed -> skip
rem  - different content -> back up old file, then overwrite
rem ============================================================
:install_agent
set "NAME=%~1"
if exist "%AGENTS%\%NAME%" (
    fc /b "%SRC%%NAME%" "%AGENTS%\%NAME%" >nul
    if not errorlevel 1 (
        echo [SKIP] agents\%NAME% is already up to date
        exit /b
    )
    copy /y "%AGENTS%\%NAME%" "%AGENTS%\%NAME%.bak_%TS%" >nul
    echo [BAK]  agents\%NAME%.bak_%TS%
)
copy /y "%SRC%%NAME%" "%AGENTS%\%NAME%" >nul
echo [OK]   agents\%NAME%
exit /b


:done
echo.
echo Done. Restart Claude Code and run /agents to check.
echo.
pause
exit /b 0

:fail
echo.
echo Setup aborted. Nothing was changed.
echo.
pause
exit /b 1
