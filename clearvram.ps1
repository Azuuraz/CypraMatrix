param(
    [ValidateSet('','Unload','RestartOllama','RestartExplorer')]
    [string]$Job = ''
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Store = Join-Path $ProjectRoot "OllamaModels"
$HostAddr = "127.0.0.1:11435"

$env:OLLAMA_HOST = $HostAddr
$env:OLLAMA_MODELS = $Store

function Get-LoadedPortableModels {
    $rows = @(& ollama ps 2>$null)
    $names = @()
    foreach ($row in $rows) {
        $line = ([string]$row).Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^NAME\s') { continue }
        $parts = $line -split '\s+'
        if ($parts.Count -ge 1) { $names += $parts[0] }
    }
    return $names
}

if ($Job -eq 'Unload') {
    Write-Host "[*] Unloading models from GPU on $HostAddr ..."
    $loaded = @(Get-LoadedPortableModels)
    if ($loaded.Count -eq 0) {
        Write-Host "[i] Nothing loaded."
        exit 0
    }
    foreach ($n in $loaded) {
        Write-Host "[*] ollama stop $n"
        & ollama stop $n
    }
    Write-Host "[+] GPU residency cleared (engine still running)."
    exit 0
}

if ($Job -eq 'RestartOllama') {
    Write-Host "[*] Stopping portable Ollama processes..."
    Get-Process -Name ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Write-Host "[*] Starting ollama serve on $HostAddr ..."
    $exe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $exe) { throw "ollama.exe not on PATH." }
    Start-Process -FilePath $exe -ArgumentList @('serve') -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Write-Host "[+] Portable engine restarted."
    exit 0
}

if ($Job -eq 'RestartExplorer') {
    Write-Host "[!] Restarting Windows Explorer (last-resort desktop VRAM)."
    & taskkill /f /im explorer.exe | Out-Null
    Start-Sleep -Seconds 2
    Start-Process explorer.exe
    Write-Host "[+] Explorer restarted."
    exit 0
}

Write-Host "clearvram.ps1 jobs: Unload | RestartOllama | RestartExplorer"
exit 1
