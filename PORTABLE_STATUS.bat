@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title CypraTeam Portable Store Status

set "STORE=%~dp0OllamaModels"
set "HOST=127.0.0.1:11435"
set "OLLAMA_MODELS=%STORE%"
set "OLLAMA_HOST=%HOST%"

echo.
echo ============================================================
echo   CYPRATEAM PORTABLE STORE STATUS
echo ============================================================
echo   Host  : %HOST%
echo   Store : %STORE%
echo   Note  : host global Ollama store is ignored
echo.

where ollama >nul 2>&1
if errorlevel 1 (
  echo [!] ollama.exe not found on PATH.
  pause
  exit /b 1
)

if not exist "%STORE%" mkdir "%STORE%"

curl -s http://127.0.0.1:11435/api/tags >nul 2>&1
if errorlevel 1 (
  echo [*] Starting portable Ollama on %HOST% ...
  start "" /b ollama serve >nul 2>&1
  timeout /t 2 /nobreak >nul
)

echo --- REGISTERED MODELS ---
echo.
ollama list
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0modinstall.ps1" -Job Status

echo.
echo Registered = listed above.
echo Blueprint  = Modelfile exists under .\Modfiles (create when you pick the ID).
echo.
pause
endlocal
exit /b 0