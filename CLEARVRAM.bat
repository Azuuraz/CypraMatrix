@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title CypraTeam VRAM / portable Ollama

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "TOOL=%~dp0clearvram.ps1"
set "OLLAMA_HOST=127.0.0.1:11435"
set "OLLAMA_MODELS=%~dp0OllamaModels"

if /I "%~1"=="EXPLORER" goto :doexplorer

echo.
echo ============================================================
echo   CYPRATEAM VRAM TOOL
echo ============================================================
echo   Unloads this project's models from the GPU.
echo   Does not delete weights. Host global Ollama is ignored.
echo.
echo   [1] Unload GPU models     - ollama stop (no Admin)
echo   [2] Restart portable Ollama
echo   [3] Restart Explorer      - last resort, needs Admin
echo   [Q] Quit
echo.

set "JOB="
set /p "JOB=Select [1-3 / Q]: "
if not defined JOB goto :cancelled
if /I "%JOB%"=="Q" goto :cancelled

if "%JOB%"=="1" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TOOL%" -Job Unload
  goto :done
)
if "%JOB%"=="2" (
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TOOL%" -Job RestartOllama
  goto :done
)
if "%JOB%"=="3" (
  echo.
  echo [!] This kills and restarts explorer.exe. Desktop will flicker.
  set "OK="
  set /p "OK=Type EXPLORER to continue, or Q to cancel: "
  if /I "%OK%"=="Q" goto :cancelled
  if /I not "%OK%"=="EXPLORER" (
    echo Cancelled.
    goto :done
  )
  net session >nul 2>&1
  if errorlevel 1 (
    echo Requesting Administrator for Explorer restart...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'EXPLORER' -Verb RunAs"
    exit /b 0
  )
  goto :doexplorer
)

echo [!] Unknown choice.
goto :done

:doexplorer
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TOOL%" -Job RestartExplorer
goto :done

:cancelled
echo Cancelled.

:done
echo.
pause
endlocal
exit /b 0