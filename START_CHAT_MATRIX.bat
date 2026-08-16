@echo off
setlocal EnableExtensions DisableDelayedExpansion
title "CypraTeam AI Matrix"
chcp 65001 > nul
cd /d "%~dp0"

set "MATRIX_ROOT=%~dp0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%MATRIX_ROOT%launch_chat.ps1"

echo ===================================================
echo   CYPRATEAM PORTABLE AI DEVELOPMENT INFRASTRUCTURE
echo ===================================================
echo [*] Initializing portable workspace environment...
echo [i] Project root : %MATRIX_ROOT%

if not exist "%PS%" (
    echo [!] ERROR: Windows PowerShell was not found.
    echo [!] Expected: %PS%
    pause
    exit /b 1
)

if not exist "%SCRIPT%" (
    echo [!] ERROR: launch_chat.ps1 was not found in this folder.
    echo [!] Expected: %SCRIPT%
    pause
    exit /b 1
)

if not exist "OllamaModels" mkdir "OllamaModels"
if not exist "Logs" mkdir "Logs"
if not exist "Tasks" mkdir "Tasks"

echo [*] Checking Ollama engine status...
where ollama >nul 2>&1
if errorlevel 1 (
    if exist "%LOCALAPPDATA%\Programs\Ollama\ollama.exe" (
        set "PATH=%LOCALAPPDATA%\Programs\Ollama;%PATH%"
    ) else if exist "%ProgramFiles%\Ollama\ollama.exe" (
        set "PATH=%ProgramFiles%\Ollama;%PATH%"
    ) else (
        echo [!] ERROR: Ollama is not installed or not found in PATH.
        echo [!] Install Ollama from https://ollama.com before launching.
        pause
        exit /b 1
    )
)

echo [+] Ollama binary detected. Launching core matrix panel...
"%PS%" -NoExit -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
endlocal