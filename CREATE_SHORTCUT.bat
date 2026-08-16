@echo off
title CypraTeam - Universal Shortcut Generator
cd /d "%~dp0"

echo [*] Generating portable desktop shortcut...

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$workDir = '%~dp0'.TrimEnd('\');" ^
    "$desktop = [Environment]::GetFolderPath('Desktop');" ^
    "$target = Join-Path $workDir 'START_CHAT_MATRIX.bat';" ^
    "$icon = Join-Path $workDir 'Icons\START_CHAT_MATRIX.ico';" ^
    "$shortcutPath = Join-Path $desktop 'CypraTeam Matrix.lnk';" ^
    "$wsh = New-Object -ComObject WScript.Shell;" ^
    "$shortcut = $wsh.CreateShortcut($shortcutPath);" ^
    "$shortcut.TargetPath = $target;" ^
    "$shortcut.WorkingDirectory = $workDir;" ^
    "if (Test-Path $icon) { $shortcut.IconLocation = $icon };" ^
    "$shortcut.Save();"

echo.
echo [+] Success! Shortcut placed on Desktop with custom icon applied.
pause