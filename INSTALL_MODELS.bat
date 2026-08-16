@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title CypraTeam - Portable fleet tools

set "PROJECT_ROOT=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "INSTALLER=%PROJECT_ROOT%modinstall.ps1"

where ollama >nul 2>&1
if errorlevel 1 (
  echo [!] ollama.exe was not found on PATH.
  echo [!] Install Ollama on this PC. Only the model store is portable.
  pause
  exit /b 1
)

echo.
echo ============================================================
echo   CYPRATEAM PORTABLE FLEET TOOLS
echo ============================================================
echo   Endpoint : 127.0.0.1:11435
echo   Store    : %PROJECT_ROOT%OllamaModels
echo   Modfiles : %PROJECT_ROOT%Modfiles
echo.
echo   You do NOT need this to add one agent.
echo   In the Matrix, pick an ID and confirm create from its Modelfile.
echo.
echo   This program is for new PCs and fleet jobs:
echo     [1] Status          - base, Modelfiles, registered agents
echo     [2] Pull base only  - download the Gemma / chosen weights
echo     [3] Register Core   - cypra, anomaly, quantum, nexus-prime
echo     [4] Register ALL    - ollama create every existing Modelfile
echo     [5] Rebuild fleet   - rewrite Modelfiles onto a new base + register
echo     [Q] Quit
echo.

set "JOB="
set /p "JOB=Select [1-5 / Q]: "
if not defined JOB goto :cancelled
if /I "%JOB%"=="Q" goto :cancelled
if "%JOB%"=="q" goto :cancelled

if "%JOB%"=="1" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Job Status
  goto :done
)

set "TARGET_MODEL="
if "%JOB%"=="2" goto :askbase
if "%JOB%"=="5" goto :askbase
goto :runjob

:askbase
echo.
echo   Enter a base model, or Q to cancel.
set /p "TARGET_MODEL=Base model [default: huihui_ai/gemma-4-abliterated:e4b]: "
if /I "%TARGET_MODEL%"=="Q" goto :cancelled
if /I "%TARGET_MODEL%"=="QUIT" goto :cancelled
if not defined TARGET_MODEL set "TARGET_MODEL=huihui_ai/gemma-4-abliterated:e4b"

:runjob
if "%JOB%"=="2" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Job PullBase -TargetModel "%TARGET_MODEL%"
  goto :done
)
if "%JOB%"=="3" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Job RegisterCore
  goto :done
)
if "%JOB%"=="4" (
  echo.
  echo [!] This registers every Modelfile. Slow. Agents you never open do not need this.
  set "OK="
  set /p "OK=Type REGISTER ALL to continue, or Q to cancel: "
  if /I "%OK%"=="Q" goto :cancelled
  if /I not "%OK%"=="REGISTER ALL" (
    echo Cancelled.
    goto :done
  )
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Job RegisterAll
  goto :done
)
if "%JOB%"=="5" (
  echo.
  echo [!] Rebuild rewrites every Modelfile FROM line to the chosen base, then registers.
  set "OK="
  set /p "OK=Type REBUILD to continue, or Q to cancel: "
  if /I "%OK%"=="Q" goto :cancelled
  if /I not "%OK%"=="REBUILD" (
    echo Cancelled.
    goto :done
  )
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Job Rebuild -TargetModel "%TARGET_MODEL%"
  goto :done
)

echo [!] Unknown choice.
goto :done

:cancelled
echo Cancelled.
goto :done

:done
echo.
pause
endlocal
exit /b 0