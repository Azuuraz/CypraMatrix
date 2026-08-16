@echo off
setlocal
title CypraTeam Portable Model Deletion
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0delmodels.ps1"
pause
endlocal
